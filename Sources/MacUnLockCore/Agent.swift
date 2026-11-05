import Foundation
import Network

public struct AgentEvent: Identifiable {
    public enum Kind { case info, success, failure }
    public let id = UUID()
    public let date = Date()
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum PeerStatus: Equatable {
    case unconfigured
    case checking
    case online(ms: Double, locked: Bool?)
    case offline(String)
}

/// 双向代理：同时负责
/// - 监听：接收对方的 unlock / lock / ping 指令并执行
/// - 转发：本机锁屏或解锁时，把同样的动作发给对方
///
/// 防循环：执行了对方的指令后，本机随之产生的锁屏/解锁事件在短时间内不再转发回去。
public final class Agent {
    public var onEvent: ((AgentEvent) -> Void)?
    public var onPeerStatus: ((PeerStatus) -> Void)?
    public let dryRun: Bool

    private var config: Config
    private let stateLock = NSLock()
    private var suppressUntil: [String: Date] = [:]
    private let suppressWindow: TimeInterval = 5

    private var listener: NWListener?
    private var listenerPort: UInt16?
    private let guardian = ReplayGuard()
    private let work = DispatchQueue(label: "macunlock.work")       // 串行执行本机动作，避免两次输入交叉
    private let outgoing = DispatchQueue(label: "macunlock.outgoing") // 串行发送，保证锁/解锁顺序
    private var observers: [NSObjectProtocol] = []
    private var healthTimer: DispatchSourceTimer?

    public init(config: Config, dryRun: Bool = false) {
        self.config = config
        self.dryRun = dryRun
    }

    public var currentConfig: Config {
        stateLock.lock(); defer { stateLock.unlock() }
        return config
    }

    // MARK: - 生命周期

    public func start() {
        restartListenerIfNeeded()
        let center = DistributedNotificationCenter.default()
        // 测试时可用 MACUNLOCK_NOTIFY_PREFIX 换成自定义通知名，避免伪造系统通知
        let prefix = ProcessInfo.processInfo.environment["MACUNLOCK_NOTIFY_PREFIX"] ?? "com.apple"
        observers.append(center.addObserver(forName: .init("\(prefix).screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.localChanged("unlock")
        })
        observers.append(center.addObserver(forName: .init("\(prefix).screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.localChanged("lock")
        })
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 1, repeating: 30)
        t.setEventHandler { [weak self] in self?.checkPeer() }
        t.resume()
        healthTimer = t
    }

    public func stop() {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers.removeAll()
        healthTimer?.cancel()
        listener?.cancel()
        listener = nil
        listenerPort = nil
    }

    public func update(_ newConfig: Config) {
        stateLock.lock()
        config = newConfig
        stateLock.unlock()
        restartListenerIfNeeded()
        checkPeer()
    }

    private func restartListenerIfNeeded() {
        let port = currentConfig.port
        guard listenerPort != port else { return }
        listener?.cancel()
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.emit(.info, "正在监听端口 \(port)\(self?.dryRun == true ? "（演练模式）" : "")")
                case .failed(let e): self?.emit(.failure, "端口 \(port) 监听失败：\(friendlyMessage(e))")
                default: break
                }
            }
            l.start(queue: .global())
            listener = l
            listenerPort = port
        } catch {
            emit(.failure, "无法监听端口 \(port)：\(friendlyMessage(error))")
        }
    }

    // MARK: - 转发本机事件

    private func localChanged(_ cmd: String) {
        let c = currentConfig
        let label = cmd == "unlock" ? "解锁" : "锁屏"
        if isSuppressed(cmd) {  // 这次锁/解锁是对方触发的，不再转发回去
            emit(.info, "本机\(label)由对方触发，不再转发")
            return
        }
        guard !c.paused, cmd == "unlock" ? c.sendUnlock : c.sendLock, c.isPaired else { return }
        send(cmd, retries: 4) { [weak self] result in
            switch result {
            case .success(let (resp, ms)):
                self?.emit(resp.ok ? .success : .failure,
                           "本机\(label) → 对方：\(resp.msg)（\(Self.fmt(ms)) ms）")
            case .failure(let e):
                self?.emit(.failure, "本机\(label) → 对方失败：\(friendlyMessage(e))")
            }
        }
    }

    /// 给对方发指令。刚解锁时 Wi-Fi 可能还在恢复，失败会按 1 秒间隔重试。
    public func send(_ cmd: String, retries: Int = 1,
                     completion: ((Result<(Response, Double), Error>) -> Void)? = nil) {
        let c = currentConfig
        guard let key = c.key, let peer = c.peer, !peer.isEmpty else {
            completion?(.failure(WireError("还没有配置对方主机名或密钥")))
            return
        }
        outgoing.async {
            var last: Error = WireError("未发送")
            for attempt in 1...max(1, retries) {
                do {
                    let r = try sendRequest(host: peer, port: c.port, cmd: cmd, key: key, timeout: 3)
                    completion?(.success(r))
                    return
                } catch {
                    last = error
                    if attempt < retries { sleep(1) }
                }
            }
            completion?(.failure(last))
        }
    }

    public func checkPeer() {
        guard currentConfig.isPaired else { onPeerStatus?(.unconfigured); return }
        send("ping") { [weak self] result in
            switch result {
            case .success(let (resp, ms)):
                self?.onPeerStatus?(resp.ok ? .online(ms: ms, locked: resp.locked) : .offline(resp.msg))
            case .failure(let e):
                self?.onPeerStatus?(.offline(friendlyMessage(e)))
            }
        }
    }

    /// 同时锁定两台：先通知对方，再锁本机。
    public func lockBoth() {
        send("lock") { [weak self] _ in
            DispatchQueue.main.async {
                self?.suppress("lock")
                Session.lockNow()
            }
        }
    }

    // MARK: - 执行对方的指令

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        readLine(conn) { [self] data in
            let t0 = DispatchTime.now()
            var resp = Response(ok: false, msg: "无法解析请求")
            if let data, let req = try? JSONDecoder().decode(Request.self, from: data) {
                if let key = currentConfig.key {
                    if let err = guardian.check(req, key: key) {
                        resp.msg = err
                        emit(.failure, "拒绝来自 \(conn.endpoint) 的请求：\(err)")
                    } else {
                        resp = work.sync { execute(req.cmd) }
                    }
                } else {
                    resp.msg = "本机还没有配置密钥"
                }
            }
            resp.serverMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            if resp.locked == nil { resp.locked = Session.isScreenLocked() }
            var out = (try? JSONEncoder().encode(resp)) ?? Data()
            out.append(0x0A)
            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func execute(_ cmd: String) -> Response {
        let c = currentConfig
        switch cmd {
        case "ping":
            return Response(ok: true, msg: "pong")
        case "lock":
            guard !c.paused, c.acceptLock else { return Response(ok: false, msg: "对方已暂停或不接受锁屏") }
            if Session.isScreenLocked() { return Response(ok: true, msg: "本来就已锁屏") }
            suppress("lock")
            if !dryRun { Session.lockNow() }
            emit(.success, "对方锁屏 → 本机已锁屏")
            return Response(ok: true, msg: "已锁屏", locked: true)
        case "unlock":
            guard !c.paused, c.acceptUnlock else { return Response(ok: false, msg: "对方已暂停或不接受解锁") }
            return unlock(c)
        default:
            return Response(ok: false, msg: "未知命令 \(cmd)")
        }
    }

    private func unlock(_ c: Config) -> Response {
        Session.wakeDisplay()
        // 安全关键：只有确实处于锁屏时才输入密码，否则密码可能被打进某个应用的输入框
        guard dryRun || Session.isScreenLocked() else {
            return Response(ok: true, msg: "本来就未锁屏（已点亮屏幕）", locked: false)
        }
        guard let pw = Keychain.load() ?? (dryRun ? "dry-run" : nil) else {
            emit(.failure, "收到解锁指令，但钥匙串里没有保存登录密码")
            return Response(ok: false, msg: "对方没有保存登录密码")
        }
        guard dryRun || Session.hasAccessibility(prompt: false) else {
            emit(.failure, "收到解锁指令，但没有“辅助功能”权限")
            return Response(ok: false, msg: "对方没有辅助功能权限")
        }
        usleep(useconds_t(max(0, c.unlockDelayMs) * 1000))
        // 再确认一次：等待期间用户可能已经手动解锁
        guard dryRun || Session.isScreenLocked() else {
            return Response(ok: true, msg: "等待期间已被解锁", locked: false)
        }
        suppress("unlock")
        if dryRun {
            emit(.info, "演练：将输入 \(pw.count) 个字符")
            return Response(ok: true, msg: "演练完成")
        }
        Session.typePassword(pw)
        for _ in 0..<60 where Session.isScreenLocked() { usleep(50_000) }  // 最多等 3 秒
        if Session.isScreenLocked() {
            emit(.failure, "对方解锁 → 已输入密码，但 3 秒内仍在锁屏（密码是否已改？）")
            return Response(ok: false, msg: "已输入密码但仍在锁屏", locked: true)
        }
        emit(.success, "对方解锁 → 本机已解锁")
        return Response(ok: true, msg: "已解锁", locked: false)
    }

    // MARK: - 工具

    private func suppress(_ cmd: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        suppressUntil[cmd] = Date().addingTimeInterval(suppressWindow)
    }

    private func isSuppressed(_ cmd: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let until = suppressUntil[cmd], until > Date() else { return false }
        suppressUntil[cmd] = nil  // 只吞掉一次
        return true
    }

    private func emit(_ kind: AgentEvent.Kind, _ text: String) {
        onEvent?(AgentEvent(kind: kind, text: text))
    }

    public static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
}
