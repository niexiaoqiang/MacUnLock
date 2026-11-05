import Foundation
import MacUnLockCore

let usage = """
dualunlock —— MacUnLock 的命令行工具（与菜单栏 App 共用配置）

  dualunlock init [--secret <密钥>] [--peer <对方主机名>]   生成或导入共享密钥、设置对方
  dualunlock set-password                                  把本机登录密码存进钥匙串
  dualunlock status                                        查看配置、权限、对方是否在线
  dualunlock run [--dry-run]                               无界面运行（双向：监听 + 转发）
  dualunlock send <unlock|lock|ping>                       手动给对方发指令
  dualunlock bench [-n 次数] [--cmd ping|unlock]           测量延迟

配置文件：\(Config.path.path)
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func requirePaired() -> Config {
    let c = Config.load()
    guard c.isPaired else { print("还没配置好，请先运行 dualunlock init --peer <对方主机名>"); exit(1) }
    return c
}

func fmt(_ v: Double) -> String { Agent.fmt(v) }

switch args.first {
case "init":
    var c = Config.load()
    if let s = option("--secret") {
        guard Config.isValidSecret(s) else { print("密钥格式不对"); exit(1) }
        c.secret = s.trimmingCharacters(in: .whitespacesAndNewlines)
    } else if c.key == nil || args.contains("--new") {
        c.secret = Config.newSecret()
    }
    if let p = option("--peer") { c.peer = p }
    try c.save()
    print("已写入 \(Config.path.path)")
    if option("--secret") == nil {
        print("在另一台 Mac 上运行：\n  dualunlock init --secret \(c.secret) --peer \(ProcessInfo.processInfo.hostName)")
    }

case "set-password":
    guard let p = getpass("本机登录密码（不会显示）："), let pw = String(validatingUTF8: p), !pw.isEmpty else { exit(1) }
    try Keychain.save(pw)
    print("已保存到登录钥匙串")

case "status":
    let c = Config.load()
    print("本机主机名：\(ProcessInfo.processInfo.hostName)")
    print("对方主机名：\(c.peer ?? "未设置")  端口：\(c.port)")
    print("共享密钥：\(c.key != nil ? "已配置" : "未配置")")
    print("屏幕已锁定：\(Session.isScreenLocked())")
    print("辅助功能权限：\(Session.hasAccessibility(prompt: false) ? "已授予" : "未授予")")
    print("钥匙串密码：\(Keychain.load() != nil ? "已保存" : "未保存")")
    if c.isPaired, let key = c.key {
        do {
            let (resp, ms) = try sendRequest(host: c.peer!, port: c.port, cmd: "ping", key: key, timeout: 3)
            print("对方：\(resp.ok ? "在线" : resp.msg)（\(fmt(ms)) ms，锁屏=\(resp.locked.map(String.init(describing:)) ?? "?")）")
        } catch {
            print("对方：离线（\(friendlyMessage(error))）")
        }
    }

case "run":
    let agent = Agent(config: Config.load(), dryRun: args.contains("--dry-run"))
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    agent.onEvent = { e in
        let mark = e.kind == .failure ? "✗" : e.kind == .success ? "✓" : "·"
        FileHandle.standardError.write("[\(df.string(from: e.date))] \(mark) \(e.text)\n".data(using: .utf8)!)
    }
    agent.start()
    RunLoop.main.run()

case "send":
    let c = requirePaired()
    guard args.count > 1 else { print(usage); exit(1) }
    let (resp, ms) = try sendRequest(host: c.peer!, port: c.port, cmd: args[1], key: c.key!)
    print("\(resp.ok ? "成功" : "失败")：\(resp.msg)  往返 \(fmt(ms)) ms，对方处理 \(fmt(resp.serverMs)) ms")

case "bench":
    let c = requirePaired()
    let n = Int(option("-n") ?? "50") ?? 50
    let cmd = option("--cmd") ?? "ping"
    var rtt: [Double] = [], srv: [Double] = []
    for _ in 0..<n {
        let (resp, ms) = try sendRequest(host: c.peer!, port: c.port, cmd: cmd, key: c.key!)
        guard resp.ok else { print("失败：\(resp.msg)"); exit(1) }
        rtt.append(ms); srv.append(resp.serverMs)
    }
    func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        return "最小 \(fmt(s.first!))  中位 \(fmt(s[s.count / 2]))  P95 \(fmt(s[min(s.count - 1, s.count * 95 / 100)]))  最大 \(fmt(s.last!)) ms"
    }
    print("\(cmd) × \(n)")
    print("  往返：    \(stats(rtt))")
    print("  对方处理：\(stats(srv))")

default:
    print(usage)
}
