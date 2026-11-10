import Foundation
import AppKit
import ServiceManagement
import MacUnLockCore

/// 菜单栏和设置窗口共用的状态，包装 Agent。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var peer: PeerStatus = .unconfigured
    @Published private(set) var events: [AgentEvent] = []
    @Published private(set) var hasAccessibility = false
    @Published private(set) var hasPassword = false
    @Published private(set) var launchAtLogin = false

    let agent: Agent
    let hostName = ProcessInfo.processInfo.hostName

    init() {
        var c = Config.load()
        if c.key == nil {  // 第一次运行：先生成一个密钥，配对时再决定用哪台的
            c.secret = Config.newSecret()
            try? c.save()
        }
        config = c
        agent = Agent(config: c)
        agent.onEvent = { [weak self] e in Task { @MainActor in self?.append(e) } }
        agent.onPeerStatus = { [weak self] s in Task { @MainActor in self?.setPeer(s) } }
        agent.start()
        refreshChecks()
    }

    // MARK: - 配置

    func update(_ change: (inout Config) -> Void) {
        var c = config
        change(&c)
        guard c != config else { return }
        config = c
        do { try c.save() } catch { append(AgentEvent(kind: .failure, text: "保存配置失败：\(error.localizedDescription)")) }
        agent.update(c)
    }

    func copySecret() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.secret, forType: .string)
    }

    /// 从剪贴板导入对方的密钥。返回是否成功。
    func pasteSecret() -> Bool {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              Config.isValidSecret(s) else { return false }
        update { $0.secret = s }
        return true
    }

    // MARK: - 本机条件

    /// 完整检查：打开设置窗口或修改设置后调用一次。
    func refreshChecks() {
        refreshAccessibility()
        let pw = Keychain.exists()
        if pw != hasPassword { hasPassword = pw }
        let login = SMAppService.mainApp.status == .enabled
        if login != launchAtLogin { launchAtLogin = login }
    }

    /// 轻量检查：等待用户去系统设置授权时轮询。只在值变化时才触发界面刷新。
    func refreshAccessibility() {
        let ax = Session.hasAccessibility(prompt: false)
        if ax != hasAccessibility { hasAccessibility = ax }
    }

    func requestAccessibility() {
        _ = Session.hasAccessibility(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func savePassword(_ pw: String) {
        do {
            try Keychain.save(pw)
            append(AgentEvent(kind: .success, text: "登录密码已保存到钥匙串"))
        } catch {
            append(AgentEvent(kind: .failure, text: "保存密码失败：\(error.localizedDescription)"))
        }
        refreshChecks()
    }

    func deletePassword() {
        Keychain.delete()
        refreshChecks()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            append(AgentEvent(kind: .failure, text: "设置开机启动失败：\(error.localizedDescription)（需要从“应用程序”文件夹运行打包好的 App）"))
        }
        refreshChecks()
    }

    // MARK: - 动作

    func checkPeer() {
        peer = config.isPaired ? .checking : .unconfigured
        agent.checkPeer()
    }

    /// 每 30 秒的检测结果大多只是延迟毫秒数不同。只有在线/离线、锁屏状态等真正变化时才更新，
    /// 避免界面无谓地重绘。
    private func setPeer(_ s: PeerStatus) {
        if case .online(_, let was) = peer, case .online(_, let now) = s, was == now { return }
        if s != peer { peer = s }
    }

    func lockBoth() { agent.lockBoth() }

    func sendToPeer(_ cmd: String) {
        agent.send(cmd) { [weak self] result in
            let e: AgentEvent
            switch result {
            case .success(let (resp, ms)): e = AgentEvent(kind: resp.ok ? .success : .failure, text: "手动 \(cmd) → \(resp.msg)（\(Agent.fmt(ms)) ms）")
            case .failure(let err): e = AgentEvent(kind: .failure, text: "手动 \(cmd) 失败：\(friendlyMessage(err))")
            }
            Task { @MainActor in self?.append(e) }
        }
    }

    private func append(_ e: AgentEvent) {
        events.insert(e, at: 0)
        if events.count > 50 { events.removeLast(events.count - 50) }
    }

    // MARK: - 展示

    var statusSymbol: String {
        if config.paused { return "pause.circle" }
        switch peer {
        case .online: return "lock.display"
        case .unconfigured, .offline: return "exclamationmark.lock"
        case .checking: return "lock.display"
        }
    }

    var peerText: String {
        switch peer {
        case .unconfigured: return "还没有配对另一台 Mac"
        case .checking: return "正在连接 \(config.peer ?? "")…"
        case .online(_, let locked):  // 菜单里不显示延迟：它只在状态变化时更新，数值会过时
            let state = locked == true ? " · 已锁屏" : locked == false ? " · 已解锁" : ""
            return "\(config.peer ?? "") 在线\(state)"
        case .offline(let why): return "\(config.peer ?? "") 离线：\(why)"
        }
    }

    /// 设置窗口里用的简短版本（主机名已在上一行显示）
    var peerShortText: String {
        switch peer {
        case .unconfigured: return "未配对"
        case .checking: return "正在连接…"
        case .online(let ms, let locked):
            let state = locked == true ? " · 已锁屏" : locked == false ? " · 已解锁" : ""
            return "在线\(state) · \(Agent.fmt(ms)) ms"
        case .offline(let why): return "离线：\(why)"
        }
    }

    /// 本机能否被对方解锁
    var readyToBeUnlocked: Bool { hasAccessibility && hasPassword }
}
