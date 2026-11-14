import Foundation

enum ProcessConfidence: String, Equatable {
    case exact, strong, medium

    var rank: Int {
        switch self {
        case .exact: return 2
        case .strong: return 1
        case .medium: return 0
        }
    }

    var label: String {
        switch self {
        case .exact: return "明确"
        case .strong: return "强"
        case .medium: return "可能"
        }
    }

    /// 只有明确 / 强证据才在列表里显示资源占用；目录猜测只用于详情提示。
    var showsResourceUsage: Bool {
        self == .exact || self == .strong
    }
}

struct ProcessAttachment: Equatable {
    let group: AgentProcessGroup
    let confidence: ProcessConfidence
    let evidence: String
}

/// 只做“会话 → 进程树”的旁路归属，任何时候都不修改任务状态。
enum ProcessAttribution {
    static func kind(forSource source: String) -> AgentKind? {
        switch source {
        case "Claude": return .claude
        case "Codex": return .codex
        case "DeepSeek": return .deepseek
        default: return nil
        }
    }

    static func resolve(tasks: [TaskRecord],
                        groups: [AgentProcessGroup],
                        claudeSessions: [pid_t: ClaudeSessionEntry]) -> [String: ProcessAttachment] {
        guard !groups.isEmpty else { return [:] }

        var pathCache: [String: String] = [:]
        func normalize(_ path: String) -> String {
            guard !path.isEmpty else { return "" }
            if let cached = pathCache[path] { return cached }
            let value = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            pathCache[path] = value
            return value
        }

        let candidates = groups.map { (group: $0, cwd: normalize($0.cwd)) }
        var result: [String: ProcessAttachment] = [:]

        for task in tasks {
            guard let kind = kind(forSource: task.source), !task.sessionID.isEmpty else { continue }
            let matchingKind = candidates.filter { $0.group.kind == kind }
            guard !matchingKind.isEmpty else { continue }
            let project = normalize(task.project)
            var best: ProcessAttachment?

            for candidate in matchingKind {
                let group = candidate.group

                if kind == .claude {
                    let sessions = group.pids.compactMap { claudeSessions[$0] }
                    // Claude 有会话登记时以登记为准；登记指向别的会话就不再按目录猜测。
                    guard sessions.isEmpty else {
                        // 进程启动后文件仍有写入，才认为登记属于本次进程；避免 PID 复用时误认旧登记。
                        let exact = sessions.contains {
                            $0.sessionID == task.sessionID && $0.modified.addingTimeInterval(2) >= group.startedAt
                        }
                        if exact {
                            best = preferred(best, ProcessAttachment(
                                group: group, confidence: .exact, evidence: "Claude 会话登记"))
                        }
                        continue
                    }
                }

                if task.sessionID.count >= 8, group.cmd.contains(task.sessionID) {
                    best = preferred(best, ProcessAttachment(
                        group: group, confidence: .strong, evidence: "命令行包含会话标识"))
                }

                guard !project.isEmpty, candidate.cwd == project else { continue }
                let sameDirectory = matchingKind.filter { $0.cwd == candidate.cwd }
                guard sameDirectory.count == 1 else { continue }
                best = preferred(best, ProcessAttachment(
                    group: group, confidence: .medium, evidence: "工作目录唯一且一致"))
            }

            if let best { result[task.id] = best }
        }
        return result
    }

    private static func preferred(_ current: ProcessAttachment?, _ candidate: ProcessAttachment) -> ProcessAttachment {
        guard let current else { return candidate }
        return candidate.confidence.rank > current.confidence.rank ? candidate : current
    }
}
