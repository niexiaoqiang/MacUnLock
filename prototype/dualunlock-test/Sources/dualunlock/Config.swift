import Foundation

/// 两台 Mac 共用的配置，保存在 ~/.config/dualunlock/config.json（权限 600）。
struct Config: Codable {
    var secret: String          // base64 编码的 32 字节共享密钥
    var port: UInt16 = 47800
    var peer: String?           // MacBook 端填写 Mac mini 的主机名，例如 Mac-mini.local
    var unlockDelayMs: Int = 600 // 唤醒屏幕后等待密码框出现的时间

    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["DUALUNLOCK_CONFIG_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dualunlock")
    }
    static var path: URL { dir.appendingPathComponent("config.json") }

    static func load() throws -> Config {
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Config.path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.path.path)
    }

    var key: Data {
        guard let d = Data(base64Encoded: secret), d.count >= 32 else {
            fatalError("config.json 中的 secret 无效，请重新运行 dualunlock init")
        }
        return d
    }
}
