import AppKit
import SwiftUI
import Foundation
import UserNotifications
import WebKit
import SQLite3
#if canImport(LibZSTD)
import LibZSTD
#endif
import CommonCrypto
import ServiceManagement

// MARK: - 配置

struct Config {
    static let appVersion = "0.0.2"
    /// 轮询间隔（秒）
    static let pollInterval: TimeInterval = 3
    /// 活动停止后判定「任务完成」的宽限（秒）
    static let doneGrace: TimeInterval = 8
    /// CatDesk 回合结束宽限（秒）：末帧为最终 assistant 消息后再等待该时长去抖
    static let deskDoneGrace: TimeInterval = 15
    /// CatDesk 流异常防抖（秒）：error 后该时长内若有新流打开视为已恢复，不告警
    static let deskErrorGrace: TimeInterval = 20
    /// 停在工具调用中途、超过该时长判定「疑似暂停/中断」（秒）
    static let stuckThreshold: TimeInterval = 300
    /// 尾部停在 [Thinking]（模型长推理不落盘）时的放宽阈值（秒）
    static let thinkingStuckThreshold: TimeInterval = 600
    /// 命令类工具调用悬置（可能在等待用户手动确认）超过该时长 → 「等待手动确认」（秒）
    static let awaitConfirmThreshold: TimeInterval = 120
    /// 确认卡片判定落定延迟（秒）：回合结束且尾部停在未完成 [Tool call] 时，
    /// 等自动审批类工具（read_file/grep 等秒级落结果）的 [Tool result] 写入再判定，
    /// 避免把「正在自动执行的工具」误报成等待确认。真实卡片提醒延迟 ≈ 该值。
    static let cardSettleDelay: TimeInterval = 20
    /// 尾部状态不可读（transcript 缺失/无法解析）时的兜底宽限（秒）：
    /// 仅用于未知场景，长思考轮次已由尾部状态机结构性排除（见 deliverTabTurnsIfAny）。
    static let silentTurnGrace: TimeInterval = 60
/// 手动改名的持久化文件（key = 会话文件路径）
static let customTitlesURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/AgentNotifier/custom-titles.json")
    /// 只评估该窗口内结束的 Tab 回合（避免启动前太旧的回合误判为等待确认）
    static let tabTurnEvalWindow: TimeInterval = 14400
    /// 启动时发现会话在该时长内有活动 → 假定其仍在执行（随后由状态机自然收敛）
    static var assumeRunningWindow: TimeInterval { thinkingStuckThreshold }
    /// 会话标题最大长度
    static let titleMaxLength = 40

    static var catpawHome: URL {
        MonitorPreferences.shared.snapshot.sourcePaths["CatPaw"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".catpaw")
    }
    static var projectsDir: URL { catpawHome.appendingPathComponent("projects") }
    /// Codex CLI 会话根目录（~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl）
    static var codexSessionsDir: URL {
        MonitorPreferences.shared.snapshot.sourcePaths["Codex"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }
    /// Codex 会话索引（id → thread_name，用于标题同步）
    static let codexSessionIndex = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/session_index.jsonl")
    /// Claude Code 会话根目录（~/.claude/projects/<工作区>/<sid>.jsonl）
    static var claudeProjectsDir: URL {
        MonitorPreferences.shared.snapshot.sourcePaths["Claude"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }
    /// Trae / TRAE SOLO（VS Code fork 布局）：会话状态在各工作区
    /// <root>/User/workspaceStorage/<hash>/state.vscdb 的 chat.ChatSessionStore.index，
    /// 渠道标识区分两个端。entries 内部结构未定稿，先做工作区级展示
    static let traeAppDirs: [(root: URL, channel: String)] = [
        (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TRAE SOLO CN"), "SOLO"),
        (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Trae CN"), "Trae"),
    ]
    /// Trae 工作区会话索引键（state.vscdb ItemTable）
    static let traeChatIndexKey = "chat.ChatSessionStore.index"
    /// Codex 额度快照刷新间隔（秒）：快照只在回合落盘时更新，60s 足够
    static let codexQuotaRefreshInterval: TimeInterval = 60
    /// DeepSeek Harness 会话根目录（~/.dsh/sessions/<转义工作区>/session-<uuid>/session.v3.jsonl.zstd）
    static let dshSessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".dsh/sessions")
/// CatDesk 回合流信号日志（stream.open / stream.close 携带 conversationId 与结果）
static var apiRequestLogURL: URL { catpawHome.appendingPathComponent("logs/api-request.log") }
/// 进行中的会话周期性兜底深扫间隔（秒）：纠正悬置钉住/流信号丢失等状态残留
static let deepSweepInterval: TimeInterval = 60
/// CatDesk 日志目录（其下 app.N.log 含「发现需要确认的工具调用」事件）
static var catpawLogsDir: URL { catpawHome.appendingPathComponent("logs") }
/// CatDesk 会话列表接口：侧栏的 AI 摘要标题只保存在服务端，本地任何文件/日志都没有
static let deskTitleAPI = "https://catpaw-agent.sankuai.com/api/agent/conversation/list"
/// SSO 登录态配置（CatDesk 自动刷新 ssoid）
static var ssoConfigURL: URL { catpawHome.appendingPathComponent("sso_config.json") }
/// CatPaw 插件端/IDE 独立端共用的 mcopilot 界面状态库（t_ui_messages 实时含
/// 提问卡/确认卡悬置状态——这两个客户端的 transcript 只在回合落盘点写入，
/// 卡片悬置期间磁盘零足迹，该库是卡片悬置的唯一即时信号源）
static let mideCacheDB = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".sankuai/MCopilot/sqliteDB/globalCache.sqlite")
/// 状态库启动回看窗口（秒）：正在悬置的卡片（含启动前挂着的）首轮即识别，
/// 更早的孤儿卡片不重复提醒
static let mideCardStartupWindow: TimeInterval = 7200
/// 服务端会话标题同步间隔（秒）
static let deskTitleFetchInterval: TimeInterval = 300
/// 标题拉取失败后的重试间隔（秒）
static let deskTitleRetryInterval: TimeInterval = 60
    /// JetBrains IDE 日志根目录（其下 <IDE>/idea.log 含 CatPaw 插件运行错误）
    static let jetBrainsLogsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/JetBrains")
    // MARK: 桌宠（大肥鱼）
    /// 桌宠精灵图所在 bundle 子目录（Contents/Resources/pet/，dist.sh 复制）
    static let petSpriteDir = "pet"
    /// 桌宠本体尺寸（含手扶白牌，1:1 画幅）
    static let petSize = NSSize(width: 196, height: 196)
    /// 游荡带：只沿屏幕底部该比例高度慢游
    static let petBottomBandRatio: CGFloat = 0.20
    /// 游荡/动画 tick 频率
    static let petWanderInterval: TimeInterval = 1.0 / 12.0
    /// 气泡默认停留时长
    static let petBubbleDuration: TimeInterval = 6
    /// Codex 额度提醒阈值（剩余百分比，两窗口取 min）
    static let petQuotaLowRemaining = 15.0
    /// 额度提醒冷却（防刷屏；回升到阈值+5 重新武装）
    static let petQuotaRemindCooldown: TimeInterval = 6 * 3600
    /// 相同事件去重窗口
    static let petEventDedupeWindow: TimeInterval = 10
}

// MARK: - 通知

enum Notify {
private static let logLock = NSLock()
static var managedDelivery = false
/// 发送器可替换，便于单元测试拦截
static var sender: (_ title: String, _ body: String, _ sound: String, _ context: [String: String]) -> Void = { t, b, s, c in
defaultSend(title: t, body: b, sound: s, context: c)
}

/// context 携带会话定位信息（kind/path），点击通知时用于打开来源 app
static func send(title: String, body: String, sound: String, context: [String: String] = [:]) {
if managedDelivery && !title.contains("测试") { return }
sender(title, body, sound, context)
}

static func resetSender() {
sender = { t, b, s, c in defaultSend(title: t, body: b, sound: s, context: c) }
}

    /// 通知投递日志，便于排查与回看（同时展示在主窗口日志面板）
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/AgentNotifier.log")

    /// 写一行运行日志（标题同步等非通知事件）
    static func log(_ line: String) { appendLog(line) }

    /// 当前播放的音效（强引用防止播放途中被释放）
    private static var player: NSSound?

    /// 自行播放提示音：UNNotificationSound(named:) 在本机对 bundle 内自定义音效
    /// 持续解析失败（aiff 响默认音、caf 无声，三版实测），改为 App 直接 NSSound
    /// 播放 bundle 内音频文件——该路径实测稳定可听，不再依赖通知服务解析音效
    private static func playSound(named name: String) {
        guard let path = Bundle.main.path(forResource: name, ofType: "caf"),
              let s = NSSound(contentsOfFile: path, byReference: false) else { return }
        player = s
        s.play()
    }

private static func defaultSend(title: String, body: String, sound: String, context: [String: String]) {
appendLog("通知投递：\(title) · 来源=\(context["kind"] ?? "任务中心")")
// 打包为 .app 时走 UNUserNotificationCenter：通知横幅携带应用图标（哈基米小猫 Logo）
if Bundle.main.bundleIdentifier != nil {
let content = UNMutableNotificationContent()
content.title = title
content.body = body
content.userInfo = context
            content.sound = sound.isEmpty ? nil : .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { _ in }
            return
        }
        // 开发态（swift run 无 bundle）回退 osascript
        let script = """
        display notification "\(escape(body))" with title "\(escape(title))" sound name "\(sound)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private static func appendLog(_ line: String) {
        logLock.lock()
        defer { logLock.unlock() }
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64, size > 5_000_000 {
            let previous = logURL.appendingPathExtension("previous")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: logURL, to: previous)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let entry = "\(fmt.string(from: Date())) \(line)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let h = try? FileHandle(forWritingTo: logURL) {
                try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// 读取运行日志尾部，时间倒序（最新在前），供主窗口日志面板展示
func readLogLines(url: URL, maxBytes: UInt64, maxLines: Int) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
    guard let data = try? handle.readToEnd(),
          let text = String(data: data, encoding: .utf8) else { return [] }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return Array(lines.suffix(maxLines).reversed())
}

// MARK: - 项目名 / 标题解析

/// 从 jb-/ide- 项目目录名解析可读项目名。
/// 目录由原始路径转义而来：/Users/<user>/IdeaProjects-health-2/health_medical_ai
///   → jb-Users-maohuafeng-IdeaProjects-health-2-health_medical_ai
/// CatPaw IDE 独立端：ide-Users-maohuafeng-ai-workspace-xxx
func projectLabel(from dirName: String) -> String {
    var s = dirName
    // 去 jb-/ide- + Users-<user>- 前缀
    if let re = try? NSRegularExpression(pattern: "^(?:jb|ide)-Users-[^-]+-"),
       let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let r = Range(m.range, in: s) {
        s.removeSubrange(r)
    }
    // 去 IdeaProjects 父目录段：IdeaProjects[-名称][-数字]-
    if let re = try? NSRegularExpression(pattern: "^IdeaProjects(-[A-Za-z0-9]+)?(-[0-9]+)?-"),
       let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let r = Range(m.range, in: s) {
        s.removeSubrange(r)
    }
    return s.isEmpty ? dirName : s
}

/// CatDesk 工作区目录名 → 可读路径（去掉 -Users-<user>- 前缀）
/// "-Users-maohuafeng-ai-workspace-catpaw-desk" → "ai-workspace-catpaw-desk"
func workspaceLabel(from dirName: String) -> String {
    var s = dirName.hasPrefix("-") ? String(dirName.dropFirst()) : dirName
    if let re = try? NSRegularExpression(pattern: "^Users-[^-]+-"),
       let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let r = Range(m.range, in: s) {
        s.removeSubrange(r)
    }
    return s.isEmpty ? dirName : s
}

/// Claude Code 项目目录名 → 工作区短名。
/// "-Users-maohuafeng-IdeaProjects-health-5" → "health-5"；
/// "-Users-maohuafeng-ai-workspace-catpaw-desk" → "catpaw-desk"
func claudeWorkspaceLabel(from dirName: String) -> String {
    var s = workspaceLabel(from: dirName)
    for prefix in ["IdeaProjects-", "ai-workspace-"] {
        if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
    }
    return s.isEmpty ? dirName : s
}

/// workspace.json → 工作区显示名：folder/workspace URI 的末段（去 .code-workspace 后缀），
/// 解析失败回退目录哈希名。只认 file:// URI——远程工作区（vscode-remote 等）本地无路径
func traeWorkspaceName(fromWorkspaceJSON text: String, fallback: String) -> String {
    guard let d = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return fallback }
    for key in ["folder", "workspace"] {
        if let s = d[key] as? String, let u = URL(string: s), u.scheme == "file",
           !u.path.isEmpty {
            var name = u.lastPathComponent
            if name.hasSuffix(".code-workspace") {
                name = String(name.dropLast(".code-workspace".count))
            }
            if !name.isEmpty { return name }
        }
    }
    return fallback
}

/// state.vscdb 是否存在某键（短连接只读；打开失败按不存在处理，等下轮重试）
func vscdbHasItem(dbURL: URL, key: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbURL.path, &db,
                          SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else { sqlite3_close(db); return false }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 800)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT 1 FROM ItemTable WHERE key = '\(key)'",
                             -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return false }
    return sqlite3_step(s) == SQLITE_ROW
}

/// 解析 codex session_index.jsonl：会话 id → thread_name
func parseCodexSessionIndex(_ text: String) -> [String: String] {
    var map: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = obj["id"] as? String,
              let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
        map[id] = name
    }
    return map
}

/// Codex 子代理线程（guardian_review 自动审查等）不是用户会话，不监控。
/// session_meta 是 rollout 首条记录，source 含 subagent 即子代理线程
func codexIsSubagentRollout(_ url: URL) -> Bool {
guard let h = try? FileHandle(forReadingFrom: url) else { return false }
defer { try? h.close() }
guard let data = try? h.read(upToCount: 8192),
let head = String(data: data, encoding: .utf8) else { return false }
return head.contains("\"subagent\"")
}

/// rollout 文件名提取会话 uuid：rollout-<时间戳>-<uuid>.jsonl → 末 5 段
func codexSessionId(fromFile name: String) -> String {
    let base = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
    return base.split(separator: "-").suffix(5).joined(separator: "-")
}

// MARK: - Codex 额度（rate_limits 快照）

/// Codex 会话 jsonl 每回合落一份 rate_limits 快照（payload.rate_limits）：
/// primary=5 小时窗口（300 分钟），secondary=本周窗口（10080 分钟），
/// used_percent 为已用百分比。零网络零凭证——只读本地会话文件
struct CodexRateLimits: Equatable {
    var planType: String?
    var primaryUsedPercent: Double?
    var primaryWindowMinutes: Int?
    var primaryResetsAt: Date?
    var secondaryUsedPercent: Double?
    var secondaryWindowMinutes: Int?
    var secondaryResetsAt: Date?
    var creditsBalance: String?
    /// 快照落盘时刻（jsonl 行自带 timestamp）：展示陈旧度用它，而非本地扫描时间
    var snapshotAt: Date?

    /// 窗口展示名：300 分钟=5 小时、10080 分钟=本周，其余整小时化
    static func windowLabel(minutes: Int?) -> String {
        guard let m = minutes else { return "额度" }
        if m == 300 { return "5 小时" }
        if m == 10080 { return "本周" }
        if m >= 60, m % 60 == 0 { return "\(m / 60) 小时" }
        return "\(m) 分钟"
    }
}

/// 从单行 jsonl 解析 rate_limits 快照；非额度事件行返回 nil
func parseCodexRateLimits(_ line: String) -> CodexRateLimits? {
    guard line.contains("\"rate_limits\""),
          let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let payload = d["payload"] as? [String: Any],
          let rl = payload["rate_limits"] as? [String: Any] else { return nil }
    func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    func window(_ v: Any?) -> (percent: Double?, minutes: Int?, resets: Date?) {
        guard let w = v as? [String: Any] else { return (nil, nil, nil) }
        let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return (num(w["used_percent"]), (w["window_minutes"] as? NSNumber)?.intValue, resets)
    }
    var out = CodexRateLimits()
    out.planType = rl["plan_type"] as? String
    if let ts = d["timestamp"] as? String {
        out.snapshotAt = eventDate(ts)
    }
    let p = window(rl["primary"])
    out.primaryUsedPercent = p.percent
    out.primaryWindowMinutes = p.minutes
    out.primaryResetsAt = p.resets
    let s = window(rl["secondary"])
    out.secondaryUsedPercent = s.percent
    out.secondaryWindowMinutes = s.minutes
    out.secondaryResetsAt = s.resets
    if let c = rl["credits"] as? [String: Any] {
        out.creditsBalance = c["balance"] as? String
    }
    return out
}

/// 文本中最后一条含 rate_limits 的行（快照随回合追加，末尾的即最新）
func lastCodexRateLimits(in text: String) -> CodexRateLimits? {
    var latest: CodexRateLimits?
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let candidate = parseCodexRateLimits(String(line)) else { continue }
        if latest == nil || (candidate.snapshotAt ?? .distantPast) >= (latest?.snapshotAt ?? .distantPast) { latest = candidate }
    }
    return latest
}

/// 读文件尾部一个字节窗口（半行起点丢弃），供额度快照扫描等轻量读取
func readTailText(url: URL, maxBytes: UInt64) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    try? h.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
    guard let data = try? h.readToEnd() else { return nil }
    var text = String(decoding: data, as: UTF8.self)
    if size > maxBytes, let nl = text.firstIndex(of: "\n") {
        text.removeSubrange(text.startIndex...nl)
    }
    return text
}

// MARK: - DeepSeek Harness（dsh）会话解析

/// zstd 解压（vendor 的 LibZSTD 1.5.6，系统 libcompression 不支持 zstd）。
/// dsh 的 session.v3.jsonl.zstd 是持续追加的压缩流；运行中读到截断帧时返回 nil
/// （调用方保留上次解析结果），完整文件一次解出全部帧
func zstdDecompress(_ data: Data) -> Data? {
    #if canImport(LibZSTD)
    guard !data.isEmpty else { return nil }
    guard let dctx = ZSTD_createDStream() else { return nil }
    defer { ZSTD_freeDCtx(dctx) }
    _ = ZSTD_initDStream(dctx)
    var output = [UInt8]()
    output.reserveCapacity(data.count * 6)
    let status = data.withUnsafeBytes { raw -> Bool in
        guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
        var inBuf = ZSTD_inBuffer(src: src, size: data.count, pos: 0)
        let chunkSize = max(ZSTD_DStreamOutSize(), 1 << 18)
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }
        while inBuf.pos < inBuf.size {
            var outBuf = ZSTD_outBuffer(dst: chunk, size: chunkSize, pos: 0)
            let r = ZSTD_decompressStream(dctx, &outBuf, &inBuf)
            if ZSTD_isError(r) != 0 { return false } // 截断/损坏帧
            output.append(contentsOf: UnsafeBufferPointer(start: chunk, count: outBuf.pos))
            if r == 0 { _ = ZSTD_DCtx_reset(dctx, ZSTD_reset_session_only) } // 帧结束，允许多帧
        }
        return true
    }
    return status ? Data(output) : nil
    #else
    return nil // LibZSTD 未编入：dsh 会话不解码，发现阶段自然跳过
    #endif
}

/// dsh 会话尾部状态（语义化事件流，比 transcript 解析可靠）：
/// - approval/asked 无对应 approval/decided → 等待手动确认（悬停卡不产生新事件）
/// - turn/start 晚于最后 turn/end → 回合执行中
/// - turn/end reason.kind: completed=正常完成 / error=异常中断 / aborted+user=用户停止
struct DshTail: Equatable {
    enum TurnEndKind: Equatable {
        case completed
        case abortedByUser
        case error(String)
    }
    var pendingApprovalTool: String?
    var turnRunning = false
    var turnEnd: TurnEndKind?
    var title: String?
    var delegationDepth = 0
}

/// 解析 dsh 会话 jsonl 全文为尾部状态（文件解压后全量扫一遍，行数有限）
func dshTailState(from text: String) -> DshTail {
    var tail = DshTail()
    var asked: [String: String] = [:] // approval id → toolName
    var askedOrder: [String] = []
    var decided = Set<String>()
    var lastBoundary = false // true = turn/start，false = turn/end/无
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.contains("\"approval/asked\"") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let d = o["data"] as? [String: Any], let id = d["id"] as? String {
                if asked[id] == nil { askedOrder.append(id) }
                asked[id] = d["toolName"] as? String
            }
        } else if line.contains("\"approval/decided\"") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let d = o["data"] as? [String: Any], let id = d["id"] as? String {
                decided.insert(id)
            }
        } else if line.contains("\"turn/start\"") {
            lastBoundary = true
        } else if line.contains("\"turn/end\"") {
            lastBoundary = false
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let d = o["data"] as? [String: Any],
               let reason = d["reason"] as? [String: Any],
               let kind = reason["kind"] as? String {
                switch kind {
                case "completed": tail.turnEnd = .completed
                case "aborted": tail.turnEnd = .abortedByUser
                case "error":
                    let err = reason["error"] as? [String: Any]
                    let msg = (err?["message"] as? String) ?? "未知错误"
                    tail.turnEnd = .error(msg)
                default: break
                }
            }
        } else if line.contains("\"user/message\""), tail.title == nil {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let d = o["data"] as? [String: Any],
               let content = d["content"] as? [[String: Any]] {
                for c in content where (c["type"] as? String) == "text" {
                    if let t = c["text"] as? String, let title = sanitizeTitle(stripXmlBlocks(t)) {
                        tail.title = title
                        break
                    }
                }
            }
        } else if line.contains("\"delegationDepth\""), line.contains("\"type\":\"session\"") {
            if let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                tail.delegationDepth = (o["delegationDepth"] as? NSNumber)?.intValue ?? 0
            }
        }
    }
    tail.pendingApprovalTool = askedOrder.first { asked[$0] != nil && !decided.contains($0) }.flatMap { asked[$0] }
    tail.turnRunning = lastBoundary
    return tail
}

/// dsh 工作区目录名 → 可读名。转义格式 "–-Users-zhb-Desktop-tripIDE--"
/// （首尾各两横杠，路径段以单横杠连接），去壳后复用通用清洗
func dshWorkspaceLabel(from dirName: String) -> String {
    var s = dirName
    if s.hasPrefix("--") { s = String(s.dropFirst(2)) }
    if s.hasSuffix("--") { s = String(s.dropLast(2)) }
    return workspaceLabel(from: s.isEmpty ? dirName : s)
}

/// dsh 会话文件头部的 cwd（真实项目路径），用于点击打开项目文件夹
func dshSessionCWD(from text: String) -> String? {
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3) {
        guard line.contains("\"type\":\"session\""),
              let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let cwd = o["cwd"] as? String, !cwd.isEmpty else { continue }
        return cwd
    }
    return nil
}

/// Claude 会话标题：尾部最后一条 ai-title 事件的 aiTitle（AI 摘要，简洁准确）
func extractClaudeTitle(from url: URL) -> String? {
    for line in readLogLines(url: url, maxBytes: 65536, maxLines: 200) {
        guard line.contains("\"type\":\"ai-title\""),
              let d = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let title = obj["aiTitle"] as? String, !title.isEmpty else { continue }
        return title
    }
    return nil
}

/// 标题清洗：多行合并为单行、去空白、截断
func sanitizeTitle(_ raw: String) -> String? {
    let joined = raw.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    guard !joined.isEmpty else { return nil }
    if joined.count > Config.titleMaxLength {
        return String(joined.prefix(Config.titleMaxLength)) + "…"
    }
    return joined
}

/// 从 IDEA transcript 头部提取会话标题（真实提问位于 <user_query> 标签内）
func extractTitle(from url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 65536),
          let text = String(data: data, encoding: .utf8) else { return nil }
    if let re = try? NSRegularExpression(pattern: "<user_query>(.*?)</user_query>",
                                         options: [.dotMatchesLineSeparators]),
       let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let r = Range(m.range(at: 1), in: text) {
        return sanitizeTitle(String(text[r]))
    }
    return nil
}

/// 剥除文本中的 XML 块（成对标签与自闭合标签），用于从注入上下文中提取真实用户文本
func stripXmlBlocks(_ text: String) -> String {
    var s = text
    let patterns = [
        #"<([a-zA-Z_][\w.-]*)[^>]*>.*?</\1>"#, // 成对标签（含其中所有内容）
        #"<[^>]+/>"#                             // 自闭合标签
    ]
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p, options: [.dotMatchesLineSeparators]) else { continue }
        // 反复剥除直至稳定（处理相邻/嵌套块）
        var previous = ""
        while previous != s {
            previous = s
            s = re.stringByReplacingMatches(in: s,
                                            range: NSRange(s.startIndex..., in: s),
                                            withTemplate: "")
        }
    }
    return s
}

/// 从 CatDesk 会话 jsonl 提取标题：首个 user 事件中剥除注入 XML 块后的真实文本
func extractDeskTitle(from url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 4 * 1024 * 1024),
          let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(200) {
        guard let ld = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any],
              obj["type"] as? String == "user",
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { continue }
        for c in content where c["type"] as? String == "text" {
            if let t = c["text"] as? String,
               let title = sanitizeTitle(stripXmlBlocks(t)) {
                return title
            }
        }
    }
    return nil
}

// MARK: - CatDesk 回合流信号（api-request.log）

/// CatDesk 单个会话的回合状态（由 stream.open / stream.close 精确判定）
enum DeskTurnSignal: Equatable {
    case running        // stream.open：回合进行中（思考/工具/等待确认都属此类）
    case done           // stream.close outcome=success
    case stopped        // stream.close 用户主动停止（client_aborted / canceled）
    case error(String)  // stream.close 异常（stream_error / api_error / timeout ...）
}

/// 从 api-request.log 单行解析回合信号；非回合事件返回 nil
func deskTurnSignal(fromLine line: String) -> (conversationId: String, signal: DeskTurnSignal)? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          obj["operation"] as? String == "conversation.turn",
          let cid = obj["conversationId"] as? String, !cid.isEmpty else { return nil }
    switch obj["event"] as? String {
    case "http.client.stream.open":
        return (cid, .running)
    case "http.client.stream.close":
        let outcome = obj["outcome"] as? String ?? ""
        if outcome == "success" { return (cid, .done) }
        let reason = obj["closeReason"] as? String ?? ""
        if outcome == "canceled" || reason == "client_aborted" { return (cid, .stopped) }
        return (cid, .error(outcome.isEmpty ? (reason.isEmpty ? "unknown" : reason) : outcome))
    default:
        return nil
    }
}

/// 增量跟踪 api-request.log，维护每个 conversationId 的最新回合信号
final class ApiRequestLogTracker {
    private(set) var status: [String: DeskTurnSignal] = [:]
    private var offset: UInt64 = 0
    private var leftover = ""
    let url: URL
    private let fm = FileManager.default

    init(url: URL = Config.apiRequestLogURL) { self.url = url }

    /// 启动：扫描尾部建立基线（不产生任何通知）
    func calibrate() {
        let size = fileSize()
        let from: UInt64 = size > 512 * 1024 ? size - 512 * 1024 : 0
        if var text = read(from: from, to: size) {
            if from > 0, let nl = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: nl)...])
            }
            for line in text.split(separator: "\n") {
                if let (cid, sig) = deskTurnSignal(fromLine: String(line)) {
                    status[cid] = sig
                }
            }
        }
        offset = size
        leftover = ""
    }

    /// 轮询：读取增量并更新各会话信号（兼容日志轮转与半行写入）
    func poll() {
        let size = fileSize()
        if size < offset { offset = 0; leftover = "" } // 日志轮转
        guard size > offset, let text = read(from: offset, to: size) else { return }
        offset = size
        let chunk = leftover + text
        var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        leftover = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        for line in lines where !line.isEmpty {
            if let (cid, sig) = deskTurnSignal(fromLine: line) {
                status[cid] = sig
            }
        }
    }

    private func fileSize() -> UInt64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func read(from: UInt64, to: UInt64) -> String? {
        guard to > from, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: from)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - IDEA CatPaw 插件错误信号（idea.log）

struct IdeaError {
    let at: Date
    let msg: String
}

/// 判定 idea.log 单行是否为 CatPaw 插件的真实运行错误（过滤 payload.partial 等噪音）
func isIdeaAgentErrorLine(_ line: String) -> Bool {
    guard line.contains("[ERROR] [catpaw]") else { return false }
    return line.contains("onAgentError_")
        || line.contains("响应异常_")
        || line.contains("网络请求失败_")
}

/// 提取错误内容摘要（限长）
func extractIdeaErrorMsg(_ line: String) -> String {
    for marker in ["onAgentError_", "响应异常_", "网络请求失败_"] {
        if let r = line.range(of: marker) {
            var s = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if s.count > 120 { s = String(s.prefix(120)) + "…" }
            return s.isEmpty ? "agent error" : s
        }
    }
    return "agent error"
}

/// idea.log 行首时间戳（2026-10-10 19:41:24,336）
func parseIdeaLogTimestamp(_ line: String) -> Date? {
    guard line.count >= 23 else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
    return f.date(from: String(line.prefix(23)))
}

/// 一个已结束的 Tab 回合（running → completed/failed/cancelled）
struct IdeaTabTurn {
    let tabId: String
    let runningSince: Date
    let endedAt: Date
    let status: String // completed / failed / cancelled
}

/// 解析「Tab状态已更新」行 → (tabId, status)
func parseIdeaTabStatus(_ line: String) -> (tabId: String, status: String)? {
    guard let r = line.range(of: "Tab状态已更新，ID: ") else { return nil }
    let rest = line[r.upperBound...]
    guard rest.count >= 36 else { return nil }
    let tabId = String(rest.prefix(36))
    guard let s = rest.range(of: "Status: ") else { return nil }
    let status = String(rest[s.upperBound...]).components(separatedBy: CharacterSet.alphanumerics.inverted).first ?? ""
    return status.isEmpty ? nil : (tabId, status)
}

/// 增量跟踪各 JetBrains IDE 当前 idea.log，发现 CatPaw 插件运行错误与 Tab 回合状态
final class IdeaLogTracker {
    private(set) var latestError: IdeaError?
    private var finishedTurns: [IdeaTabTurn] = []
    private var tabRunningSince: [String: Date] = [:]
    private var offsets: [String: UInt64] = [:]
    private let logsRoot: URL
    private let fm = FileManager.default

    init(logsRoot: URL = Config.jetBrainsLogsDir) { self.logsRoot = logsRoot }

    /// 启动：回填近期 Tab 回合（覆盖应用启动前停下的确认卡片），再对齐到文件末尾。
    /// IDEA 日志量大（半小时可达数 MB），按时间窗过滤而非固定尾部大小，上限 32MB。
    func calibrate(now: Date = Date()) {
        let maxTail: UInt64 = 32 * 1024 * 1024
        let cutoff = now.addingTimeInterval(-Config.tabTurnEvalWindow)
        for url in currentIdeaLogs() {
            let size = fileSize(url)
            let off = size > maxTail ? size - maxTail : 0
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: off)
                if let data = try? handle.readToEnd(),
                   let text = String(data: data, encoding: .utf8) {
                    for raw in text.split(separator: "\n") {
                        let line = String(raw)
                        guard line.contains("Tab状态已更新") else { continue }
                        if let at = parseIdeaLogTimestamp(line), at < cutoff { continue }
                        processLine(line, collectError: false)
                    }
                }
                try? handle.close()
            }
            offsets[url.path] = size
        }
    }

/// 取走自上次以来新结束的回合
func takeFinishedTurns() -> [IdeaTabTurn] {
defer { finishedTurns.removeAll() }
return finishedTurns
}

/// 该 Tab 在指定时间之后是否又出现了 running。
/// CatPaw 插件的 Tab running/completed 是「模型轮次」粒度：一个用户回合由几十对
/// 轮次事件组成，completed 后约 1 秒就会接下一个 running。只有「没有后续 running
/// 的 completed」才是真正的回合结束（最终回复或停在确认卡片）。
func tabResumed(_ tabId: String, after endedAt: Date) -> Bool {
    (tabRunningSince[tabId] ?? .distantPast) > endedAt
}

    func poll() {
        for url in currentIdeaLogs() {
            let path = url.path
            let size = fileSize(url)
            var off = offsets[path] ?? size // 新出现的日志文件从末尾开始
            if size < off { off = 0 }        // 日志轮转
            guard size > off else { offsets[path] = size; continue }
            if let handle = try? FileHandle(forReadingFrom: url) {
                try? handle.seek(toOffset: off)
                if let data = try? handle.readToEnd(),
                   let text = String(data: data, encoding: .utf8) {
                    for line in text.split(separator: "\n") {
                        processLine(String(line), collectError: true)
                    }
                }
                try? handle.close()
            }
            offsets[path] = size
        }
    }

    private func currentIdeaLogs() -> [URL] {
        guard let dirs = try? fm.contentsOfDirectory(atPath: logsRoot.path) else { return [] }
        return dirs
            .map { logsRoot.appendingPathComponent($0).appendingPathComponent("idea.log") }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    /// 处理一行 idea.log：插件运行错误 / Tab 状态变更
    private func processLine(_ line: String, collectError: Bool) {
        if collectError, isIdeaAgentErrorLine(line) {
            latestError = IdeaError(at: Date(), msg: extractIdeaErrorMsg(line))
        } else if let (tabId, status) = parseIdeaTabStatus(line) {
            let at = parseIdeaLogTimestamp(line) ?? Date()
            if status == "running" {
                tabRunningSince[tabId] = at
            } else if let since = tabRunningSince.removeValue(forKey: tabId) {
                finishedTurns.append(IdeaTabTurn(tabId: tabId, runningSince: since, endedAt: at, status: status))
            }
        }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }
}

// MARK: - CatDesk 工具确认事件（~/.catpaw/logs/app.N.log）

/// 解析 app 日志行中的 conversationId
func parseDeskAppLogConversationId(_ line: String) -> String? {
    guard let r = line.range(of: "conversationId=") else { return nil }
    let rest = line[r.upperBound...]
    guard rest.count >= 36 else { return nil }
    let cid = String(rest.prefix(36))
    return cid.contains("-") ? cid : nil
}

/// 增量跟踪 CatDesk 的 app.N.log，发现「发现需要确认的工具调用」事件（提案时即记录，
/// 此时 jsonl 还没有任何新事件，是 CatDesk 侧等待确认的唯一即时信号）。
///
/// 注意必须按文件独立尾随（offsets 按路径记录），不能「按 mtime 选最新文件单文件跟踪」：
/// CatDesk 可能多个 CLI 进程并行写不同序号的日志（如旧进程写 app.3.log、新进程写
/// app.4.log），mtime 最新者会来回跳动；每次「换文件」若从 0 重读，会把几十 MB 历史里的
/// 旧确认事件当新事件重复告警（2026-10-12 19:42 误报事故：app.3↔app.4 跳动，重读
/// app.3.log 全文，把 9-24 和 10-10 的旧事件重新发出）。
final class DeskAppLogTracker {
    private var pending: [(conversationId: String, at: Date)] = []
    /// 提问卡（AskQuestion）悬置事件：agent/turn-executor 的 #XMDT# 元数据
    /// status=interaction_pending / exitReason=interaction_pending / interactionPending=true
    private var pendingInteractions: [(conversationId: String, at: Date)] = []
    /// 用户手动停止事件：reason=user_stop（[Turn] aborted）/ status=canceled（reportStatus）
    private var pendingStops: [(conversationId: String, at: Date)] = []
    /// 每个 app.N.log 的读取偏移（按文件路径独立）
    private var offsets: [String: UInt64] = [:]
    /// 每个文件的跨行残片
    private var leftovers: [String: String] = [:]
    private let logsDir: URL
    private let fm = FileManager.default

    init(logsDir: URL = Config.catpawLogsDir) { self.logsDir = logsDir }

    /// 启动：所有文件对齐到末尾，历史确认事件不重复提醒
    func calibrate() {
        offsets.removeAll()
        leftovers.removeAll()
        for url in appLogs() { offsets[url.path] = fileSize(url) }
    }

    func takePendingConfirms() -> [(conversationId: String, at: Date)] {
        defer { pending.removeAll() }
        return pending
    }

    func takePendingInteractions() -> [(conversationId: String, at: Date)] {
        defer { pendingInteractions.removeAll() }
        return pendingInteractions
    }

    func takePendingStops() -> [(conversationId: String, at: Date)] {
        defer { pendingStops.removeAll() }
        return pendingStops
    }

    func poll() {
        for url in appLogs() {
            let path = url.path
            let size = fileSize(url)
            if let off = offsets[path], size < off {
                // 文件被截断重写：从头读
                offsets[path] = 0
                leftovers[path] = ""
            }
            guard let offset = offsets[path] else {
                // 运行中新出现的文件（轮转/新进程）：跳过既有内容只追新增，
                // 防止把历史确认事件当新事件重复提醒
                offsets[path] = size
                continue
            }
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { continue }
            try? handle.seek(toOffset: offset)
            let data = try? handle.readToEnd()
            try? handle.close()
            guard let data, let text = String(data: data, encoding: .utf8) else { continue }
            offsets[path] = size
            let chunk = (leftovers[path] ?? "") + text
            var lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            leftovers[path] = chunk.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
            for line in lines {
                // 工具确认卡：必须来自 tool-orchestrator 组件——Assistant 回复正文
                // （turn-executor 记录）里若引用这句话，不能误判为确认事件
                if line.contains("tool-orchestrator") && line.contains("发现需要确认的工具调用") {
                    if let cid = parseDeskAppLogConversationId(line) {
                        pending.append((cid, parseIdeaLogTimestamp(line) ?? Date()))
                    }
                    continue
                }
                // 提问卡（AskQuestion）悬置：仅匹配 #XMDT# 元数据字段，不碰正文
                if line.contains("status=interaction_pending")
                    || line.contains("exitReason=interaction_pending")
                    || line.contains("interactionPending=true") {
                    if let cid = parseDeskAppLogConversationId(line) {
                        pendingInteractions.append((cid, parseIdeaLogTimestamp(line) ?? Date()))
                    }
                    continue
                }
                // 用户手动停止：回合中止（reason=user_stop）/ 状态上报取消（status=canceled）
                if line.contains("reason=user_stop") || line.contains("status=canceled") {
                    if let cid = parseDeskAppLogConversationId(line) {
                        pendingStops.append((cid, parseIdeaLogTimestamp(line) ?? Date()))
                    }
                }
            }
        }
    }

    /// 所有 app.N.log（按文件名排序，稳定遍历全部序号文件）
    private func appLogs() -> [URL] {
        guard let files = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return [] }
        return files
            .filter { $0.hasPrefix("app") && $0.hasSuffix(".log") }
            .sorted()
            .map { logsDir.appendingPathComponent($0) }
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func fileMtime(_ url: URL) -> Date? {
        try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

// MARK: - CatPaw 插件/IDE 界面状态库（globalCache.sqlite）

/// t_ui_messages 工具消息行的卡片状态
enum MideCardState: Equatable {
    /// 卡片悬置等待用户操作（question=true 为 AskQuestion 提问卡）
    case pending(tool: String, question: Bool)
    /// 卡片已了结（回答/批准/拒绝/取消/失败）
    case resolved
    /// 与卡片无关的中间态
    case other
}

/// 解析 t_ui_messages.content（JSON）判定卡片状态：
/// - 提问卡：tooluseName=AskQuestion 且 status=asking → 悬置；answered → 了结
/// - 工具确认卡：toolAskStatus=normal 且 streamStatus=streaming → 悬置；
///   toolAskStatus=tool_execute_* 或 streamStatus=completed → 了结
func mideCardState(content: String) -> MideCardState {
    guard let data = content.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return .other }
    let tool = obj["tooluseName"] as? String ?? ""
    let status = obj["status"] as? String ?? ""
    let askStatus = obj["toolAskStatus"] as? String ?? ""
    let stream = obj["streamStatus"] as? String ?? ""
    if status == "asking" { return .pending(tool: tool, question: true) }
    if status == "answered" { return .resolved }
    if askStatus == "normal" && stream == "streaming" {
        return .pending(tool: tool, question: false)
    }
    if askStatus.hasPrefix("tool_execute_") || stream == "completed" { return .resolved }
    return .other
}

/// 增量跟踪 CatPaw 插件端（JETBRAINS）与 CatPaw IDE 独立端（MIDE）共用的
/// mcopilot 界面状态库（Config.mideCacheDB）。
///
/// 背景（v0.10.31）：这两个客户端的 transcript.txt 只在回合落盘点才写入——
/// 提问卡/确认卡悬置期间磁盘零足迹（新会话甚至连会话目录都还没创建），
/// transcript 尾部判定（v0.10.29）覆盖不到；而所有卡片都实时写入
/// t_ui_messages（UI 渲染数据源），这是卡片悬置的唯一即时落盘信号。
final class MideUICacheTracker {
    /// 一张悬置中的卡片
    struct PendingCard {
        let conversationId: String
        let tool: String
        let isQuestion: Bool
        let firstSeen: Date
    }
    /// conversation_id → 悬置卡片（了结时移除；同一会话同一时刻只有一张卡）
    private(set) var pendingCards: [String: PendingCard] = [:]
    /// 本轮新了结卡片的会话 ID（用于解除既有悬置钉住）
    private var resolvedIds: [String] = []
    /// update_time 高水位（毫秒）
    private var watermarkMs: Int64 = 0
    /// 会话元信息缓存（t_conversations：标题/端类型/工作区），查不到不缓存（行可能稍后才有）
    private var metaCache: [String: (title: String?, ideType: String, workspace: String)] = [:]
    private let dbURL: URL

    init(dbURL: URL = Config.mideCacheDB) { self.dbURL = dbURL }

    /// 启动：水位对齐到回看窗口——正在悬置的卡片首轮即识别，更早的孤儿卡不重复提醒
    func calibrate(now: Date = Date()) {
        watermarkMs = Int64(now.addingTimeInterval(-Config.mideCardStartupWindow)
            .timeIntervalSince1970) * 1000
    }

    func takeResolved() -> [String] {
        defer { resolvedIds.removeAll() }
        return resolvedIds
    }

    /// 会话元信息（标题/端类型 JETBRAINS|MIDE /工作区路径）
    func conversationMeta(_ cid: String)
        -> (title: String?, ideType: String, workspace: String)? {
        if let hit = metaCache[cid] { return hit }
        var result: (String?, String, String)?
        query("SELECT title, ide_type, workspace_id FROM t_conversations "
            + "WHERE conversation_id = '\(cid)'") { stmt in
            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            let ide = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let ws = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            result = (title, ide, ws)
        }
        if let result { metaCache[cid] = result }
        return result
    }

    func poll(now: Date = Date()) {
        var maxSeen = watermarkMs
        // 注意 +message_type 的一元加号不是笔误：t_ui_messages 超 10 万行且 content
        // 总量上 GB（大量 overflow 页）。若让 SQLite 走 idx_message_type 等值索引，
        // 需回表 4 万+ tool 行并临时 B 树排序，主线程每轮卡 ~4 秒（点 Dock 图标迟迟
        // 不前台的根因）。一元加号使该项不可用于索引，规划器改走
        // idx_message_update_time 范围扫描（天然有序），只回表新增行，毫秒级完成。
        query("SELECT conversation_id, content, update_time FROM t_ui_messages "
            + "WHERE update_time > \(watermarkMs) AND +message_type = 'tool' "
            + "ORDER BY update_time") { [self] stmt in
            guard let cstr = sqlite3_column_text(stmt, 0),
                  let contentC = sqlite3_column_text(stmt, 1) else { return }
            let cid = String(cString: cstr)
            let content = String(cString: contentC)
            let ts = sqlite3_column_int64(stmt, 2)
            if ts > maxSeen { maxSeen = ts }
            switch mideCardState(content: content) {
            case .pending(let tool, let question):
                if pendingCards[cid] == nil {
                    pendingCards[cid] = PendingCard(
                        conversationId: cid, tool: tool, isQuestion: question,
                        firstSeen: Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
                }
            case .resolved:
                if pendingCards.removeValue(forKey: cid) != nil { resolvedIds.append(cid) }
            case .other:
                break
            }
        }
        watermarkMs = maxSeen
        // 卡片永不回应（用户直接关掉 IDE 等）：超时按了结处理，避免会话永远钉在悬置
        let ttl = Config.tabTurnEvalWindow
        for (cid, card) in pendingCards where now.timeIntervalSince(card.firstSeen) > ttl {
            pendingCards.removeValue(forKey: cid)
            resolvedIds.append(cid)
        }
    }

    /// 每轮短连接只读查询（WAL 模式下只读连接可并发；失败静默跳过等下轮）
    private func query(_ sql: String, row: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 800)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while let s = stmt, sqlite3_step(s) == SQLITE_ROW { row(s) }
    }
}

// MARK: - CatDesk 服务端会话标题

/// CatDesk 侧栏的 AI 摘要标题（如「开发 Mac 办公工具：监控 CatPaw」）由 conversation.summary
/// 在服务端生成，本地 jsonl / 日志 / 压缩 LevelDB 均无法读取。这里用 sso_config.json 的
/// ssoid 调 conversation/list 接口周期性同步，覆盖首句截断标题，与 CatDesk 侧栏保持一致。
final class DeskTitleFetcher {
    private var lastAttemptAt = Date.distantPast
    private var lastAttemptOK = false
    private var inFlight = false

    /// 从 sso_config.json 读取 ssoid（CatDesk 登录态，App 会自动刷新该文件）
    static func readSSOID(url: URL = Config.ssoConfigURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ssoid = obj["ssoid"] as? String, !ssoid.isEmpty else { return nil }
        return ssoid
    }

    /// 解析一页列表响应 → (conversationId → 标题, 总条数)；业务失败返回 nil
    static func parseTitles(from data: Data) -> (titles: [String: String], total: Int)? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["unifyCode"] as? Int) == 0,
              let d = obj["data"] as? [String: Any],
              let total = d["total"] as? Int,
              let list = d["list"] as? [[String: Any]] else { return nil }
        var titles: [String: String] = [:]
        for item in list {
            guard let cid = item["conversationId"] as? String,
                  let t = item["title"] as? String else { continue }
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { titles[cid] = trimmed }
        }
        return (titles, total)
    }

    /// 节流拉取：成功 5 分钟一次，失败 1 分钟重试；completion 在主线程回调（仅成功时）
    func fetchIfDue(now: Date = Date(), completion: @escaping ([String: String]) -> Void) {
        guard !inFlight else { return }
        let minInterval = lastAttemptOK ? Config.deskTitleFetchInterval : Config.deskTitleRetryInterval
        guard now.timeIntervalSince(lastAttemptAt) >= minInterval,
              let ssoid = DeskTitleFetcher.readSSOID() else { return }
        inFlight = true
        lastAttemptAt = now
        DispatchQueue.global(qos: .utility).async {
            var all: [String: String] = [:]
            var ok = false
            var page = 1
            var total = Int.max
            // pageSize 上限 100，最多翻 5 页（500 个会话足够覆盖监控范围）
            while page <= 5, (page - 1) * 100 < total {
                guard let data = DeskTitleFetcher.requestPage(page, ssoid: ssoid),
                      let (titles, t) = DeskTitleFetcher.parseTitles(from: data) else { break }
                all.merge(titles) { _, new in new }
                total = t
                ok = true
                page += 1
            }
            DispatchQueue.main.async {
                self.inFlight = false
                self.lastAttemptOK = ok
                if ok { completion(all) }
            }
        }
    }

    /// 同步请求一页（仅在后台队列内调用）
    private static func requestPage(_ page: Int, ssoid: String) -> Data? {
        guard let url = URL(string: Config.deskTitleAPI) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ssoid=\(ssoid)", forHTTPHeaderField: "Cookie")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pageNum": page, "pageSize": 100])
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        return sem.wait(timeout: .now() + 15) == .success ? result : nil
    }
}

// MARK: - 会话手动改名

/// 手动改名存储：IDEA 插件会话的 Tab 标题（AI 摘要）只存在 mcopilot 服务端与插件内存，
/// 本地文件/日志/开放 API 均不可达（已逐一排查）→ 提供右键重命名人工对齐，持久化到本地。
/// key 为会话文件路径（含会话 UUID，稳定）。手动标题优先级最高，覆盖首句标题与服务端标题。
final class CustomTitleStore {
    private let url: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    private(set) var titles: [String: String] = [:]

    init(url: URL = Config.customTitlesURL) {
        self.url = url
        load()
    }

    func title(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return titles[key] }

    /// 设置/清除（传 nil 或空白）手动标题并落盘
    func set(_ title: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { titles.removeValue(forKey: key) } else { titles[key] = trimmed }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        titles = obj
    }

    private func save() {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: titles,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url)
    }
}

// MARK: - 会话状态机

/// Dock 图标状态角标：在应用图标底部叠加深色条带，显示 待确认/执行中/已完成 数量。
/// 消失机制：
/// - 待确认/执行中为实时统计，归零自动恢复纯净图标；
/// - 已完成按「未读」语义累计，应用激活（用户看过窗口）时清零；
/// - 应用在前台时新完成不计入未读；超过 1 小时未查看自动过期清零。
enum DockStatus {
    static func setQueueCounts(completed: Int) {
        completedUnack = completed
        lastCompletedAt = Date()
    }
    private(set) static var completedUnack = 0
    private(set) static var lastCompletedAt = Date.distantPast
    /// 已完成未读过期时间（秒）
    static var doneExpire: TimeInterval = 3600
    private static var lastRendered: (Int, Int, Int)?

    /// 一个会话进入已完成 → 累计未读（应用前台时不计，用户正看着）
    static func noteCompleted(now: Date = Date()) {
        if NSApp != nil, NSApp.isActive { return }
        completedUnack += 1
        lastCompletedAt = now
    }

    /// 用户激活应用 → 未读清零并按最近统计重绘
    static func acknowledge() {
        completedUnack = 0
        lastRendered = nil
        if let last = lastCounts { render(running: last.0, awaiting: last.1) }
    }

    private static var lastCounts: (Int, Int)?

    /// 未读过期判定（纯逻辑，可测试）
    static func effectiveDone(now: Date = Date()) -> Int {
        if completedUnack > 0, now.timeIntervalSince(lastCompletedAt) > doneExpire {
            completedUnack = 0
        }
        return completedUnack
    }

    /// 每个轮询周期调用：按当前统计重绘 Dock 图标（数值不变时跳过）
    static func render(running: Int, awaiting: Int, now: Date = Date()) {
        lastCounts = (running, awaiting)
        let done = effectiveDone(now: now)
        let key = (running, awaiting, done)
        if let last = lastRendered, last == key { return }
        lastRendered = key
        guard Bundle.main.bundleIdentifier != nil, NSApp != nil else { return }
        let tile = NSApp.dockTile
        if running == 0, awaiting == 0, done == 0 {
            if tile.contentView != nil { tile.contentView = nil; tile.display() }
            return
        }
        let size = tile.size
        guard size.width > 0 else { return }
        let iv = NSImageView(image: makeImage(running: running, awaiting: awaiting, done: done, size: size))
        iv.frame = NSRect(origin: .zero, size: size)
        tile.contentView = iv
        tile.display()
    }

    /// 绘制：应用图标打底 + 底部状态条带
    static func makeImage(running: Int, awaiting: Int, done: Int, size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        defer { img.unlockFocus() }
        let rect = NSRect(origin: .zero, size: size)
        // 裁剪为圆角矩形，避免状态条带的直角突出图标轮廓
        NSBezierPath(roundedRect: rect, xRadius: size.width * 0.225, yRadius: size.width * 0.225).addClip()
        if let icon = NSApp?.applicationIconImage {
            icon.draw(in: rect)
        } else {
            NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.75, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: size.width * 0.22, yRadius: size.width * 0.22).fill()
        }
        // 状态行（每行可多个分段）：最多两行，保证小猫脸部不被遮挡
        let yellow = NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.25, alpha: 1)
        let green = NSColor(calibratedRed: 0.25, green: 0.85, blue: 0.50, alpha: 1)
        var lines: [[(String, NSColor)]] = []
        if awaiting > 0 {
            var rest: [(String, NSColor)] = []
            if running > 0 { rest.append(("执行中 \(running)", green)) }
            if done > 0 { rest.append(("已完成 \(done)", .white)) }
            lines = [[("待确认 \(awaiting)", yellow)]] + (rest.isEmpty ? [] : [rest])
        } else {
            if running > 0 { lines.append([("执行中 \(running)", green)]) }
            if done > 0 { lines.append([("已完成 \(done)", .white)]) }
        }
        guard !lines.isEmpty else { return img }

        // 单行更宽松、字号更大（Dock 小尺寸下可读性优先）
        let lineH = size.height * (lines.count == 1 ? 0.21 : 0.165)
        let pad = size.height * 0.025
        let bandH = lineH * CGFloat(lines.count) + pad * 2
        let bandRect = NSRect(x: 0, y: 0, width: size.width, height: bandH)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bandRect, xRadius: size.width * 0.12, yRadius: size.width * 0.12).fill()

        let dotR = lineH * 0.22
        let gap = lineH * 0.25
        let segGap = lineH * 0.55
        // 字号自适应：任一行超宽则整体缩字号（最多打 5 折）
        let maxW = size.width * 0.96
        var fontSize = lineH * 0.8
        var attrs: [NSAttributedString.Key: Any] = [:]
        func lineWidth(_ line: [(String, NSColor)]) -> CGFloat {
            var w: CGFloat = 0
            for (j, seg) in line.enumerated() {
                w += dotR * 2 + gap + (seg.0 as NSString).size(withAttributes: attrs).width
                if j < line.count - 1 { w += segGap }
            }
            return w
        }
        while fontSize > lineH * 0.37 {
            attrs = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.white]
            if lines.allSatisfy({ lineWidth($0) <= maxW }) { break }
            fontSize *= 0.88
        }
        attrs = [.font: NSFont.boldSystemFont(ofSize: fontSize), .foregroundColor: NSColor.white]
        for (i, line) in lines.enumerated() {
            let cy = pad + lineH * CGFloat(lines.count - 1 - i) + lineH / 2
            var totalW: CGFloat = 0
            for (j, seg) in line.enumerated() {
                totalW += dotR * 2 + gap + (seg.0 as NSString).size(withAttributes: attrs).width
                if j < line.count - 1 { totalW += segGap }
            }
            var x = (size.width - totalW) / 2
            for (j, seg) in line.enumerated() {
                seg.1.setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: cy - dotR, width: dotR * 2, height: dotR * 2)).fill()
                x += dotR * 2 + gap
                let textSize = (seg.0 as NSString).size(withAttributes: attrs)
                (seg.0 as NSString).draw(at: NSPoint(x: x, y: cy - textSize.height / 2), withAttributes: attrs)
                x += textSize.width + (j < line.count - 1 ? segGap : 0)
            }
        }
        return img
    }

    /// 测试用：重置全部状态
    static func resetForTesting() {
        completedUnack = 0
        lastCompletedAt = .distantPast
        lastRendered = nil
        lastCounts = nil
    }
}

enum SessionState: String {
    case idle = "空闲"
    case running = "执行中"
    case done = "已完成"
    case stuck = "疑似暂停/中断"
    case error = "异常中断"
    case awaitingConfirm = "等待手动确认"
    case stopped = "已停止"

    var icon: String {
        switch self {
        case .running: return "🟢"
        case .done: return "✅"
        case .stuck: return "⚠️"
        case .error: return "⛔️"
        case .awaitingConfirm: return "🟡"
        case .stopped: return "⏹"
        case .idle: return "⚪️"
        }
    }

    var tint: Color {
        switch self {
        case .running: return Color(red: 0.25, green: 0.85, blue: 0.50)
        case .done: return Color(red: 0.30, green: 0.65, blue: 0.98)
        case .stuck: return Color(red: 0.98, green: 0.60, blue: 0.25)
        case .error: return Color(red: 0.96, green: 0.35, blue: 0.35)
        case .awaitingConfirm: return Color(red: 0.98, green: 0.80, blue: 0.25)
        case .stopped, .idle: return Color.ink(0.35)
        }
    }
}

final class SessionWatch {
    enum Kind {
        /// IDEA CatPaw 插件：transcript 尾部内容判定
        case ideaTranscript
        /// CatDesk：优先使用 api-request.log 回合流信号，缺失时回退 jsonl 末帧判定
        case deskConversation
        /// Codex CLI：rollout jsonl 事件流（task_started/task_complete/工具调用）判定
        case codexSession
        /// Claude Code：项目 jsonl 末帧（stop_reason/tool_use/tool_result）判定
        case claudeSession
        /// Trae / TRAE SOLO：工作区 state.vscdb 的会话索引（entries 结构未定稿，
        /// 先按库文件活动做工作区级展示，无回合级判定与通知）
        case traeState
        /// DeepSeek Harness（dsh）：~/.dsh/sessions 的 zstd 压缩语义事件流
        /// （turn/start·end、approval/asked·decided）判定
        case dshSession
    }

    let kind: Kind
    let url: URL
    let label: String
    /// 来源渠道标识（同一来源内的细分：IDE-CatPaw 下分 JetBrains 插件端 / CatPaw IDE 独立端）
    let channel: String?
/// 会话标题：初始为首条提问截断；CatDesk 会话会被服务端 AI 摘要标题覆盖（与侧栏一致）；
/// 手动改名优先级最高
var title: String?
/// 发现时的原始标题（首句截断），清除手动改名后回退到它
let derivedTitle: String?
/// 会话根目录：监控其下所有文件的活动（工具执行/终端输出也会刷新）
let sessionDir: URL?
    /// CatDesk 会话 ID（用于关联 api-request.log 回合信号）
    let conversationId: String?

    var state: SessionState = .idle {
        didSet {
            if state == .done, oldValue != .done, !Notify.managedDelivery { DockStatus.noteCompleted() }
        }
    }
    /// 最近一次观测到的活动（用于计算静默时长）
var lastActivity = Date.distantPast
/// 最近一次观测到的文件 mtime（用于变更检测与静默回合归因）
private(set) var lastSeenMtime = Date.distantPast
/// 文件内容高水位（字节数）。已完成状态下，只有 mtime 触达且大小超过它
/// 才允许重新武装通知：Claude Code 等会周期性原样重写会话文件（内容不变
/// 仅刷 mtime），只看 mtime 会把早已结束的回合重置 → 误报「回合结束」
private var lastSeenSize: UInt64 = 0
var notifiedDone = false
    var notifiedStuck = false
    var notifiedError = false
    var notifiedAwait = false
    /// 外部信号判定的「等待手动确认」（确认卡片不产生任何文件写入，需靠此外部标记压住状态机）
    var awaitingExternal = false
    var waitConfirmed = false
    var waitIsQuestion = false
    var waitEvidence: String?
    var waitSignalAt: Date?
    private var awaitSignature: String?
    /// 用户已手动停止（CatDesk app 日志 user_stop/status=canceled）：门闩压住状态机，
    /// 防止 status 字典中残留的 .done 信号每轮把状态翻回 running/awaitingConfirm；
    /// 新一轮写入或新流打开（用户继续提问）时解除
    var userStopped = false
    /// 标记悬置时的文件大小：悬置期间只有内容真正增长才解除（目录级 mtime 噪声不解除）
    private var awaitMarkSize: UInt64 = 0
    /// 是否已收到过首个回合流信号（首个信号静默对齐基线，不补发通知）
    private var deskSignalSeen = false
    /// 首次观测到流异常的时间（用于 deskErrorGrace 防抖）
    private var deskErrorSince: Date?
    /// 最近一次被归因的 IDEA 插件错误时间
    var lastIdeaErrorAt = Date.distantPast

    private let fm = FileManager.default

    init(kind: Kind, url: URL, label: String, title: String? = nil,
         sessionDir: URL? = nil, conversationId: String? = nil, channel: String? = nil) {
        self.kind = kind
        self.url = url
        self.label = label
        self.title = title
        self.derivedTitle = title
        self.sessionDir = sessionDir
        self.conversationId = conversationId
        self.channel = channel
    }

    /// 来源名称（用于标题前缀与面板分组）
    var sourceName: String {
        switch kind {
        case .ideaTranscript: return "IDE-CatPaw"
        case .deskConversation: return "CatDesk"
        case .codexSession: return "Codex"
        case .claudeSession: return "Claude"
        case .traeState: return "Trae"
        case .dshSession: return "DeepSeek"
        }
    }

    /// 通知携带的会话定位信息：点击通知时打开来源 app（能锚定则锚定到会话）
    private var notifyContext: [String: String] { ["kind": sourceName, "path": url.path] }

    /// 展示用主标题：来源前缀 + 会话标题（无标题时用标签）
    var displayName: String { "\(sourceName)：\(title ?? label)" }

    /// 启动时对齐基线。近期有活动的会话假定仍在执行（避免显示「空闲」误报），
    /// 但抑制首次收敛的通知，防止对启动前已结束的会话补发。
    func calibrate(now: Date = Date()) {
        lastSeenMtime = latestActivity()
        lastActivity = lastSeenMtime
        lastSeenSize = fileSize(url)
        if now.timeIntervalSince(lastSeenMtime) < Config.assumeRunningWindow {
            state = .running
            notifiedDone = true
            notifiedStuck = true
        }
    }

    func poll(now: Date = Date(), deskSignal: DeskTurnSignal? = nil) {
        let mtime = latestActivity()
        if mtime > lastSeenMtime {
            lastSeenMtime = mtime
            let size = fileSize(url)
            let grew = size > lastSeenSize
            lastSeenSize = size
            lastActivity = now
            // 已完成之后，只有会话文件内容真实增长才允许重新武装：
            // Claude Code 会周期性原样重写会话文件（内容不变仅刷 mtime），
            // 若不加区分地重置 notifiedDone，会对旧最终回复误报「回合结束」
            if state == .done && !grew { return }
            if awaitingExternal {
                // 悬置期间：只有 transcript/jsonl 内容真正增长（用户确认/拒绝后工具落盘）才解除
                let signature = readTailText(url: url, maxBytes: 8192).map(stableKey)
                guard fileSize(url) != awaitMarkSize || (signature != nil && signature != awaitSignature) else {
                    state = .awaitingConfirm
                    return
                }
                clearAwaiting()
            }
            // 有写入 → 视为活跃（重新武装所有通知开关）
            state = .running
            userStopped = false
            notifiedDone = false
            notifiedStuck = false
            notifiedError = false
            notifiedAwait = false
            return
        }

        let idleFor = now.timeIntervalSince(lastActivity)
        if state == .done && notifiedDone && (kind == .codexSession || kind == .claudeSession || kind == .ideaTranscript) { return }

        switch kind {
        case .ideaTranscript:
            pollIdea(now: now, idleFor: idleFor)
        case .deskConversation:
            if let sig = deskSignal {
                pollDeskBySignal(sig, now: now)
            } else {
                pollDeskLegacy(now: now, idleFor: idleFor)
            }
        case .codexSession:
            pollCodex(now: now, idleFor: idleFor)
        case .claudeSession:
            pollClaude(now: now, idleFor: idleFor)
        case .traeState:
            pollTraeState(now: now, idleFor: idleFor)
        case .dshSession:
            pollDsh(now: now, idleFor: idleFor)
        }
    }

    /// 外部信号判定会话停在确认卡片：
    /// IDEA 插件「回合结束但 transcript 零产出」/ CatDesk「app 日志发现需要确认的工具调用」
    func markAwaitingConfirm(source: String, confirmed: Bool = false, question: Bool = false, at: Date? = nil) {
        awaitMarkSize = fileSize(url)
        awaitSignature = readTailText(url: url, maxBytes: 8192).map(stableKey)
        waitConfirmed = confirmed
        waitIsQuestion = question
        waitSignalAt = at ?? lastActivity
        waitEvidence = confirmed ? (question ? "来源明确报告未决提问" : "来源明确报告未决审批") : "工具调用长期未返回；执行与等待审批尚不能区分"
        awaitingExternal = true
        state = .awaitingConfirm
        if !notifiedAwait {
            notifiedAwait = true
            Notify.send(title: "\(source) 等待手动确认 🟡",
                        body: "\(displayName) 可能在等待你确认操作（如删除/执行命令）",
                        sound: "DogBark", context: notifyContext)
        }
    }

    /// 后续回合正常产出（对话已继续）→ 解除悬置并重新武装，不发通知
    func clearAwaiting() {
        awaitingExternal = false
        notifiedAwait = false
        waitConfirmed = false
        waitIsQuestion = false
        waitEvidence = nil
        waitSignalAt = nil
    }

    /// 用户手动停止会话（CatDesk app 日志 reason=user_stop / status=canceled）：
    /// 解除悬置钉住并落终态「已停止」，不补发通知——
    /// 停在确认卡片的 jsonl 尾部永远不会再变，不处理会永远挂在「等待确认」（v0.10.30）
    func markUserStopped(source: String) {
        if awaitingExternal { clearAwaiting() }
        guard state == .running || state == .awaitingConfirm || state == .stuck else { return }
        Notify.log("手动停止：\(displayName)（\(source)）→ 已停止")
        state = .stopped
        userStopped = true
    }

    // MARK: 周期兜底深扫

    /// 周期性兜底纠正（Monitor 每 Config.deepSweepInterval 触发一次）：
    /// 1. 外部悬置信号把会话钉在「等待手动确认」，但文件尾部已出现回合结束边界
    ///    （典型：Claude 压缩会话文件后 awaitMarkSize 增长检查永久失效）→ 解除钉住
    /// 2. CatDesk 流信号丢失（app 崩溃/日志轮转）时，运行中的会话 jsonl 已收尾 → 直接收敛
    /// 返回是否发生了纠正（用于日志）
    func deepSweep(now: Date) -> Bool {
        var corrected = false
        if awaitingExternal, tailSaysFinished() {
            clearAwaiting()
            corrected = true
        }
        if kind == .deskConversation,
           state == .running || state == .stuck || state == .awaitingConfirm,
           deskTurnFinished(), now.timeIntervalSince(lastActivity) >= Config.deskDoneGrace {
            state = .done
            if !notifiedDone {
                notifiedDone = true
                Notify.send(title: "CatDesk 回合结束 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
            corrected = true
        }
        return corrected
    }

    /// 各来源「尾部已收尾」的结构性判定（用于解除外部悬置钉住）
    private func tailSaysFinished() -> Bool {
        switch kind {
        case .claudeSession: return claudeTailState() == .finalReply
        case .codexSession: return codexTailState() == .done
        case .deskConversation: return deskTurnFinished()
        case .ideaTranscript:
            // ideaTailState() 本身就是可靠的结构性信号（确认卡片检测也在用）：
            // 用户确认/拒绝后回合跑完，transcript 尾部以 assistant 最终回复收尾 → 解除钉住；
            // .working / .pendingToolCall 说明任务仍在推进或仍悬置，保持钉住。
            return ideaTailState() == .complete
        case .traeState: return true // 无悬置钉住机制，兜底空实现
        case .dshSession: return dshTailCache?.turnEnd != nil
        }
    }

    /// 归因到本会话的 IDEA 插件运行错误（网络失败等，transcript 不再推进）
    func markIdeaError(at: Date, msg: String) {
        lastIdeaErrorAt = at
        state = .error
        if !notifiedError {
            notifiedError = true
            Notify.send(title: "CatPaw 会话异常中断 ⛔️",
                        body: "\(displayName)：\(msg)",
                        sound: "DogBark", context: notifyContext)
        }
    }

    // MARK: IDEA 轮询

private func pollIdea(now: Date, idleFor: TimeInterval) {
// 外部信号压住的悬置态：直到 transcript 出现新写入前不被状态机覆盖
if awaitingExternal { state = .awaitingConfirm; return }
guard state == .running || state == .done || state == .awaitingConfirm else { return }

        let complete = tailLooksComplete()
        if idleFor >= Config.doneGrace && complete {
            state = .done
            if !notifiedDone {
                notifiedDone = true
                Notify.send(title: "CatPaw 任务完成 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
            return
        }
        guard !complete && state != .done else { return }

        // 工具调用悬置（尾部停在无 [Tool result] 收尾的 [Tool call]）：
        // [Tool call] 在模型发起调用时即落盘，与用户是否确认无关——非后台工具持续悬置
        // 且无执行活动 → 停在 IDE 确认卡片（delete_file / run_terminal_cmd 等需手动批准
        // 的工具）。该判定不依赖 idea.log 回合事件，插件端与 CatPaw IDE 独立端同样生效
        // （v0.10.29，替代原先仅识别 run_terminal_cmd 的 tailEndsWithPendingCommand）。
        if case .pendingToolCall(let background) = ideaTailState() {
            // 活跃阈值内不提醒：等自动审批工具的 [Tool result] 落盘；
            // latestActivity 已含 agent-tools/terminals 写入，执行中的工具 idleFor 恒小，
            // hasToolActivity 兜底不落盘的长工具，二者共同排除「自动执行中」误报
            if !background, idleFor >= Config.cardSettleDelay,
               !hasToolActivity(after: lastActivity) {
                markAwaitingConfirm(source: "CatPaw")
            }
            return // 悬置期间不再升级为「疑似中断」
        }

        // 模型长思考期间 transcript 不落盘，放宽阈值
        let threshold = tailEndsWithThinking()
            ? Config.thinkingStuckThreshold
            : Config.stuckThreshold
        if idleFor >= threshold {
            state = .stuck
            if !notifiedStuck {
                notifiedStuck = true
                Notify.send(title: "CatPaw 疑似暂停/中断 ⚠️",
                            body: "\(displayName) 已 \(Int(idleFor))s 无进展",
                            sound: "DogBark", context: notifyContext)
            }
        }
    }

    // MARK: Codex 轮询（rollout jsonl 事件流）

    /// Codex 尾部状态：task_started/task_complete 决定回合边界；
    /// 悬置的 custom_tool_call/function_call（无对应 *_output）= 等待审批或工具执行中
    enum CodexTailState: Equatable {
        case done        // 最后的回合边界是 task_complete
        case running     // task_started 后未完结
        case pendingTool // 悬置工具调用
        case awaitingUserInput // task_complete 收尾但最后一个调用是 request_user_input（提问卡片，output 仅是受理回执）
        case unknown
    }

    func codexTailState() -> CodexTailState {
        guard let tail = readTail(maxBytes: 65536) else { return .unknown }
        var boundary: CodexTailState = .unknown
        var pendingCall = false
        // 提问卡片是否悬而未答：request_user_input 调用置位；
        // 用户作答/新提问都会以 task_started 开启新回合 → 旧卡片已了结，复位
        var questionPending = false
        for line in tail.split(separator: "\n") {
            if line.contains("\"type\":\"task_started\"") {
                boundary = .running
                questionPending = false
            }
            if line.contains("\"type\":\"task_complete\"") { boundary = .done }
            if line.contains("\"type\":\"custom_tool_call\"") || line.contains("\"type\":\"function_call\"") {
                pendingCall = true
                // payload 的 name 字段出现在 arguments 之前，取首个匹配即可
                if let r = line.range(of: "\"name\":\""),
                   let e = line[r.upperBound...].firstIndex(of: "\"") {
                    let name = line[r.upperBound..<e]
                    if name.hasPrefix("request_user_input") { questionPending = true }
                }
            }
            if line.contains("\"type\":\"custom_tool_call_output\"") || line.contains("\"type\":\"function_call_output\"") {
                pendingCall = false
            }
        }
        if questionPending { return .awaitingUserInput }
        if boundary == .done { return .done }
        if pendingCall { return .pendingTool }
        return boundary
    }

    private func pollCodex(now: Date, idleFor: TimeInterval) {
        if awaitingExternal { state = .awaitingConfirm; return }
        switch codexTailState() {
        case .done:
            // 历史会话静默对齐，不补发通知
            if state == .idle {
                state = .done
                notifiedDone = true; notifiedStuck = true; notifiedAwait = true
                return
            }
            state = .done
            if !notifiedDone, idleFor >= Config.doneGrace {
                notifiedDone = true
                Notify.send(title: "Codex 回合结束 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
        case .awaitingUserInput:
            // 提问卡片：结构性确认在等用户作答，无需长阈值，与 CatPaw 卡片同节奏
            if state == .idle {
                // 近 4 小时内停下的提问卡片：回填提醒（与 CatPaw 确认卡片回填同语义）；
                // 更早的静默对齐为悬置态，不补发
                if now.timeIntervalSince(ownFileMtime) >= Config.tabTurnEvalWindow {
                    notifiedAwait = true
                }
                markAwaitingConfirm(source: "Codex")
                return
            }
            guard state == .running || state == .done else { return }
            if idleFor >= Config.cardSettleDelay {
                markAwaitingConfirm(source: "Codex")
            }
        case .pendingTool:
            // 工具执行或等待审批：CLI 无目录活动可查，长悬置才提醒（与命令悬置同语义）
            guard state == .running else { return }
            if idleFor >= Config.awaitConfirmThreshold {
                markAwaitingConfirm(source: "Codex")
            }
case .running, .unknown:
guard state == .running || state == .done || state == .stuck else { return }
state = .running
notifiedDone = false
// 状态迁移与通知解耦：calibrate 假定运行的会话虽抑制提醒，
// 但超过阈值仍需翻成疑似中断，否则永远卡在执行中
if idleFor >= Config.stuckThreshold {
state = .stuck
if !notifiedStuck {
notifiedStuck = true
Notify.send(title: "Codex 疑似暂停/中断 ⚠️",
body: "\(displayName) 已 \(Int(idleFor))s 无进展",
sound: "DogBark", context: notifyContext)
}
}
}
    }

    // MARK: Claude Code 轮询（jsonl 末帧）

    /// Claude 尾部状态：assistant 的 stop_reason 决定回合边界；
    /// 尾部 assistant 含 tool_use 且无后续 user（tool_result）= 等待权限或工具执行中
    enum ClaudeTailState: Equatable {
        case finalReply  // assistant 以 end_turn/stop_sequence 收尾
        case pendingTool // assistant 停在 tool_use
        case working     // 最后是 user（新提问/工具结果），模型工作中
        case unknown
    }

    func claudeTailState() -> ClaudeTailState {
        // v2.x 会在最终回复后追加大型 meta 记录（attachment/system/atis-latch 等，
        // 实测一个 "hi" 回合的 meta 就有 ~300KB），64KB 窗口会漏掉 end_turn
        // 导致已完成会话永远停在执行中 → 用 1MB 窗口
        let window: UInt64 = 1_048_576
        guard let tail = readTail(maxBytes: window) else { return .unknown }
        var lines = tail.split(separator: "\n")
        // 窗口是文件切片时首行可能被起点切断（半条 JSON），丢弃避免误判
        if fileSize(url) > window, !lines.isEmpty { lines.removeFirst() }
var last: ClaudeTailState = .unknown
for line in lines {
// v2.x 存在「tool_use 收尾、无最终 end_turn」的回合（典型：回答
// AskUserQuestion 后跑了条长命令），此后只有 tool_result + system 记录。
// 而 v2.x 每个回合结束都会写 system/turn_duration → 作为可靠的回合结束边界
if line.contains("\"type\":\"system\""), line.contains("\"subtype\":\"turn_duration\"") {
last = .finalReply
} else if line.contains("\"type\":\"assistant\"") {
                if line.contains("\"stop_reason\":\"end_turn\"") || line.contains("\"stop_reason\":\"stop_sequence\"") {
                    last = .finalReply
                } else if line.contains("\"stop_reason\":\"tool_use\"") || line.contains("\"type\":\"tool_use\"") {
                    last = .pendingTool
                } else {
                    last = .working
                }
            } else if line.contains("\"type\":\"user\"") {
                last = .working
            }
        }
        return last
    }

    private func pollClaude(now: Date, idleFor: TimeInterval) {
        if awaitingExternal { state = .awaitingConfirm; return }
        switch claudeTailState() {
        case .finalReply:
            if state == .idle {
                state = .done
                notifiedDone = true; notifiedStuck = true; notifiedAwait = true
                return
            }
            state = .done
            if !notifiedDone, idleFor >= Config.doneGrace {
                notifiedDone = true
                Notify.send(title: "Claude 回合结束 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
        case .pendingTool:
            guard state == .running else { return }
            if idleFor >= Config.awaitConfirmThreshold {
                markAwaitingConfirm(source: "Claude")
            }
case .working, .unknown:
guard state == .running || state == .done || state == .stuck else { return }
state = .running
notifiedDone = false
// 状态迁移与通知解耦：calibrate 假定运行的会话虽抑制提醒，
// 但超过阈值仍需翻成疑似中断，否则永远卡在执行中
if idleFor >= Config.stuckThreshold {
state = .stuck
if !notifiedStuck {
notifiedStuck = true
Notify.send(title: "Claude 疑似暂停/中断 ⚠️",
body: "\(displayName) 已 \(Int(idleFor))s 无进展",
sound: "DogBark", context: notifyContext)
}
}
}
    }

    // MARK: Trae 轮询（工作区活动推断）

    /// Trae 展示模块 MVP：state.vscdb 有写入 → poll 通用路径已置「执行中」；
    /// 静默超过 stuckThreshold → 归于「空闲」。entries 结构未定稿前无回合级信号，
    /// 不发通知（通知开关常置位压制）。
    private func pollTraeState(now: Date, idleFor: TimeInterval) {
        guard state == .running, idleFor >= Config.stuckThreshold else { return }
        state = .idle
        notifiedDone = true
        notifiedStuck = true
        notifiedError = true
        notifiedAwait = true
    }

    // MARK: DeepSeek Harness（dsh）轮询

    /// zstd 解压结果缓存：(mtime, size) 未变时直接复用上次的 DshTail，
    /// 避免 3s 轮询反复解压几百 KB 的压缩流
    private var dshCacheStamp: (mtime: Date, size: UInt64)?
    private var dshTailCache: DshTail?

    /// 文件变化时重新解压+解析。截断帧（正在追加）解不出 END 也返回已解出部分，
    /// 末尾半行丢弃（zstdDecompress 对截断帧返回 nil 时保留旧缓存）
    private func refreshDshTail() {
        let m = fileMtime(url) ?? .distantPast
        let s = fileSize(url)
        if let stamp = dshCacheStamp, stamp.mtime == m, stamp.size == s { return }
        guard let raw = try? Data(contentsOf: url),
              var text = String(data: zstdDecompress(raw) ?? Data(), encoding: .utf8),
              !text.isEmpty else { return }
        dshCacheStamp = (m, s)
        // 末尾半行丢弃（事件行不完整不应参与状态判定）
        if let lastNL = text.lastIndex(of: "\n") { text = String(text[..<lastNL]) }
        let tail = dshTailState(from: text)
        dshTailCache = tail
        if title == nil, let t = tail.title { title = t }
    }

    /// dsh 语义事件流状态机：
    /// - approval/asked 未决定 → 等待手动确认（工具调用悬置在确认卡片）
    /// - turn/start 后无 turn/end → 回合执行中；静默超 stuckThreshold → 疑似中断
    /// - turn/end：completed → 已完成（doneGrace 去抖）/ error → 异常中断 /
    ///   aborted(user) → 已停止（不补发通知）
    private func pollDsh(now: Date, idleFor: TimeInterval) {
        if userStopped { state = .stopped; return }
        refreshDshTail()
        guard let tail = dshTailCache else { return }

        if let tool = tail.pendingApprovalTool {
            state = .awaitingConfirm
            if !notifiedAwait {
                notifiedAwait = true
                Notify.send(title: "DeepSeek 等待手动确认 🟡",
                            body: "\(displayName) 的 \(tool) 调用正在等待你确认",
                            sound: "DogBark", context: notifyContext)
            }
            return
        }

        if tail.turnRunning {
            if idleFor >= Config.stuckThreshold {
                state = .stuck
                if !notifiedStuck {
                    notifiedStuck = true
                    Notify.send(title: "DeepSeek 疑似暂停/中断 ⚠️",
                                body: "\(displayName) 回合进行中但已 \(Int(idleFor))s 无进展",
                                sound: "DogBark", context: notifyContext)
                }
            } else {
                state = .running
                notifiedDone = false
                notifiedError = false
                notifiedStuck = false
            }
            return
        }

        switch tail.turnEnd {
        case .completed:
            guard idleFor >= Config.doneGrace else {
                state = .running // turn/end 刚落盘，去抖窗口内维持执行中
                return
            }
            state = .done
            if !notifiedDone {
                notifiedDone = true
                Notify.send(title: "DeepSeek 回合结束 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
        case .error(let msg):
            state = .error
            if !notifiedError {
                notifiedError = true
                Notify.send(title: "DeepSeek 会话异常中断 ⛔️",
                            body: "\(displayName)：\(msg)",
                            sound: "DogBark", context: notifyContext)
            }
        case .abortedByUser:
            state = .stopped
            userStopped = true
        case nil:
            break // 只有 session 头、尚无回合：保持 idle
        }
    }

    // MARK: CatDesk 轮询（流信号驱动）

private func pollDeskBySignal(_ sig: DeskTurnSignal, now: Date) {
// 外部信号压住的悬置态：等待用户确认期间不被流信号覆盖
if awaitingExternal { state = .awaitingConfirm; return }
// 新流打开 = 停止后继续提问：解除停止门闩
if sig == .running { userStopped = false }
// 用户已手动停止：status 字典中残留的旧信号（停前最后一次 success close）
// 每轮都会重放，不得把状态翻回 running/awaitingConfirm
if userStopped { state = .stopped; return }
// 首个信号静默对齐，避免对历史状态补发通知
if !deskSignalSeen {
            deskSignalSeen = true
            switch sig {
            case .running:
                // 回合在进行中：正常武装，回合结束时会提醒
                // （不重置 notifiedStuck：中断提醒只发一次，恢复靠真实文件写入重置）
                state = .running
                notifiedDone = false
                notifiedError = false
            case .done:
                state = .done
                notifiedDone = true
            case .error:
                state = .error
                notifiedError = true
            case .stopped:
                state = .stopped
            }
            return
        }

        switch sig {
        case .running:
            state = .running
            notifiedDone = false
            notifiedError = false
            deskErrorSince = nil // 流恢复，清除异常防抖计时
            lastActivity = now
            deskRunningHousekeeping(now: now)
        case .done:
            // stream.close 只是单次模型请求结束（一次回合内会反复 open/close）；
            // 只有 jsonl 末帧也是最终回复时才认定回合真正结束
            guard deskTurnFinished() else {
                state = .running
                notifiedDone = false
                notifiedError = false
                deskErrorSince = nil
                deskRunningHousekeeping(now: now)
                return
            }
            let fileIdle = now.timeIntervalSince(fileMtime(url) ?? .distantPast)
            guard fileIdle >= Config.deskDoneGrace else { return }
            state = .done
            if !notifiedDone {
                notifiedDone = true
                Notify.send(title: "CatDesk 回合结束 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
        case .error(let info):
            // 防抖：deskErrorGrace 内若有新流打开（客户端自动重试）则视为恢复
            if deskErrorSince == nil { deskErrorSince = now }
            guard let since = deskErrorSince,
                  now.timeIntervalSince(since) >= Config.deskErrorGrace else { return }
            state = .error
            if !notifiedError {
                notifiedError = true
                Notify.send(title: "CatDesk 会话异常中断 ⛔️",
                            body: "\(displayName)：\(info)",
                            sound: "DogBark", context: notifyContext)
            }
        case .stopped:
            state = .stopped
        }
    }

    /// 回合进行中（或模型调用间隙）的辅助判定：等待手动确认 / 疑似中断兜底
    private func deskRunningHousekeeping(now: Date) {
        if deskAwaitingConfirmation(now: now) {
            state = .awaitingConfirm
            if !notifiedAwait {
                notifiedAwait = true
                Notify.send(title: "CatDesk 等待手动确认 🟡",
                            body: "\(displayName) 的命令可能需要在会话中手动执行",
                            sound: "DogBark", context: notifyContext)
            }
            return
        }
        // 兜底：流异常存活（如 CatDesk 被强杀无 close 事件）时仍可按静默升级。
        // 用目录级活跃度（含 transcript/工具文件）而非主 jsonl 的 mtime：长回合中
        // transcript 持续写入但主 jsonl 可能几分钟不更新，误把活跃回合判成中断
        let fileIdle = now.timeIntervalSince(latestActivity())
        if fileIdle >= Config.stuckThreshold && !deskTurnFinished() {
            state = .stuck
            if !notifiedStuck {
                notifiedStuck = true
                Notify.send(title: "CatDesk 疑似暂停/中断 ⚠️",
                            body: "\(displayName) 已 \(Int(fileIdle))s 无进展",
                            sound: "DogBark", context: notifyContext)
            }
        }
    }

    // MARK: CatDesk 轮询（无流信号时的 jsonl 末帧兜底）

private func pollDeskLegacy(now: Date, idleFor: TimeInterval) {
if awaitingExternal { state = .awaitingConfirm; return }
if userStopped { state = .stopped; return }
guard state == .running || state == .done else { return }
        let finished = deskTurnFinished()
        if idleFor >= Config.deskDoneGrace && finished {
            state = .done
            if !notifiedDone {
                notifiedDone = true
                Notify.send(title: "CatDesk 回合结束 ✅",
                            body: "\(displayName) 已输出最终回复",
                            sound: "DogBark", context: notifyContext)
            }
        } else if !finished && state != .done && idleFor >= Config.stuckThreshold {
            state = .stuck
            if !notifiedStuck {
                notifiedStuck = true
                Notify.send(title: "CatDesk 疑似暂停/中断 ⚠️",
                            body: "\(displayName) 已 \(Int(idleFor))s 无进展",
                            sound: "DogBark", context: notifyContext)
            }
        }
    }

    /// 最新活动时间：主文件与会话目录内所有文件的最大 mtime
    func latestActivity() -> Date {
        var latest = fileMtime(url) ?? .distantPast
        if let dir = sessionDir {
            for sub in ["agent-transcripts", "agent-tools", "terminals"] {
                let subURL = dir.appendingPathComponent(sub)
                guard let files = try? fm.contentsOfDirectory(atPath: subURL.path) else { continue }
                for f in files {
                    if let m = fileMtime(subURL.appendingPathComponent(f)), m > latest {
                        latest = m
                    }
                }
            }
        }
        return latest
    }

    // MARK: IDEA transcript 判定

    /// transcript 尾部是否以 assistant 最终回复收尾
    func tailLooksComplete() -> Bool {
        guard let tail = readTail(maxBytes: 8192) else { return false }
        let lastAssistant = tail.range(of: "\nassistant:", options: .backwards)?.upperBound
        let lastToolCall = tail.range(of: "[Tool call]", options: .backwards)?.upperBound
        let lastToolResult = tail.range(of: "[Tool result]", options: .backwards)?.upperBound
        let lastThinking = tail.range(of: "[Thinking]", options: .backwards)?.upperBound

        guard let a = lastAssistant else { return false }
        for marker in [lastToolCall, lastToolResult, lastThinking] {
            if let m = marker, m > a { return false }
        }
        // assistant: 之后需有实质内容
        let after = tail[a...].trimmingCharacters(in: .whitespacesAndNewlines)
        return !after.isEmpty
    }

    /// transcript 尾部最后一个信号是否为 [Thinking]（模型长推理中）
    func tailEndsWithThinking() -> Bool {
        guard let tail = readTail(maxBytes: 8192) else { return false }
        guard let thinking = tail.range(of: "[Thinking]", options: .backwards)?.upperBound else {
            return false
        }
        for pattern in ["[Tool call]", "[Tool result]", "\nassistant:"] {
            if let m = tail.range(of: pattern, options: .backwards)?.upperBound, m > thinking {
                return false
            }
        }
        return true
    }

    /// transcript 尾部是否停在 run_terminal_cmd 的 [Tool call]（命令悬置，可能在等待手动确认）
    func tailEndsWithPendingCommand() -> Bool {
        guard let tail = readTail(maxBytes: 8192) else { return false }
        guard let call = tail.range(of: "[Tool call]", options: .backwards) else { return false }
        if let result = tail.range(of: "[Tool result]", options: .backwards),
           result.upperBound > call.upperBound { return false }
        if let a = tail.range(of: "\nassistant:", options: .backwards),
           a.upperBound > call.upperBound { return false }
        // 工具名与 [Tool call] 同行：「[Tool call] run_terminal_cmd」
        let callLine = tail[call.lowerBound...].prefix(while: { $0 != "\n" })
        return callLine.contains("run_terminal_cmd")
    }

    /// IDEA transcript 尾部结构状态（[Tool call] 在模型发起调用时即落盘，
    /// 与用户是否确认无关——历史会话中存在大量永远无 result 的孤儿调用可证）
    enum IdeaTailState: Equatable {
        /// 尾部停在未完成的 [Tool call]：确认卡片悬置（background=true 为后台命令，无需确认）
        case pendingToolCall(background: Bool)
        /// 尾部是 [Tool result]/[Thinking]：模型仍在推进（长思考轮次也落在此类）
        case working
        /// 尾部是 assistant 最终回复：回合正常结束
        case complete
        /// transcript 缺失或无法解析
        case unknown
    }

    /// 解析 transcript 尾部最后一个结构标记，判别确认卡片与思考轮次
    func ideaTailState() -> IdeaTailState {
        guard let tail = readTail(maxBytes: 8192) else { return .unknown }
        let call = tail.range(of: "[Tool call]", options: .backwards)?.upperBound
        let result = tail.range(of: "[Tool result]", options: .backwards)?.upperBound
        let thinking = tail.range(of: "[Thinking]", options: .backwards)?.upperBound
        let assistant = tail.range(of: "\nassistant:", options: .backwards)?.upperBound
        let latest = [call, result, thinking, assistant].compactMap { $0 }.max()
        guard let latest else { return .unknown }
        if latest == call, let c = call {
            // [Tool call] 是最后一个标记：取该调用块头部判断是否为后台命令
            let block = tail[c...].prefix(600)
            return .pendingToolCall(background: block.contains("is_background: true"))
        }
        if latest == assistant, let a = assistant {
            let after = tail[a...].trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty ? .working : .complete
        }
        return .working
    }

    /// 会话目录下工具执行区（agent-tools/terminals）在指定时间之后是否有写入：
    /// 有写入说明工具/后台命令仍在执行，而非停在确认卡片
    func hasToolActivity(after date: Date) -> Bool {
        guard let dir = sessionDir else { return false }
        for sub in ["agent-tools", "terminals"] {
            let subURL = dir.appendingPathComponent(sub)
            guard let files = try? fm.contentsOfDirectory(atPath: subURL.path) else { continue }
            for f in files {
                if let m = fileMtime(subURL.appendingPathComponent(f)), m > date { return true }
            }
        }
        return false
    }

    // MARK: CatDesk jsonl 判定

    /// jsonl 末帧是否为「回合结束」的最终 assistant 消息：
    /// type=assistant，含非空 text 块，且不含 tool_use 块。
    /// 执行工具/思考期间末帧是 tool 或带 tool_use 的 assistant，不会误判。
    func deskTurnFinished() -> Bool {
        guard let last = lastDeskEvent() else { return false }
        guard last["type"] as? String == "assistant",
              let msg = last["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return false }
        var hasToolUse = false
        var hasText = false
        for c in content {
            switch c["type"] as? String {
            case "tool_use":
                hasToolUse = true
            case "text":
                if let t = c["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasText = true
                }
            default:
                break
            }
        }
        return hasText && !hasToolUse
    }

    /// 末帧是否为悬置的命令类工具调用（assistant 发出 bash 类 tool_use，尚未有执行结果）
    func deskPendingCommand() -> Bool {
        guard let last = lastDeskEvent(),
              last["type"] as? String == "assistant",
              let msg = last["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]] else { return false }
        // 提问卡片（AskQuestion/AskUserQuestion）同为悬置待用户操作：
        // 主信号是 app 日志 interaction_pending 即时事件，这里作日志缺失时的带内兜底
        let commandTools: Set<String> = ["bash", "shell", "run_terminal_cmd", "terminal",
                                         "AskQuestion", "AskUserQuestion"]
        for c in content where c["type"] as? String == "tool_use" {
            let name = (c["name"] as? String) ?? (c["toolName"] as? String) ?? ""
            if commandTools.contains(name) { return true }
        }
        return false
    }

    /// 是否在等待手动确认：命令类工具悬置且 jsonl 静默超阈值
    func deskAwaitingConfirmation(now: Date) -> Bool {
        guard deskPendingCommand() else { return false }
        let m = fileMtime(url) ?? .distantPast
        return now.timeIntervalSince(m) >= Config.awaitConfirmThreshold
    }

    /// 读取 jsonl 最后一个非空事件（末行解析失败视为无事件，保守处理）
    private func lastDeskEvent() -> [String: Any]? {
        guard let tail = readTail(maxBytes: 512 * 1024) else { return nil }
        for rawLine in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return nil
    }

    private func readTail(maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = fileSize(url)
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        // 容错解码：窗口起点可能切断多字节字符（中文 3 字节），严格解码会整体返回 nil，
        // 导致尾部状态误判 unknown（曾因此把提问卡片漏到 300s stuck 路径）
        return String(decoding: data, as: UTF8.self)
    }

    /// 会话文件本身的最后修改时间（区别于 latestActivity 的目录级口径，不含噪声）
    var ownFileMtime: Date { fileMtime(url) ?? .distantPast }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func fileMtime(_ url: URL) -> Date? {
        try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }
}

// MARK: - 监控器

struct SessionRow: Identifiable {
    let id: String // 文件路径
    let source: String // IDE-CatPaw / CatDesk
    let label: String // 项目 · 会话短 ID
    let title: String?
    let state: SessionState
    let lastActivity: Date
    /// 来源渠道标识（如 IDE-CatPaw 下的 插件/IDE），nil 不展示
    var channel: String? = nil

    init(_ watch: SessionWatch) {
        self.init(id: watch.url.path, source: watch.sourceName, label: watch.label,
                  title: watch.title, state: watch.state, lastActivity: watch.lastActivity,
                  channel: watch.channel)
    }

    init(id: String, source: String, label: String, title: String?,
         state: SessionState, lastActivity: Date, channel: String? = nil) {
        self.id = id
        self.source = source
        self.label = label
        self.title = title
        self.state = state
        self.lastActivity = lastActivity
        self.channel = channel
    }

    var displayName: String { "\(source)：\(title ?? label)" }
    var caption: String { "\(state.rawValue) · \(label)" }

    var timeText: String { SessionRow.formatTime(lastActivity, now: Date()) }

    /// 时间列：今天只显示时分秒；非今天带日期（同年 MM-dd，跨年 yyyy-MM-dd），
    /// 否则历史会话分不清是哪天的
    static func formatTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let fmt = DateFormatter()
        if calendar.isDate(date, inSameDayAs: now) {
            fmt.dateFormat = "HH:mm:ss"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            fmt.dateFormat = "MM-dd HH:mm"
        } else {
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return fmt.string(from: date)
    }
}

/// 回合结束归因目标：取最近活跃的 IDEA 会话（个人使用场景足够准确）。
func tabTurnTarget(_ watches: [SessionWatch]) -> SessionWatch? {
    watches.filter { $0.kind == .ideaTranscript }
        .max(by: { $0.lastSeenMtime < $1.lastSeenMtime })
}

func ideaErrorTarget(_ watches: [SessionWatch], message: String) -> SessionWatch? {
    let matches = watches.filter { watch in
        guard watch.kind == .ideaTranscript, let id = watch.sessionDir?.lastPathComponent, !id.isEmpty else { return false }
        return message.contains(id)
    }
    return matches.count == 1 ? matches.first : nil
}

/// 非正常结束（cancelled=用户主动停止 / failed=插件报错）的回合是否应解除确认卡片钉住：
/// 尾部停在前台工具调用 → 卡片已死，解除；尾部已收尾/仍在推进 → 无需处理；
/// 尾部不可读时保守判定（无工具活动且尾部不完整才视为停在卡片上）
func cancelledTurnReleasesPin(awaiting: Bool, tail: SessionWatch.IdeaTailState, toolActivity: Bool, complete: Bool) -> Bool {
    guard awaiting else { return false }
    switch tail {
    case .pendingToolCall(let background):
        return !background
    case .unknown:
        return !toolActivity && !complete
    case .working, .complete:
        return false
    }
}

/// 用户停止/插件报错导致回合非正常结束：解除确认卡片钉住并落到终态（不补发通知）
func releaseCardPin(_ target: SessionWatch, turnStatus: String) {
    let stopped = turnStatus == "cancelled"
    target.clearAwaiting()
    target.state = stopped ? .stopped : .error
    if !stopped { target.notifiedError = true } // 失败态不再补发错误通知
    Notify.log("回合\(turnStatus)：解除 \(target.displayName) 的确认卡片钉住（→ \(stopped ? "已停止" : "异常中断")）")
}

/// 回合 completed 且无后续 running、尾部停在 [Tool result]（.working）时是否应按确认卡片处理：
/// 正常轮次边界已被 tabResumed 排除，走到这里只剩两种可能——工具仍在执行（目录有写入，
/// 如自动批准的长命令）或模型循环停在确认卡片（高风险拦截命令确认前不落 [Tool call]，
/// 尾部永久停在上一轮 [Tool result]，v0.10.16 修复）。
/// 无工具活动且已过落定时间 → 按卡片标记。
func workingTailTurnIsCard(toolActivity: Bool, settled: Bool) -> Bool {
    !toolActivity && settled
}

final class Monitor: ObservableObject {
let center = TaskCenterStore()
private let projector = SessionProjector()
private let scanQueue = DispatchQueue(label: "AgentNotifier.scan", qos: .utility)
private var scanInFlight = false
private var scanSettings = MonitorSettings()
private var scanProblems: [String: String] = [:]
private var lastDiscovery = Date.distantPast
func requestDiscovery(resetSources: Bool = false) {
    scanQueue.async {
        self.lastDiscovery = .distantPast
        if resetSources {
            self.watches.removeAll()
            self.deskTracker = ApiRequestLogTracker()
            self.deskAppTracker = DeskAppLogTracker()
            self.deskTracker.calibrate()
            self.deskAppTracker.calibrate()
        }
    }
}
@Published private(set) var rows: [SessionRow] = []
/// 主窗口宫格用：按来源分组各自取最近 N 个（全局 12 上限会把 Trae 等低频新渠道
/// 的工作区挤出展示），仍按最近活动排序
@Published private(set) var gridRows: [SessionRow] = []
@Published private(set) var runningCount: Int = 0
@Published private(set) var logLines: [String] = []

private var watches: [String: SessionWatch] = [:] // key: 文件路径
private var deskTracker = ApiRequestLogTracker()
private let ideaTracker = IdeaLogTracker()
private var deskAppTracker = DeskAppLogTracker()
/// CatPaw 插件/IDE 界面状态库跟踪器（提问卡/确认卡悬置即时信号）
private let mideTracker = MideUICacheTracker()
/// CatDesk 服务端会话标题同步（AI 摘要标题与侧栏一致）
private let deskTitleFetcher = DeskTitleFetcher()
private var deskTitles: [String: String] = [:]
/// 手动改名（右键菜单设置，覆盖一切自动标题）
private let customTitles = CustomTitleStore()
/// Codex 额度快照（rate_limits）与上次刷新时间
@Published private(set) var codexQuota: CodexRateLimits?
@Published private(set) var codexQuotaFetchedAt: Date?
private var lastQuotaScan = Date.distantPast
private var pendingTabTurns: [IdeaTabTurn] = []
private var lastDeliveredIdeaError = Date.distantPast
/// 上次兜底深扫时间（间隔 Config.deepSweepInterval）
private var lastDeepSweep = Date.distantPast
private let fm = FileManager.default

init() {
    scanQueue.async {
        self.deskTracker.calibrate()
        self.ideaTracker.calibrate()
        self.deskAppTracker.calibrate()
        self.mideTracker.calibrate()
    }
}

    /// Mutable source watchers are confined to one serial worker; publishing stays on main.
    func scanAndPoll(now: Date = Date()) {
        guard !scanInFlight else { return }
        scanInFlight = true
        let settings = MonitorPreferences.shared.value
        scanQueue.async { self.performScan(now: now, settings: settings) }
    }

    private func performScan(now: Date, settings: MonitorSettings) {
let started = Date()
scanSettings = settings
if !settings.disabledSources.contains("Codex") { scanCodexQuota(now: now) }
if !settings.disabledSources.contains("CatDesk") { deskTracker.poll(); deskAppTracker.poll() }
if !settings.disabledSources.contains("IDE-CatPaw") { ideaTracker.poll(); mideTracker.poll(now: now) }
pendingTabTurns.append(contentsOf: ideaTracker.takeFinishedTurns())
let shouldDiscover = now.timeIntervalSince(lastDiscovery) >= 15
if shouldDiscover { lastDiscovery = now; discover(now: now) }
watches = watches.filter { !settings.disabledSources.contains($0.value.sourceName) }
// 同步 CatDesk 服务端会话标题（回调已切回主线程）
if settings.titlesEnabled && !settings.disabledSources.contains("CatDesk") {
    DispatchQueue.main.async {
        guard MonitorPreferences.shared.value.titlesEnabled else { return }
        self.deskTitleFetcher.fetchIfDue(now: now) { [weak self] titles in
            guard let self else { return }
            self.scanQueue.async { self.deskTitles.merge(titles) { _, new in new } }
        }
    }
}
for w in watches.values {
    // 手动改名优先级最高
    if let t = customTitles.title(for: w.url.path) {
        if w.title != t { w.title = t }
    } else if w.kind == .deskConversation,
              let cid = w.conversationId, let t = deskTitles[cid], w.title != t {
        w.title = t
        Notify.log("标题同步：\(cid.prefix(8)) → \(t)")
    }
}
if !settings.disabledSources.contains("IDE-CatPaw") {
deliverIdeaErrorIfAny()
deliverMideCardsIfAny(now: now)
deliverTabTurnsIfAny(now: now)
}
if !settings.disabledSources.contains("CatDesk") { deliverDeskConfirmsIfAny() }
        for w in watches.values {
            let sig = w.kind == .deskConversation
                ? w.conversationId.flatMap { deskTracker.status[$0] }
                : nil
            w.poll(now: now, deskSignal: sig)
        }
        // 周期兜底深扫：纠正悬置钉住/流信号丢失造成的进行中状态残留
        if now.timeIntervalSince(lastDeepSweep) >= Config.deepSweepInterval {
            lastDeepSweep = now
            for w in watches.values
            where w.state == .running || w.state == .awaitingConfirm || w.state == .stuck {
                let before = w.state
                if w.deepSweep(now: now) {
                    Notify.log("兜底纠正：\(w.displayName)（\(before.rawValue) → \(w.state.rawValue)）")
                }
            }
        }
        // 清理被删除的会话文件（状态库合成的 watch 锚定的 transcript 可能尚未落盘——
        // 回合落盘点才创建——悬置钉住期间保留，卡片了结后下轮自然清理）
        watches = watches.filter {
            fm.fileExists(atPath: $0.key)
                || ($0.value.kind == .ideaTranscript && $0.value.awaitingExternal)
        }
        publish()
        let observations = watches.values.map { projector.observation($0, now: now) }
        let elapsed = Date().timeIntervalSince(started) * 1000
        let logs = readLogLines(url: Notify.logURL, maxBytes: 16384, maxLines: 80)
        let problems = scanProblems
        DispatchQueue.main.async {
            self.scanInFlight = false
            self.center.sourceProblems = problems
            let liveSettings = MonitorPreferences.shared.value
            self.center.reconcile(observations, settings: liveSettings, at: now)
            if shouldDiscover { self.center.probeSources(settings: liveSettings, at: now) }
            self.center.scanMilliseconds = elapsed
            self.runningCount = self.center.runningCount
            if Notify.managedDelivery { DockStatus.setQueueCounts(completed: self.center.reviewCount) }
            DockStatus.render(running: self.center.runningCount, awaiting: self.center.actionableCount, now: now)
            self.logLines = logs
        }
    }

/// CatDesk app 日志报「发现需要确认的工具调用」→ 直接定位会话标记等待确认
private func deliverDeskConfirmsIfAny() {
for pc in deskAppTracker.takePendingConfirms() {
guard let w = watches.values.first(where: {
$0.kind == .deskConversation && $0.conversationId == pc.conversationId
}) else { continue }
w.markAwaitingConfirm(source: "CatDesk", confirmed: true, at: pc.at)
}
// 提问卡（AskQuestion 交互悬置）：与工具确认卡同语义，即时标记
for pc in deskAppTracker.takePendingInteractions() {
guard let w = watches.values.first(where: {
$0.kind == .deskConversation && $0.conversationId == pc.conversationId
}) else { continue }
w.markAwaitingConfirm(source: "CatDesk", confirmed: true, question: true, at: pc.at)
}
// 用户手动停止：解除悬置钉住并落终态（停止时无新流事件，流信号覆盖不到）
for ps in deskAppTracker.takePendingStops() {
guard let w = watches.values.first(where: {
$0.kind == .deskConversation && $0.conversationId == ps.conversationId
}) else { continue }
w.markUserStopped(source: "CatDesk")
}
}

/// CatPaw 插件/IDE 界面状态库信号（v0.10.31）：提问卡/确认卡悬置即时标记，
/// 卡片了结解除钉住。这两个客户端的 transcript 只在回合落盘点写入，卡片悬置期间
/// 磁盘零足迹（新会话连目录都没有），状态库是唯一即时信号源。
private func deliverMideCardsIfAny(now: Date) {
    // 已了结（回答/批准/拒绝/取消）：解除既有悬置钉住——transcript 尚未落盘时
    // 等不到内容增长解除，卡片会永远挂着
    for cid in mideTracker.takeResolved() {
        guard let w = mideWatch(for: cid), w.awaitingExternal else { continue }
        w.clearAwaiting()
        w.state = .running
        w.lastActivity = now
        Notify.log("卡片了结：\(w.displayName)（状态库）→ 解除等待确认")
    }
    for card in mideTracker.pendingCards.values {
        let w = mideWatch(for: card.conversationId)
            ?? createMideWatch(for: card.conversationId, now: now)
        guard let w, !w.awaitingExternal else { continue }
        // 提问卡只能由用户回答，即时标记；工具确认卡等落定窗口并排除工具自动执行中
        // （自动审批工具的 normal+streaming 中间态时长不明，沿用 cardSettleDelay 防抖）
        if !card.isQuestion {
            guard now.timeIntervalSince(card.firstSeen) >= Config.cardSettleDelay,
                  !w.hasToolActivity(after: card.firstSeen) else { continue }
        }
        w.markAwaitingConfirm(source: "CatPaw", confirmed: true, question: card.isQuestion, at: card.firstSeen)
    }
}

/// 按 conversation_id 定位既有 jb-/ide- 会话（conversation_id 即会话目录名）
private func mideWatch(for cid: String) -> SessionWatch? {
    watches.values.first {
        $0.kind == .ideaTranscript && $0.sessionDir?.lastPathComponent == cid
    }
}

/// 卡片悬置时 transcript/会话目录可能尚未创建，用 t_conversations 元信息直接合成
/// watch：目录出现后由常规目录发现接管（watches key 即 transcript 路径，不会重复）
private func createMideWatch(for cid: String, now: Date) -> SessionWatch? {
    guard let meta = mideTracker.conversationMeta(cid), !meta.workspace.isEmpty
    else { return nil }
    let isPlugin = meta.ideType == "JETBRAINS"
    let projDir = (isPlugin ? "jb-" : "ide-")
        + meta.workspace.drop(while: { $0 == "/" }).replacingOccurrences(of: "/", with: "-")
    let sessionDir = Config.projectsDir
        .appendingPathComponent(projDir).appendingPathComponent(cid)
    let transcript = sessionDir.appendingPathComponent("agent-transcripts/transcript.txt")
    let rawTitle = meta.title?
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let title = rawTitle.map { String($0.prefix(Config.titleMaxLength)) }
    let w = SessionWatch(
        kind: .ideaTranscript,
        url: transcript,
        label: "\(URL(fileURLWithPath: meta.workspace).lastPathComponent) · \(cid.prefix(8))",
        title: title,
        sessionDir: sessionDir,
        channel: isPlugin ? "插件" : "IDE"
    )
    w.lastActivity = now
    watches[transcript.path] = w
    Notify.log("会话发现：\(w.sourceName)·\(w.channel ?? "") · \(w.label)（状态库）")
    return w
}

/// IDEA 回合结束归因：停在确认卡片 → 标记等待确认；正常产出 → 解除既有悬置。
/// 宽限后判定（等延迟落盘），且只评估近期结束的回合（避免启动前旧回合误判）。
private func deliverTabTurnsIfAny(now: Date) {
    guard !pendingTabTurns.isEmpty else { return }
    var remaining: [IdeaTabTurn] = []
    for turn in pendingTabTurns {
        // completed 后同一 Tab 又出现了 running：只是模型轮次边界，任务还在继续，
        // 直接丢弃——否则会对着正在生成的会话误报「等待手动确认」
        if ideaTracker.tabResumed(turn.tabId, after: turn.endedAt) { continue }
        guard now.timeIntervalSince(turn.endedAt) <= Config.tabTurnEvalWindow,
              let target = watches.values.first(where: { $0.kind == .ideaTranscript && $0.sessionDir?.lastPathComponent == turn.tabId })
        else { continue }
        // 非正常结束（cancelled=用户主动停止 / failed=插件报错）的回合：
        // 若会话钉在「等待手动确认」且尾部停在未完成的 [Tool call]，必须解除钉住——
        // 用户点了停止就不会再确认，卡片会永远挂着（deepSweep 只解除尾部已收尾的场景，
        // 覆盖不了这种「尾部永久悬置 + 会话已死」的组合，v0.10.15 修复）
        if turn.status != "completed" {
            let tail = target.ideaTailState()
            if cancelledTurnReleasesPin(
                awaiting: target.awaitingExternal,
                tail: tail,
                toolActivity: tail == .unknown && target.hasToolActivity(after: turn.endedAt),
                complete: tail == .unknown && target.tailLooksComplete()) {
                releaseCardPin(target, turnStatus: turn.status)
            }
            continue
        }
        // 结构性判别：确认卡片与长思考轮次在「文件写入」上同构（都静默），
        // 但 transcript 尾部结构不同——卡片停在未完成的 [Tool call]，
        // 思考轮次停在 [Tool result]/[Thinking]/assistant。据此即时判别，
        // 无需再用长宽限掩盖思考轮次（v0.8.0，替代 240s 宽限方案）。
        switch target.ideaTailState() {
        case .pendingToolCall(let background):
            // 后台命令悬置无需确认；前台工具执行中（目录有写入）也不是卡片
            if background { continue }
            if target.hasToolActivity(after: turn.endedAt) { continue }
            // 短暂落定：等自动审批工具的 [Tool result] 写入，避免把秒级自动执行误报成卡片
            guard now.timeIntervalSince(turn.endedAt) >= Config.cardSettleDelay else {
                remaining.append(turn)
                continue
            }
            target.markAwaitingConfirm(source: "CatPaw")
        case .working:
            // 尾部停在 [Tool result] 且回合 completed 后无后续 running（tabResumed 已排除
            // 正常轮次边界，下一个 running 通常 1 秒内出现）——模型循环已停但没有收尾
            // assistant，典型场景是高风险命令确认卡片（命中系统黑名单的命令在确认前
            // 不会把 [Tool call] 落进 transcript，尾部永久停在上一轮 [Tool result]，
            // v0.10.16 修复前直接丢弃导致此类卡片完全不提示）。
            // 目录仍有写入 = 工具真在执行，丢弃，避免误报
            let toolActivity = target.hasToolActivity(after: turn.endedAt)
            // 短暂落定：等收尾 assistant/下一个轮次的写入，避免把落盘延迟误报成卡片
            let settled = now.timeIntervalSince(turn.endedAt) >= Config.cardSettleDelay
            guard workingTailTurnIsCard(toolActivity: toolActivity, settled: settled) else {
                if !toolActivity { remaining.append(turn) } // 未落定：下轮再判
                continue
            }
            target.markAwaitingConfirm(source: "CatPaw")
        case .complete:
            if target.awaitingExternal { target.clearAwaiting() }
        case .unknown:
            // transcript 不可读时退回保守路径：目录有活动视为执行中，否则短宽限后按尾部完整性判定
            if target.hasToolActivity(after: turn.endedAt) { continue }
            guard now.timeIntervalSince(turn.endedAt) >= Config.silentTurnGrace else {
                remaining.append(turn)
                continue
            }
            if !target.tailLooksComplete() {
                target.markAwaitingConfirm(source: "CatPaw")
            } else if target.awaitingExternal {
                target.clearAwaiting()
            }
        }
    }
    pendingTabTurns = remaining
}

/// 将最新 IDEA 插件错误归因给最近活跃的 IDEA 会话并提醒（无会话时发通用提醒）
private func deliverIdeaErrorIfAny() {
        guard let err = ideaTracker.latestError, err.at > lastDeliveredIdeaError else { return }
        lastDeliveredIdeaError = err.at
        if let target = ideaErrorTarget(Array(watches.values), message: err.msg) {
            target.markIdeaError(at: err.at, msg: err.msg)
        } else {
            scanProblems["IDE-CatPaw"] = "观察到无法可靠归因的插件错误；未改变任意会话状态。"
        }
    }

// MARK: 手动改名

func hasCustomTitle(key: String) -> Bool { customTitles.title(for: key) != nil }

/// 右键「重命名会话…」：弹输入框；留空保存 = 恢复默认标题
func promptRenameSession(key: String, current: String?) {
    let alert = NSAlert()
    alert.messageText = "重命名会话"
    alert.informativeText = "IDEA 插件会话的 Tab 标题（AI 摘要）本地无法自动获取，可手动与 CatPaw 面板保持一致；留空保存则恢复默认标题。"
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
    field.stringValue = current ?? ""
    field.placeholderString = "输入新标题，留空恢复默认"
    alert.accessoryView = field
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    renameSession(key: key, title: field.stringValue)
}

/// 设置/清除手动标题（nil 或空白 = 恢复默认），立即生效并落盘
func renameSession(key: String, title: String?) {
    scanQueue.async { self.performRename(key: key, title: title) }
}

private func performRename(key: String, title: String?) {
    customTitles.set(title, for: key)
    if let w = watches[key], let restored = customTitles.title(for: key) ?? w.derivedTitle,
       w.title != restored {
        w.title = restored
    }
    if let t = customTitles.title(for: key) {
        Notify.log("手动改名：\(key.suffix(45)) → \(t)")
    } else {
        Notify.log("恢复默认标题：\(key.suffix(45))")
    }
    publish()
}

private func publish() {
        let all = watches.values.sorted { $0.lastActivity > $1.lastActivity }
        let rows = all.prefix(12).map { SessionRow($0) }
        let grouped = Dictionary(grouping: all, by: { $0.sourceName })
        let grid = grouped.values.flatMap { $0.prefix(8) }.sorted { $0.lastActivity > $1.lastActivity }.map { SessionRow($0) }
        DispatchQueue.main.async { self.rows = rows; self.gridRows = grid }
    }

    private func discover(now: Date) {
        if let projects = try? fm.contentsOfDirectory(atPath: Config.projectsDir.path) {
            for proj in projects {
                let projURL = Config.projectsDir.appendingPathComponent(proj)
                if proj.hasPrefix("jb-") {
                    guard !scanSettings.disabledSources.contains("IDE-CatPaw") else { continue }
                    discoverIdeaSessions(projURL: projURL, projName: proj, now: now, channel: "插件")
                } else if proj.hasPrefix("ide-") {
                    guard !scanSettings.disabledSources.contains("IDE-CatPaw") else { continue }
                    // CatPaw IDE 独立端：与 jb- 相同的 transcript 协议，渠道标为 IDE
                    discoverIdeaSessions(projURL: projURL, projName: proj, now: now, channel: "IDE")
                } else {
                    guard !scanSettings.disabledSources.contains("CatDesk") else { continue }
                    discoverDeskConversations(projURL: projURL, projName: proj, now: now)
                }
            }
        }
        discoverCodexSessions(now: now)
        discoverClaudeSessions(now: now)
        discoverTraeWorkspaces(now: now)
        #if canImport(LibZSTD)
        discoverDshSessions(now: now)
        #endif
    }

    /// DeepSeek Harness 会话：~/.dsh/sessions/<转义工作区>/session-<uuid>/session.v3.jsonl.zstd
    /// 发现时解压头部一次：delegationDepth > 0 的子代理会话跳过（跟随主会话），
    /// cwd 用作卡片标题
    private func discoverDshSessions(now: Date) {
        let root = Config.dshSessionsDir
        guard fm.fileExists(atPath: root.path) else { return }
        for ws in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let wsDir = root.appendingPathComponent(ws)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: wsDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for sess in (try? fm.contentsOfDirectory(atPath: wsDir.path)) ?? []
            where sess.hasPrefix("session-") {
                let sessDir = wsDir.appendingPathComponent(sess)
                let fileURL = sessDir.appendingPathComponent("session.v3.jsonl.zstd")
                guard fm.fileExists(atPath: fileURL.path), watches[fileURL.path] == nil else { continue }
                guard let raw = try? Data(contentsOf: fileURL),
                      let text = String(data: zstdDecompress(raw) ?? Data(), encoding: .utf8) else {
                    Notify.log("会话发现跳过：dsh \(ws)/\(sess) 解压失败")
                    continue
                }
                let tail = dshTailState(from: text)
                guard tail.delegationDepth == 0 else { continue }
                let label = dshSessionCWD(from: text)
                    .flatMap { workspaceLabel(from: URL(fileURLWithPath: $0).lastPathComponent) }
                    ?? dshWorkspaceLabel(from: ws)
                let w = SessionWatch(kind: .dshSession, url: fileURL, label: label,
                                     sessionDir: sessDir)
                w.calibrate(now: now)
                watches[fileURL.path] = w
                Notify.log("会话发现：DeepSeek · \(w.label)")
            }
        }
    }

    /// Trae / TRAE SOLO 工作区：state.vscdb 含会话索引键的出一张工作区卡片。
    /// 一张卡片 = 一个工作区（所有聊天共享同一 state.vscdb，暂不能拆到会话级）；
    /// 卡片锚定 state.vscdb 路径，状态按库文件活动推断（见 pollTraeState）
    private func discoverTraeWorkspaces(now: Date) {
        guard !scanSettings.disabledSources.contains("Trae") else { return }
        for (root, channel) in Config.traeAppDirs {
            let wsRoot = root.appendingPathComponent("User/workspaceStorage")
            guard let wsDirs = try? fm.contentsOfDirectory(atPath: wsRoot.path) else { continue }
            for ws in wsDirs {
                let wsDir = wsRoot.appendingPathComponent(ws)
                let dbURL = wsDir.appendingPathComponent("state.vscdb")
                guard fm.fileExists(atPath: dbURL.path), watches[dbURL.path] == nil else { continue }
                guard vscdbHasItem(dbURL: dbURL, key: Config.traeChatIndexKey) else { continue }
                let fallbackName = "\(root.lastPathComponent) · \(ws.prefix(6))"
                let name = (try? String(contentsOf: wsDir.appendingPathComponent("workspace.json"),
                                        encoding: .utf8))
                    .map { traeWorkspaceName(fromWorkspaceJSON: $0, fallback: fallbackName) }
                    ?? fallbackName
                let w = SessionWatch(
                    kind: .traeState,
                    url: dbURL,
                    label: name,
                    channel: channel
                )
                w.calibrate(now: now)
                watches[dbURL.path] = w
                Notify.log("会话发现：Trae·\(channel) · \(w.label)")
            }
        }
    }

    /// Scan by file activity, select by the source event timestamp, never by rollout filename.
    private var quotaScanInFlight = false
    private func scanCodexQuota(now: Date) {
        guard !quotaScanInFlight, now.timeIntervalSince(lastQuotaScan) >= Config.codexQuotaRefreshInterval else { return }
        lastQuotaScan = now
        quotaScanInFlight = true
        let root = Config.codexSessionsDir
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            var files: [(URL, Date)] = []
            if let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in iterator where url.pathExtension == "jsonl" {
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    files.append((url, date))
                }
            }
            let snapshots = files.sorted { $0.1 > $1.1 }.prefix(40).compactMap { file -> CodexRateLimits? in
                guard let text = readTailText(url: file.0, maxBytes: 1_048_576) else { return nil }
                return lastCodexRateLimits(in: text)
            }
            let latest = snapshots.max { ($0.snapshotAt ?? .distantPast) < ($1.snapshotAt ?? .distantPast) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanQueue.async { self.quotaScanInFlight = false }
                guard MonitorPreferences.shared.enabled("Codex"), let latest else { return }
                if let current = self.codexQuota?.snapshotAt, (latest.snapshotAt ?? .distantPast) < current { return }
                if latest != self.codexQuota {
                    self.codexQuota = latest
                    self.codexQuotaFetchedAt = Date()
                }
            }
        }
    }

    /// 目录条目按名倒序（适配 YYYY/MM/DD 与 rollout 时间戳命名）
    private func sortedDescNames(at url: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted().reversed()
    }

    /// Codex CLI 会话：~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
    private func discoverCodexSessions(now: Date) {
        guard !scanSettings.disabledSources.contains("Codex") else { return }
        let root = Config.codexSessionsDir
        guard fm.fileExists(atPath: root.path) else { return }
        // 标题索引每轮重读（文件很小），thread_name 可能在会话开始后才生成
        let titles = (try? String(contentsOf: Config.codexSessionIndex, encoding: .utf8))
            .map { parseCodexSessionIndex($0) } ?? [:]
        for y in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let yURL = root.appendingPathComponent(y)
            for m in (try? fm.contentsOfDirectory(atPath: yURL.path)) ?? [] {
                let mURL = yURL.appendingPathComponent(m)
                for d in (try? fm.contentsOfDirectory(atPath: mURL.path)) ?? [] {
                    let dURL = mURL.appendingPathComponent(d)
                    for f in (try? fm.contentsOfDirectory(atPath: dURL.path)) ?? []
                    where f.hasPrefix("rollout-") && f.hasSuffix(".jsonl") {
                        let fileURL = dURL.appendingPathComponent(f)
                        let sid = codexSessionId(fromFile: f)
                        if let w = watches[fileURL.path] {
                            // 已有会话：索引里出现新标题则同步（手动改名优先）
                            if let t = titles[sid], w.title != t,
                               !hasCustomTitle(key: w.url.path) {
                                w.title = t
                            }
                            continue
                        }
let w = SessionWatch(
kind: .codexSession,
url: fileURL,
label: "codex · \(sid.prefix(8))",
title: titles[sid]
)
// 子代理线程（guardian_review 自动审查等）不是用户会话，跳过
if codexIsSubagentRollout(fileURL) { continue }
w.calibrate(now: now)
                        watches[fileURL.path] = w
                    }
                }
            }
        }
    }

    /// Claude Code 会话：~/.claude/projects/<工作区>/<sid>.jsonl
    private func discoverClaudeSessions(now: Date) {
        guard !scanSettings.disabledSources.contains("Claude") else { return }
        let root = Config.claudeProjectsDir
        guard let projects = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        for proj in projects {
            let projURL = root.appendingPathComponent(proj)
            for f in (try? fm.contentsOfDirectory(atPath: projURL.path)) ?? []
            where f.hasSuffix(".jsonl") {
                let fileURL = projURL.appendingPathComponent(f)
                if let w = watches[fileURL.path] {
                    // ai-title 事件可能在会话开始后才写入：无标题时补抓（手动改名优先）
                    if w.title == nil, !hasCustomTitle(key: w.url.path) {
                        w.title = extractClaudeTitle(from: fileURL)
                    }
                    continue
                }
                let sid = String(f.dropLast(".jsonl".count))
                let w = SessionWatch(
                    kind: .claudeSession,
                    url: fileURL,
                    label: "\(claudeWorkspaceLabel(from: proj)) · \(sid.prefix(8))",
                    title: extractClaudeTitle(from: fileURL)
                )
                w.calibrate(now: now)
                watches[fileURL.path] = w
            }
        }
    }

    /// IDEA 插件 / CatPaw IDE 会话：(jb|ide)-*/<sid>/agent-transcripts/transcript.txt
    private func discoverIdeaSessions(projURL: URL, projName: String, now: Date, channel: String) {
        guard let sessions = try? fm.contentsOfDirectory(atPath: projURL.path) else { return }
        for sid in sessions {
            let sessionDir = projURL.appendingPathComponent(sid)
            let t = sessionDir.appendingPathComponent("agent-transcripts/transcript.txt")
            guard fm.fileExists(atPath: t.path), watches[t.path] == nil else { continue }
            let w = SessionWatch(
                kind: .ideaTranscript,
                url: t,
                label: "\(projectLabel(from: projName)) · \(sid.prefix(8))",
                title: extractTitle(from: t),
                sessionDir: sessionDir,
                channel: channel
            )
            w.calibrate(now: now)
            watches[t.path] = w
            Notify.log("会话发现：\(w.sourceName)·\(channel) · \(w.label)")
        }
    }

    /// CatDesk 会话：<工作区目录>/<conversationId>.jsonl
    private func discoverDeskConversations(projURL: URL, projName: String, now: Date) {
        guard let files = try? fm.contentsOfDirectory(atPath: projURL.path) else { return }
        for f in files where f.hasSuffix(".jsonl") {
            let fileURL = projURL.appendingPathComponent(f)
            guard watches[fileURL.path] == nil else { continue }
            let sid = String(f.dropLast(".jsonl".count))
            let w = SessionWatch(
                kind: .deskConversation,
                url: fileURL,
                label: "\(workspaceLabel(from: projName)) · \(sid.prefix(8))",
                title: extractDeskTitle(from: fileURL),
                conversationId: sid
            )
            w.calibrate(now: now)
            watches[fileURL.path] = w
        }
    }
}

// MARK: - Chrome SSO 登录态导入（免扫码）

/// credit-hub 取数依赖 console 域的浏览器 SSO cookie。为免用户重复登录，
/// 会话缺失/失效时先静默尝试从本机 Chrome 导入 sankuai/meituan 域的登录态
///（UISkip 模式：只有用户历史上授权过才会成功，绝不弹授权框打扰用户），
/// 拿不到则回退到内置登录窗（扫码一次长期有效）。
/// 解密方式：钥匙串「Chrome Safe Storage」→ PBKDF2 派生 AES-128-CBC，
/// v10 前缀，M80+ 明文带 32 字节 SHA256(host) 前缀。
enum ChromeCookieImporter {
    /// 返回成功注入的 cookie 数（0 = 未拿到或全部失败）
    /// 钥匙串授权框会同步阻塞，因此解密与读库放后台线程，只把注入留在主线程上
    static func importInto(_ store: WKWebsiteDataStore) async -> Int {
        let unique = await Task.detached(priority: .userInitiated) { () -> [HTTPCookie] in
            guard let aesKey = deriveAESKey() else { return [] }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let bases = [home.appendingPathComponent("Library/Application Support/Google/Chrome")]
            var cookies: [HTTPCookie] = []
            for base in bases {
                let profiles = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.hasDirectoryPath }
                for dir in profiles {
                    let db = dir.appendingPathComponent("Cookies")
                    guard FileManager.default.fileExists(atPath: db.path) else { continue }
                    cookies.append(contentsOf: readCookies(db: db, aesKey: aesKey))
                }
            }
            var seen = Set<String>()
            return cookies.filter { seen.insert("\($0.domain)|\($0.name)|\($0.path)").inserted }
        }.value
        guard !unique.isEmpty else { return 0 }
        for c in unique { await store.httpCookieStore.setCookie(c) }
        // setCookie 逐条异步落盘，等一拍再开始取数
        try? await Task.sleep(nanoseconds: 800_000_000)
        return unique.count
    }

    /// 静默读 Chrome 加密密钥并 PBKDF2 派生 AES key。
    /// kSecUseAuthenticationUISkip：历史上授权过（ACL 信任本应用）才返回数据，
    /// 否则 errSecInteractionNotAllowed 直接放弃——绝不弹密码框。
    private static func deriveAESKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data, !password.isEmpty else { return nil }
        var derived = [UInt8](repeating: 0, count: 16)
        let salt = [UInt8]("saltysalt".utf8)
        let result = password.withUnsafeBytes { pwBuf -> Int32 in
            salt.withUnsafeBytes { saltBuf -> Int32 in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwBuf.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                                     saltBuf.baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     &derived, 16)
            }
        }
        return result == Int32(kCCSuccess) ? Data(derived) : nil
    }

    private static func readCookies(db: URL, aesKey: Data) -> [HTTPCookie] {
        // 复制到临时文件再打开，避免与运行中的 Chrome 抢锁（WAL 一并复制以读到最新写入）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("an-ck-\(UUID().uuidString)")
        defer {
            for ext in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: tmp.path + ext) }
        }
        guard (try? FileManager.default.copyItem(at: db, to: tmp)) != nil else { return [] }
        for ext in ["-wal", "-shm", "-journal"] {
            let side = db.path + ext
            if FileManager.default.fileExists(atPath: side) {
                try? FileManager.default.copyItem(atPath: side, toPath: tmp.path + ext)
            }
        }
        var dbh: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &dbh, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(dbh) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT host_key, name, encrypted_value, path, is_secure, expires_utc
        FROM cookies WHERE host_key IN (
            'sankuai.com', '.sankuai.com', 'ssosv.sankuai.com', '.ssosv.sankuai.com',
            'console.catpaw.sankuai.com', '.console.catpaw.sankuai.com',
            'credit-hub.sankuai.com', '.credit-hub.sankuai.com'
        )
        """
        guard sqlite3_prepare_v2(dbh, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [HTTPCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hostPtr = sqlite3_column_text(stmt, 0),
                  let namePtr = sqlite3_column_text(stmt, 1) else { continue }
            let host = String(cString: hostPtr)
            let name = String(cString: namePtr)
            let encLen = sqlite3_column_bytes(stmt, 2)
            guard encLen > 19, let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let enc = Data(bytes: blob, count: Int(encLen))
            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "/"
            let secure = sqlite3_column_int(stmt, 4) == 1
            let expires = sqlite3_column_int64(stmt, 5)
            guard let value = decrypt(enc, aesKey: aesKey, host: host), !value.isEmpty else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: host,
                .name: name,
                .path: path.isEmpty ? "/" : path,
                .value: value,
            ]
            if secure { props[.secure] = "TRUE" }
            if expires > 0 {
                // Chrome epoch（1601 微秒）→ Unix 秒
                props[.expires] = Date(timeIntervalSince1970: Double(expires) / 1_000_000 - 11_644_473_600)
            }
            if let c = HTTPCookie(properties: props) { out.append(c) }
        }
        return out
    }

    /// v10 = AES-128-CBC(iv: 16 个空格)；M80+ 的明文带 32 字节 SHA256(host) 前缀
    private static func decrypt(_ enc: Data, aesKey: Data, host: String) -> String? {
        guard enc.count > 3, enc.prefix(3) == Data("v10".utf8) else { return nil }
        let cipher = [UInt8](enc.dropFirst(3))
        guard cipher.count % 16 == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: cipher.count)
        var outLen = 0
        let iv = [UInt8](repeating: 0x20, count: 16)
        let status = aesKey.withUnsafeBytes { keyBuf -> Int32 in
            iv.withUnsafeBytes { ivBuf -> Int32 in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBuf.baseAddress!, aesKey.count,
                        ivBuf.baseAddress!,
                        cipher, cipher.count,
                        &out, out.count, &outLen)
            }
        }
        guard status == Int32(kCCSuccess) else { return nil }
        var plain = Data(out[..<outLen])
        if plain.count > 32, let hostData = host.data(using: .utf8) {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            hostData.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(hostData.count), &digest) }
            if plain.prefix(32) == Data(digest) { plain = plain.dropFirst(32) }
        }
        return String(data: plain, encoding: .utf8)
    }
}

// MARK: - 匿名使用统计

/// 匿名埋点：首次启动报 install、每天首次启动报 heartbeat，写入 AIBase 事件表。
/// 隐私：device_id 为本地生成的随机 UUID，不采集任何账号/内容信息；anonKey 仅有 INSERT 权限。
/// 卸载量无法直接探测，统计侧以「超 7 天无心跳」代理流失。失败静默，不打扰用户。
enum Telemetry {
    private static let endpoint = URL(string: "https://iqnxas42l4.aibase.sankuai.com/rest/v1/agent_notifier_events")!
    private static let anonKey = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbl9pcW54YXM0Mmw0IiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3NDgxMzEyMDAsImV4cCI6MTg5MzQ1NjAwMH0.AVLaIabQP8LLE4LHV0zZeQY5Iu1KaLCZ1VcTI-MW_3Q"
    private static let deviceKey = "telemetry.deviceId"
    private static let installSentKey = "telemetry.installSent"
    private static let lastHeartbeatKey = "telemetry.lastHeartbeatDay"
    /// Credit 登录态解出的 mis（CreditStore 写入）；存在时埋点按人去重，否则按匿名设备 ID
    static let misKey = "telemetry.mis"

    /// 埋点 mis 解析链（v0.10.32）：Credit 登录态 > CatDesk sso_config.misId > 本机账号名
    ///（美团办公 Mac 本地账号即 mis）。此前只有 Credit 看板登录成功才有 mis，
    /// 没开过看板的设备事件 mis 全是 NULL。
    static func currentMis() -> String? {
        if let m = UserDefaults.standard.string(forKey: misKey), !m.isEmpty { return m }
        if let m = misFromSSOConfig(Config.ssoConfigURL) { return m }
        let u = NSUserName()
        return u.isEmpty ? nil : u
    }

    /// 从 CatDesk 登录态配置解 misId
    static func misFromSSOConfig(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mis = obj["misId"] as? String, !mis.isEmpty else { return nil }
        return mis
    }

    static var deviceId: String {
        let d = UserDefaults.standard
        if let s = d.string(forKey: deviceKey) { return s }
        let s = UUID().uuidString
        d.set(s, forKey: deviceKey)
        return s
    }

    /// 启动时调用一次：首次启动报 install；每个自然日首次启动报 heartbeat
    static func reportLaunch(now: Date = Date()) {
        guard MonitorPreferences.shared.value.telemetry else { return }
        let d = UserDefaults.standard
        if !d.bool(forKey: installSentKey) {
            send("install") { ok in if ok { d.set(true, forKey: installSentKey) } }
        }
        let today = dayString(now)
        if d.string(forKey: lastHeartbeatKey) != today {
            send("heartbeat") { ok in if ok { d.set(today, forKey: lastHeartbeatKey) } }
        }
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func send(_ event: String, done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
    let payload: [String: String] = [
            "device_id": deviceId,
            "event": event,
            "version": Config.appVersion,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            done((resp as? HTTPURLResponse)?.statusCode == 201)
        }.resume()
    }
}

// MARK: - Credit 用量看板

/// credit-hub 只接受「console 浏览器 cookie 会话」签发的 websso token，
/// mtsso / catdesk 换发的 AT 一律被 SSO authentication failed 拒绝（已实测）。
/// 因此内置一个持久化 WKWebView：SSO 登录态存于应用自己的 WebKit 数据目录，
/// 取数时在 WebView 内执行 JS：websso/token/get 取 token → 调 credit-hub 看板 API。
@MainActor
final class CreditStore: NSObject, WKNavigationDelegate, NSWindowDelegate, ObservableObject {
    struct Snapshot {
        var allocated: Double
        var used: Double
        var remaining: Double
        var trend: [(date: String, value: Double)]
    }
    enum CreditError: LocalizedError {
        case notLoggedIn
        case badPayload
        var errorDescription: String? {
            switch self {
            case .notLoggedIn: return "未登录 CatPaw Console"
            case .badPayload: return "用量数据解析失败"
            }
        }
    }

    static let dashboardURL = URL(string: "https://console.catpaw.sankuai.com/credit-mgmt/personal")!
    private static let consoleHost = "console.catpaw.sankuai.com"

    @Published private(set) var allocated: Double = 0
    @Published private(set) var used: Double = 0
    @Published private(set) var remaining: Double = 0
    @Published private(set) var trend: [(date: String, value: Double)] = []
    @Published private(set) var hasData = false
    @Published private(set) var needsLogin = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var fetchError: String?

    private let webView: WKWebView
    private var offscreenWindow: NSWindow?
    private var loginWindow: NSWindow?
    private var refreshTimer: Timer?
    private var refreshing = false
    private var refreshTask: Task<Void, Never>?
    /// 用户手动关过登录窗后不再自动弹，只能点头部按钮唤起
    private var loginDismissed = false

    override init() {
        let config = WKWebViewConfiguration()
        if #available(macOS 14, *) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "7F3A1C2E-5B6D-4E8F-9A0B-1C2D3E4F5A6B")!)
        } else {
            config.websiteDataStore = .default()
        }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 560, height: 760), configuration: config)
        super.init()
        webView.navigationDelegate = self
        // 离屏宿主窗口：保证 WebView 在后台也能正常加载与执行 JS
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 760),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = webView
        host.orderBack(nil)
        offscreenWindow = host
    }

    func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func applyNetworkSetting() {
        if MonitorPreferences.shared.value.creditEnabled { start() }
        else {
            refreshTask?.cancel()
            refreshTimer?.invalidate()
            webView.stopLoading()
            refreshing = false
        }
    }

    /// 头部「登录查看 Credit 用量」按钮
    func showLogin() {
        loginDismissed = false
        presentLoginWindow()
    }

    func refresh() {
        guard MonitorPreferences.shared.value.creditEnabled else { return }
        guard !refreshing else { return }
        refreshing = true
        refreshTask = Task { @MainActor in
            defer { self.refreshing = false }
            do {
                let snapshot = try await self.fetchSnapshot()
                try Task.checkCancellation()
                guard MonitorPreferences.shared.value.creditEnabled else { return }
                self.applySnapshot(snapshot)
            } catch CreditError.notLoggedIn {
                self.fetchError = "登录已失效，保留上次可信额度"
                await self.handleNotLoggedIn()
            } catch {
                self.fetchError = "获取失败，当前显示上次数据"
                Notify.log("Credit 拉取失败：\(error.localizedDescription)")
            }
        }
    }

    private func applySnapshot(_ snap: Snapshot) {
        lastUpdated = Date()
        fetchError = nil
        self.allocated = snap.allocated
        self.used = snap.used
        self.remaining = snap.remaining
        self.trend = snap.trend
        self.hasData = true
        if self.needsLogin { self.needsLogin = false }
        // 只有登录窗还在展示时才需要收回（避免每次刷新都重复打「登录成功」日志）
        if self.loginWindow?.isVisible == true { self.dismissLoginWindow() }
    }

    /// 登录态缺失：先自动从 Chrome 导入最新 SSO cookie 补救（用户 Chrome 在线时无感恢复），
    /// 仍失败才弹内置登录窗
    private func handleNotLoggedIn() async {
        guard MonitorPreferences.shared.value.creditEnabled, !Task.isCancelled else { return }
        let n = MonitorPreferences.shared.value.chromeImport ? await ChromeCookieImporter.importInto(webView.configuration.websiteDataStore) : 0
        if n > 0 {
            do {
                self.applySnapshot(try await self.fetchSnapshot())
                Notify.log("Credit：已复用 Chrome 登录态（导入 \(n) 条 cookie），免登录读取成功")
                return
            } catch { /* 导入后仍失败，走登录窗 */ }
        }
        if !self.needsLogin { Notify.log("Credit：SSO 登录态缺失，请在登录窗中完成扫码登录") }
        self.needsLogin = true
    }

    // MARK: 私有

    private func fetchSnapshot() async throws -> Snapshot {
        try await ensureConsoleLoaded()
        let js = """
        const t = await fetch('/websso/token/get?client_id=518aba86d4&loginProtocol=OIDC&mode=browser&sdk=SSOWebOIDC_1.4.0').then(r => r.json());
        if (!t.data || !t.data.access_token) return { noauth: true };
        const h = { headers: { 'access-token': t.data.access_token } };
        const base = 'https://credit-hub.sankuai.com/ui/credit/dashboard/personal/';
        const n = new Date();
        const ds = n.getFullYear() + '-' + String(n.getMonth() + 1).padStart(2, '0') + '-' + String(n.getDate()).padStart(2, '0');
        const [quota, tr] = await Promise.all([
            fetch(base + 'today-quota', h).then(r => r.json()),
            fetch(base + 'trend?days=7&date=' + ds, h).then(r => r.json())
        ]);
        if (!quota.data) return { noauth: true };
        return { quota: quota.data, trend: tr.data || [] };
        """
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        } catch {
            // 页面可能正在跳转（如 SSO 重定向中），按未登录处理，下轮重试
            throw CreditError.notLoggedIn
        }
        guard let dict = raw as? [String: Any] else { throw CreditError.badPayload }
        if dict["noauth"] as? Bool == true { throw CreditError.notLoggedIn }
        guard let quota = dict["quota"] as? [String: Any] else { throw CreditError.badPayload }
        let num: (Any?) -> Double? = { v in
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let s = v as? String { return Double(s) }
            return nil
        }
        guard let allocated = num(quota["allocatedQuota"]),
              let used = num(quota["usedAmount"]),
              let remaining = num(quota["remainingQuota"]) else { throw CreditError.badPayload }
        var points: [(date: String, value: Double)] = []
        if let arr = dict["trend"] as? [[String: Any]] {
            for item in arr {
                let d = (item["date"] as? String) ?? ""
                if let v = num(item["credit"]) { points.append((d, v)) }
            }
        }
        return Snapshot(allocated: allocated, used: used, remaining: remaining, trend: points)
    }

    /// 确保 WebView 停在 console 域（fetch 需要同源 cookie 上下文）。
    /// 未登录时页面会被 302 到 SSO 登录页，直接抛 notLoggedIn 走登录窗流程。
    private func ensureConsoleLoaded() async throws {
        if webView.url?.host == Self.consoleHost { return }
        webView.load(URLRequest(url: Self.dashboardURL))
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 300_000_000)
            guard let host = webView.url?.host, !webView.isLoading else { continue }
            if host == Self.consoleHost {
                for _ in 0..<20 {
                    let state = (try? await webView.evaluateJavaScript("document.readyState")) as? String
                    if state == "complete" || state == "interactive" { return }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
                return
            }
            throw CreditError.notLoggedIn   // 已被重定向到 SSO 登录页
        }
        throw CreditError.notLoggedIn
    }

    private func presentLoginWindow() {
        if loginWindow == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 760),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "登录 CatPaw Console（登录成功后自动关闭）"
            win.isReleasedWhenClosed = false
            win.delegate = self
            loginWindow = win
        }
        guard let win = loginWindow, !win.isVisible else { return }
        webView.removeFromSuperview()
        win.contentView = webView
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webView.load(URLRequest(url: Self.dashboardURL))
        // 登录探测：每 5 秒尝试一次取数，成功即收回 WebView 并关窗
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.loginWindow?.isVisible == true else { t.invalidate(); return }
                self.refresh()
            }
        }
    }

    private func dismissLoginWindow() {
        guard let win = loginWindow else { return }
        loginDismissed = false
        webView.removeFromSuperview()
        win.contentView = nil
        win.close()
        offscreenWindow?.contentView = webView
        Notify.log("Credit：SSO 登录成功，开始读取用量看板")
    }

    /// 用户手动关掉登录窗 → 收回 WebView 到离屏宿主
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if let win = self.loginWindow, notification.object as? NSWindow === win,
               self.webView.superview != nil {
                self.loginDismissed = true
                self.webView.removeFromSuperview()
                win.contentView = nil
                self.offscreenWindow?.contentView = self.webView
            }
        }
    }
}

// MARK: Credit 用量头部卡片

struct CreditHeaderView: View {
    @ObservedObject var credit: CreditStore

    var body: some View {
        Group {
            if credit.needsLogin {
                Button(action: { credit.showLogin() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "person.badge.key")
                            .font(.system(size: 10, weight: .semibold))
                        Text("登录查看 Credit 用量")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color(red: 0.98, green: 0.80, blue: 0.25))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().stroke(Color.ink(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("优先复用 Chrome 登录态；拿不到时扫码登录一次即可长期读取")
            } else if credit.hasData {
                dataCard
            }
        }
    }

    private var dataCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 8))
                    Text("剩余 Credit")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.ink(0.5))
                Text(Self.fmt(credit.remaining))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.ink)
                usageBar
            }
            trendBars
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.ink(0.12), lineWidth: 1))
        .help("Credit 总量 \(Self.fmt(credit.allocated)) · 已用 \(Self.fmt(credit.used))（\(Self.pct(credit.used, credit.allocated))）")
    }

    private var usageBar: some View {
        let ratio = credit.allocated > 0 ? min(max(credit.used / credit.allocated, 0), 1) : 0
        return HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink(0.12))
                Capsule()
                    .fill(Color(red: 0.98, green: 0.60, blue: 0.25))
                    .frame(width: max(2, 110 * ratio))
            }
            .frame(width: 110, height: 4)
            Text("已用 \(Self.pct(credit.used, credit.allocated))")
                .font(.system(size: 8))
                .foregroundColor(.ink(0.4))
        }
    }

    private var trendBars: some View {
        let maxV = credit.trend.map(\.value).max() ?? 0
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(credit.trend.enumerated()), id: \.offset) { _, p in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(red: 0.30, green: 0.65, blue: 0.98).opacity(0.85))
                    .frame(width: 4, height: max(2, 20 * (maxV > 0 ? p.value / maxV : 0)))
            }
        }
        .frame(height: 20, alignment: .bottom)
        .help("7 日消耗趋势")
    }

    private static func fmt(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }

    private static func pct(_ used: Double, _ total: Double) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.2f%%", used / total * 100)
    }
}

// MARK: - 主窗口（SwiftUI，玻璃态扁平风格）

/// 真玻璃背景：NSVisualEffectView 嵌入 SwiftUI
struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// AI 端分组：会话按来源分板块展示（rawValue 与 SessionWatch.sourceName 对齐）
enum SourceGroup: String, CaseIterable, Identifiable {
    case catpaw = "IDE-CatPaw"
    case desk = "CatDesk"
    case codex = "Codex"
    case claude = "Claude"
    case trae = "Trae"
    case dsh = "DeepSeek"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .catpaw: return "pawprint.fill"
        case .desk: return "desktopcomputer"
        case .codex: return "apple.terminal.fill"
        case .claude: return "sparkle"
        case .trae: return "chevron.left.forwardslash.chevron.right"
        case .dsh: return "fish"
        }
    }

    /// bundle 内的真实应用图标（icon-<case>.png），取自各 AI 端官方图标
    var iconImage: NSImage? {
        let name: String
        switch self {
        case .catpaw: name = "icon-catpawide"
        case .desk:   name = "icon-catdesk"
        case .codex:  name = "icon-codex"
        case .claude: name = "icon-claude"
        case .trae:   name = "icon-trae"
        case .dsh:    name = "icon-dsh"
        }
        guard let p = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
        return NSImage(contentsOfFile: p)
    }

    var accent: Color {
        switch self {
        case .catpaw: return Color(red: 0.62, green: 0.45, blue: 0.95)
        case .desk: return Color(red: 0.30, green: 0.60, blue: 0.98)
        case .codex: return Color(red: 0.25, green: 0.80, blue: 0.55)
        case .claude: return Color(red: 0.98, green: 0.60, blue: 0.30)
        case .trae: return Color(red: 0.90, green: 0.28, blue: 0.22)
        case .dsh: return Color(red: 0.29, green: 0.45, blue: 0.98)
        }
    }
}

/// 头部 Codex 额度卡：primary/secondary 两个窗口的已用百分比条，
/// 数据来自本地会话 jsonl 的 rate_limits 快照（零网络零凭证）
struct CodexQuotaView: View {
    let quota: CodexRateLimits?
    let fetchedAt: Date?

    var body: some View {
        GlassPanel(radius: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.98, green: 0.60, blue: 0.30))
                    Text("Codex 额度")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.ink(0.85))
                    if let plan = quota?.planType {
                        Text(plan)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color(red: 0.90, green: 0.28, blue: 0.22).opacity(0.85)))
                    }
                    Spacer(minLength: 0)
                    Text(stalenessText)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(.ink(0.32))
                }
                if let q = quota {
                    quotaBar(label: CodexRateLimits.windowLabel(minutes: q.primaryWindowMinutes),
                             used: q.primaryUsedPercent,
                             resetsAt: q.primaryResetsAt)
                    quotaBar(label: CodexRateLimits.windowLabel(minutes: q.secondaryWindowMinutes),
                             used: q.secondaryUsedPercent,
                             resetsAt: q.secondaryResetsAt)
                    if let balance = q.creditsBalance, balance != "0" {
                        Text("credits $\(balance)")
                            .font(.system(size: 9))
                            .foregroundColor(.ink(0.45))
                    }
                } else {
                    Text("暂无数据 · Codex 跑一回合后显示")
                        .font(.system(size: 10))
                        .foregroundColor(.ink(0.35))
                        .padding(.vertical, 8)
                }
            }
            .padding(10)
            .frame(width: 185, alignment: .leading)
        }
    }

    private var stalenessText: String {
        // 快照落盘时刻优先：Codex 只在回合落盘时写快照，扫描到的数据可能是几小时前的
        let at = quota?.snapshotAt ?? fetchedAt
        guard let at else { return "--:--" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: at)
    }

    /// 单窗口进度条：与 ChatGPT 额度页同语义，展示「剩余」——
    /// 剩余 <15% 红、<40% 黄，其余绿；悬停提示含已用与重置时间
    private func quotaBar(label: String, used: Double?, resetsAt: Date?) -> some View {
        let used = min(max(used ?? 0, 0), 100)
        let remaining = 100 - used
        let color: Color = remaining < 15 ? Color(red: 0.96, green: 0.35, blue: 0.35)
            : remaining < 40 ? Color(red: 0.98, green: 0.80, blue: 0.25)
            : Color(red: 0.25, green: 0.85, blue: 0.50)
        var tip = "已用 \(Int(used))% · 剩余 \(Int(remaining))%"
        if let resetsAt {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            tip += " · \(fmt.string(from: resetsAt)) 重置"
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundColor(.ink(0.55))
                Spacer(minLength: 0)
                Text("剩 \(Int(remaining))%")
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.ink(0.75))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ink(0.10))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * remaining / 100)
                }
            }
            .frame(height: 5)
        }
        .help(tip)
    }
}

/// 玻璃卡片容器（面板/日志区共用）
extension Color {
    /// 自适应墨色（暗黑外观=白 / 明亮外观=黑），主窗口所有文案与描边的基色
    static var ink: Color { Color(nsColor: .labelColor) }
    static func ink(_ opacity: Double) -> Color { Color(nsColor: .labelColor).opacity(opacity) }
}

/// 外观模式：明亮 / 暗黑（默认暗黑）
enum UITheme: String, CaseIterable {
    case light, dark
    var label: String {
        switch self { case .light: return "明亮"; case .dark: return "暗黑" }
    }
    var icon: String {
        switch self { case .light: return "sun.max.fill"; case .dark: return "moon.fill" }
    }
    var scheme: ColorScheme? {
        switch self { case .light: return .light; case .dark: return .dark }
    }
}

struct GlassPanel<Content: View>: View {
    var radius: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.ink(0.16), Color.ink(0.05)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// 紧凑会话行：玻璃面板内的单行卡片
struct SessionMiniRow: View {
    let row: SessionRow
    /// 执行中呼吸动效驱动
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.state.tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: (row.state == .running || row.state == .error || row.state == .awaitingConfirm)
                            ? row.state.tint.opacity(0.9) : .clear,
                            radius: 3)
                Text(row.title ?? row.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.ink(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(row.timeText)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.ink(0.32))
            }
            HStack(spacing: 4) {
                // 渠道标识：同一来源内的端区分（IDE-CatPaw 下的 插件/IDE）
                if let channel = row.channel {
                    Text(channel)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(red: 0.40, green: 0.52, blue: 0.98).opacity(0.85)))
                }
                Text(row.caption)
                    .font(.system(size: 10))
                    .foregroundColor(.ink(0.40))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 13)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ink(0.05))
                if row.state == .running {
                    // 活跃呼吸背景：渐变填充 + 描边同步呼吸
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [row.state.tint.opacity(pulse ? 0.20 : 0.07),
                                     row.state.tint.opacity(pulse ? 0.09 : 0.03)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(row.state.tint.opacity(pulse ? 0.45 : 0.12), lineWidth: 1)
                }
            }
        )
        .onAppear { startPulseIfNeeded() }
        .onChange(of: row.state) { _ in startPulseIfNeeded() }
        // 点击会话行 → 打开来源 app（能锚定则锚定到具体会话）
        .contentShape(Rectangle())
        .onTapGesture { SourceOpener.open(kindRaw: row.source, path: row.id) }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func startPulseIfNeeded() {
        guard row.state == .running, !pulse else { return }
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

/// 单个 AI 端板块：图标 + 名称 + 计数 + 会话列表
struct SourcePanel: View {
    let group: SourceGroup
    let rows: [SessionRow]
    let monitor: Monitor

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if let img = group.iconImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [group.accent, group.accent.opacity(0.65)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: group.icon)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 24, height: 24)
                    }
                    Text(group.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.ink(0.85))
                    Spacer()
                    Text("\(rows.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.ink(0.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.ink(0.07)))
                }

                if rows.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: group.icon)
                            .font(.system(size: 18))
                            .foregroundColor(.ink(0.12))
                        Text("暂无会话")
                            .font(.system(size: 11))
                            .foregroundColor(.ink(0.25))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(rows) { row in
                                SessionMiniRow(row: row)
                                    .contextMenu {
                                        Button("重命名会话…") {
                                            monitor.promptRenameSession(key: row.id, current: row.title)
                                        }
                                        if monitor.hasCustomTitle(key: row.id) {
                                            Button("恢复默认标题") { monitor.renameSession(key: row.id, title: nil) }
                                        }
                                    }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var credit: CreditStore
    @ObservedObject var updater: UpdateChecker
    /// 开机自启（SMAppService，macOS 13+）
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// 外观模式（默认暗黑）
    @AppStorage("ui.theme") private var themeRaw = UITheme.dark.rawValue
    @Environment(\.colorScheme) private var scheme
    private var theme: UITheme { UITheme(rawValue: themeRaw) ?? .dark }

    var body: some View {
        ZStack {
            if scheme == .dark {
                // 玻璃基底：桌面壁纸透出的磨砂质感 + 轻微压暗
                VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()
                LinearGradient(
                    colors: [Color.black.opacity(0.22), Color.black.opacity(0.42)],
                    startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                // 明亮模式：纯白底
                Color.white.ignoresSafeArea()
            }
            VStack(spacing: 12) {
                header
                    .fixedSize(horizontal: false, vertical: true)
                sessionsSection
                logSection
                    .fixedSize(horizontal: false, vertical: true)
                footer
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.top, 34) // fullSizeContentView：避让红绿灯
            .padding(.bottom, 12)
        }
        .preferredColorScheme(theme.scheme)
        .frame(minWidth: 1118, minHeight: 740)
    }

    // MARK: 头部

    /// 与任务中心共用哈基米小猫品牌形象。
    private var appLogo: some View {
        BrandMascotView(size: 44)
    }

    private var header: some View {
        HStack(spacing: 12) {
            appLogo

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Agent哈基米")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.ink)
                    // 正在监听会话动态
                    Image(systemName: "ear")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(red: 0.98, green: 0.80, blue: 0.25))
                        .help("正在监听会话动态")
                    Text("· 任务监测器")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.ink(0.45))
                        .help("Agent哈基米 · 监测 Agent 任务与会话状态")
                }
                Text("v\(Config.appVersion) · CatPaw / CatDesk / Codex / Claude / Trae / DeepSeek 会话监控")
                    .font(.system(size: 11))
                    .foregroundColor(.ink(0.45))
            }
            Spacer()
            CreditHeaderView(credit: credit)
            CodexQuotaView(quota: monitor.codexQuota, fetchedAt: monitor.codexQuotaFetchedAt)
            runningPill
            themeMenu
        }
        .padding(.horizontal, 4)
    }

    /// 外观切换：跟随系统 / 明亮 / 暗黑，右上角平铺展示
    private var themeMenu: some View {
        HStack(spacing: 2) {
            ForEach(UITheme.allCases, id: \.rawValue) { t in
                Button(action: { themeRaw = t.rawValue }) {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(t.label)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(themeRaw == t.rawValue ? .ink : .ink(0.42))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(themeRaw == t.rawValue ? 0.10 : 0)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.ink(0.14), lineWidth: 1))
        .help("外观：明亮 / 暗黑（默认暗黑）")
    }

    private var runningPill: some View {
        let active = monitor.runningCount > 0
        return HStack(spacing: 6) {
            Circle()
                .fill(active ? Color(red: 0.25, green: 0.85, blue: 0.5)
                             : Color.ink(0.3))
                .frame(width: 7, height: 7)
            Text(active ? "\(monitor.runningCount) 个会话执行中" : "无会话执行")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(active ? Color(red: 0.4, green: 0.9, blue: 0.6)
                                : .ink(0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.ink(0.14), lineWidth: 1))
    }

    // MARK: 会话宫格（按 AI 端分板块，两列自适应，跟随 SourceGroup.allCases）

    private func rows(for group: SourceGroup) -> [SessionRow] {
        monitor.gridRows.filter { $0.source == group.rawValue }
    }

    private var sessionsSection: some View {
        // 手动 2×2 网格（原 LazyVGrid 在窗口高度不足时不参与压缩，会把
        // 日志区/底部按钮栏推出窗口底边裁剪，v0.10.34 修复）；
        // HStack/VStack 内嵌的 ScrollView 可正常吸收压缩。
        // 分组两列配对，奇数组末行补空位保持两列等宽
        let groups = SourceGroup.allCases
        let pairs = stride(from: 0, to: groups.count, by: 2)
            .map { Array(groups[$0..<min($0 + 2, groups.count)]) }
        return VStack(spacing: 10) {
            ForEach(pairs.indices, id: \.self) { i in
                HStack(spacing: 10) {
                    ForEach(pairs[i]) { group in
                        SourcePanel(group: group, rows: rows(for: group), monitor: monitor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if pairs[i].count == 1 {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 运行日志（时间倒序）

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("运行日志")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.ink(0.55))
                Spacer()
                Button(action: { NSWorkspace.shared.open(Notify.logURL) }) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.ink(0.4))
                .help("打开日志文件")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if monitor.logLines.isEmpty {
                        Text("暂无日志")
                            .font(.system(size: 11))
                            .foregroundColor(.ink(0.3))
                    } else {
                        ForEach(Array(monitor.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.ink(0.55))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .frame(height: 96)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ink(0.09), lineWidth: 1)
        )
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack {
            Button("发送测试通知") {
                Notify.send(title: "Agent哈基米 测试 🐾",
                            body: "通知链路正常，已播放当前提示音",
                            sound: "DogBark")
            }
Button(action: {
openSystemNotificationSettings()
}) {
                Label("打开通知设置", systemImage: "bell.badge")
            }
            .help("系统设置 → 通知 → Agent哈基米（建议提醒样式选「持续」）")
            if UpdateChecker.inAppUpdatesAvailable {
                Button(action: {
                    if updater.latestVersion != nil {
                        updater.performUpdate()
                    } else {
                        updater.check(manual: true)
                    }
                }) {
                    if let v = updater.latestVersion {
                        Label("立即更新 v\(v)", systemImage: "arrow.down.circle.fill")
                    } else {
                        Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(updater.checking || updater.updating)
                .help(updater.latestVersion != nil
                      ? "下载最新 dmg 并自动替换安装"
                      : "比对代码仓库 dist 目录里的最新 dmg 版本（每小时自动检查一次）")
            } else {
                Link("查看项目更新", destination: UpdateChecker.projectURL)
            }
            if let tip = updater.tip {
                Text(tip)
                    .font(.system(size: 11))
                    .foregroundColor(updater.latestVersion != nil ? .orange : .ink(0.55))
                    .lineLimit(1)
            }
            Spacer()
            Toggle("桌宠", isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "pet.enabled") },
                set: { want in PetController.shared.setEnabled(want) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("在桌面显示大肥鱼桌宠")
            Toggle("开机启动", isOn: Binding(
                get: { launchAtLogin },
                set: { want in
                    do {
                        if want { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        Notify.log("launch-at-login: \(want ? "enabled" : "disabled")")
                    } catch {
                        Notify.log("launch-at-login failed: \(error.localizedDescription)")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("登录 macOS 后自动启动 Agent哈基米")
            Button("退出") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // 提升布局优先级：窗口高度不足时压缩会话网格而不是裁掉底部按钮
        .layoutPriority(1)
        .padding(.bottom, 2)
    }
}


// MARK: - 检查更新

/// 主链路：复用 SSO WebView 会话抓取 dev.sankuai.com 仓库 dist 目录列表，网页下载 dmg；
/// dev 仓库不可用/超时/SSO 未登录时，降级到 AIBase 版本记录表 + dmg 直链（免 SSO）。
/// 比对版本号，有更新时底部栏提示，用户确认后自动下载并替换安装。
@MainActor
final class UpdateChecker: NSObject, ObservableObject {
    /// 独立版本从 0.0.2 开始；新发布源接入前不使用原项目更新渠道。
    static let inAppUpdatesAvailable = false
    static let projectURL = URL(string: "https://github.com/zZzzPpp12/workAgent")!
    static let unavailableMessage = "应用内更新暂未接入，请到 workAgent 仓库查看新版本。"
    static let listURLString = "https://dev.sankuai.com/code/repo-detail/~maohuafeng/agent-notifier-macos/file/list?branch=refs%2Fheads%2Fmaster&path=dist"
    /// AIBase 备用链路：版本记录表 PostgREST（anonKey 只读，免 SSO）；dist.sh 发版时经 mas.health 上传并登记
    static let aibaseListURL = "https://iqnxas42l4.aibase.sankuai.com/rest/v1/agent_notifier_releases?select=version,dmg_url&order=created_at.desc&limit=20"
    static let aibaseAnonKey = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbl9pcW54YXM0Mmw0IiwiaXNzIjoic3VwYWJhc2UiLCJpYXQiOjE3NDgxMzEyMDAsImV4cCI6MTg5MzQ1NjAwMH0.AVLaIabQP8LLE4LHV0zZeQY5Iu1KaLCZ1VcTI-MW_3Q"

    enum UpdateError: LocalizedError {
        case noDownloadURL
        case mountFailed
        case appNotFoundInDMG
        case shellFailed(String)
        var errorDescription: String? {
            switch self {
            case .noDownloadURL: return "未找到 dmg 下载地址"
            case .mountFailed: return "dmg 挂载失败"
            case .appNotFoundInDMG: return "dmg 内未找到 AgentNotifier.app"
            case .shellFailed(let s): return s.isEmpty ? "安装命令执行失败" : s
            }
        }
    }

    @Published private(set) var checking = false
    @Published private(set) var updating = false
    /// 远端发现的更高版本号（nil = 当前已是最新）
    @Published private(set) var latestVersion: String?
    /// 底部栏提示文案
    @Published private(set) var tip: String?

    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var timer: Timer?
    private var pendingFilename: String?
    /// AIBase 表读到的最新版 dmg 直链（备用下载链路用）
    private var latestDmgURL: URL?
    private var downloadDest: URL?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var clearTipTask: Task<Void, Never>?

    override init() {
        super.init()
        guard Self.inAppUpdatesAvailable else { return }
        let config = WKWebViewConfiguration()
        // 与 CreditStore 同一个持久化 data store，共享 SSO 登录态
        if #available(macOS 14, *) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "7F3A1C2E-5B6D-4E8F-9A0B-1C2D3E4F5A6B")!)
        } else {
            config.websiteDataStore = .default()
        }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        webView = wv
        wv.navigationDelegate = self
        wv.uiDelegate = self
        // 离屏宿主窗口：保证后台也能正常加载与执行 JS
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 760),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = wv
        host.orderBack(nil)
        hostWindow = host
    }

    /// 启动 20s 后先查一次，之后每小时自动查一次
    func start() {
        guard Self.inAppUpdatesAvailable else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self.check(manual: false)
        }
    }

    /// 语义化版本比较：a 比 b 新返回 true
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func check(manual: Bool) {
        guard Self.inAppUpdatesAvailable else {
            if manual { showTip(Self.unavailableMessage, sticky: false) }
            return
        }
        guard manual || MonitorPreferences.shared.value.updatesEnabled else { return }
        guard !checking, !updating else { return }
        checking = true
        if manual { showTip("正在检查更新…", sticky: true) }
        Task { @MainActor in
            defer { self.checking = false }
            self.latestDmgURL = nil
            // 主链路：dev 仓库页面抓取 dist 列表（含 SSO 会话）
            guard let wv = self.webView else {
                if manual { self.showTip("检查失败：WebView 未就绪", sticky: false) }
                return
            }
            wv.load(URLRequest(url: URL(string: Self.listURLString)!))
            // SPA 渲染需要时间：每秒轮询一次页面 DOM
            // 跳转到 SSO 时多为重定向握手（Cookie 有效会自动跳回），给 8s 宽限；
            // 仍未跳回视为会话失效——不弹任何窗口，直接回退 AIBase 兜底链路
            let js = """
            (() => {
              const out = [];
              const seen = new Set();
              const put = (v, href) => { if (!seen.has(v)) { seen.add(v); out.push({ v, href: href || '' }); } };
              document.querySelectorAll('a').forEach(a => {
                const m = ((a.textContent || '') + ' ' + (a.href || ''))
                  .match(/AgentNotifier-(\\d+\\.\\d+\\.\\d+)\\.dmg/);
                if (m) put(m[1], a.href);
              });
              if (!out.length) {
                // 文件名可能不在 <a> 里（span + 点击路由）：全文兜底，href 取最近祖先 <a>
                document.querySelectorAll('td,span,div,p').forEach(e => {
                  if (e.children.length) return;
                  const m = (e.textContent || '').match(/AgentNotifier-(\\d+\\.\\d+\\.\\d+)\\.dmg/);
                  if (m) { const a = e.closest('a'); put(m[1], a ? a.href : ''); }
                });
              }
              return JSON.stringify(out);
            })()
            """
            var found: [(String, String)] = []
            let maxWait = 25
            var ssoStuck = 0
            for _ in 0..<maxWait {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let host = (try? await wv.evaluateJavaScript("location.host")) as? String ?? ""
                if host.contains("ssosv.sankuai.com") {
                    ssoStuck += 1
                    if ssoStuck < 8 { continue }
                    Notify.log("检查更新：SSO 会话失效，dev 仓库跳过，回退 AIBase 版本表")
                    break
                }
                ssoStuck = 0
                if let raw = (try? await wv.evaluateJavaScript(js)) as? String,
                   let data = raw.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    found = arr.compactMap { d in d["v"].map { ($0, d["href"] ?? "") } }
                    if !found.isEmpty { break }
                }
            }
            if !found.isEmpty,
               let newest = found.map({ $0.0 }).max(by: { Self.isNewer($1, than: $0) }) {
                self.handleFound(newest: newest, manual: manual)
                return
            }
            // 兜底链路：AIBase 版本记录表（免 SSO，同时拿到 dmg 直链）
            if let ab = await Self.fetchAIBaseNewest() {
                Notify.log("检查更新：dev 仓库不可用，已回退 AIBase 版本表")
                self.latestDmgURL = ab.1
                self.handleFound(newest: ab.0, manual: manual)
                return
            }
            if manual { self.showTip("检查失败：dev 仓库与 AIBase 版本表均不可用", sticky: false) }
            Notify.log("检查更新失败：dev 仓库与 AIBase 均无数据")
        }
    }

    /// 拿到远端最新版本后的统一判定与提示
    private func handleFound(newest: String, manual: Bool) {
        Notify.log("检查更新：远端最新 v\(newest)，当前 v\(Config.appVersion)")
        // 调试钩子：update.forceLatest 置任意值即强制进入更新分支（下载的仍是远端真实最新包）
        let forced = UserDefaults.standard.string(forKey: "update.forceLatest") != nil
        if forced || Self.isNewer(newest, than: Config.appVersion) {
            self.latestVersion = newest
            self.showTip("发现新版本 v\(newest)，点击「立即更新」升级", sticky: true)
            // 隐藏测试开关：检测到新版本自动执行更新（update.autoPerform）
        } else {
            self.latestVersion = nil
            if manual { self.showTip("已是最新版本 v\(Config.appVersion)", sticky: false) }
        }
    }

    /// 从 AIBase 版本表读取最新版本与 dmg 下载地址；失败/为空返回 nil（走 dev 仓库兜底）
    nonisolated private static func fetchAIBaseNewest() async -> (String, URL)? {
        guard let url = URL(string: aibaseListURL) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(aibaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(aibaseAnonKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let parsed: [(String, URL)] = rows.compactMap { row in
            guard let v = row["version"] as? String,
                  let u = row["dmg_url"] as? String,
                  let link = URL(string: u) else { return nil }
            return (v, link)
        }
        return parsed.max(by: { isNewer($1.0, than: $0.0) })
    }

    /// AIBase 登记的 dmg 直链下载（免 SSO）；失败抛错走 dev 仓库兜底
    nonisolated private static func downloadDirect(dmgURL: URL, version: String) async throws -> URL {
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotifier-\(version).dmg")
        try? FileManager.default.removeItem(at: dest)
        let (tmp, resp) = try await URLSession.shared.download(from: dmgURL)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noDownloadURL
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// 用户确认更新：主链路 dev 仓库网页下载；异常/超时降级到 AIBase dmg 直链；成功后替换安装并重启
    func performUpdate() {
        guard Self.inAppUpdatesAvailable else {
            showTip(Self.unavailableMessage, sticky: false)
            return
        }
        guard let version = latestVersion, !updating else { return }
        updating = true
        showTip("正在下载 v\(version)…", sticky: true)
        Task { @MainActor in
            do {
                // 主链路：dev 仓库网页下载
                let file = try await self.downloadDmg(version: version)
                self.showTip("下载完成，正在安装 v\(version)…", sticky: true)
                try await Self.install(dmg: file)
                // install 成功后会拉起新版本并终止当前进程；走到这里说明未退出（视为失败兜底）
                self.updating = false
            } catch {
                // 兜底链路：AIBase 版本表登记的 dmg 直链（免 SSO）
                Notify.log("更新下载：dev 仓库失败（\(error.localizedDescription)），回退 AIBase 直链")
                do {
                    guard let ab = await Self.fetchAIBaseNewest() else { throw UpdateError.noDownloadURL }
                    let f = try await Self.downloadDirect(dmgURL: ab.1, version: ab.0)
                    Notify.log("更新下载：AIBase 直链完成")
                    self.showTip("下载完成，正在安装 v\(ab.0)…", sticky: true)
                    try await Self.install(dmg: f)
                    self.updating = false
                } catch {
                    self.updating = false
                    self.showTip("更新失败：\(error.localizedDescription)", sticky: true)
                    Notify.log("自动更新失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 详情页点「下载文件」按钮触发下载；二进制响应由 WKNavigationDelegate 转成 WKDownload 接管
    private func downloadDmg(version: String) async throws -> URL {
        guard let wv = webView else { throw UpdateError.noDownloadURL }
        let filename = "AgentNotifier-\(version).dmg"
        let detail = "https://dev.sankuai.com/code/repo-detail/~maohuafeng/agent-notifier-macos/file/detail?branch=refs%2Fheads%2Fmaster&path=dist%2F\(filename)"
        let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dest)
        self.pendingFilename = filename
        self.downloadDest = dest
        wv.load(URLRequest(url: URL(string: detail)!))
        // 等详情页渲染出「下载文件」按钮（SSO 已登录时通常 2~5s）
        let findJS = """
        [...document.querySelectorAll('button')].some(x => (x.textContent || '').trim() === '下载文件')
        """
        var ready = false
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if ((try? await wv.evaluateJavaScript(findJS)) as? Bool) == true { ready = true; break }
        }
        Notify.log("更新下载：详情页就绪=\(ready) url=\(wv.url?.absoluteString.prefix(120) ?? "nil")")
        guard ready else { throw UpdateError.noDownloadURL }
        return try await withCheckedThrowingContinuation { cont in
            self.downloadContinuation = cont
            Task { @MainActor in
                let r1 = (try? await wv.evaluateJavaScript("""
                (() => {
                  const b = [...document.querySelectorAll('button')].find(x => (x.textContent || '').trim() === '下载文件');
                  if (b) { b.click(); return 'clicked'; }
                  return 'not-found';
                })()
                """)) as? String ?? "js-err"
                Notify.log("更新下载：已点「下载文件」=\(r1)")
                // 若弹出确认对话框（确定/取消），点确定
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let r2 = (try? await wv.evaluateJavaScript("""
                (() => {
                  const ok = [...document.querySelectorAll('button')].find(x => (x.textContent || '').trim() === '确定' && x.offsetParent !== null);
                  if (ok) { ok.click(); return 'ok-clicked'; }
                  return 'no-dialog';
                })()
                """)) as? String ?? "js-err"
                Notify.log("更新下载：确认框=\(r2)")
                // 60s 超时保护
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    if let c = self.downloadContinuation {
                        self.downloadContinuation = nil
                        c.resume(throwing: UpdateError.shellFailed("下载超时（60s）"))
                    }
                }
            }
        }
    }

    /// 挂载 dmg → 用其中的 AgentNotifier.app 替换 ~/Applications 旧版 → 拉起新版并退出当前进程
    static func install(dmg: URL) async throws {
        let out = try await shellOut("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", dmg.path])
        var mount: String?
        for line in out.split(separator: "\n") {
            if let last = line.split(separator: "\t").last, last.hasPrefix("/Volumes/") {
                mount = String(last)
            }
        }
        guard let mountPoint = mount else { throw UpdateError.mountFailed }
        defer { Task.detached { _ = try? await shellOut("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]) } }
        let src = URL(fileURLWithPath: mountPoint).appendingPathComponent("AgentNotifier.app")
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { throw UpdateError.appNotFoundInDMG }
        // Structural signature verification alone cannot authenticate an ad-hoc publisher.
        _ = try await shellOut("/usr/bin/codesign", ["--verify", "--deep", "--strict", src.path])
        let currentIdentity = UpdateIdentity.parse(try await shellOut("/usr/bin/codesign", ["--display", "--verbose=4", Bundle.main.bundleURL.path]))
        let incomingIdentity = UpdateIdentity.parse(try await shellOut("/usr/bin/codesign", ["--display", "--verbose=4", src.path]))
        guard currentIdentity.accepts(incomingIdentity) else {
            throw UpdateError.shellFailed("更新签名身份不匹配，或当前为未配置可信发布身份的本地构建；保留当前版本。")
        }
        guard let incomingVersion = Bundle(url: src)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              isNewer(incomingVersion, than: Config.appVersion) else {
            throw UpdateError.shellFailed("下载产物版本不高于当前版本，未覆盖安装。")
        }
        let appsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let dest = appsDir.appendingPathComponent("AgentNotifier.app")
        let staged = appsDir.appendingPathComponent(".AgentNotifier-new.app")
        // 先拷到暂存目录并去隔离属性，全部就绪后再替换旧版——避免「删了旧的没拷上」的空窗
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        try fm.copyItem(at: src, to: staged)
        let backup = appsDir.appendingPathComponent(".AgentNotifier-backup-\(UUID().uuidString).app")
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: backup) }
        do {
            try fm.moveItem(at: staged, to: dest)
            _ = try await shellOut("/usr/bin/open", ["-n", dest.path])
        } catch {
            if fm.fileExists(atPath: dest.path) {
                try? fm.moveItem(at: dest, to: appsDir.appendingPathComponent(".AgentNotifier-failed-\(UUID().uuidString).app"))
            }
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: dest) }
            throw error
        }
        Notify.log("更新安装完成，重启进入新版本")
        try? await Task.sleep(nanoseconds: 800_000_000)
        await MainActor.run { NSApp.terminate(nil) }
    }

    /// 递归移除 quarantine 隔离属性（下载的 dmg 会带上它，不清会导致 Gatekeeper 拦截启动）
    private static func stripQuarantine(_ url: URL) {
        let key = "com.apple.quarantine"
        removexattr(url.path, key, 0)
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let f as URL in e { removexattr(f.path, key, 0) }
        }
    }

    private static func shellOut(_ path: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard p.terminationStatus == 0 else {
                throw UpdateError.shellFailed(s.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return s
        }.value
    }

    private func showTip(_ text: String?, sticky: Bool) {
        clearTipTask?.cancel()
        tip = text
        if text != nil && !sticky {
            clearTipTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled {
                    self.tip = self.latestVersion.map { "发现新版本 v\($0)，点击「立即更新」升级" }
                }
            }
        }
    }

}

extension UpdateChecker: WKNavigationDelegate {
    /// 主框架遇到非 HTML（或 attachment）响应时转下载，交给 WKDownloadDelegate
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationResponse: WKNavigationResponse,
                             decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        let mime = navigationResponse.response.mimeType ?? ""
        let disp = ((navigationResponse.response as? HTTPURLResponse)?
            .allHeaderFields["Content-Disposition"] as? String) ?? ""
        if disp.contains("attachment") || (!mime.isEmpty && !mime.contains("html") && !mime.contains("json") && !mime.contains("javascript")) {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView,
                             navigationResponse: WKNavigationResponse,
                             didBecome download: WKDownload) {
        Task { @MainActor in download.delegate = self }
    }

    /// 「下载文件」按钮走 JS 触发 <a download>：导航动作层面就要接管下载
    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            Notify.log("更新下载：接管下载动作 url=\(navigationAction.request.url?.absoluteString.prefix(120) ?? "?")")
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    nonisolated func webView(_ webView: WKWebView,
                             navigationAction: WKNavigationAction,
                             didBecome download: WKDownload) {
        Task { @MainActor in download.delegate = self }
    }
}

extension UpdateChecker: WKUIDelegate {
    /// 「下载文件」若走 window.open：拉回当前 WebView 加载，交给下载链路
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url != nil {
            Task { @MainActor in webView.load(navigationAction.request) }
        }
        return nil
    }
}

extension UpdateChecker: WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload,
                              decideDestinationUsing response: URLResponse,
                              suggestedFilename: String) async -> URL? {
        await MainActor.run {
            let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let dest = dir.appendingPathComponent(self.pendingFilename ?? suggestedFilename)
            self.downloadDest = dest
            return dest
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            let dest = self.downloadDest
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(self.pendingFilename ?? "AgentNotifier.dmg")
            self.downloadContinuation?.resume(returning: dest)
            self.downloadContinuation = nil
        }
    }

    nonisolated func download(_ download: WKDownload,
                              didFailWithError error: Error,
                              resumeData: Data?) {
        Task { @MainActor in
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
        }
    }
}

// MARK: - App Delegate

/// 菜单栏悬浮事件接收器：tracking area 的 owner 必须是 NSResponder
final class HoverMenuOpener: NSResponder {
    var onHover: () -> Void = {}
    override func mouseEntered(with event: NSEvent) { onHover() }
}

extension SessionState {
    /// 快捷面板用 NSColor 版状态色（与主窗口 SwiftUI tint 一致）
    var nsTint: NSColor {
        switch self {
        case .running: return NSColor(red: 0.25, green: 0.85, blue: 0.50, alpha: 1)
        case .done: return NSColor(red: 0.30, green: 0.65, blue: 0.98, alpha: 1)
        case .stuck: return NSColor(red: 0.98, green: 0.60, blue: 0.25, alpha: 1)
        case .error: return NSColor(red: 0.96, green: 0.35, blue: 0.35, alpha: 1)
        case .awaitingConfirm: return NSColor(red: 0.98, green: 0.80, blue: 0.25, alpha: 1)
        case .stopped, .idle: return NSColor.labelColor.withAlphaComponent(0.35)
        }
    }
}

/// 快捷面板会话行：状态色圆点与主窗口一致，进行中的会话高亮背景
final class SessionMenuRowView: NSView {
    private let row: SessionRow

    init(row: SessionRow) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let tint = row.state.nsTint
        if row.state == .running {
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6)
            tint.withAlphaComponent(0.16).setFill()
            bg.fill()
            tint.withAlphaComponent(0.45).setStroke()
            bg.lineWidth = 1
            bg.stroke()
        }
        if hovering {
            let hl = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), xRadius: 6, yRadius: 6)
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            hl.fill()
        }
        let d: CGFloat = 8
        let dotRect = NSRect(x: 16, y: (bounds.height - d) / 2, width: d, height: d)
        tint.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let trunc = NSMutableParagraphStyle()
        trunc.lineBreakMode = .byTruncatingTail
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: trunc,
        ]
        let caption = "\(row.state.rawValue) · \(row.timeText)"
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let capSize = (caption as NSString).size(withAttributes: capAttrs)
        (row.displayName as NSString).draw(
            in: NSRect(x: 32, y: (bounds.height - 16) / 2,
                       width: bounds.width - 32 - capSize.width - 24, height: 16),
            withAttributes: titleAttrs)
        (caption as NSString).draw(
            in: NSRect(x: bounds.width - capSize.width - 14, y: (bounds.height - 14) / 2,
                       width: capSize.width, height: 14),
            withAttributes: capAttrs)
    }

    // MARK: 点击打开来源 app（自定义视图需自己转发菜单项动作）

    private var hovering = false {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// 打开系统通知设置并尽力锚定到 Agent哈基米。
/// macOS 没有官方「定位到具体 App」的深链（iOS 有
/// UIApplicationOpenNotificationSettingsURLString，macOS 只能打开通知列表），
/// 所以用 UI 脚本在搜索框输入应用名做尽力锚定；无自动化权限时静默降级为只打开列表
func openSystemNotificationSettings() {
    guard let u = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
    NSWorkspace.shared.open(u)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
        let script = NSAppleScript(source: """
        tell application "System Events"
            repeat with p in (every process whose name is "System Settings" or name is "System Preferences")
                tell p
                    try
                        set value of text field 1 of group 1 of toolbar 1 of window 1 to "Agent哈基米"
                    end try
                end tell
            end repeat
        end tell
        """)
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
    }
}

// MARK: - 来源 app 打开（通知 / 会话行点击）

/// 点击通知或会话行时打开来源 app，能锚定则锚定到具体会话/项目：
/// - CatDesk → 激活 CatDesk.app（有 catdesk:// 深链但参数格式未公开，先只做激活）
/// - Codex → 激活 Codex.app（无公开会话深链）
/// - IDE-CatPaw → 用最近活跃的 JetBrains IDE 打开会话所属项目
/// - Claude → 会话仍在运行时按 tty 聚焦对应 iTerm 标签页；
///   已结束则新开 iTerm 窗口 `claude --resume <sid>` 直接恢复到该会话
enum SourceOpener {

    /// kindRaw 为 SessionWatch.sourceName（IDE-CatPaw / CatDesk / Codex / Claude）
    static func open(kindRaw: String, path: String) {
        TaskNavigator.openPath(source: kindRaw, path: path)
    }

    private static func activate(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    // MARK: Trae / TRAE SOLO（VS Code fork，无公开会话深链）
    // path 为工作区 state.vscdb，其旁 workspace.json 记录真实项目路径；
    // 应用可能未安装（仅数据目录存在）：能定位应用则带项目打开，否则只开项目文件夹

    private static func openTrae(path: String) {
        let wsDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        var projectURL: URL?
        if let text = try? String(contentsOf: wsDir.appendingPathComponent("workspace.json"),
                                  encoding: .utf8),
           let d = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            for key in ["folder", "workspace"] {
                if let s = d[key] as? String, let u = URL(string: s), u.scheme == "file",
                   !u.path.isEmpty {
                    projectURL = URL(fileURLWithPath: u.path)
                    break
                }
            }
        }
        let apps = ["TRAE SOLO CN", "Trae CN"].map { "/Applications/\($0).app" }
        if let app = apps.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let appURL = URL(fileURLWithPath: app)
            if let projectURL {
                NSWorkspace.shared.open([projectURL], withApplicationAt: appURL,
                                        configuration: .init()) { _, _ in }
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
            }
            return
        }
        if let projectURL { NSWorkspace.shared.open(projectURL) }
    }

    // MARK: DeepSeek Harness（dsh，已从 npm 卸载也无妨）
    // path 为 session.v3.jsonl.zstd；解压头部读 cwd（真实项目路径），
    // 应用可能未安装：能定位应用则带项目打开，否则只开项目文件夹

    private static func openDsh(path: String) {
        let raw = try? Data(contentsOf: URL(fileURLWithPath: path))
        let cwd = raw.flatMap { zstdDecompress($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { dshSessionCWD(from: $0) }
        let projectURL = cwd.map { URL(fileURLWithPath: $0) }
        let apps = ["/Applications/DeepSeek.app"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        if let appURL = apps.first.map(URL.init(fileURLWithPath:)) {
            if let projectURL {
                NSWorkspace.shared.open([projectURL], withApplicationAt: appURL,
                                        configuration: .init()) { _, _ in }
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
            }
            return
        }
        if let projectURL { NSWorkspace.shared.open(projectURL) }
    }

    // MARK: IDE-CatPaw（jb- = JetBrains 插件端；ide- = CatPaw IDE 独立端）

    private static func openIdea(path: String) {
        // ~/.catpaw/projects/(jb|ide)-<转义路径>/<sid>/agent-transcripts/transcript.txt
        let comps = URL(fileURLWithPath: path).pathComponents
        if let comp = comps.first(where: { $0.hasPrefix("ide-") }) {
            // CatPaw IDE 独立端
            let projectURL = decodeEscapedPath(String(comp.dropFirst(4)))
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.meituan.catpaw")
                ?? URL(fileURLWithPath: "/Applications/CatPaw IDE.app")
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                if let projectURL { NSWorkspace.shared.open(projectURL) }
                return
            }
            if let projectURL {
                NSWorkspace.shared.open([projectURL], withApplicationAt: appURL,
                                        configuration: .init()) { _, _ in }
            } else {
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, _ in }
            }
            return
        }
        // JetBrains 插件端
        var projectURL: URL?
        for comp in comps where comp.hasPrefix("jb-") {
            projectURL = decodeEscapedPath(String(comp.dropFirst(3)))
            break
        }
        let ide = jetBrainsIDE()
        if let ide, let projectURL {
            NSWorkspace.shared.open([projectURL], withApplicationAt: ide,
                                    configuration: .init()) { _, _ in }
            return
        }
        if let ide {
            NSWorkspace.shared.openApplication(at: ide, configuration: .init()) { _, _ in }
        } else if let projectURL {
            NSWorkspace.shared.open(projectURL)
        }
    }

    /// 最近活跃的 JetBrains IDE（按 ~/Library/Logs/JetBrains 下日志目录 mtime 排序）
    private static func jetBrainsIDE() -> URL? {
        let map: [(prefix: String, app: String)] = [
            ("IntelliJIdea", "IntelliJ IDEA"), ("IdeaIC", "IntelliJ IDEA CE"),
            ("GoLand", "GoLand"), ("WebStorm", "WebStorm"), ("PyCharm", "PyCharm"),
            ("RubyMine", "RubyMine"), ("CLion", "CLion"), ("DataGrip", "DataGrip"),
            ("AndroidStudio", "Android Studio"), ("RustRover", "RustRover"),
        ]
        let root = Config.jetBrainsLogsDir
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        let sorted = dirs.sorted { a, b in
            let ma = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(a).path)[.modificationDate] as? Date) ?? nil
            let mb = (try? fm.attributesOfItem(atPath: root.appendingPathComponent(b).path)[.modificationDate] as? Date) ?? nil
            return (ma ?? .distantPast) > (mb ?? .distantPast)
        }
        for d in sorted {
            for (prefix, app) in map where d.hasPrefix(prefix) {
                let url = URL(fileURLWithPath: "/Applications/\(app).app")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    // MARK: Claude

    private static func openClaude(path: String) {
        let url = URL(fileURLWithPath: path)
        let sid = url.deletingPathExtension().lastPathComponent
        let projectDir = decodeEscapedPath(url.deletingLastPathComponent().lastPathComponent)
        if let dir = projectDir {
            if let tty = claudeTTY(projectDir: dir.path) {
                // 1) 会话仍在运行：按 tty 聚焦对应 iTerm 标签页
                if focusItermTab(tty: tty) { return }
                // 聚焦失败（会话在非 iTerm 终端，或尚未授予自动化权限）：
                // 不新开 resume 窗口制造存活会话的副本
                Notify.log("打开来源：Claude \(sid.prefix(8)) 仍在运行但无法聚焦 iTerm 标签页（\(tty)）")
                return
            }
            // 2) 已结束：新开 iTerm 窗口直接恢复该会话
            if spawnIterm(command: "cd \(shellQuote(dir.path)) && claude --resume \(sid)") { return }
        }
        // 3) 兜底：激活 iTerm
        activate(bundleID: "com.googlecode.iterm2")
    }

    /// 找到 cwd 为 projectDir 的 claude 进程的 tty（/dev/ttysNNN）
    private static func claudeTTY(projectDir: String) -> String? {
        let script = #"pgrep -f '(^|/)claude( |$)' | while read -r p; do d=$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'); t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' '); [ -n "$d" ] && echo "$d $t"; done"#
        guard let out = shell("/bin/bash", ["-c", script]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, String(parts[0]) == projectDir, parts[1].hasPrefix("ttys") {
                return "/dev/\(parts[1])"
            }
        }
        return nil
    }

    /// 在 iTerm 中找到指定 tty 的标签页并选中；找不到返回 false
    private static func focusItermTab(tty: String) -> Bool {
        let source = """
        tell application "System Events" to set itermRunning to (name of processes) contains "iTerm2"
        if not itermRunning then return "no"
        tell application "iTerm"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select t
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "miss"
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return result?.stringValue == "ok"
    }

    /// 新开 iTerm 窗口执行命令（用于 claude --resume 锚定已结束会话）
    private static func spawnIterm(command: String) -> Bool {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "System Events" to set itermRunning to (name of processes) contains "iTerm2"
        tell application "iTerm"
            activate
            try
                if itermRunning then
                    set w to (create window with default profile)
                else
                    delay 1
                    try
                        set w to current window
                    on error
                        set w to (create window with default profile)
                    end try
                end if
                tell current session of w to write text "\(escaped)"
                return "ok"
            on error
                return "fail"
            end try
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return result?.stringValue == "ok"
    }

    // MARK: 工具

    /// 把转义目录名还原为文件系统路径：
    /// "Users-maohuafeng-IdeaProjects-health-2-health_medical_ai" →
    /// /Users/maohuafeng/IdeaProjects-health-2/health_medical_ai
    /// 真实目录名本身可能含连字符（转义只是把 "/" 换成 "-"），
    /// 用「最长存在优先」的贪心切分消歧
    static func decodeEscapedPath(_ escaped: String) -> URL? {
        let parts = escaped.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        let fm = FileManager.default
        var current = "/"
        var i = 0
        while i < parts.count {
            var j = parts.count
            var matched: String?
            while j > i {
                let candidate = parts[i..<j].joined(separator: "-")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: current + candidate, isDirectory: &isDir), isDir.boolValue {
                    matched = candidate
                    break
                }
                j -= 1
            }
            guard let m = matched else { return nil }
            current += m + "/"
            i = j
        }
        return URL(fileURLWithPath: String(current.dropLast()))
    }

    private static func shellQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func shell(_ launch: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

// MARK: - 桌宠（大肥鱼）

/// 桌宠姿势：对应 bundle 内 `pet-<fileName>.png`（多帧则 `pet-<fileName>-2.png`…），
/// 缺图时退到 SF Symbol 占位——用户素材到位前功能即可用
enum PetPose: String, CaseIterable {
    case swim        // 平时慢游
    case sleep       // 打盹（长时间无事件）
    case surprised   // 摸头/额度告警
    case celebrate   // 任务完成
    case sad         // 异常中断
    case confused    // 疑似暂停
    case alert       // 等待手动确认

    var fileName: String { "pet-\(rawValue)" }

    var fallbackSymbol: String {
        switch self {
        case .swim: return "fish.fill"
        case .sleep: return "zzz"
        case .surprised: return "exclamationmark.bubble.fill"
        case .celebrate: return "party.popper.fill"
        case .sad: return "fish"
        case .confused: return "questionmark.bubble.fill"
        case .alert: return "exclamationmark.triangle.fill"
        }
    }

    /// 多帧姿势的帧序列文件名（pet-swim.png, pet-swim-2.png…）
    var frameNames: [String] { (0...7).map { $0 == 0 ? fileName : "\(fileName)-\($0 + 1)" } }
}

/// 精灵图加载与缓存：按姿势缓存帧序列（含 miss 缓存，防 12Hz 循环反复 stat bundle）
@MainActor
final class PetSpriteStore {
    private var cache: [PetPose: [NSImage]] = [:]
    private(set) var usingFallbackArt = false
    private var fallbackLogged = false

    func frames(for pose: PetPose) -> [NSImage] {
        if let hit = cache[pose] { return hit }
        var frames: [NSImage] = []
        for name in pose.frameNames {
            let path = Bundle.main.path(forResource: name, ofType: "png",
                                        inDirectory: Config.petSpriteDir)
                ?? Bundle.main.path(forResource: name, ofType: "png")
            guard let p = path, let img = NSImage(contentsOfFile: p) else { break }
            frames.append(img)
        }
        if frames.isEmpty {
            if let sym = NSImage(systemSymbolName: pose.fallbackSymbol, accessibilityDescription: pose.rawValue) {
                sym.isTemplate = true
                frames = [sym]
                usingFallbackArt = true
            }
        }
        if usingFallbackArt, !fallbackLogged {
            fallbackLogged = true
            Notify.log("桌宠：bundle 内无精灵图，使用占位图（放 Resources/pet/pet-<姿势>.png 即可替换）")
        }
        cache[pose] = frames
        return frames
    }
}

/// 桌宠事件：从系统通知标题分类（纯函数可单测），标题里的 emoji/关键词与
/// SessionWatch 各状态机的 Notify.send 文案一一对应
enum PetEvent: Equatable {
    case celebrate(sessionTitle: String?)
    case sad(sessionTitle: String?)
    case confused(sessionTitle: String?)
    case alert(sessionTitle: String?, kind: String?, path: String?)
    case quotaLow(remaining: Double)
    case test

    /// 优先级：高优先级事件可打断低优先级的表情 hold
    var priority: Int {
        switch self {
        case .celebrate: return 6
        case .alert: return 5
        case .quotaLow: return 4
        case .sad: return 3
        case .confused: return 2
        case .test: return 1
        }
    }

    /// 去重键（相同事件 10s 内只反应一次）
    var dedupeKey: String {
        switch self {
        case .celebrate(let t): return "celebrate:\(t ?? "")"
        case .sad(let t): return "sad:\(t ?? "")"
        case .confused(let t): return "confused:\(t ?? "")"
        case .alert(let t, _, let p): return "alert:\(t ?? ""):\(p ?? "")"
        case .quotaLow(let r): return "quota:\(Int(r))"
        case .test: return "test"
        }
    }

    var bubbleText: String {
        switch self {
        case .celebrate: return "跑完啦 ✅"
        case .sad: return "好像出错了…"
        case .confused: return "卡住了？"
        case .alert: return "在等你确认哦！"
        case .quotaLow(let r): return "Codex 额度只剩 \(Int(r))% 了"
        case .test: return "测试收到 🐾"
        }
    }

    /// 白牌顶部灰字折叠栏（还原「已思考（用时 1 秒）⌄」样式）
    var signHeader: String {
        switch self {
        case .celebrate: return "已思考 (任务完成 ✅)"
        case .alert: return "思考中断 (等待确认 🟡)"
        case .quotaLow(let r): return "额度预警 (剩余 \(Int(r))% ⚠️)"
        case .sad: return "思考异常 (会话中断 ⛔️)"
        case .confused: return "思考停滞 (疑似卡住 ⚠️)"
        case .test: return "已思考 (自测通过 🐾)"
        }
    }

    /// 白牌底部圆点正文（还原「• 我操，我不思考了。」样式，优先展示具体会话/报错）
    var signDetail: String {
        switch self {
        case .celebrate(let t): return t ?? bubbleText
        case .alert(let t, _, _): return t ?? bubbleText
        case .quotaLow(let r): return "Codex 额度仅剩 \(Int(r))%，省着点用！"
        case .sad(let t): return t ?? bubbleText
        case .confused(let t): return t ?? bubbleText
        case .test: return "大肥鱼收到测试信号啦！"
        }
    }

    /// 表情保持时长（到点自动降回游荡）
    var holdDuration: TimeInterval {
        switch self {
        case .celebrate: return 5
        case .alert: return 10
        case .quotaLow: return 8
        case .sad: return 6
        case .confused: return 6
        case .test: return 4
        }
    }

    static func classify(title: String, body: String? = nil, context: [String: String]) -> PetEvent? {
        let t = title
        if t.contains("测试") { return .test }
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title0: String
        if !trimmedBody.isEmpty {
            title0 = trimmedBody
        } else {
            title0 = context["kind"].map { "\($0)：\(t)" } ?? t
        }
        if t.contains("✅") || t.contains("完成") || t.contains("回合结束") {
            return .celebrate(sessionTitle: title0)
        }
        if t.contains("⛔️") || t.contains("异常") { return .sad(sessionTitle: title0) }
        if t.contains("⚠️") || t.contains("暂停") { return .confused(sessionTitle: title0) }
        if t.contains("🟡") || t.contains("等待手动确认") {
            return .alert(sessionTitle: title0, kind: context["kind"], path: context["path"])
        }
        return nil
    }
}

/// 桌宠可观察状态（PetView 渲染的唯一数据源）
@MainActor
final class PetModel: ObservableObject {
    @Published var pose: PetPose = .swim
    @Published var bubble: String?
    /// 大肥鱼手扶白牌顶部标题（如「已思考 (用时 1 秒)」）
    @Published var signHeader: String?
    /// 大肥鱼手扶白牌圆点正文（如「我操，我不思考了。」或具体任务/额度提示）
    @Published var signDetail: String?
    /// 实时运行中的会话数与 Codex 最低剩余额度百分比（平时巡航白牌兜底展示）
    @Published var activeRunningCount: Int = 0
    @Published var latestQuotaRemaining: Int?
    /// 气泡关联的会话（等待确认时点击直达）
    @Published var bubbleSession: (kind: String, path: String)?
    @Published var facingLeft = false
    @Published var wobble = false
    @Published var usingFallbackArt = false

    fileprivate var moodHoldUntil = Date.distantPast
    fileprivate var currentPriority = 0
    fileprivate var frameIndex = 0
    var sprites = PetSpriteStore()

    /// 当前应渲染的帧（姿势多帧时按 tick 轮播）
    var currentFrame: NSImage? {
        let frames = sprites.frames(for: pose)
        guard !frames.isEmpty else { return nil }
        defer { frameIndex = frames.count > 1 ? (frameIndex + 1) % frames.count : 0 }
        return frames[min(frameIndex, frames.count - 1)]
    }

    private static let patLines = ["我操，我不思考了。", "别摸啦，脑子要过载了！", "鱼生愉快，摸鱼中 🫧", "再摸要化掉了…"]

    /// 当前白牌应展示的（顶部灰字栏, 底部圆点正文, 是否高优告警态）
    var currentSignContent: (header: String, detail: String, isAlert: Bool) {
        if let h = signHeader, let d = signDetail {
            let alert = (pose == .alert || pose == .sad || pose == .confused || h.contains("预警"))
            return (h, d, alert)
        }
        if let b = bubble {
            return ("已思考 (用时 1 秒)", b, false)
        }
        if let q = latestQuotaRemaining, q < Int(Config.petQuotaLowRemaining) {
            return ("额度预警 (剩余 \(q)% ⚠️)", "Codex 额度仅剩 \(q)%，省着点用！", true)
        }
        if activeRunningCount > 0 {
            let quotaSuffix = latestQuotaRemaining.map { " · 额度 \($0)%" } ?? ""
            return ("思考中 (\(activeRunningCount) 个任务运行中)", "正在盯梢 AI 干活\(quotaSuffix)", false)
        }
        if let q = latestQuotaRemaining {
            return ("已思考 (Codex 剩余 \(q)%)", "我操，我不思考了。", false)
        }
        return ("已思考 (用时 1 秒)", "我操，我不思考了。", false)
    }

    /// 事件反应：hold 期内忽略 ≤ 当前优先级的事件，高优先级可打断
    func react(to event: PetEvent, now: Date = Date()) {
        if now < moodHoldUntil, event.priority <= currentPriority { return }
        pose = poseFor(event)
        bubble = event.bubbleText
        signHeader = event.signHeader
        signDetail = event.signDetail
        if case .alert(_, let kind, let path) = event, let kind, let path {
            bubbleSession = (kind, path)
        } else {
            bubbleSession = nil
        }
        moodHoldUntil = now + event.holdDuration
        currentPriority = event.priority
    }

    private func poseFor(_ event: PetEvent) -> PetPose {
        switch event {
        case .celebrate: return .celebrate
        case .sad: return .sad
        case .confused: return .confused
        case .alert: return .alert
        case .quotaLow: return .surprised
        case .test: return .celebrate
        }
    }

    /// 摸头：惊讶一下 + 随机气泡（hold 期内不响应，避免打断庆祝）
    func pat(now: Date = Date()) {
        guard now >= moodHoldUntil else { return }
        pose = .surprised
        let line = Self.patLines.randomElement() ?? "我操，我不思考了。"
        bubble = line
        signHeader = "已思考 (用时 1 秒)"
        signDetail = line
        bubbleSession = nil
        moodHoldUntil = now + 3
        wobble = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.wobble = false
        }
    }

    /// 每个 wander tick 调一次：hold 到点降回游荡；气泡过期清除
    func step(now: Date) {
        if now >= moodHoldUntil, pose != .swim || bubble != nil || signHeader != nil {
            pose = .swim
            bubble = nil
            signHeader = nil
            signDetail = nil
            bubbleSession = nil
            currentPriority = 0
        }
    }
}

/// 接收首次点击并直接处理拖拽/单击/双击的容器视图（解决 nonactivatingPanel + 透明窗口下 SwiftUI 吃掉鼠标或穿透的问题）
@MainActor
final class PetHostView: NSView {
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?

    private var dragStartMouse: NSPoint = .zero
    private var dragStartOrigin: NSPoint = .zero
    private var didDrag = false
    fileprivate(set) var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = win.frame.origin
        didDrag = false
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let cur = NSEvent.mouseLocation
        let dx = cur.x - dragStartMouse.x
        let dy = cur.y - dragStartMouse.y
        if !didDrag && hypot(dx, dy) < 3 { return }
        didDrag = true
        isDragging = true
        win.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        guard let win = window else { return }
        if didDrag {
            isDragging = false
            didDrag = false
            PetController.shared.commitDragPosition(win.frame.origin)
            return
        }
        isDragging = false
        if event.clickCount >= 2 {
            onDoubleTap?()
        } else {
            onSingleTap?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.rightMouseDown(with: event)
    }
}

/// 桌宠窗口：无边框非激活面板，永不抢焦点，跟随所有 Space，支持左键自由拖拽与单击/双击
@MainActor
final class PetPanel: NSPanel {
    let hostView = PetHostView()

    var isDragging: Bool { hostView.isDragging }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = NSAppearance(named: .darkAqua)
        hostView.frame = NSRect(origin: .zero, size: contentRect.size)
        hostView.autoresizingMask = [.width, .height]
        contentView = hostView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 右键菜单（不经 SwiftUI 的 contextMenu——那可能激活 app）
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开主窗口", action: #selector(petOpenMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let resetPos = NSMenuItem(title: "重置到右下角", action: #selector(petResetPosition), keyEquivalent: "")
        resetPos.target = self
        menu.addItem(resetPos)
        let wander = NSMenuItem(title: "底部自由游动", action: #selector(petToggleWander), keyEquivalent: "")
        wander.target = self
        wander.state = PetController.shared.isWanderEnabled ? .on : .off
        menu.addItem(wander)
        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏桌宠 🐟", action: #selector(petHide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        // event.locationInWindow 是窗口坐标；转成 content view 坐标再弹菜单
        let at = contentView?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        menu.popUp(positioning: nil, at: at, in: contentView)
    }

    @objc private func petOpenMain() { PetController.shared.openMainWindow?() }
    @objc private func petResetPosition() { PetController.shared.resetToBottomRight() }
    @objc private func petToggleWander() {
        PetController.shared.setWanderEnabled(!PetController.shared.isWanderEnabled)
    }
    @objc private func petHide() { PetController.shared.setEnabled(false) }
}

/// 桌宠视图：大肥鱼精灵图 + 手扶白牌内动态渲染任务提示/额度警示（还原 DeepSeek 思考框样式）
struct PetView: View {
    @ObservedObject var model: PetModel

    var body: some View {
        TimelineView(.animation(minimumInterval: Config.petWanderInterval)) { _ in
            ZStack(alignment: .bottom) {
                if model.usingFallbackArt, let bubble = model.bubble {
                    fallbackBubbleCard(bubble)
                }
                spriteWithSign
            }
            .frame(width: 220, height: 215, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    private var spriteWithSign: some View {
        ZStack(alignment: .bottom) {
            if let img = model.currentFrame {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Config.petSize.width, height: Config.petSize.height)
                    // 精灵图内嵌了白色手扶牌，不再镜像翻转以保证手指压框与文字方向一致
                if !model.usingFallbackArt {
                    signOverlay
                }
            } else {
                Image(systemName: "fish.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.cyan)
            }
        }
        .scaleEffect(x: model.wobble ? 1.05 : 1.0, y: model.wobble ? 0.95 : 1.0)
        .offset(y: bobOffset)
    }

    /// 大肥鱼手扶白牌内的文字层（按 726×726 裁切图的白框内部坐标 20...706 × 538...714 比例映射）
    private var signOverlay: some View {
        let sign = model.currentSignContent
        let w = Config.petSize.width * 0.88
        let h = Config.petSize.height * 0.22
        let bottomPad = Config.petSize.height * 0.025
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(sign.header)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(sign.isAlert
                        ? Color(red: 0.82, green: 0.24, blue: 0.16)
                        : Color(white: 0.45))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Color(white: 0.48))
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle()
                    .fill(sign.isAlert
                        ? Color(red: 0.90, green: 0.32, blue: 0.20)
                        : Color(white: 0.56))
                    .frame(width: 4.5, height: 4.5)
                    .offset(y: -1)
                Text(sign.detail)
                    .font(.system(size: 11.5, weight: sign.isAlert ? .semibold : .medium))
                    .foregroundColor(sign.isAlert
                        ? Color(red: 0.72, green: 0.14, blue: 0.12)
                        : Color(white: 0.28))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: w, height: h, alignment: .leading)
        .offset(y: -bottomPad)
    }

    /// 游动时的上下浮动（Celebrating 姿势跳动更大）
    private var bobOffset: CGFloat {
        switch model.pose {
        case .celebrate: return -6
        case .alert: return -2
        default: return 0
        }
    }

    private func fallbackBubbleCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
            .fixedSize()
            .offset(y: 4)
    }
}

/// 桌宠总控：窗口生命周期、游荡循环、事件接入、额度检查、持久化
@MainActor
final class PetController {
    static let shared = PetController()

    let model = PetModel()
    var openMainWindow: (() -> Void)?

    private var panel: PetPanel?
    private var wanderTimer: Timer?
    private var moveObserver: NSObjectProtocol?
    private var notifyInstalled = false

    // 游荡状态
    private var targetX: CGFloat?
    private var baseY: CGFloat = 0
    private var bobPhase: Double = 0
    private var lastTargetPick = Date.distantPast

    // 额度提醒状态（穿越阈值 + 冷却 + 滞回）
    private var lastQuotaRemaining: Double?
    private var lastQuotaRemindAt = Date.distantPast

    private var defaults: UserDefaults { .standard }

    var isEnabled: Bool { defaults.bool(forKey: "pet.enabled") }
    /// 是否开启底部自动游荡（默认 false：静置在屏幕右下角或用户拖拽位置，不自动乱跑）
    var isWanderEnabled: Bool { defaults.bool(forKey: "pet.wander") }

    private init() {}

    // MARK: 生命周期

    func start(openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
        installNotifyWrapper()
        guard isEnabled else { return }
        showPet()
    }

    func setEnabled(_ want: Bool) {
        let was = isEnabled
        defaults.set(want, forKey: "pet.enabled")
        guard want != was else { return }
        if want {
            showPet()
            Notify.log("桌宠：显示")
        } else {
            panel?.orderOut(nil)
            wanderTimer?.invalidate()
            wanderTimer = nil
            Notify.log("桌宠：隐藏")
        }
    }

    func setWanderEnabled(_ want: Bool) {
        defaults.set(want, forKey: "pet.wander")
        if let p = panel {
            baseY = p.frame.origin.y
            targetX = nil
        }
    }

    /// 重置回主屏幕右下角默认位置
    func resetToBottomRight() {
        let size = panel?.frame.size ?? NSSize(width: 220, height: 215)
        let origin = defaultBottomRightOrigin(panelSize: size)
        panel?.setFrameOrigin(origin)
        commitDragPosition(origin)
    }

    /// 拖拽松手后钳制到最近屏幕可视区并持久化保存
    func commitDragPosition(_ rawOrigin: NSPoint) {
        guard let p = panel else { return }
        let clamped = clampToNearestScreen(rawOrigin, size: p.frame.size)
        if clamped != p.frame.origin {
            p.setFrameOrigin(clamped)
        }
        baseY = clamped.y
        targetX = nil
        defaults.set(Double(clamped.x), forKey: "pet.x")
        defaults.set(Double(clamped.y), forKey: "pet.y")
    }

    private func showPet() {
        if panel == nil {
            let size = NSSize(width: 220, height: 215)
            let origin = restoredOrigin(panelSize: size)
            let p = PetPanel(contentRect: NSRect(origin: origin, size: size))
            p.hostView.onSingleTap = { [weak self] in
                guard let self else { return }
                if let s = self.model.bubbleSession {
                    SourceOpener.open(kindRaw: s.kind, path: s.path)
                } else {
                    self.model.pat()
                }
            }
            p.hostView.onDoubleTap = { [weak self] in
                self?.openMainWindow?()
            }
            let hosting = NSHostingView(rootView: PetView(model: model))
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.autoresizingMask = [.width, .height]
            p.hostView.addSubview(hosting)
            panel = p
        }
        guard let p = panel else { return }
        baseY = p.frame.origin.y
        p.orderFrontRegardless()
        startWanderTimer()
    }

    // MARK: 事件接入

    /// 包装 Notify.sender：分类后驱动桌宠，再永远链回原投递（测试进程不受影响——
    /// 它们用 resetSender 在自己的进程里替换）
    private func installNotifyWrapper() {
        guard !notifyInstalled else { return }
        notifyInstalled = true
        let base = Notify.sender
        Notify.sender = { [weak self] title, body, sound, context in
            if let event = PetEvent.classify(title: title, body: body, context: context) {
                Task { @MainActor in
                    self?.model.react(to: event)
                }
            }
            base(title, body, sound, context)
        }
    }

    // MARK: 额度提醒与实时状态同步（不走 Notify，按 tick 观察）

    func tickStatus(runningCount: Int, quota: CodexRateLimits?, now: Date = Date()) {
        model.activeRunningCount = runningCount
        if let q = quota {
            let remaining = [CodexRateLimits.remaining(used: q.primaryUsedPercent, resetsAt: q.primaryResetsAt, snapshotAt: q.snapshotAt, now: now),
                             CodexRateLimits.remaining(used: q.secondaryUsedPercent, resetsAt: q.secondaryResetsAt, snapshotAt: q.snapshotAt, now: now)].compactMap { $0 }.min()
            model.latestQuotaRemaining = remaining.map { Int($0.rounded()) }
        }
        // R1 local snapshots have no verified account scope: passive display only.
    }

    func tickQuota(quota: CodexRateLimits?, now: Date = Date()) {
        guard isEnabled, let q = quota else { return }
        // 字段语义为已用百分比，展示与提醒都按剩余 = 100 - used，两窗口取 min
        let remaining = min(100 - (q.primaryUsedPercent ?? 100),
                            100 - (q.secondaryUsedPercent ?? 100))
        defer { lastQuotaRemaining = remaining }
        guard remaining < Config.petQuotaLowRemaining else {
            // 滞回：回升到阈值 + 5 以上才重新武装
            if remaining > Config.petQuotaLowRemaining + 5 { lastQuotaRemindAt = .distantPast }
            return
        }
        guard let last = lastQuotaRemaining, remaining < last - 0.5 || lastQuotaRemindAt == .distantPast
        else { return }
        guard now.timeIntervalSince(lastQuotaRemindAt) >= Config.petQuotaRemindCooldown else { return }
        lastQuotaRemindAt = now
        model.react(to: .quotaLow(remaining: remaining), now: now)
        // 游向屏幕中心引人注意
        if let screen = nearestScreen(to: panel?.frame ?? .zero) {
            targetX = screen.visibleFrame.midX
            lastTargetPick = Date()
        }
    }

    // MARK: 游荡

    private func startWanderTimer() {
        guard wanderTimer == nil else { return }
        wanderTimer = Timer.scheduledTimer(withTimeInterval: Config.petWanderInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.wanderTick() }
        }
    }

    private func wanderTick() {
        guard let p = panel, p.isVisible, !p.isDragging else { return }
        let now = Date()
        model.step(now: now)
        guard model.pose == .swim, isEnabled else { return }
        // 默认固定在屏幕右下角或用户拖放的位置（呼吸微动），仅当开启「底部自由游动」时才左右漫游
        guard isWanderEnabled else { return }
        guard let screen = nearestScreen(to: p.frame) else { return }
        let band = screen.visibleFrame
        // 到点或超时重选目标
        if let tx = targetX, abs(p.frame.midX - tx) > 4, now.timeIntervalSince(lastTargetPick) < 30 {
            // 保持当前目标
        } else {
            targetX = CGFloat.random(in: (band.minX + 30)...(band.maxX - 30))
            lastTargetPick = now
        }
        guard let tx = targetX else { return }
        let dir: CGFloat = tx < p.frame.midX ? -1 : 1
        model.facingLeft = dir < 0
        bobPhase += 0.18
        let bob = CGFloat(sin(bobPhase)) * 3
        var next = p.frame.origin
        next.x += dir * 2.2 // ~26pt/s 的慢游速度
        next.y = baseY + bob
        // 钳制在游荡带内
        let bandTop = band.minY + band.height * Config.petBottomBandRatio
        next.y = min(max(next.y, band.minY), bandTop)
        next.x = min(max(next.x, band.minX), band.maxX - p.frame.width)
        p.setFrameOrigin(next)
    }

    // MARK: 位置持久化与钳制

    private func defaultBottomRightOrigin(panelSize: NSSize) -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - panelSize.width - 24, y: vf.minY + 20)
    }

    private func restoredOrigin(panelSize: NSSize) -> NSPoint {
        let hasSaved = defaults.object(forKey: "pet.x") != nil && defaults.object(forKey: "pet.y") != nil
        let x = defaults.double(forKey: "pet.x")
        let y = defaults.double(forKey: "pet.y")
        guard hasSaved, (x != 0 || y != 0) else {
            // 默认：主屏幕右下角
            return defaultBottomRightOrigin(panelSize: panelSize)
        }
        return clampToNearestScreen(NSPoint(x: x, y: y), size: panelSize)
    }

    /// 多显示器：优先取包含窗口中心点的屏幕，其次取重叠面积最大的屏幕，最后取到屏幕矩形边界距离最近的屏幕
    func clampToNearestScreen(_ point: NSPoint, size: NSSize) -> NSPoint {
        guard let screen = nearestScreen(to: NSRect(origin: point, size: size)) else { return point }
        let vf = screen.visibleFrame
        let x = min(max(point.x, vf.minX), vf.maxX - size.width)
        let y = min(max(point.y, vf.minY), vf.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    private func nearestScreen(to rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        // 1. 中心点直接落在该屏幕 frame 内
        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }
        // 2. 与窗口矩形有交集且交集面积最大的屏幕
        let intersecting = NSScreen.screens
            .map { ($0, $0.frame.intersection(rect)) }
            .filter { !$0.1.isNull && $0.1.width > 0 && $0.1.height > 0 }
        if let bestOverlap = intersecting.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) {
            return bestOverlap.0
        }
        // 3. 兜底：到屏幕 visibleFrame 矩形边界（而非中心点！）的欧氏距离最小
        func distToRect(_ p: NSPoint, _ r: NSRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX)
            let dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return hypot(dx, dy)
        }
        return NSScreen.screens.min { distToRect(center, $0.visibleFrame) < distToRect(center, $1.visibleFrame) }
            ?? NSScreen.main
    }
    private func nearestScreen(to point: NSPoint) -> NSScreen? {
        nearestScreen(to: NSRect(origin: point, size: .zero))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let monitor = Monitor()
    private let creditStore = CreditStore()
    private let updateChecker = UpdateChecker()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var lastTickAt = Date()
    /// 菜单栏悬浮打开快捷面板的事件接收器
    private let hoverOpener = HoverMenuOpener()
    /// 桌宠（大肥鱼）
    private let pet = PetController.shared

    /// 把当前运行的 .app 拷进 ~/Applications（若已在 /Applications 系目录则跳过），
    /// 去 quarantine 后以新位置重启并退出当前进程。返回 true 表示已触发迁移（本进程即将退出）。
    @discardableResult
    private static func relocateToApplicationsIfNeeded() -> Bool {
        let src = Bundle.main.bundleURL
        let path = src.path
        if path.hasPrefix("/Applications/") {
            Self.stripQuarantine(at: src)
            return false
        }
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        if path.hasPrefix(homeApps.path + "/") {
            // 已在目标位置，仅顺手去隔离（首次「仍要打开」后不再被拦）
            Self.stripQuarantine(at: src)
            return false
        }
        let dst = homeApps.appendingPathComponent(src.lastPathComponent)
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: homeApps, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            Self.stripQuarantine(at: dst)
            Notify.log("已自动移动到应用程序：\(dst.path)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", dst.path]
            try p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
        } catch {
            Notify.log("自动移动到应用程序失败：\(error.localizedDescription)")
        }
        return true
    }

    /// 递归移除 quarantine 隔离属性
    private static func stripQuarantine(at url: URL) {
        let key = "com.apple.quarantine"
        removexattr(url.path, key, 0)
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let f as URL in e { removexattr(f.path, key, 0) }
        }
    }

    /// 把 bundle 内的自定义提示音复制到 ~/Library/Sounds（已存在则跳过）
    static func installCustomSounds() {
        guard let src = Bundle.main.path(forResource: "DogBark", ofType: "caf") else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds")
        let dst = dir.appendingPathComponent("DogBark.caf")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dst.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: src, toPath: dst.path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notify.managedDelivery = true
        NSApp.setActivationPolicy(.regular) // 显示 Dock 图标，便于找到应用

        // 首启自迁移：从 DMG/Downloads 直接运行时，自动搬进 ~/Applications 并去隔离属性重启，
        // 否则 Launchpad/应用程序里搜不到，且 quarantine 会反复触发 Gatekeeper 拦截
        if Self.relocateToApplicationsIfNeeded() { return }

        // 强制使用 bundle 内的小猫图标（避免 Dock 图标缓存返回旧爪印）
        if let p = Bundle.main.path(forResource: "app-icon-1024", ofType: "png"),
           let icon = NSImage(contentsOfFile: p) {
            NSApp.applicationIconImage = icon
        }

        // 自定义提示音自愈安装：notificationcenterd 对 bundle 内音效可能解析失败
        // （实测 0.8.1 自测通知只响默认音），~/Library/Sounds 是系统音效搜索路径，
        // 放一份副本可保证 UNNotificationSound(named:) 与 osascript 路径都能解析到
        Self.installCustomSounds()

        // 通知权限 + 前台时也展示横幅
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // 菜单栏图标
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 悬浮即打开快捷面板（免点击）
        hoverOpener.onHover = { [weak self] in
            if MonitorPreferences.shared.value.hoverMenu { self?.statusItem.button?.performClick(nil) }
        }
        if let button = statusItem.button {
            button.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: hoverOpener, userInfo: nil))
        }

        // 主窗口
        let hosting = NSHostingController(rootView: TaskCenterView(monitor: monitor, credit: creditStore, updater: updateChecker))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Agent哈基米 · 会话监控"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = .clear
        win.isOpaque = false
        win.isMovableByWindowBackground = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.setContentSize(NSSize(width: 1100, height: 800))
        // 防止缩到内容最小高度以下把底部按钮裁掉
        win.minSize = NSSize(width: 800, height: 580)
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        window = win

        // 桌宠：先于首个通知装配（Notify 包装器必须在任何 send 前就位）
        pet.start(openMainWindow: { [weak self] in self?.showWindow() })
        monitor.center.deliver = { title, body, audible, context in
            Notify.sender(title, body, audible ? "System" : "", context)
        }

        rebuildMenu()
        updateIcon()
        showWindow()
        creditStore.start()
        updateChecker.start()
        Telemetry.reportLaunch()
        DispatchQueue.main.async { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.center.resume()
                self?.monitor.requestDiscovery()
                self?.tick()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.center.persist()
        monitor.center.flushPersistence()
    }

    /// 点 Dock 图标时重新打开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// 用户激活窗口（看过状态）→ Dock 图标「已完成」未读清零
    func applicationDidBecomeActive(_ notification: Notification) {
        // Individual review is managed by the task center; activation never clears it.
    }

/// 应用在前台时通知依然以横幅+声音展示
nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
willPresent notification: UNNotification,
withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
completionHandler([.banner, .sound])
}

/// 点击通知 → 打开来源 app（能锚定则锚定到具体会话）
nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
didReceive response: UNNotificationResponse,
withCompletionHandler completionHandler: @escaping () -> Void) {
let info = response.notification.request.content.userInfo
let kind = info["kind"] as? String
let path = info["path"] as? String
let taskID = info["taskID"] as? String
let attentionID = info["attentionID"] as? String
Task { @MainActor in
    if let delegate = Entry.delegate {
        UserDefaults.standard.set("overview", forKey: "r1.page")
        delegate.showWindow()
        if let taskID {
            delegate.monitor.center.see(taskID, attentionID: attentionID)
            delegate.monitor.center.requestedAttentionID = attentionID
            delegate.monitor.center.requestedTaskID = taskID
        }
    } else if let kind, let path {
        TaskNavigator.openPath(source: kind, path: path)
    }
}
completionHandler()
}

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func tick() {
        if Date().timeIntervalSince(lastTickAt) > 60 { monitor.center.resume() }
        lastTickAt = Date()
        monitor.scanAndPoll()
        pet.tickStatus(runningCount: monitor.runningCount, quota: monitor.codexQuota)
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let n = monitor.center.runningCount
        let pending = monitor.center.actionableCount
        if button.image == nil {
            if let p = Bundle.main.path(forResource: "menubar-cat", ofType: "png"),
               let img = NSImage(contentsOfFile: p) {
                // 彩色小猫（非模板渲染），尺寸压到菜单栏标准 18pt
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else if let img = NSImage(systemSymbolName: "pawprint.fill",
                                        accessibilityDescription: "Agent哈基米") {
                img.isTemplate = true
                button.image = img
            }
            button.imagePosition = .imageLeft
        }
        button.title = pending > 0 ? " 待处理 \(pending) · \(n)" : n > 0 ? " \(n)" : ""
        button.alphaValue = n > 0 || pending > 0 ? 1.0 : 0.55
    }

    /// 首次启动引导：提示开启系统通知，并建议提醒样式选「持续」
    private func showNotificationGuideIfNeeded() {
        let key = "hasShownNotificationGuide"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        // 延迟一点弹出，避免与系统权限弹窗抢焦点
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let alert = NSAlert()
            alert.messageText = "开启系统通知 🐾"
            alert.informativeText = """
            Agent哈基米 通过系统通知提醒你「跑完了 / 出错了 / 在等你确认」。

            1. 在 系统设置 → 通知 → Agent哈基米 中打开「允许通知」
            2. 提醒样式建议选择「持续」——重要状态不会自动消失，回到电脑也不会错过
            """
            alert.addButton(withTitle: "打开通知设置")
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
if alert.runModal() == .alertFirstButtonReturn {
openSystemNotificationSettings()
}
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "打开主窗口", action: #selector(openWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        // 菜单每 3s 重建：开关状态从 UserDefaults 读取（setEnabled 是唯一写入方）
        let petItem = NSMenuItem(title: pet.isEnabled ? "隐藏桌宠 🐟" : "显示桌宠 🐟",
                                 action: #selector(togglePet), keyEquivalent: "")
        petItem.target = self
        petItem.state = pet.isEnabled ? .on : .off
        menu.addItem(petItem)
        menu.addItem(.separator())

        let queue = monitor.center.visibleItems().prefix(5)
        if queue.isEmpty {
            let empty = NSMenuItem(title: "暂无待处理事项", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for item in queue {
                guard let task = monitor.center.task(item.taskID) else { continue }
                let mi = NSMenuItem(title: "\(item.phase.label) · \(task.title.prefix(32))", action: #selector(openCenterTask(_:)), keyEquivalent: "")
                mi.representedObject = ["taskID": task.id, "attentionID": item.id]
                mi.target = self
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        let testItem = NSMenuItem(title: "发送测试通知", action: #selector(sendTest), keyEquivalent: "t")
        testItem.target = self
        menu.addItem(testItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func openWindow() { showWindow() }
    @objc private func openCenterTask(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let id = info["taskID"] else { return }
        UserDefaults.standard.set("overview", forKey: "r1.page")
        monitor.center.see(id, attentionID: info["attentionID"])
        monitor.center.requestedAttentionID = info["attentionID"]
        monitor.center.requestedTaskID = id
        showWindow()
    }

    /// 菜单栏开关桌宠（菜单每 3s 重建，状态自动跟随 UserDefaults）
    @objc private func togglePet() { pet.setEnabled(!pet.isEnabled) }

    /// 快捷面板会话行点击 → 打开来源 app（能锚定则锚定到具体会话）
    @objc private func openMenuSession(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? SessionRow else { return }
        SourceOpener.open(kindRaw: row.source, path: row.id)
    }

    @objc private func sendTest() {
        Notify.send(title: "Agent哈基米 测试 🐾",
                    body: "通知链路正常，已播放当前提示音",
                    sound: "DogBark")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

/// 持有 delegate 强引用（NSApplication.delegate 为弱引用）
enum Entry {
    static var delegate: AppDelegate?
}

let app = NSApplication.shared
MainActor.assumeIsolated {
    let d = AppDelegate()
    Entry.delegate = d
    app.delegate = d
}
app.run()
