#!/bin/bash
# 无 Xcode 环境的手工构建脚本：用 Command Line Tools 直接编译打包 .app
# 产出: dist/TokenUsage.app（ad-hoc 签名，可直接本机运行）
#
# 注意：本脚本不打包 Widget 小组件。macOS 强制要求扩展进程必须带 sandbox
# 运行，而 ad-hoc 签名（无开发者 Team）的进程启用 sandbox 会在启动时被系统
# 终止（_libsecinit_appsandbox）。小组件需通过 Xcode 工程用免费开发者
# Team 签名后构建，详见 README。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX1[5-9]*.sdk 2>/dev/null | sort -V | tail -1)"
if [ -z "${SDK:-}" ]; then
    SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk | sort -V | tail -1)"
fi
TARGET="arm64-apple-macosx15.0"
DIST="$ROOT/dist"
APP="$DIST/TokenUsage.app"

echo "==> SDK: $SDK"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# ---------- 图标 ----------
echo "==> 生成应用图标"
ICONSET="$DIST/AppIcon.iconset"
mkdir -p "$ICONSET"
swiftc -sdk "$SDK" -target "$TARGET" -O "$ROOT/Tools/make_icon.swift" -o "$DIST/make_icon"
"$DIST/make_icon" "$DIST/icon_1024.png"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" \
            "512:icon_512x512" "1024:icon_512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$DIST/icon_1024.png" --out "$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# ---------- 资源目录（AccentColor 等） ----------
echo "==> 编译 Asset Catalog"
actool --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 15.0 \
    "$ROOT/TokenUsage/Assets.xcassets" >/dev/null 2>&1 || \
    echo "    (actool 跳过：仅 AccentColor，不影响运行)"

# ---------- 编译主程序 ----------
echo "==> 编译 TokenUsage 主程序"
swiftc -sdk "$SDK" -target "$TARGET" -swift-version 5 -O \
    -module-name TokenUsage \
    "$ROOT"/Shared/*.swift \
    "$ROOT"/TokenUsage/TokenUsageApp.swift \
    "$ROOT"/TokenUsage/Services/*.swift \
    "$ROOT"/TokenUsage/State/*.swift \
    "$ROOT"/TokenUsage/Views/*.swift \
    -o "$APP/Contents/MacOS/TokenUsage"

# ---------- Info.plist ----------
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleDisplayName</key><string>Token 用量</string>
	<key>CFBundleExecutable</key><string>TokenUsage</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.tokenusage.app</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>TokenUsage</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# ---------- 签名（ad-hoc，保留 App Group 权限；不启用 sandbox，本机直装用） ----------
echo "==> Ad-hoc 签名"
ENT="$DIST/entitlements.plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.tokenusage.shared</string>
	</array>
</dict>
</plist>
PLIST

codesign -s - --entitlements "$ENT" -f "$APP"

echo "==> 完成: $APP"
