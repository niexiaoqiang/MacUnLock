#!/bin/zsh
# 打包 MacUnLock.app（Intel + Apple 芯片通用），输出到 dist/
#
# 签名身份按以下顺序选择：
#   1. 环境变量 MACUNLOCK_SIGN_ID
#   2. ~/.macunlock-signing 里的 “MacUnLock Local Signing” 自签名证书（scripts/create-signing-cert.sh 生成）
#   3. 钥匙串里的 “Apple Development” 证书（Xcode 登录 Apple ID 后免费获得）
#   4. 临时签名（每次重新打包都要重新授予辅助功能权限）
# 一旦选定就不要再换，换了签名身份需要重新授权。
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-1.0.0}
BUNDLE_ID=com.nie.macunlock
APP=dist/MacUnLock.app

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacUnLock" "$APP/Contents/MacOS/MacUnLock"
cp "$BIN/dualunlock" "$APP/Contents/MacOS/dualunlock"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>MacUnLock</string>
  <key>CFBundleDisplayName</key><string>MacUnLock</string>
  <key>CFBundleExecutable</key><string>MacUnLock</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Personal use</string>
</dict></plist>
EOF

SIGN_KC="$HOME/.macunlock-signing/signing.keychain-db"
KC_ARGS=()
if [[ -n ${MACUNLOCK_SIGN_ID:-} ]]; then
  ID=$MACUNLOCK_SIGN_ID
elif [[ -f $SIGN_KC ]]; then
  security unlock-keychain -p "$(<"$HOME/.macunlock-signing/keychain-password")" "$SIGN_KC"
  ID="MacUnLock Local Signing"
  KC_ARGS=(--keychain "$SIGN_KC")
else
  ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
  [[ -z $ID ]] && ID="-"
fi

codesign --force "${KC_ARGS[@]}" --sign "$ID" --identifier "$BUNDLE_ID.cli" "$APP/Contents/MacOS/dualunlock"
codesign --force "${KC_ARGS[@]}" --sign "$ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

rm -f dist/MacUnLock.zip
ditto -c -k --keepParent "$APP" dist/MacUnLock.zip

echo
echo "完成：$APP 和 dist/MacUnLock.zip"
if [[ $ID == "-" ]]; then
  echo "⚠️  使用的是临时签名：每次重新打包后都要在“辅助功能”里重新授权。"
  echo "    建议运行 scripts/create-signing-cert.sh，或在 Xcode 里登录 Apple ID。"
else
  echo "签名身份：$ID"
fi
