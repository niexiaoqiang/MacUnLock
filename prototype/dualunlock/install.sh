#!/bin/zsh
# 用法：./install.sh serve   （Mac mini 上）
#       ./install.sh watch   （MacBook 上）
#       ./install.sh uninstall
set -e
ROLE=$1
DEST="$HOME/Applications/dualunlock"
LABEL="com.dualunlock.$ROLE"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ $ROLE == uninstall ]]; then
  for r in serve watch; do
    launchctl bootout gui/$UID/com.dualunlock.$r 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.dualunlock.$r.plist"
  done
  echo "已卸载后台服务（配置和钥匙串密码保留）"; exit 0
fi
[[ $ROLE == serve || $ROLE == watch ]] || { echo "用法：$0 serve|watch|uninstall"; exit 1; }

cd "${0:A:h}"
swift build -c release
mkdir -p "$DEST"
cp .build/release/dualunlock "$DEST/dualunlock"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/dualunlock</string><string>$ROLE</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/dualunlock-$ROLE.log</string>
</dict></plist>
EOF
launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
launchctl bootstrap gui/$UID "$PLIST"
echo "已安装并启动 $LABEL，日志：~/Library/Logs/dualunlock-$ROLE.log"
[[ $ROLE == serve ]] && echo "别忘了在 系统设置 → 隐私与安全性 → 辅助功能 中允许 $DEST/dualunlock"
