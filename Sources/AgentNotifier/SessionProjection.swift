import Foundation

func eventDate(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

struct ParsedRun: Equatable {
    var phase: TaskPhase = .unknown
    var runID: String?
    var requestID: String?
    var eventAt: Date?
    var validLines = 0
    var evidence = "尚无可识别的回合边界"
}

enum RunParser {
    static func objects(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    static func codex(_ text: String) -> ParsedRun {
        codex(objects(text))
    }

    static func codex(_ records: [[String: Any]]) -> ParsedRun {
        var out = ParsedRun()
        var calls: [String: String] = [:]
        var questions = Set<String>()
        for obj in records {
            out.validLines += 1
            let payload = obj["payload"] as? [String: Any] ?? obj
            let type = payload["type"] as? String ?? ""
            let eventTurn = payload["turn_id"] as? String
            if type == "task_started" {
                out.runID = eventTurn ?? obj["timestamp"] as? String
                out.phase = .running
                out.eventAt = eventDate(obj["timestamp"])
                calls.removeAll(); questions.removeAll()
            } else if type == "task_complete" || type == "turn_aborted" || type == "task_failed" {
                if let eventTurn, let current = out.runID, eventTurn != current { continue }
                out.phase = type == "task_complete" ? .completed : type == "turn_aborted" ? .stopped : .failed
                out.eventAt = eventDate(obj["timestamp"])
            } else if type == "function_call" || type == "custom_tool_call" {
                let id = payload["call_id"] as? String ?? "call-\(out.validLines)"
                let name = payload["name"] as? String ?? "tool"
                calls[id] = name
                if name.contains("request_user_input") { questions.insert(id) }
            } else if type == "function_call_output" || type == "custom_tool_call_output" {
                let id = payload["call_id"] as? String ?? calls.keys.sorted().first ?? ""
                calls.removeValue(forKey: id)
                // Async receipts are not answers. Structured answers are explicit resolution evidence.
                if let output = payload["output"] as? String, output.contains("\"answers\"") {
                    questions.remove(id)
                }
            }
        }
        if !questions.isEmpty && out.phase != .stopped && out.phase != .failed {
            out.phase = .input
            out.requestID = questions.sorted().joined(separator: ",")
            out.evidence = "发现 request_user_input 请求，尚未发现回答或后续回合"
        } else if !calls.isEmpty && out.phase != .completed && !out.phase.terminal {
            out.evidence = "工具调用仍未返回；可能执行中，不能据此确认正在等待审批"
        } else {
            out.evidence = out.phase == .completed ? "来源 task_complete：仅代表本轮结束，尚未验收结果"
                : out.phase == .running ? "来源 task_started，尚未发现同回合结束边界"
                : out.phase == .stopped ? "来源明确记录回合中断" : out.evidence
        }
        return out
    }

    static func claude(_ text: String) -> ParsedRun {
        claude(objects(text))
    }

    static func claude(_ records: [[String: Any]]) -> ParsedRun {
        var out = ParsedRun()
        var questions = Set<String>()
        for obj in records {
            out.validLines += 1
            let type = obj["type"] as? String ?? ""
            let message = obj["message"] as? [String: Any] ?? [:]
            if type == "user" {
                let content = message["content"] as? [[String: Any]] ?? []
                let toolResult = content.contains { ($0["type"] as? String) == "tool_result" }
                if !toolResult {
                    out.runID = obj["uuid"] as? String ?? obj["timestamp"] as? String
                    questions.removeAll()
                } else {
                    for result in content {
                        if let id = result["tool_use_id"] as? String { questions.remove(id) }
                    }
                }
                out.phase = .running
                out.eventAt = eventDate(obj["timestamp"])
            } else if type == "assistant" {
                let stop = message["stop_reason"] as? String
                if stop == "end_turn" || stop == "stop_sequence" { out.phase = .completed }
                else { out.phase = .running }
                let content = message["content"] as? [[String: Any]] ?? []
                if let question = content.first(where: { ($0["name"] as? String) == "AskUserQuestion" }) {
                    questions.insert(question["id"] as? String ?? "question-\(out.validLines)")
                }
                out.eventAt = eventDate(obj["timestamp"])
            } else if type == "system", (obj["subtype"] as? String) == "turn_duration" {
                if out.phase != .input { out.phase = .completed }
                out.eventAt = eventDate(obj["timestamp"])
            }
        }
        if !questions.isEmpty { out.phase = .input; out.requestID = questions.sorted().joined(separator: ",") }
        out.evidence = out.phase == .completed ? "来源 end_turn / turn_duration：本轮已结束，结果待查看"
            : out.phase == .input ? "来源 AskUserQuestion 交互请求"
            : out.phase == .running ? "来源对话仍在推进；工具权限等待需增强事件确认" : out.evidence
        return out
    }
}

/// Cache bounded tail windows by actual file stamp. Repeated ticks never reparse cold history.
final class SessionProjector {
    private struct Cached {
        var stamp: String
        var parsed: ParsedRun
        var sessionID: String
        var project: String
        var workflow: WorkflowSnapshot?
    }
    private var cache: [String: Cached] = [:]

    func observation(_ watch: SessionWatch, now: Date) -> TaskObservation {
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: watch.url.path)
        let size = attributes?[.size] as? UInt64 ?? 0
        let mtime = attributes?[.modificationDate] as? Date ?? .distantPast
        let stamp = "\(size):\(mtime.timeIntervalSince1970)"
        var entry = cache[watch.url.path]
        if entry?.stamp != stamp {
            var parsed = ParsedRun()
            var workflow: WorkflowSnapshot?
            var sid = watch.conversationId ?? watch.sessionDir?.lastPathComponent ?? watch.url.deletingPathExtension().lastPathComponent
            var project = watch.label.components(separatedBy: " · ").first ?? watch.label
            if watch.kind == .ideaTranscript,
               let component = watch.url.pathComponents.first(where: { $0.hasPrefix("jb-") || $0.hasPrefix("ide-") }) {
                project = SourceOpener.decodeEscapedPath(String(component.dropFirst(component.hasPrefix("jb-") ? 3 : 4)))?.path ?? project
            }
            if watch.kind == .codexSession || watch.kind == .claudeSession || watch.kind == .deskConversation {
                if let text = readTailText(url: watch.url, maxBytes: 1_048_576) {
                    let records = RunParser.objects(text)
                    if watch.kind == .codexSession { parsed = RunParser.codex(records) }
                    if watch.kind == .claudeSession { parsed = RunParser.claude(records) }
                    workflow = WorkflowParser.parse(records, source: watch.sourceName, partial: size > 1_048_576)
                }
                if let handle = try? FileHandle(forReadingFrom: watch.url) {
                    let head = (try? handle.read(upToCount: 262144)) ?? Data()
                    try? handle.close()
                    for obj in RunParser.objects(String(decoding: head, as: UTF8.self)).prefix(8) {
                        let payload = obj["payload"] as? [String: Any] ?? obj
                        if let cwd = payload["cwd"] as? String { project = cwd }
                        if watch.kind == .codexSession, (obj["type"] as? String) == "session_meta", let id = payload["id"] as? String { sid = id }
                    }
                }
            }
            if watch.kind == .ideaTranscript, let text = readTailText(url: watch.url, maxBytes: 262144) {
                workflow = WorkflowParser.transcript(text, offset: max(0, Int(size) - text.utf8.count))
            }
            entry = Cached(stamp: stamp, parsed: parsed, sessionID: sid, project: project, workflow: workflow)
            cache[watch.url.path] = entry
        }
        let e = entry!
        var phase: TaskPhase
        switch watch.state {
        case .idle: phase = .idle
        case .running: phase = .running
        case .done: phase = .completed
        case .stuck: phase = .stalled
        case .error: phase = .failed
        case .awaitingConfirm: phase = watch.waitConfirmed ? (watch.waitIsQuestion ? .input : .approval) : .suspected
        case .stopped: phase = .stopped
        }
        var evidence = watch.waitEvidence ?? "根据来源会话尾部和最近活动判断"
        if watch.kind == .codexSession || watch.kind == .claudeSession {
            if e.parsed.phase != .unknown {
                // Explicit boundaries outrank an old size-based pin and delayed old events.
                phase = e.parsed.phase
                if phase == .running && watch.state == .awaitingConfirm { phase = .suspected }
                if phase == .running && watch.state == .stuck { phase = .stalled }
                evidence = e.parsed.evidence
            }
        }
        let synthetic = watch.kind == .ideaTranscript && watch.awaitingExternal && attributes == nil
        let readable = (fm.isReadableFile(atPath: watch.url.path) || synthetic)
            && (!(watch.kind == .codexSession || watch.kind == .claudeSession) || size == 0 || e.parsed.validLines > 0)
        if !readable { phase = .unknown; evidence = "来源文件暂不可读；没有将其推断为成功或失败" }
        if watch.kind == .traeState { phase = .idle; evidence = "仅展示工作区活动，不支持回合与待确认判断" }
        if phase == .stalled { evidence = "长时间未观察到有效输出；可能仍在思考或执行，尚不能确认中断" }
        let baseActivity = phase.terminal ? (e.parsed.eventAt ?? watch.lastActivity) : watch.lastActivity
        let activity = max(baseActivity, watch.waitSignalAt ?? .distantPast)
        return TaskObservation(id: watch.sourceName + ":" + e.sessionID, source: watch.sourceName,
            path: watch.url.path, title: watch.title ?? watch.label, project: e.project,
            phase: phase, runID: e.parsed.runID, activity: activity,
            evidence: evidence, readable: readable, precise: watch.kind != .traeState,
            interactionID: e.parsed.requestID ?? (watch.awaitingExternal ? watch.waitSignalAt.map { String($0.timeIntervalSince1970) } : nil),
            identityIsFallback: watch.kind == .codexSession && e.sessionID.hasPrefix("rollout-"), workflow: e.workflow)
    }
}
