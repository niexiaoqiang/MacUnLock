import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import ApplicationServices
import Security

/// 对本机会话的操作：判断锁屏、唤醒屏幕、输入密码、锁屏。
public enum Session {
    public static func isScreenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        if let n = d["CGSSessionScreenIsLocked"] as? Int { return n != 0 }
        return false
    }

    /// 模拟一次“用户活动”，点亮显示器（等价于 caffeinate -u）。
    public static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("MacUnLock" as CFString, kIOPMUserActiveLocal, &id)
        // 持有 2 秒后释放，避免屏幕刚亮又熄
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { IOPMAssertionRelease(id) }
    }

    public static func hasAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 通过 CGEvent 逐字符输入密码并回车（需要“辅助功能”权限）。
    static func typePassword(_ password: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        for unit in password.utf16 {
            var u = unit
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)!
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                e.post(tap: .cghidEventTap)
            }
            usleep(8_000)
        }
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)!.post(tap: .cghidEventTap) // Return
        }
    }

    /// 立即锁屏：优先用系统私有接口 SACLockScreenImmediate，失败则让显示器睡眠。
    public static func lockNow() {
        typealias Fn = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let h = dlopen(path, RTLD_NOW), let sym = dlsym(h, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: Fn.self)()
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["displaysleepnow"]
            try? p.run()
        }
    }
}

/// 登录密码存在本机“登录”钥匙串里，只由 MacUnLock 自己读写，从不经过网络。
public enum Keychain {
    static let service = "MacUnLock"

    public static func save(_ password: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: NSUserName()]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }

    public static func load() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: NSUserName(),
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 只检查是否存在，不读取密码内容。
    public static func exists() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: NSUserName(),
                                kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: NSUserName()] as CFDictionary)
    }
}
