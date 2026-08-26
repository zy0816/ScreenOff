#!/bin/bash
# 构建 DisplayToggle.app —— 只需要 Xcode Command Line Tools，不用 Xcode。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DisplayToggle"
BUNDLE_ID="com.zy0816.displaytoggle"
VERSION="1.3"
MIN_MACOS="13.0"

BUILD="build"
APP="$BUILD/$APP_NAME.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
swiftc -O \
    -target "arm64-apple-macos$MIN_MACOS" \
    -framework AppKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    Sources/DisplayAPI.swift Sources/main.swift

echo "==> 编译自测程序"
swiftc -O \
    -target "arm64-apple-macos$MIN_MACOS" \
    -framework AppKit \
    -o "$BUILD/selftest" \
    Sources/DisplayAPI.swift Tests/main.swift

echo "==> 生成图标"
if ./makeicon.sh "$APP/Contents/Resources/AppIcon.icns"; then
    ICON_ENTRY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
    echo "    (图标生成失败，跳过)"
    ICON_ENTRY=""
fi

echo "==> 写 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    $ICON_ENTRY
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "==> 签名"
# ad-hoc 签名：本机自用够了，SMAppService（开机启动）也要求 bundle 有签名。
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo
echo "构建完成: $(cd "$BUILD" && pwd)/$APP_NAME.app"
echo "安装:     cp -R '$BUILD/$APP_NAME.app' /Applications/"
