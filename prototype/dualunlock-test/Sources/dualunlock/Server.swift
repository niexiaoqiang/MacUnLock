import Foundation
import Network

/// Mac mini 端：监听局域网请求，执行解锁 / 锁屏。
final class Server {
    let config: Config
    let dryRun: Bool
    let guardian = ReplayGuard()
    let work = DispatchQueue(label: "dualunlock.work") // 串行执行，避免两次解锁交叉输入

    init(config: Config, dryRun: Bool) {
        self.config = config
        self.dryRun = dryRun
    }

    func run() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { log("监听端口 \(self.config.port)\(self.dryRun ? "（演练模式，不输入密码）" : "")") }
            if case .failed(let e) = state { log("监听失败：\(e)"); exit(1) }
        }
        listener.start(queue: .global())
        dispatchMain()
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        readLine(conn) { [self] data in
            let t0 = DispatchTime.now()
            var resp = Response(ok: false, msg: "", serverMs: 0)
            if let data, let req = try? JSONDecoder().decode(Request.self, from: data) {
                if let err = guardian.check(req, key: config.key) {
                    resp.msg = err
                    log("拒绝来自 \(conn.endpoint) 的请求：\(err)")
                } else {
                    resp = work.sync { execute(req.cmd) }
                }
            } else {
                resp.msg = "无法解析请求"
            }
            resp.serverMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            var out = (try? JSONEncoder().encode(resp)) ?? Data()
            out.append(0x0A)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func execute(_ cmd: String) -> Response {
        switch cmd {
        case "ping":
            return Response(ok: true, msg: "pong locked=\(Session.isScreenLocked())", serverMs: 0)
        case "lock":
            if !dryRun { Session.lockNow() }
            log("锁屏")
            return Response(ok: true, msg: "locked", serverMs: 0)
        case "unlock":
            return unlock()
        default:
            return Response(ok: false, msg: "未知命令 \(cmd)", serverMs: 0)
        }
    }

    private func unlock() -> Response {
        Session.wakeDisplay()
        // 安全关键：只有确实处于锁屏时才输入密码，否则密码可能被打进某个应用的输入框
        // 演练模式当作已锁屏，用来在未锁屏的机器上测完整流程的耗时
        guard dryRun || Session.isScreenLocked() else {
            log("收到解锁请求，屏幕本来就没锁，只唤醒显示器")
            return Response(ok: true, msg: "already unlocked (display woken)", serverMs: 0)
        }
        guard let pw = Keychain.load() ?? (dryRun ? "dry-run" : nil) else {
            return Response(ok: false, msg: "钥匙串中没有密码，请运行 dualunlock set-password", serverMs: 0)
        }
        guard dryRun || Session.hasAccessibility(prompt: false) else {
            return Response(ok: false, msg: "没有“辅助功能”权限", serverMs: 0)
        }
        usleep(useconds_t(config.unlockDelayMs * 1000))
        if dryRun {
            log("演练：将输入 \(pw.count) 个字符")
            return Response(ok: true, msg: "dry-run", serverMs: 0)
        }
        Session.typePassword(pw)
        // 等待解锁生效，最多 3 秒
        for _ in 0..<60 {
            if !Session.isScreenLocked() {
                log("解锁成功")
                return Response(ok: true, msg: "unlocked", serverMs: 0)
            }
            usleep(50_000)
        }
        log("已输入密码，但 3 秒内仍处于锁屏状态")
        return Response(ok: false, msg: "typed but still locked", serverMs: 0)
    }
}

func log(_ s: String) {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
    FileHandle.standardError.write("[\(f.string(from: Date()))] \(s)\n".data(using: .utf8)!)
}
