#!/bin/bash
# 组装 jiantieban.app（CLT-only，无 actool：图标后期用 iconutil 手搓）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product jiantieban

APP=build/jiantieban.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/jiantieban "$APP/Contents/MacOS/jiantieban"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "built $APP"
