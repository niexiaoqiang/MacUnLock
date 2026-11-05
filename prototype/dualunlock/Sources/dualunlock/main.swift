import Foundation
import Security

let usage = """
dualunlock —— 解锁 MacBook 时自动解锁 Mac mini（原型）

两台都用：
  dualunlock init                  生成共享密钥（在第一台上运行）
  dualunlock init --secret <密钥>   导入共享密钥（在第二台上运行）
  dualunlock send <unlock|lock|ping> [--peer 主机名]
  dualunlock bench [--peer 主机名] [-n 次数] [--cmd ping|unlock]

Mac mini 上：
  dualunlock set-password           把登录密码存进钥匙串
  dualunlock status                 检查锁屏状态、辅助功能权限、钥匙串
  dualunlock serve [--dry-run]      启动服务端

MacBook 上：
  dualunlock watch [--peer 主机名]  监听本机锁屏/解锁并转发
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func loadConfig() -> Config {
    do { return try Config.load() } catch {
        print("找不到配置，请先运行 dualunlock init"); exit(1)
    }
}

func peer(_ c: Config) -> String {
    guard let p = option("--peer") ?? c.peer else { print("请用 --peer 指定 Mac mini 的主机名"); exit(1) }
    return p
}

switch args.first {
case "init":
    var key = Data(count: 32)
    if let s = option("--secret") {
        guard let d = Data(base64Encoded: s), d.count >= 32 else { print("密钥格式不对"); exit(1) }
        key = d
    } else {
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
    }
    var c = (try? Config.load()) ?? Config(secret: "")
    c.secret = key.base64EncodedString()
    if let p = option("--peer") { c.peer = p }
    try c.save()
    print("已写入 \(Config.path.path)")
    if option("--secret") == nil {
        print("在另一台 Mac 上运行：\n  dualunlock init --secret \(c.secret)")
    }

case "set-password":
    guard let p = getpass("Mac mini 登录密码（不会显示）："), let pw = String(validatingUTF8: p), !pw.isEmpty else { exit(1) }
    try Keychain.save(pw)
    print("已保存到登录钥匙串（服务名 \(Keychain.service)）")

case "status":
    print("屏幕已锁定：\(Session.isScreenLocked())")
    print("辅助功能权限：\(Session.hasAccessibility(prompt: true) ? "已授予" : "未授予（已弹出系统设置提示）")")
    print("钥匙串密码：\(Keychain.load() != nil ? "已保存" : "未保存")")

case "serve":
    try Server(config: loadConfig(), dryRun: args.contains("--dry-run")).run()

case "watch":
    let c = loadConfig()
    Watcher(config: c, peer: peer(c)).run()

case "send":
    let c = loadConfig()
    guard args.count > 1 else { print(usage); exit(1) }
    let (resp, ms) = try sendRequest(host: peer(c), port: c.port, cmd: args[1], key: c.key)
    print("\(resp.ok ? "成功" : "失败")：\(resp.msg)  往返 \(fmt(ms)) ms，服务端处理 \(fmt(resp.serverMs)) ms")

case "bench":
    let c = loadConfig()
    let n = Int(option("-n") ?? "50") ?? 50
    let cmd = option("--cmd") ?? "ping"
    var rtt: [Double] = [], srv: [Double] = []
    for _ in 0..<n {
        let (resp, ms) = try sendRequest(host: peer(c), port: c.port, cmd: cmd, key: c.key)
        guard resp.ok else { print("失败：\(resp.msg)"); exit(1) }
        rtt.append(ms); srv.append(resp.serverMs)
    }
    func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        return "最小 \(fmt(s.first!))  中位 \(fmt(s[s.count / 2]))  P95 \(fmt(s[min(s.count - 1, s.count * 95 / 100)]))  最大 \(fmt(s.last!)) ms"
    }
    print("\(cmd) × \(n)")
    print("  往返：  \(stats(rtt))")
    print("  服务端：\(stats(srv))")

default:
    print(usage)
}
