import Foundation
import Combine

struct PetChatMessage: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var role: String
    var text: String
}
struct PetChat: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var sessionID: String?
    var project: String
    var title: String
    var messages: [PetChatMessage] = []
    var progress: [String] = []
    var phase: TaskPhase = .running
    var updatedAt = Date()
    var allowEdits = false
}

@MainActor
final class PetChatStore: ObservableObject {
    static let shared = PetChatStore()
    @Published private(set) var chats: [PetChat] = []
    @Published var selectedID: String?
    @Published var openRequest = UUID()
    @Published var issue: String?
    private var jobs: [String: Process] = [:]
    private let url: URL
    private let executable: URL?
    private var readOnly = false
    var openMainWindow: (() -> Void)?
    var changed: (() -> Void)?
    var terminal: ((PetChat) -> Void)?
    init(url: URL = TaskCenterStore.dataDirectory.appendingPathComponent("pet-chats-v1.json"), executable: URL? = nil) {
        self.url = url
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        self.executable = executable ?? candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            chats = try JSONDecoder().decode([PetChat].self, from: Data(contentsOf: url))
            for i in chats.indices where chats[i].phase == .running {
                chats[i].phase = .unknown
                chats[i].progress.append("应用重启，上一轮执行结果待核实")
            }
        } catch { issue = "对话记录无法读取，已保护原文件。"; readOnly = true }
    }
    var selected: PetChat? { chats.first { $0.id == selectedID } }
    func reveal() { openRequest = UUID(); openMainWindow?() }
    func newChat() { selectedID = nil; reveal() }

    @discardableResult
    func send(_ prompt: String, project: String, allowEdits: Bool = false, new: Bool = false) -> Bool {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, !prompt.isEmpty, prompt.utf8.count <= 64_000 else { issue = "请输入有效内容（最多 64 KB）。"; return false }
        guard let executable else { issue = "未找到 Codex CLI，请先安装并登录 Codex。"; return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory), isDirectory.boolValue else {
            issue = "请先选择有效的项目目录。"; return false
        }
        let existing = new ? nil : selected
        guard existing.map({ jobs[$0.id] == nil }) ?? true else { issue = "当前对话仍在运行，可新建另一个对话。"; return false }
        let prior = chats
        var chat = existing ?? PetChat(project: project, title: String(prompt.prefix(80)), allowEdits: allowEdits)
        chat.messages.append(PetChatMessage(role: "user", text: prompt))
        chat.phase = .running; chat.progress = ["开始处理任务"]; chat.updatedAt = Date()
        if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = chat } else { chats.insert(chat, at: 0) }
        selectedID = chat.id
        guard persist() else { chats = prior; return false }
        let process = Process()
        process.executableURL = executable
        var args = ["exec", "--json", "--color", "never", "--sandbox", chat.allowEdits ? "workspace-write" : "read-only", "-C", chat.project, "--skip-git-repo-check"]
        if let session = chat.sessionID { args += ["resume", session] }
        args += ["-"]
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: chat.project)
        var environment = ProcessInfo.processInfo.environment
        // 避免继承桌面开发代理的会话标识；登录仍由 Codex 自己管理。
        environment.removeValue(forKey: "CODEX_THREAD_ID")
        process.environment = environment
        let output = Pipe(), input = Pipe()
        process.standardOutput = output; process.standardError = output; process.standardInput = input
        let id = chat.id
        do { try process.run() } catch {
            issue = "无法启动 Codex，请检查安装路径与权限。"
            mutate(id) { $0.phase = .failed; $0.progress.append("无法启动 Codex：\(error.localizedDescription)") }
            return false
        }
        jobs[id] = process; issue = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    // 仅传递允许的公开事件；不把推理条目、命令参数或原始错误日志送入 UI。
                    let event = PetChatEvent.parse(object)
                    DispatchQueue.main.async { self?.apply(event, to: id) }
                }
                if buffer.count > 1_000_000 { buffer.removeAll() }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                self.jobs.removeValue(forKey: id)
                let wasRunning = self.chats.first { $0.id == id }?.phase == .running
                self.mutate(id) { chat in
                    if chat.phase == .running {
                        chat.phase = status == 0 ? .unknown : .failed
                        chat.progress.append(status == 0 ? "未收到明确结束事件，请核实结果" : "执行退出，请检查 Codex 登录、网络或权限")
                    }
                }
                if wasRunning, let chat = self.chats.first(where: { $0.id == id }), chat.phase == .failed { self.terminal?(chat) }
            }
        }
        reveal(); changed?()
        return true
    }
    func shutdown() {
        for id in Array(jobs.keys) { cancel(id) }
    }
    func cancel(_ id: String) {
        guard let process = jobs[id] else { return }
        process.terminate()
        mutate(id) { $0.phase = .stopped; $0.progress.append("已请求停止") }
    }
    private func apply(_ event: PetChatEvent, to id: String) {
        guard event != .ignored else { return }
        let wasRunning = chats.first { $0.id == id }?.phase == .running
        mutate(id) { chat in
            guard chat.phase == .running else { return }
            switch event {
            case .session(let value): chat.sessionID = value
            case .message(let text):
                chat.messages.append(PetChatMessage(role: "assistant", text: String(text.prefix(100_000))))
                chat.progress.append(String(text.prefix(160)))
                chat.progress = Array(chat.progress.suffix(50))
            case .progress(let text):
                if chat.progress.last != text { chat.progress.append(text) }
                chat.progress = Array(chat.progress.suffix(50))
            case .completed: chat.phase = .completed; chat.progress.append("本轮已结束")
            case .failed: chat.phase = .failed; chat.progress.append("执行失败，请检查登录、网络或权限")
            case .ignored: break
            }
        }
        if wasRunning, let chat = chats.first(where: { $0.id == id }), [.completed, .failed].contains(chat.phase) { terminal?(chat) }
    }
    private func mutate(_ id: String, _ edit: (inout PetChat) -> Void) {
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        edit(&chats[i]); chats[i].updatedAt = Date(); _ = persist(); changed?()
    }
    @discardableResult private func persist() -> Bool {
        guard !readOnly else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(chats).write(to: url, options: .atomic)
            return true
        } catch { issue = "对话保存失败：\(error.localizedDescription)"; return false }
    }
}

enum PetChatEvent: Equatable {
    case session(String), message(String), progress(String), completed, failed, ignored
    static func parse(_ object: [String: Any]) -> PetChatEvent {
        let type = object["type"] as? String ?? ""
        if type == "thread.started", let id = object["thread_id"] as? String { return .session(id) }
        if type == "turn.completed" { return .completed }
        if type == "turn.failed" || type == "error" { return .failed }
        guard let item = object["item"] as? [String: Any], let kind = item["type"] as? String else { return .ignored }
        if kind == "agent_message", type == "item.completed", let text = item["text"] as? String { return .message(text) }
        let names = ["command_execution": "终端命令", "file_change": "文件修改", "mcp_tool_call": "工具调用", "web_search": "资料搜索", "todo_list": "更新任务计划"]
        guard let name = names[kind] else { return .ignored }
        return .progress(name + (type == "item.started" ? "进行中" : "已更新"))
    }
}
