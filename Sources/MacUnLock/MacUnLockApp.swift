import SwiftUI
import MacUnLockCore

@main
struct MacUnLockApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)  // 只在菜单栏显示，不占程序坞
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Self.snapshotSettings(to: CommandLine.arguments[i + 1])
        }
    }

    /// 开发用：把设置窗口渲染成 PNG 后退出，用来检查布局。
    @MainActor
    static func snapshotSettings(to path: String) {
        let view = SettingsView(height: 1500).environmentObject(AppModel())
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 1500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.statusSymbol)
        }
        .menuBarExtraStyle(.menu)

        Window("MacUnLock 设置", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.peerText)
        if !model.readyToBeUnlocked {
            Text("⚠️ 本机还不能被对方解锁，请在设置中完成")
        }
        Divider()

        Button("立即锁定两台 Mac") { model.lockBoth() }
            .keyboardShortcut("l", modifiers: [.control, .option, .command])
        Toggle("暂停联动", isOn: Binding(get: { model.config.paused },
                                       set: { v in model.update { $0.paused = v } }))
        Divider()

        Toggle("本机解锁时，解锁对方", isOn: Binding(get: { model.config.sendUnlock },
                                              set: { v in model.update { $0.sendUnlock = v } }))
        Toggle("本机锁屏时，锁定对方", isOn: Binding(get: { model.config.sendLock },
                                              set: { v in model.update { $0.sendLock = v } }))
        Divider()

        if !model.events.isEmpty {
            Menu("最近记录") {
                ForEach(model.events.prefix(10)) { e in
                    Text("\(e.date.formatted(date: .omitted, time: .standard))  \(e.text)")
                }
            }
        }
        Button("设置…") {
            model.refreshChecks()
            model.checkPeer()
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")
        Button("退出 MacUnLock") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
