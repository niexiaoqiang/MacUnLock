import Foundation
import Security

/// 两台 Mac 共用的配置，保存在 ~/Library/Application Support/MacUnLock/config.json（权限 600）。
public struct Config: Codable, Equatable {
    public var secret: String = ""        // base64 编码的 32 字节共享密钥，两台必须一致
    public var port: UInt16 = 47800
    public var peer: String?              // 另一台 Mac 的主机名，例如 Mac-mini.local
    public var sendUnlock = true          // 本机解锁时，让对方也解锁
    public var sendLock = true            // 本机锁屏时，让对方也锁屏
    public var acceptUnlock = true        // 接受对方的解锁指令
    public var acceptLock = true          // 接受对方的锁屏指令
    public var paused = false
    public var unlockDelayMs = 600        // 唤醒屏幕后等待密码框出现的时间

    public init() {}

    // 逐项读取，缺失的字段用默认值，方便以后增加配置项
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? d.secret
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        peer = try c.decodeIfPresent(String.self, forKey: .peer)
        sendUnlock = try c.decodeIfPresent(Bool.self, forKey: .sendUnlock) ?? d.sendUnlock
        sendLock = try c.decodeIfPresent(Bool.self, forKey: .sendLock) ?? d.sendLock
        acceptUnlock = try c.decodeIfPresent(Bool.self, forKey: .acceptUnlock) ?? d.acceptUnlock
        acceptLock = try c.decodeIfPresent(Bool.self, forKey: .acceptLock) ?? d.acceptLock
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        unlockDelayMs = try c.decodeIfPresent(Int.self, forKey: .unlockDelayMs) ?? d.unlockDelayMs
    }

    public static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["MACUNLOCK_CONFIG_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacUnLock")
    }
    public static var path: URL { dir.appendingPathComponent("config.json") }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: path),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Config.path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.path.path)
    }

    public var key: Data? {
        guard let d = Data(base64Encoded: secret), d.count >= 32 else { return nil }
        return d
    }

    public var isPaired: Bool { key != nil && !(peer ?? "").isEmpty }

    public static func newSecret() -> String {
        var key = Data(count: 32)
        _ = key.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return key.base64EncodedString()
    }

    public static func isValidSecret(_ s: String) -> Bool {
        (Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines))?.count ?? 0) >= 32
    }
}
