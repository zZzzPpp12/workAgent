#!/bin/bash
# AgentNotifier 打包安装脚本：编译 release → 组装 .app → 安装到 ~/Applications
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="AgentNotifier"
INSTALL_DIR="$HOME/Applications"
APP_DIR="$INSTALL_DIR/$APP_NAME.app"

echo "==> 编译 release"
swift build -c release

echo "==> 组装 $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# 窗口头部 logo 资源
cp "Resources/app-icon-1024.png" "$APP_DIR/Contents/Resources/app-icon-1024.png"
# 通知提示音：狗叫（UNUserNotificationCenter 仅识别 bundle 内 aiff）
cp "Resources/DogBark.caf" "$APP_DIR/Contents/Resources/DogBark.caf"
# 来源应用图标
cp Resources/icon-catpaw.png Resources/icon-catpawide.png Resources/icon-catdesk.png Resources/icon-codex.png Resources/icon-claude.png Resources/icon-dsh.png "$APP_DIR/Contents/Resources/"
# 菜单栏小猫图标
cp "Resources/menubar-cat.png" "$APP_DIR/Contents/Resources/menubar-cat.png"
# 升级安装时清理旧品牌的菜单栏资源。
rm -f "$APP_DIR/Contents/Resources/menubar-dog.png"
# 桌宠精灵图（大肥鱼）
if [ -d "Resources/pet" ]; then
  mkdir -p "$APP_DIR/Contents/Resources/pet"
  cp Resources/pet/*.png "$APP_DIR/Contents/Resources/pet/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Agent哈基米</string>
<key>CFBundleDisplayName</key><string>Agent哈基米</string>
    <key>CFBundleIdentifier</key><string>com.maohuafeng.AgentNotifier</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.0.2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>AgentNotifier</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

# 移除隔离属性并 ad-hoc 签名（本地运行需要）
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "==> 安装完成：$APP_DIR"
echo "    启动：open \"$APP_DIR\""
echo "    开机自启：App 底部栏「开机启动」开关"
