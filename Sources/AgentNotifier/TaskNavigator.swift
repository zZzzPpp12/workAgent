import Foundation
import AppKit

struct SessionDestination: Equatable {
    let url: URL
    let bundleID: String
}

enum TaskNavigator {
    /// 仅使用已核对的客户端路由，不附带 prompt、autoSend 或任意命令。
    static func sessionDestination(for task: TaskRecord) -> SessionDestination? {
        switch task.source {
        case "Codex":
            guard let id = codexSessionID(task.sessionID),
                  let url = URL(string: "codex://threads/" + id) else { return nil }
            return SessionDestination(url: url, bundleID: "com.openai.codex")
        case "CatDesk":
            let id = task.sessionID
            guard !id.isEmpty, id.utf8.count <= 512,
                  id.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            var parts = URLComponents()
            parts.scheme = "catdesk"
            parts.host = "session"
            parts.path = "/open"
            // URLSearchParams 把裸 + 当空格；按 RFC 3986 编码整个参数值。
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            parts.percentEncodedQuery = "conversationId=" + encoded
            guard let url = parts.url else { return nil }
            return SessionDestination(url: url, bundleID: "com.catpaw.cowork")
        default: return nil
        }
    }

    static func returnDescription(for task: TaskRecord) -> String {
        if sessionDestination(for: task) != nil { return "直接打开对应会话，继续查看任务进展。" }
        if task.source == "Codex" { return "尚未识别有效会话 ID，将打开 Codex；可复制 ID 手动查找。" }
        return "此来源暂不支持会话直达，将打开来源应用或项目；可复制会话 ID 手动查找。"
    }

    static func codexSessionID(_ value: String) -> String? {
        if let uuid = UUID(uuidString: value) { return uuid.uuidString.lowercased() }
        // 兼容旧任务及菜单入口保存的 rollout-时间戳-UUID 文件名。
        if value.hasPrefix("rollout-"), value.count > 36,
           let uuid = UUID(uuidString: String(value.suffix(36))) { return uuid.uuidString.lowercased() }
        return nil
    }

    static func open(_ task: TaskRecord, completion: @escaping (String) -> Void) {
        let workspace = NSWorkspace.shared
        if let destination = sessionDestination(for: task),
           let app = workspace.urlForApplication(withBundleIdentifier: destination.bundleID) {
            workspace.open([destination.url], withApplicationAt: app, configuration: .init()) { _, error in
                DispatchQueue.main.async {
                    if let error {
                        openFallback(task, reason: "会话跳转请求失败（\(error.localizedDescription)）。", completion: completion)
                    } else {
                        completion("已请求 \(task.source) 打开会话 \(task.sessionID)。")
                    }
                }
            }
            return
        }
        openFallback(task, reason: "", completion: completion)
    }

    private static func openFallback(_ task: TaskRecord, reason: String, completion: @escaping (String) -> Void) {
        let workspace = NSWorkspace.shared
        let report: (String) -> Void = { completion(reason + $0) }
        let candidates: [String]
        switch task.source {
        case "Codex": candidates = ["com.openai.codex"]
        case "CatDesk": candidates = ["com.catpaw.cowork"]
        case "IDE-CatPaw": candidates = task.path.contains("/ide-") ? ["com.meituan.catpaw"] : ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.WebStorm", "com.jetbrains.pycharm", "com.jetbrains.goland"]
        case "Claude": candidates = ["com.googlecode.iterm2", "com.apple.Terminal"]
        default: candidates = []
        }
        let app = candidates.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        if let app {
            if task.source == "IDE-CatPaw", task.project.hasPrefix("/"), FileManager.default.fileExists(atPath: task.project) {
                workspace.open([URL(fileURLWithPath: task.project)], withApplicationAt: app, configuration: .init()) { _, error in
                    DispatchQueue.main.async { report(error.map { "打开项目失败：\($0.localizedDescription)" } ?? "已打开项目；当前未定位到具体会话，请选择「\(task.title)」。") }
                }
                return
            }
            workspace.openApplication(at: app, configuration: .init()) { _, error in
                DispatchQueue.main.async {
                    if let error { report("未能打开来源：\(error.localizedDescription)。可复制会话 ID 手动返回。") }
                    else { report("已打开 \(task.source)，当前未定位到具体会话。请手动选择「\(task.title)」。") }
                }
            }
            return
        }
        if task.project.hasPrefix("/"), FileManager.default.fileExists(atPath: task.project) {
            let ok = workspace.open(URL(fileURLWithPath: task.project))
            report(ok ? "来源应用不可定位，已打开项目；可复制会话 ID 继续查找。" : "无法打开项目，请复制会话 ID 或项目路径手动返回。")
        } else {
            report("未能定位 \(task.source) 应用或项目。请从详情复制会话 ID 手动返回。")
        }
    }

    static func openPath(source: String, path: String) {
        let task = taskForPath(source: source, path: path)
        open(task) { message in Notify.log("返回来源：\(message)") }
    }

    /// 兼容旧面板和菜单栏：从原始日志恢复 ID，而非把 rollout 文件名当会话 ID。
    static func taskForPath(source: String, path: String) -> TaskRecord {
        let url = URL(fileURLWithPath: path)
        var project = ""
        var sessionID = url.deletingPathExtension().lastPathComponent
        if source == "IDE-CatPaw", url.deletingLastPathComponent().lastPathComponent == "agent-transcripts" {
            sessionID = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        if let handle = try? FileHandle(forReadingFrom: url) {
            let data = (try? handle.read(upToCount: 262144)) ?? Data()
            try? handle.close()
            for object in RunParser.objects(String(decoding: data, as: UTF8.self)).prefix(8) {
                let payload = object["payload"] as? [String: Any] ?? object
                if let cwd = payload["cwd"] as? String { project = cwd }
                if source == "Codex", object["type"] as? String == "session_meta",
                   let raw = payload["id"] as? String, let id = codexSessionID(raw) { sessionID = id }
            }
        }
        if project.isEmpty, source == "Claude" {
            project = SourceOpener.decodeEscapedPath(url.deletingLastPathComponent().lastPathComponent)?.path ?? ""
        }
        return TaskRecord(id: source + ":" + sessionID,
            source: source, path: path, title: url.deletingPathExtension().lastPathComponent,
            project: project, phase: .unknown, runID: "", activity: Date(), observedAt: Date(), changedAt: Date(),
            evidence: "", readable: true, precise: false)
    }

    static func resumeCommand(_ task: TaskRecord) -> String {
        let command = "claude --resume " + quote(task.sessionID)
        return task.project.hasPrefix("/") ? "cd " + quote(task.project) + " && " + command : command
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension CodexRateLimits {
    func isStale(at now: Date) -> Bool {
        guard let snapshotAt else { return true }
        return now.timeIntervalSince(snapshotAt) > 600 || snapshotAt > now.addingTimeInterval(60)
    }
    static func remaining(used: Double?, resetsAt: Date?, snapshotAt: Date?, now: Date) -> Double? {
        guard let used, used.isFinite else { return nil }
        if let reset = resetsAt, now >= reset, snapshotAt == nil || snapshotAt! < reset { return nil }
        return 100 - min(100, max(0, used))
    }
}
