#!/bin/bash
# 自签证书签名：证书身份稳定 → TCC（辅助功能权限）跨重编译不反复弹窗。
# 首次运行自动创建自签证书 jiantieban-dev 并导入登录钥匙串（-A 免逐次授权）。
#
# 踩坑记录（2026-08 实测）：
# - openssl3 默认 PKCS12 (AES) → security import 报 MAC verification failed
# - openssl3 -legacy PKCS12 (RC2) → 私钥被静默丢弃，只导入证书
# - 私钥必须转 traditional (PKCS1) PEM 单独导入，PKCS8 PEM 报 Unknown format
# - 证书必须带 codeSigning EKU，否则 codesign 不认
set -euo pipefail
cd "$(dirname "$0")/.."

CERT_NAME="jiantieban-dev"
APP="${1:-build/jiantieban.app}"

if ! security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "creating self-signed cert: $CERT_NAME"
    TMP=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/k8.pem" -out "$TMP/c.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_NAME" \
        -addext "keyUsage = digitalSignature" \
        -addext "extendedKeyUsage = codeSigning" 2>/dev/null
    openssl rsa -in "$TMP/k8.pem" -out "$TMP/k1.pem" -traditional 2>/dev/null
    security import "$TMP/k1.pem" -f openssl -t priv -A
    security import "$TMP/c.pem" -t cert -A
    rm -rf "$TMP"
fi

codesign --force --sign "$CERT_NAME" --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
echo "signed $APP with $CERT_NAME"
