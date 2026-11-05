import Foundation

/// MacBook 端：监听本机锁屏 / 解锁，把同样的动作转发给 Mac mini。
final class Watcher {
    let config: Config
    let peer: String
    let queue = DispatchQueue(label: "dualunlock.watch")

    init(config: Config, peer: String) {
        self.config = config
        self.peer = peer
    }

    func run() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [self] _ in
            forward("unlock")
        }
        center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: nil) { [self] _ in
            forward("lock")
        }
        log("正在监听本机锁屏/解锁，转发到 \(peer):\(config.port)")
        RunLoop.main.run()
    }

    /// 刚解锁时 Wi-Fi 可能还在恢复，失败后重试几次。
    private func forward(_ cmd: String) {
        queue.async { [self] in
            for attempt in 1...4 {
                do {
                    let (resp, ms) = try sendRequest(host: peer, port: config.port, cmd: cmd, key: config.key, timeout: 3)
                    log("\(cmd) → \(resp.ok ? "成功" : "失败")：\(resp.msg)（往返 \(fmt(ms)) ms，其中 Mac mini 处理 \(fmt(resp.serverMs)) ms）")
                    return
                } catch {
                    log("\(cmd) 第 \(attempt) 次发送失败：\(error.localizedDescription)")
                    sleep(1)
                }
            }
        }
    }
}

func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
