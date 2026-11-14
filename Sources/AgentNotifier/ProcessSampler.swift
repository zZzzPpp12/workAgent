import Foundation
import Darwin
import CProcInfo

/// 一帧进程表里的单个进程。字段只在本机内存中使用，不持久化。
struct RawProcess: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let cwd: String
    let cmd: String
    let rss: UInt64
    let cpuSeconds: Double
    let startSeconds: Int64
}

/// pid + 启动时间：防止 PID 复用把两个进程的 CPU 差值算到一起。
struct ProcessKey: Hashable {
    let pid: pid_t
    let startSeconds: Int64
}

enum AgentKind: String, CaseIterable, Equatable {
    case claude, codex, gemini, deepseek, kimi, minimax

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi Code"
        case .minimax: return "MiniMax Code"
        }
    }

    /// 只按可执行文件与命令行识别，不读取任何对话内容。
    static func classify(_ process: RawProcess) -> AgentKind? {
        let executablePath = process.path.isEmpty ? process.name : process.path
        // .app 内部的 Helper / Framework 不是用户会话的 CLI，排除以免把桌面应用辅助进程当成 Agent。
        if process.path.lowercased().contains(".app/contents/") { return nil }
        let executable = (executablePath as NSString).lastPathComponent.lowercased()
        let command = process.cmd.lowercased()

        if executable == "claude" || command.contains("@anthropic-ai/claude-code") || command.contains("/bin/claude") {
            return .claude
        }
        if executable.hasPrefix("codex") || command.contains("/codex ") || command.hasSuffix("/codex") {
            return .codex
        }
        if executable == "gemini" || command.contains("@google/gemini-cli") {
            return .gemini
        }
        if executable == "dsh" || executable.contains("deepseek") || command.contains("deepseek-harness") {
            return .deepseek
        }
        if executable.contains("kimi") {
            return .kimi
        }
        if executable.contains("minimax") {
            return .minimax
        }
        return nil
    }
}

/// 按进程树归并后的一个 Agent。RSS 与 CPU 为整棵树合计。
struct AgentProcessGroup: Equatable {
    let kind: AgentKind
    let rootPID: pid_t
    let pids: [pid_t]
    let rss: UInt64
    let cpuPercent: Double
    let cwd: String
    let cmd: String
    let startedAt: Date
    let lastSeen: Date
}

struct ProcessSample {
    let processes: [RawProcess]
    let groups: [AgentProcessGroup]
    let sampledAt: Date
    let duration: TimeInterval
}

enum RawProcessReader {
    static func read() -> [RawProcess] {
        let capacity = Int(an_proc_list(nil, 0))
        guard capacity > 0 else { return [] }

        var pids = [pid_t](repeating: 0, count: capacity + 32)
        let count = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return an_proc_list(base, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        let currentUID = getuid()
        var result: [RawProcess] = []
        result.reserveCapacity(Int(count))

        for index in 0..<min(Int(count), pids.count) {
            let pid = pids[index]
            guard pid > 0 else { continue }
            var info = an_proc_info_t()
            guard an_proc_info(pid, &info) == 0, info.uid == currentUID else { continue }
            let name = decodeCString(info.name)
            let path = decodeCString(info.path)
            result.append(RawProcess(
                pid: pid,
                ppid: info.ppid,
                uid: info.uid,
                name: name,
                path: path,
                cwd: decodeCString(info.cwd),
                cmd: shouldReadCommand(name: name, path: path) ? readCommand(pid) : "",
                rss: info.rss_bytes,
                cpuSeconds: Double(info.cpu_ns) / 1_000_000_000,
                startSeconds: info.start_sec
            ))
        }
        return result
    }

    /// 只有可能解释为 Agent 的进程才读取命令行，避免对整个进程表做 KERN_PROCARGS2。
    private static func shouldReadCommand(name: String, path: String) -> Bool {
        let executablePath = path.isEmpty ? name : path
        let executable = (executablePath as NSString).lastPathComponent.lowercased()
        if ["node", "bun", "deno"].contains(executable) { return true }
        return ["claude", "codex", "gemini", "dsh", "kimi", "minimax", "deepseek"]
            .contains { executable.contains($0) }
    }

    private static func readCommand(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 2048)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            an_proc_args(pid, pointer.baseAddress, Int32(pointer.count))
        }
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    /// C 固定长度字符数组导入 Swift 后是 CChar 元组，按字节重绑定读取。
    private static func decodeCString<T>(_ value: T) -> String {
        var copy = value
        return withUnsafePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}

enum ProcessGrouper {
    static func groups(raw: [RawProcess],
                       previousCPU: [ProcessKey: Double],
                       interval: TimeInterval,
                       now: Date) -> [AgentProcessGroup] {
        guard !raw.isEmpty else { return [] }

        let byPID = Dictionary(uniqueKeysWithValues: raw.map { ($0.pid, $0) })
        var kinds: [pid_t: AgentKind] = [:]
        for process in raw {
            if let kind = AgentKind.classify(process) { kinds[process.pid] = kind }
        }
        guard !kinds.isEmpty else { return [] }

        var children: [pid_t: [pid_t]] = [:]
        for process in raw {
            children[process.ppid, default: []].append(process.pid)
        }

        let roots = raw.filter { process in
            guard let kind = kinds[process.pid] else { return false }
            guard let parent = byPID[process.ppid], let parentKind = kinds[parent.pid] else { return true }
            return parentKind != kind
        }

        return roots.compactMap { root -> AgentProcessGroup? in
            guard let kind = kinds[root.pid] else { return nil }
            var tree: [pid_t] = []
            var stack = [root.pid]
            var seen = Set<pid_t>()
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                tree.append(pid)
                for child in children[pid] ?? [] {
                    // 嵌套的其他 Agent 是独立根，不能同时计入本树，避免资源重复计算。
                    if let childKind = kinds[child], childKind != kind { continue }
                    stack.append(child)
                }
            }

            let rss = tree.compactMap { byPID[$0]?.rss }.reduce(UInt64(0), +)
            var cpu = 0.0
            if interval > 0.2 {
                for pid in tree {
                    guard let process = byPID[pid],
                          let previous = previousCPU[ProcessKey(pid: pid, startSeconds: process.startSeconds)] else { continue }
                    cpu += max(0, process.cpuSeconds - previous)
                }
                cpu = cpu / interval * 100
            }

            return AgentProcessGroup(
                kind: kind,
                rootPID: root.pid,
                pids: tree.sorted(),
                rss: rss,
                cpuPercent: cpu,
                cwd: root.cwd,
                cmd: root.cmd,
                startedAt: root.startSeconds > 0
                    ? Date(timeIntervalSince1970: TimeInterval(root.startSeconds))
                    : .distantPast,
                lastSeen: now
            )
        }.sorted { $0.rootPID < $1.rootPID }
    }
}

/// 维护两帧之间的 CPU 累计时间差；采样本身不启动任何子进程。
final class ProcessSampler {
    private var previousCPU: [ProcessKey: Double] = [:]
    private var lastSampleAt: Date?

    func sample(now: Date = Date()) -> ProcessSample {
        let start = CFAbsoluteTimeGetCurrent()
        let raw = RawProcessReader.read()
        let interval = lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
        let groups = ProcessGrouper.groups(raw: raw, previousCPU: previousCPU, interval: interval, now: now)
        previousCPU = Dictionary(uniqueKeysWithValues: raw.map {
            (ProcessKey(pid: $0.pid, startSeconds: $0.startSeconds), $0.cpuSeconds)
        })
        lastSampleAt = now
        return ProcessSample(processes: raw, groups: groups, sampledAt: now, duration: CFAbsoluteTimeGetCurrent() - start)
    }
}

/// Claude Code 会在 ~/.claude/sessions/<pid>.json 登记当前会话。
struct ClaudeSessionEntry: Equatable {
    let sessionID: String
    let modified: Date
}

enum ClaudeSessionRegistry {
    private struct Entry: Decodable {
        let pid: Int?
        let sessionId: String?
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [pid_t: ClaudeSessionEntry] {
        let directory = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var result: [pid_t: ClaudeSessionEntry] = [:]
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            guard size > 0, size <= 64 * 1024,
                  let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  let pid = entry.pid, pid > 0, pid <= Int(Int32.max),
                  let session = entry.sessionId, !session.isEmpty else { continue }
            result[pid_t(pid)] = ClaudeSessionEntry(
                sessionID: session,
                modified: values?.contentModificationDate ?? .distantFuture
            )
        }
        return result
    }
}
