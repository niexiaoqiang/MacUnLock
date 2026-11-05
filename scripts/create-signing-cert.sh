#!/bin/zsh
# 创建 MacUnLock 专用的自签名代码签名证书。
#
# 证书放在独立的钥匙串 ~/.macunlock-signing/signing.keychain-db 里，
# 不导入登录钥匙串，也不修改系统的证书信任设置。
# 签名后 App 的身份 = 标识符 + 证书指纹，重新打包不会变，
# 因此“辅助功能”权限和钥匙串授权只需给一次。
#
# 只需在负责打包的那台 Mac 上运行一次。
set -euo pipefail

NAME="MacUnLock Local Signing"
DIR="$HOME/.macunlock-signing"
KC="$DIR/signing.keychain-db"

if [[ -f $KC ]]; then
  echo "签名钥匙串已存在：$KC"; exit 0
fi

mkdir -p "$DIR" && chmod 700 "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

KCPASS=$(openssl rand -hex 24)
P12PASS=$(openssl rand -hex 16)
print -r -- "$KCPASS" > "$DIR/keychain-password" && chmod 600 "$DIR/keychain-password"

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# OpenSSL 3 默认的 PKCS#12 加密方式 macOS 不认，需要 -legacy；LibreSSL 没有这个参数
openssl pkcs12 -legacy -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout "pass:$P12PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
       -out "$TMP/cert.p12" -passout "pass:$P12PASS"

security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"   # 不自动上锁
security unlock-keychain -p "$KCPASS" "$KC"
security import "$TMP/cert.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null

echo "已创建签名证书 “$NAME”"
echo "  钥匙串：$KC"
echo "  指纹：$(openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
echo "请备份 $DIR 文件夹：换电脑或重装系统后用同一个证书，权限就不用重新授予。"
