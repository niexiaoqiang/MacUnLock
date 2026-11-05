// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacUnLock",
    platforms: [.macOS(.v13)],
    targets: [
        // 两台 Mac 共用的核心：配置、通信协议、锁屏操作、双向代理
        .target(name: "MacUnLockCore"),
        // 菜单栏 App（正式使用）
        .executableTarget(name: "MacUnLock", dependencies: ["MacUnLockCore"]),
        // 命令行工具（调试、测速、无界面运行）
        .executableTarget(name: "dualunlock", dependencies: ["MacUnLockCore"])
    ]
)
