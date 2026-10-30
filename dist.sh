#!/bin/bash
# AgentNotifier 分发包制作：通用二进制（arm64+x86_64）→ .app → DMG（含使用说明）
set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR="$(pwd)"
APP_NAME="AgentNotifier"
VERSION="0.0.2"
DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/stage"

echo "==> 清理旧产物"
rm -rf "$DIST_DIR"
mkdir -p "$STAGE_DIR"

echo "==> 运行单元测试"
swift test 2>&1 | grep -E "Executed .* tests" | tail -1

echo "==> 编译通用二进制 (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

BIN=".build/apple/Products/Release/$APP_NAME"
[ -f "$BIN" ] || BIN=".build/release/$APP_NAME"
lipo -info "$BIN"

echo "==> 组装 .app"
APP_DIR="$STAGE_DIR/$APP_NAME.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# 窗口头部 logo 资源
cp "Resources/app-icon-1024.png" "$APP_DIR/Contents/Resources/app-icon-1024.png"
# 提示音资源：保留旧入口音效，并提供哈基米完成提醒。
cp "Resources/DogBark.caf" "$APP_DIR/Contents/Resources/DogBark.caf"
cp "Resources/HakimiComplete.caf" "$APP_DIR/Contents/Resources/HakimiComplete.caf"
# 来源应用图标
cp Resources/icon-catpaw.png Resources/icon-catpawide.png Resources/icon-catdesk.png Resources/icon-codex.png Resources/icon-claude.png Resources/icon-dsh.png "$APP_DIR/Contents/Resources/"
# 菜单栏小猫图标
cp "Resources/menubar-cat.png" "$APP_DIR/Contents/Resources/menubar-cat.png"
# 桌宠精灵图（可选：目录不存在或缺图时运行时用 SF Symbol 占位）
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

codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "==> 生成使用说明"
cat > "$STAGE_DIR/❗首次安装必看（双击无反应点我）.txt" <<'README'
AgentNotifier（Agent哈基米）— AI 编程助手会话提醒工具
=====================================================

【安装：推荐路径，30 秒搞定】
1. 在本窗口里【右键】AgentNotifier.app → 选【打开】
   （注意是右键！双击只会弹一个没有「打开」按钮的提示框）
2. 弹窗点【打开】——App 启动后会自动把自己装进「应用程序」并解除拦截，
   以后双击/启动台打开都不再拦。
3. 按提示允许通知权限，完成。

【如果习惯了先拖进应用程序再打开】
1. 把 AgentNotifier.app 拖入「应用程序」文件夹；
2. 双击会弹「未打开 AgentNotifier / Apple 无法验证」窗口——
   这个窗口只有【完成】按钮，属正常现象，点【完成】关掉即可，App 并没有坏；
3. 打开 系统设置 → 左侧「隐私与安全性」（手掌图标，在「锁定屏幕」下面）
   → 右侧「安全性」板块，会看到「已阻止“AgentNotifier”以保护 Mac。」
   → 点它右边的【仍要打开】→ 弹窗再点【打开】，只需操作这一次。

【免进设置的替代方案】
打开「终端」执行（App 已拖进系统应用程序目录时）：
  xattr -dr com.apple.quarantine /Applications/AgentNotifier.app && open /Applications/AgentNotifier.app
若装在个人应用程序目录则路径换成 ~/Applications/AgentNotifier.app。

【功能】
监控本机 CatPaw（IDEA 插件 / CatDesk）、Codex CLI、Claude Code
会话状态并发送 macOS 系统通知：
- 任务完成 / 回合结束（1.4 秒哈基米提示音，10 秒内合并一次）
- 异常中断：网络请求失败、流错误等（系统提示音）
- 等待手动确认：命令需在 IDE / 会话中手动执行（系统提示音）
- 疑似暂停/中断：长时间无进展（默认不发声）
主窗口实时显示各会话状态（含会话标题与来源），下方内嵌通知日志
（时间倒序）；菜单栏小猫图标显示执行中会话数。
Dock 图标始终显示哈基米小猫 Logo，底部叠加状态条带（最多两行）：
待确认（黄）/ 执行中（绿）/ 已完成（白）。待确认与执行中实时统计、
归零自动消失；已完成按未读累计，打开主窗口即清零，
超过 1 小时未查看也会自动消失。

【使用】
- 双击启动后会出现主窗口和菜单栏图标，之后无需任何操作。
- 关闭主窗口不会退出应用（菜单栏图标仍在）；点 Dock 图标可重新打开。
- 开机自启：系统设置 → 通用 → 登录项 → 添加 Agent哈基米。
- 运行日志：主窗口底部直接查看，或打开 ~/Library/Logs/AgentNotifier.log

【判定规则】
- CatDesk：基于请求流（stream open/close）精确判定回合开始、
  正常结束、异常中断（stream_error/api_error/timeout）与用户停止，
  思考中不再误报完成
- IDEA CatPaw 插件：任务完成 = 8 秒无新输出且以最终回复收尾；
  异常中断 = 捕获 idea.log 中插件运行错误（网络失败等）；
  等待手动确认 = Tab 回合结束但 transcript 未以最终回复收尾
  （停在删除/执行等确认卡片，含回合零产出与工具执行一半被截停两种形态），
  或命令悬置超过 120 秒；启动时自动回填近 4 小时内停下的确认卡片
- CatDesk 等待手动确认：app 日志出现「发现需要确认的工具调用」；
  确认/拒绝后自动恢复正常监测
- Codex CLI（~/.codex/sessions）：回合结束 = task_complete 事件落盘；
  等待手动确认 = 工具调用悬置（无 output）超过 120 秒，
  或停在提问卡片（request_user_input，约 20 秒提醒，
  启动时自动回填近 4 小时内悬置的提问卡片）；
  会话标题自动同步 session_index 的 thread_name
- Claude Code（~/.claude/projects）：回合结束 = assistant 以 end_turn 收尾；
  等待手动确认 = 停在 tool_use（等待权限或工具执行）超过 120 秒；
  会话标题自动提取 AI 生成的 ai-title
- 疑似暂停/中断：停在工具调用中途超过 300 秒无进展；
  模型长思考中（Thinking）放宽到 600 秒
- 会话活跃度覆盖整个会话目录（含工具执行/终端输出），
  工具长时间运行不会误判中断

【要求】
macOS 13 及以上，Apple Silicon / Intel 均可。
README

echo "==> 制作 DMG"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
# 放入「应用程序」快捷方式，支持拖拽安装
ln -sf /Applications "$STAGE_DIR/应用程序"
hdiutil create -volname "$APP_NAME 安装" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH" >/dev/null

# 排版 dmg 窗口：大图标 + 说明文件置顶，让引导一眼可见
MOUNT_POINT="$(hdiutil attach "$DMG_PATH" -nobrowse | tail -1 | awk '{print $3}')" || true
if [ -n "${MOUNT_POINT:-}" ] && [ -d "$MOUNT_POINT" ]; then
  osascript <<'EOF' 2>/dev/null || true
tell application "Finder"
  tell disk "AgentNotifier 安装"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {400, 100, 1160, 480}
    set theViewOptions to icon view options of container window
    set icon size of theViewOptions to 96
    set arrangement of theViewOptions to not arranged
    set position of item "AgentNotifier.app" of container window to {180, 190}
    set position of item "应用程序" of container window to {400, 190}
    set position of item "❗首次安装必看（双击无反应点我）.txt" of container window to {620, 190}
    close
    open
    update without registering applications
  end tell
end tell
EOF
  hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
fi

echo "==> 同时产出 zip（备用）"
(cd "$STAGE_DIR" && zip -qr -y "../${APP_NAME}-${VERSION}.zip" .)

echo "==> 上传备用下载链路（mas.health 接口 → AIBase 版本表登记）"
if [ -f "$HOME/.config/agent-notifier-release.env" ] || [ -n "${MAS_COOKIE:-}" ]; then
  python3 "$SCRIPT_DIR/release-upload.py" "$DMG_PATH" "$VERSION" || echo "!! 备用链路上传失败（不影响本地产物；若鉴权失败需重抓 MAS_COOKIE）"
else
  echo "   跳过：未配置 ~/.config/agent-notifier-release.env（MAS_COOKIE + AIBASE_SERVICE_ROLE_KEY）"
fi

rm -rf "$STAGE_DIR"
echo ""
echo "✅ 分发包已生成："
ls -lh "$DIST_DIR"
