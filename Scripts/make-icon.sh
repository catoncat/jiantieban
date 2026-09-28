#!/bin/bash
# 从一张 1024x1024 PNG 生成 AppIcon.icns（CLT-only，无 actool，用 iconutil 手搓）。
# 用法: Scripts/make-icon.sh <source.png> [output.icns]
set -euo pipefail

SRC="${1:?usage: Scripts/make-icon.sh <source.png> [output.icns]}"
OUT="${2:-build/AppIcon.icns}"

if ! sips -g pixelWidth -g pixelHeight "$SRC" >/dev/null 2>&1; then
    echo "invalid image: $SRC" >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUT")"

for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 64 128 256; do
    double=$((size * 2))
    sips -z "$double" "$double" "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$OUT"
echo "wrote $OUT"
