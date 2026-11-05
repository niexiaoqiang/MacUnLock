# dualunlock（原型）

用触控 ID 解锁 MacBook 时，Mac mini 自动唤醒并解锁；MacBook 锁屏时，Mac mini 也跟着锁屏。

```
MacBook (watch)  ──局域网 TCP，HMAC 签名──▶  Mac mini (serve)
监听 com.apple.screenIsUnlocked / Locked       唤醒屏幕 → 确认处于锁屏 → 输入钥匙串里的密码
```

## 安装与测试

**1. 两台都要**：拷贝这个文件夹，然后在终端进入该目录。

**2. Mac mini 上**：

```bash
swift build -c release && .build/release/dualunlock init
```

记下输出里的 `--secret`，然后：

```bash
.build/release/dualunlock set-password
```

```bash
./install.sh serve
```

再到 **系统设置 → 隐私与安全性 → 辅助功能**，允许 `~/Applications/dualunlock/dualunlock`。

最后执行 `~/Applications/dualunlock/dualunlock status`，确认三项都正常。第一次读取钥匙串时如果有弹窗，选「始终允许」。

**3. MacBook 上**：

```bash
swift build -c release && .build/release/dualunlock init --secret <上一步的密钥> --peer Mac-mini.local
```

```bash
.build/release/dualunlock send ping
```

```bash
./install.sh watch
```

**4. 实测**：先锁 MacBook，确认 Mac mini 跟着锁屏；再用触控 ID 解锁 MacBook，看 Mac mini 是否自动解锁。日志在两台的 `~/Library/Logs/dualunlock-*.log`。

卸载：`./install.sh uninstall`

## 技术可行性

| 环节 | 实现方式 | 状态 |
|---|---|---|
| 感知 MacBook 解锁/锁屏 | `DistributedNotificationCenter` 的 `com.apple.screenIsUnlocked` / `screenIsLocked` | 业界常用方式，Hammerspoon 等工具都在用 |
| 局域网通信与鉴权 | TCP + HMAC-SHA256 + 时间戳 ±15s + nonce 防重放 | ✅ 已测试，错误密钥会被拒 |
| 唤醒 Mac mini 屏幕 | `IOPMAssertionDeclareUserActivity`（等同 `caffeinate -u`） | 公开 API |
| 判断是否锁屏 | `CGSessionCopyCurrentDictionary` 的 `CGSSessionScreenIsLocked` | 未公开但长期可用的键；**只有锁屏时才输入密码** |
| 输入密码（方案 A） | `CGEvent` 逐字符输入，需“辅助功能”权限 | Unlox 也是这个思路；**需要在 Mac mini 锁屏状态下实测** |
| 输入密码（方案 B，备选） | Karabiner DriverKit 虚拟 HID 键盘，系统视为真实键盘 | 官方文档确认可在登录界面输入；需要 root 和 C++ 客户端，原型未实现 |
| 锁屏 | 私有 `SACLockScreenImmediate`，失败时回退到 `pmset displaysleepnow` | 常见做法 |

**主要风险**

1. 方案 A 在 macOS 27 锁屏界面的可用性还没有实测。如果失败，就改用方案 B。
2. Mac mini **不能进入系统睡眠**，只允许显示器关闭，否则收不到请求。可以考虑加网络唤醒，需要有线网络。
3. 每次重新编译，二进制签名都会变化，要重新授予“辅助功能”权限和钥匙串访问。正式版需要固定签名。
4. 开启 FileVault 后，**重启后的第一次登录**无法用这个方式完成。它只能处理日常锁屏。

## 性能（本机回环实测，Apple 芯片，macOS 27.0.1）

| 指标 | 结果 |
|---|---|
| ping 往返（200 次） | 中位 0.8 ms，P95 4.3 ms |
| 解锁流程服务端耗时（演练，含 600 ms 等待） | 中位 609 ms |
| 服务端常驻内存 / CPU | 约 17 MB / 空闲时接近 0% |

在真实局域网中，Wi-Fi 一般会增加 2–20 ms。MacBook 刚解锁时，Wi-Fi 可能还在恢复，所以代码里有重试，最多 4 次，每次间隔 1 秒。预计从按下指纹到 Mac mini 解锁，总耗时约 **0.7–1.5 秒**，主要来自等待密码框出现的 600 ms，可以通过 `unlockDelayMs` 调整。

## 安全说明

- Mac mini 的登录密码只保存在 **Mac mini 自己的钥匙串**里，不会经过网络传输；网络上只传带签名的“解锁”指令。
- 共享密钥保存在 `~/.config/dualunlock/config.json`，权限 600。
- 实际效果是：**能解锁你 MacBook 的人，也能解锁 Mac mini**。
