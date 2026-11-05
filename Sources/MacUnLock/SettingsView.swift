import SwiftUI
import MacUnLockCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var height: CGFloat = 640
    @State private var peerDraft = ""
    @State private var portDraft = ""
    @State private var password = ""
    @State private var secretNote = ""
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("本机主机名") {
                    HStack {
                        Text(model.hostName).textSelection(.enabled)
                        Button("复制") { copy(model.hostName) }
                    }
                }
                LabeledContent("另一台 Mac") {
                    TextField("", text: $peerDraft, prompt: Text("例如 Mac-mini.local"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 240)
                        .onSubmit(applyPeer)
                }
                LabeledContent("端口") {
                    TextField("", text: $portDraft, prompt: Text("47800"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .onSubmit(applyPeer)
                }
                LabeledContent("共享密钥") {
                    HStack {
                        Text(model.config.key != nil ? "已配置" : "无效").foregroundStyle(.secondary)
                        Button("复制") { model.copySecret(); secretNote = "已复制，到另一台 Mac 上点“粘贴”" }
                        Button("粘贴") { secretNote = model.pasteSecret() ? "已导入" : "剪贴板里不是有效的密钥" }
                        Button("重新生成") { model.update { $0.secret = Config.newSecret() }; secretNote = "已生成新密钥，记得同步到另一台" }
                    }
                }
                if !secretNote.isEmpty {
                    Text(secretNote).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("连接状态") {
                    HStack {
                        Text(model.peerShortText)
                            .foregroundStyle(peerColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.peerText)
                        Button("测试") { applyPeer(); model.checkPeer() }
                    }
                }
            } header: {
                Text("配对")
            } footer: {
                Text("两台 Mac 的共享密钥必须一致：在一台上点“复制”，通过信息、备忘录等方式发到另一台，再点“粘贴”。")
            }

            Section("联动") {
                Toggle("本机解锁时，自动解锁另一台", isOn: bind(\.sendUnlock))
                Toggle("本机锁屏时，自动锁定另一台", isOn: bind(\.sendLock))
                Toggle("允许另一台解锁本机", isOn: bind(\.acceptUnlock))
                Toggle("允许另一台锁定本机", isOn: bind(\.acceptLock))
                Stepper(value: bind(\.unlockDelayMs), in: 200...3000, step: 100) {
                    Text("唤醒后等待 \(model.config.unlockDelayMs) ms 再输入密码")
                }
            }

            Section {
                LabeledContent("辅助功能权限") {
                    HStack {
                        status(model.hasAccessibility, ok: "已授予", bad: "未授予")
                        if !model.hasAccessibility { Button("去授权") { model.requestAccessibility() } }
                    }
                }
                LabeledContent("登录密码") {
                    HStack {
                        status(model.hasPassword, ok: "已保存", bad: "未保存")
                        if model.hasPassword { Button("删除") { model.deletePassword() } }
                    }
                }
                LabeledContent(model.hasPassword ? "更新密码" : "保存密码") {
                    HStack {
                        SecureField("", text: $password, prompt: Text("本机登录密码"))
                            .labelsHidden()
                            .frame(width: 200)
                            .onSubmit(savePassword)
                        Button("保存", action: savePassword).disabled(password.isEmpty)
                    }
                }
            } header: {
                Text("让另一台能解锁本机")
            } footer: {
                Text("密码只保存在本机钥匙串中，从不经过网络。只有本机确实处于锁屏状态时才会输入。")
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: Binding(get: { model.launchAtLogin },
                                                  set: { model.setLaunchAtLogin($0) }))
            }

            Section("最近记录") {
                if model.events.isEmpty {
                    Text("暂无").foregroundStyle(.secondary)
                }
                ForEach(model.events.prefix(15)) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.date.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(e.text).foregroundStyle(e.kind == .failure ? .red : .primary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: height)
        .onAppear {
            peerDraft = model.config.peer ?? ""
            portDraft = String(model.config.port)
            model.refreshChecks()
        }
        .onReceive(tick) { _ in
            // 只在等待辅助功能授权时轮询，授权后不再做任何事
            if !model.hasAccessibility { model.refreshAccessibility() }
        }
    }

    private var peerColor: Color {
        switch model.peer {
        case .online: return .green
        case .offline: return .red
        default: return .secondary
        }
    }

    private func bind<T>(_ kp: WritableKeyPath<Config, T>) -> Binding<T> where T: Equatable {
        Binding(get: { model.config[keyPath: kp] }, set: { v in model.update { $0[keyPath: kp] = v } })
    }

    private func status(_ ok: Bool, ok okText: String, bad: String) -> some View {
        Label(ok ? okText : bad, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }

    private func applyPeer() {
        let host = peerDraft.trimmingCharacters(in: .whitespaces)
        let port = UInt16(portDraft) ?? model.config.port
        model.update { $0.peer = host.isEmpty ? nil : host; $0.port = port }
        portDraft = String(port)
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        model.savePassword(password)
        password = ""
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
