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
    }
}

/// 设置窗口：自己管理 NSWindow，关闭时释放里面的 SwiftUI 视图。
///
/// 不用 SwiftUI 的 Window 场景，是因为它关闭时只隐藏窗口：SettingsView 仍然活着，
/// 每次对方状态更新都会在后台重新布局，而 SwiftUI 每次布局都会留下一组释放不掉的观察记录，
/// 内存一直上涨（macOS 27 上实测每天约 35 MB）。
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(model))
            let w = NSWindow(contentViewController: host)
            w.title = "MacUnLock 设置"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("MacUnLockSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        window = nil
        w.delegate = nil
        // 等关闭流程走完再拆掉视图，之后它不会再收到任何状态更新
        DispatchQueue.main.async { w.contentViewController = nil }
    }
}

struct MenuView: View {
    @EnvironmentObject var model: AppModel

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
            SettingsWindow.shared.show(model: model)
        }
        .keyboardShortcut(",")
        Button("退出 MacUnLock") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
