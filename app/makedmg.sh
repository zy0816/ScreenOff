#!/bin/bash
# 打一个可拖拽安装的 DMG。先跑 build.sh，再执行本脚本。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DisplayToggle"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "build/$APP_NAME.app/Contents/Info.plist")"
DMG="build/$APP_NAME-$VERSION.dmg"

if [ ! -d "build/$APP_NAME.app" ]; then
    echo "先跑 ./build.sh" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "build/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # 拖拽安装的目标

rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

echo "$DMG  ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG" | awk '{print "sha256: " $1}'
