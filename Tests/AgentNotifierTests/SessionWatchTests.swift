import XCTest
import SQLite3
@testable import AgentNotifier

final class SessionWatchTests: XCTestCase {

    private var tmpDir: URL!
    private var captured: [(title: String, body: String, sound: String)]!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentNotifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        captured = []
        Notify.sender = { [self] t, b, s, _ in captured.append((t, b, s)) }
    }

    override func tearDownWithError() throws {
        Notify.resetSender()
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: 工具方法

    private func makeFile(_ name: String = "transcript.txt", contents: String = "") -> URL {
        let url = tmpDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: contents.data(using: .utf8))
        return url
    }

    private func append(_ text: String, to url: URL) {
        let h = try! FileHandle(forWritingTo: url)
        try! h.seekToEnd()
        try! h.write(contentsOf: text.data(using: .utf8)!)
        try! h.close()
    }

    private func deskEvent(type: String, contentTypes: [(String, String)]) -> String {
        let blocks = contentTypes.map { (t, text) -> String in
            if t == "text" {
                return #"{"type":"text","text":"\#(text)"}"#
            }
            return #"{"type":"\#(t)","id":"toolu_1","name":"bash"}"#
        }.joined(separator: ",")
        return #"{"type":"\#(type)","message":{"content":[\#(blocks)]}}"# + "\n"
    }

    // MARK: IDEA transcript 状态机

    /// 完整链路：执行中 → assistant 收尾 → 宽限后判定完成，且只通知一次
    func testIdeaCompleteFlow() {
        let f = makeFile(contents: "[Tool call] read_file\n  target_file: /tmp/a\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "测试会话")
        let t0 = Date()
        w.calibrate(now: t0)

        append("[Tool result] read_file\n", to: f)
        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        append("\nassistant:\n任务已完成。\n", to: f)
        let t1 = t0.addingTimeInterval(1)
        w.poll(now: t1)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t1.addingTimeInterval(Config.doneGrace - 1))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        w.poll(now: t1.addingTimeInterval(Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("任务完成"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        w.poll(now: t1.addingTimeInterval(Config.doneGrace + 100))
        XCTAssertEqual(captured.count, 1)
    }

    /// 中断链路：停在工具调用中途（非思考状态），超过 stuckThreshold 判定疑似暂停/中断
    func testIdeaStuckFlow() {
        let f = makeFile(contents: "[Tool call] run_terminal_cmd\n  command: mvn compile\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "卡住会话")
        let t0 = Date()
        w.calibrate(now: t0)

        append("[Tool result] run_terminal_cmd\n", to: f)
        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t0.addingTimeInterval(Config.doneGrace + 5))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 5))
        XCTAssertEqual(w.state, .stuck)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("暂停/中断"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 500))
        XCTAssertEqual(captured.count, 1)
    }

    /// 思考宽限：尾部停在 [Thinking] 时使用 thinkingStuckThreshold，避免长推理误判
    func testThinkingGrace() {
        let f = makeFile(contents: "[Tool result] read_file\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "思考会话")
        let t0 = Date()
        w.calibrate(now: t0)

        append("[Thinking] 模型正在长推理...\n", to: f)
        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 60))
        XCTAssertTrue(captured.isEmpty)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t0.addingTimeInterval(Config.thinkingStuckThreshold + 5))
        XCTAssertEqual(w.state, .stuck)
        XCTAssertEqual(captured.count, 1)
    }

    /// 目录级活跃度：transcript 未动但 agent-tools 有输出 → 保持执行中，不误判中断
    func testDirActivityKeepsRunning() {
        let sessionDir = tmpDir.appendingPathComponent("session-1")
        let transcripts = sessionDir.appendingPathComponent("agent-transcripts")
        let tools = sessionDir.appendingPathComponent("agent-tools")
        try! FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let t = transcripts.appendingPathComponent("transcript.txt")
        FileManager.default.createFile(atPath: t.path,
                                       contents: "[Tool call] run_terminal_cmd\n".data(using: .utf8))

        let w = SessionWatch(kind: .ideaTranscript, url: t, label: "长工具会话", sessionDir: sessionDir)
        let t0 = Date()
        w.calibrate(now: t0)

        append("[Tool result] run_terminal_cmd\n", to: t)
        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        let toolLog = tools.appendingPathComponent("shell-1.log")
        FileManager.default.createFile(atPath: toolLog.path,
                                       contents: "compiling...\n".data(using: .utf8))
        let t1 = t0.addingTimeInterval(290)
        w.poll(now: t1)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t0.addingTimeInterval(310))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)
    }

    /// 恢复活动后状态与通知标记重置
    func testResumeResetsFlags() {
        let f = makeFile(contents: "")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "恢复会话")
        let t0 = Date()
        w.calibrate(now: t0)

        append("\nassistant:\n完成。\n", to: f)
        w.poll(now: t0)
        w.poll(now: t0.addingTimeInterval(Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)

        append("[Tool call] read_file\n", to: f)
        let t1 = t0.addingTimeInterval(100)
        w.poll(now: t1)
        XCTAssertEqual(w.state, .running)

        append("\nassistant:\n又完成了。\n", to: f)
        w.poll(now: t1.addingTimeInterval(1))
        w.poll(now: t1.addingTimeInterval(Config.doneGrace + 2))
        XCTAssertEqual(captured.count, 2)
    }

    /// assistant 后又有工具调用 → 不判定完成
    func testToolCallAfterAssistantNotComplete() {
        let f = makeFile(contents: "\nassistant:\n中间回复\n[Tool call] read_file\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "多轮会话")
        let t0 = Date()
        w.calibrate(now: t0)

        append("[Tool result] read_file\n", to: f)
        w.poll(now: t0)
        w.poll(now: t0.addingTimeInterval(Config.doneGrace + 5))
        XCTAssertTrue(captured.isEmpty)
        XCTAssertFalse(w.tailLooksComplete())
    }

    /// assistant: 后无实质内容 → 不判定完成
    func testEmptyAssistantNotComplete() {
        let f = makeFile(contents: "\nassistant:\n   \n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "空回复")
        w.calibrate()
        XCTAssertFalse(w.tailLooksComplete())
    }

    // MARK: CatDesk jsonl 状态机

    /// 回合结束：末帧为纯 text 的 assistant → 宽限后通知（Purr）
    func testDeskTurnEndFlow() {
        let f = makeFile("conv.jsonl", contents: deskEvent(type: "user", contentTypes: [("text", "你好")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk")
        let t0 = Date()
        w.calibrate(now: t0)

        // 助手带 tool_use → 执行中，不判完成
        append(deskEvent(type: "assistant", contentTypes: [("text", "我先查一下"), ("tool_use", "")]), to: f)
        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)
        w.poll(now: t0.addingTimeInterval(Config.deskDoneGrace + 10))
        XCTAssertTrue(captured.isEmpty)

        // 工具结果 → 仍不判完成
        append(deskEvent(type: "tool", contentTypes: [("text", "result")]), to: f)
        let t1 = t0.addingTimeInterval(30)
        w.poll(now: t1)
        w.poll(now: t1.addingTimeInterval(Config.deskDoneGrace + 10))
        XCTAssertTrue(captured.isEmpty)

        // 最终 assistant 纯文本 → 宽限后判定回合结束
        append(deskEvent(type: "assistant", contentTypes: [("text", "已完成")]), to: f)
        let t2 = t1.addingTimeInterval(30)
        w.poll(now: t2)
        w.poll(now: t2.addingTimeInterval(Config.deskDoneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("CatDesk"))
        XCTAssertEqual(captured[0].sound, "DogBark")
    }

    /// 末帧 text 为空字符串 → 不算最终回复
    func testDeskEmptyTextNotFinished() {
        let f = makeFile("conv.jsonl",
                         contents: deskEvent(type: "assistant", contentTypes: [("text", "")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk")
        w.calibrate()
        XCTAssertFalse(w.deskTurnFinished())
    }

    /// 末行半截 JSON（写入中）→ 保守视为未结束
    func testDeskPartialLineNotFinished() {
        let f = makeFile("conv.jsonl",
                         contents: deskEvent(type: "assistant", contentTypes: [("text", "已完成")])
                            + #"{"type":"assistant","message":{"cont"#)
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk")
        w.calibrate()
        XCTAssertFalse(w.deskTurnFinished())
    }

    // MARK: calibrate 假定运行

    /// 启动时发现 10 分钟内有活动 → 假定执行中（修复「实际在跑却显示空闲」），
    /// 但首次收敛不补发通知
    func testCalibrateAssumesRunningForRecentActivity() {
        let f = makeFile(contents: "\nassistant:\n刚完成的回复\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "近期会话")
        w.calibrate(now: Date())
        XCTAssertEqual(w.state, .running)

        // 状态机收敛为 done，但不发通知（启动静默）
        w.poll(now: Date().addingTimeInterval(Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertTrue(captured.isEmpty)
    }

    /// 远古会话 → 保持空闲
    func testCalibrateOldSessionStaysIdle() {
        let f = makeFile(contents: "\nassistant:\n很久以前\n")
        // 把 mtime 改成 2 小时前
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: f.path)
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "远古会话")
        w.calibrate(now: Date())
        XCTAssertEqual(w.state, .idle)
    }

    // MARK: 会话标题提取

    func testExtractTitleFromUserQuery() {
        let content = """
        user:
        [Rule]
        <catpaw_rules_context>
        大量规则内容...
        </catpaw_rules_context>
        <user_query>
        regeo failed, status not 200
        310错误码debug
        </user_query>

        [Tool call] read_file
        """
        let f = makeFile(contents: content)
        let title = extractTitle(from: f)
        XCTAssertEqual(title, "regeo failed, status not 200 310错误码debug")
    }

    func testExtractTitleTruncatesLongQuery() {
        let long = String(repeating: "长", count: 100)
        let f = makeFile(contents: "user:\n<user_query>\n\(long)\n</user_query>\n")
        let title = extractTitle(from: f)
        XCTAssertNotNil(title)
        XCTAssertTrue(title!.hasSuffix("…"))
        XCTAssertEqual(title!.count, Config.titleMaxLength + 1)
    }

    func testExtractTitleMissingReturnsNil() {
        let f = makeFile(contents: "user:\n没有标签的普通内容\n")
        XCTAssertNil(extractTitle(from: f))
    }

    /// CatDesk 标题：跳过 "<" 开头的注入上下文块，取首个真实用户文本
    func testExtractDeskTitle() {
        let injected = #"{"type":"user","message":{"content":[{"type":"text","text":"<expert_instructions>注入内容</expert_instructions>"}]}}"# + "\n"
        let real = #"{"type":"user","message":{"content":[{"type":"text","text":"帮我开发一个办公工具"}]}}"# + "\n"
        let f = makeFile("conv.jsonl", contents: injected + real)
        XCTAssertEqual(extractDeskTitle(from: f), "帮我开发一个办公工具")
    }

    func testExtractDeskTitleAllInjectedReturnsNil() {
        let injected = #"{"type":"user","message":{"content":[{"type":"text","text":"<system>x</system>"}]}}"# + "\n"
        let f = makeFile("conv.jsonl", contents: injected)
        XCTAssertNil(extractDeskTitle(from: f))
    }

    /// 真实文本与注入 XML 混排在同一文本块（sandbox_context / attachment_context）
    func testExtractDeskTitleMixedWithInjectedXml() {
        let mixed = #"{"type":"user","message":{"content":[{"type":"text","text":"<sandbox_context mode=\"full\" />\n\n<attachment_context>\nIMPORTANT: 说明文字\n<file type=\"image\" />\n</attachment_context>\n\n1、catdesk还在思考中也发了结束通知\n2、增加标题展示"}]}}"# + "\n"
        let f = makeFile("conv.jsonl", contents: mixed)
        XCTAssertEqual(extractDeskTitle(from: f), "1、catdesk还在思考中也发了结束通知 2、增加标题展示")
    }

    /// 剥除 XML 块单元测试
    func testStripXmlBlocks() {
        XCTAssertEqual(stripXmlBlocks("<a>x</a>hello"), "hello")
        XCTAssertEqual(stripXmlBlocks("<a /> \n <b>y</b> 真实内容")
            .trimmingCharacters(in: .whitespacesAndNewlines), "真实内容")
        XCTAssertEqual(stripXmlBlocks("纯文本"), "纯文本")
    }

    /// 真实提问在较靠后的 user 事件（前 30 行之后）也能取到
    func testExtractDeskTitleBeyondFirstLines() {
        let injected = #"{"type":"user","message":{"content":[{"type":"text","text":"<system>x</system>"}]}}"# + "\n"
        let filler = #"{"type":"assistant","message":{"content":[{"type":"text","text":"干活中"}]}}"# + "\n"
        let real = #"{"type":"user","message":{"content":[{"type":"text","text":"第二轮提问内容"}]}}"# + "\n"
        let f = makeFile("conv.jsonl", contents: injected + String(repeating: filler, count: 60) + real)
        XCTAssertEqual(extractDeskTitle(from: f), "第二轮提问内容")
    }

    func testSanitizeTitle() {
        XCTAssertNil(sanitizeTitle("  \n  \n"))
        XCTAssertEqual(sanitizeTitle("  hello \n world "), "hello world")
    }

    // MARK: 目录名解析

    func testProjectLabelParsing() {
        XCTAssertEqual(
            projectLabel(from: "jb-Users-maohuafeng-IdeaProjects-health-2-health_medical_ai"),
            "health_medical_ai")
        XCTAssertEqual(
            projectLabel(from: "jb-Users-maohuafeng-IdeaProjects-xiaotuan-xt-ai-agent"),
            "xt-ai-agent")
        XCTAssertEqual(
            projectLabel(from: "jb-Users-someone-IdeaProjects-health_medical_ai_python"),
            "health_medical_ai_python")
        // CatPaw 独立端：ide- 前缀同样剥掉 Users-<user>-，剩余路径段保留（与 CatDesk workspaceLabel 一致）
        XCTAssertEqual(
            projectLabel(from: "ide-Users-maohuafeng-ai-workspace-元析AI-Coding-Framework-V0-94"),
            "ai-workspace-元析AI-Coding-Framework-V0-94")
        XCTAssertEqual(projectLabel(from: "random-dir"), "random-dir")
    }

    func testWorkspaceLabelParsing() {
        XCTAssertEqual(
            workspaceLabel(from: "-Users-maohuafeng-ai-workspace-catpaw-desk"),
            "ai-workspace-catpaw-desk")
        XCTAssertEqual(
            workspaceLabel(from: "Users-maohuafeng-ai-workspace-health-personal-doctor"),
            "ai-workspace-health-personal-doctor")
    }

    // MARK: CatDesk 回合流信号解析（api-request.log）

    private func streamLine(event: String, cid: String,
                            outcome: String? = nil, reason: String? = nil) -> String {
        var s = #"{"event":"\#(event)","operation":"conversation.turn","conversationId":"\#(cid)""#
        if let o = outcome { s += #","outcome":"\#(o)""# }
        if let r = reason { s += #","closeReason":"\#(r)""# }
        return s + "}\n"
    }

    func testDeskTurnSignalParsing() {
        let open = deskTurnSignal(fromLine: streamLine(event: "http.client.stream.open", cid: "abc"))
        XCTAssertEqual(open?.conversationId, "abc")
        XCTAssertEqual(open?.signal, .running)

        let done = deskTurnSignal(fromLine: streamLine(event: "http.client.stream.close",
                                                       cid: "abc", outcome: "success",
                                                       reason: "server_completed"))
        XCTAssertEqual(done?.signal, .done)

        let err = deskTurnSignal(fromLine: streamLine(event: "http.client.stream.close",
                                                      cid: "abc", outcome: "stream_error",
                                                      reason: "stream_error"))
        XCTAssertEqual(err?.signal, .error("stream_error"))

        let stopped = deskTurnSignal(fromLine: streamLine(event: "http.client.stream.close",
                                                          cid: "abc", outcome: "canceled",
                                                          reason: "client_aborted"))
        XCTAssertEqual(stopped?.signal, .stopped)

        // 非回合事件 / 非 JSON → nil
        XCTAssertNil(deskTurnSignal(fromLine: #"{"event":"http.client.request","operation":"metric.report"}"#))
        XCTAssertNil(deskTurnSignal(fromLine: "not json"))
    }

    func testApiRequestLogTracker() {
        let f = makeFile("api-request.log",
                         contents: streamLine(event: "http.client.stream.open", cid: "c1")
                            + streamLine(event: "http.client.stream.close", cid: "c1", outcome: "success")
                            + streamLine(event: "http.client.stream.open", cid: "c2"))
        let tracker = ApiRequestLogTracker(url: f)
        tracker.calibrate()
        XCTAssertEqual(tracker.status["c1"], .done)
        XCTAssertEqual(tracker.status["c2"], .running)

        // 增量：c2 异常结束
        append(streamLine(event: "http.client.stream.close", cid: "c2", outcome: "stream_error"), to: f)
        tracker.poll()
        XCTAssertEqual(tracker.status["c2"], .error("stream_error"))

        // 半行写入不崩溃，补全后可解析
        append(#"{"event":"http.client.stream.open","operation":"conversation.turn","convers"#, to: f)
        tracker.poll()
        XCTAssertEqual(tracker.status["c3"], nil)
        append(#"ationId":"c3"}"# + "\n", to: f)
        tracker.poll()
        XCTAssertEqual(tracker.status["c3"], .running)
    }

    // MARK: IDEA 插件错误信号（idea.log）

    func testIdeaErrorLineMatching() {
        let errLine = #"[webview][b5-40ad][2026-10-10 16:44:44.835] [ERROR] [catpaw] onAgentError_{"errorType":"ResponseError","errorMsg":"{\"ok\":false,\"status\":406}"}"#
        XCTAssertTrue(isIdeaAgentErrorLine(errLine))
        XCTAssertTrue(extractIdeaErrorMsg(errLine).contains("ResponseError"))

        let respLine = #"[webview][e2-ac84][2026-10-10 16:57:52.791] [ERROR] [catpaw] [stream_16:56:56.691] 响应异常_{"ok":false,"status":406}"#
        XCTAssertTrue(isIdeaAgentErrorLine(respLine))

        let netLine = #"[webview][e2-ac84][2026-10-10 17:01:27.144] [ERROR] [catpaw] [stream_17:00:25.801] 网络请求失败_{"url":"https://mcopilot.sankuai.com"}"#
        XCTAssertTrue(isIdeaAgentErrorLine(netLine))

        // 噪音与无关行不匹配
        let noise = #"[webview][e2][2026-10-10 17:22:27.515] [ERROR] [catpaw] AgentBaseMessage.updateMessage: payload.partial字段不存在"#
        XCTAssertFalse(isIdeaAgentErrorLine(noise))
        XCTAssertFalse(isIdeaAgentErrorLine("2026-10-10 INFO - some other log"))
    }

    func testMarkIdeaError() {
        let f = makeFile(contents: "[Tool call] read_file\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "出错会话")
        w.calibrate()

        w.markIdeaError(at: Date(), msg: #"{"ok":false,"status":406}"#)
        XCTAssertEqual(w.state, .error)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("异常中断"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        // 重复归因不重复提醒
        w.markIdeaError(at: Date(), msg: "again")
        XCTAssertEqual(captured.count, 1)
    }

    // MARK: CatDesk 流信号驱动状态机

    /// 首个信号静默对齐（不补发历史状态），之后 done 正常提醒
    func testDeskSignalFirstAdoptSilent() {
        let f = makeFile("conv.jsonl", contents: deskEvent(type: "user", contentTypes: [("text", "你好")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c1")
        w.calibrate(now: Date())

        // 首个信号是 done（历史回合）→ 静默对齐，不通知
        w.poll(deskSignal: .done)
        XCTAssertEqual(w.state, .done)
        XCTAssertTrue(captured.isEmpty)

        // 首个信号是 error（历史）→ 静默
        let w2 = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c2")
        w2.calibrate(now: Date())
        w2.poll(deskSignal: .error("stream_error"))
        XCTAssertEqual(w2.state, .error)
        XCTAssertTrue(captured.isEmpty)
    }

    /// 流信号驱动：running（思考中）不提醒完成；close success 且 jsonl 末帧为最终回复才提醒
    func testDeskSignalDoneNotifies() {
        let f = makeFile("conv.jsonl", contents: deskEvent(type: "user", contentTypes: [("text", "你好")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c1")
        w.calibrate(now: Date())

        w.poll(deskSignal: .running) // 首个信号：对齐为执行中
        XCTAssertEqual(w.state, .running)

        // 长时间思考（多次 running 信号）→ 不发「回合结束」
        for i in 1...5 {
            w.poll(now: Date().addingTimeInterval(TimeInterval(i * 30)), deskSignal: .running)
        }
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        // 流正常关闭，但 jsonl 末帧不是最终回复（仍是用户消息）→ 视为模型请求间歇，不提醒
        w.poll(now: Date().addingTimeInterval(180), deskSignal: .done)
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        // jsonl 末帧出现最终回复后，再次 close → 回合结束提醒
        // （首次 poll 检测到文件写入会提前 return，信号下一轮才处理）
        append(deskEvent(type: "assistant", contentTypes: [("text", "已完成")]), to: f)
        w.poll(now: Date().addingTimeInterval(190), deskSignal: .done)
        w.poll(now: Date().addingTimeInterval(200), deskSignal: .done)
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("CatDesk"))
        XCTAssertEqual(captured[0].sound, "DogBark")
    }

    /// 模型调用间歇的 done（jsonl 末帧 assistant 带 tool_use）→ 保持执行中，不误报回合结束
    func testDeskSignalDoneBetweenModelCallsStaysRunning() {
        let f = makeFile("conv.jsonl", contents: deskEvent(type: "assistant", contentTypes: [("text", "我先查一下"), ("tool_use", "")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c1")
        let t0 = Date()
        w.calibrate(now: t0)

        w.poll(now: t0, deskSignal: .running)
        XCTAssertEqual(w.state, .running)

        // 一次模型请求结束（jsonl 未到最终回复）→ 仍执行中，无通知
        w.poll(now: t0.addingTimeInterval(5), deskSignal: .done)
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        // 工具执行完、最终回复出现 + 下一次 close → 真正结束
        append(deskEvent(type: "tool", contentTypes: [("text", "result")]), to: f)
        append(deskEvent(type: "assistant", contentTypes: [("text", "都办好了")]), to: f)
        w.poll(now: t0.addingTimeInterval(Config.deskDoneGrace + 20), deskSignal: .done)
        w.poll(now: t0.addingTimeInterval(Config.deskDoneGrace + 30), deskSignal: .done)
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].sound, "DogBark")
    }

    /// 流信号 error → 防抖宽限后才异常中断提醒；宽限内恢复（running）不提醒；用户停止 → 已停止不提醒
    func testDeskSignalErrorNotifies() {
        let f = makeFile("conv.jsonl", contents: deskEvent(type: "user", contentTypes: [("text", "你好")]))
        let t0 = Date()
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c1")
        w.calibrate(now: t0)

        w.poll(now: t0, deskSignal: .running)

        // 异常信号刚出现：宽限期内不判异常、不提醒（客户端可能自动重试）
        w.poll(now: t0.addingTimeInterval(1), deskSignal: .error("stream_error"))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)
        w.poll(now: t0.addingTimeInterval(Config.deskErrorGrace - 1), deskSignal: .error("stream_error"))
        XCTAssertTrue(captured.isEmpty)

        // 宽限后仍未恢复 → 异常中断提醒
        w.poll(now: t0.addingTimeInterval(Config.deskErrorGrace + 1), deskSignal: .error("stream_error"))
        XCTAssertEqual(w.state, .error)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("异常中断"))
        XCTAssertTrue(captured[0].body.contains("stream_error"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        // 用户重试 → running → 正常完成 → 再次提醒完成
        w.poll(deskSignal: .running)
        XCTAssertEqual(w.state, .running)
        append(deskEvent(type: "assistant", contentTypes: [("text", "重试后完成")]), to: f)
        w.poll(now: Date().addingTimeInterval(Config.deskDoneGrace + 1), deskSignal: .done)
        w.poll(now: Date().addingTimeInterval(Config.deskDoneGrace + 5), deskSignal: .done)
        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured[1].title.contains("回合结束"))

        // 宽限期内收到 running → 视为自动重试恢复，不提醒异常
        let w3 = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c3")
        let t3 = Date()
        w3.calibrate(now: t3)
        w3.poll(now: t3, deskSignal: .running)
        w3.poll(now: t3.addingTimeInterval(2), deskSignal: .error("timeout"))
        w3.poll(now: t3.addingTimeInterval(5), deskSignal: .running)
        XCTAssertEqual(w3.state, .running)
        XCTAssertEqual(captured.count, 2)

        // 用户主动停止 → 状态变更但不提醒
        let w2 = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c2")
        w2.calibrate(now: Date())
        w2.poll(deskSignal: .running)
        w2.poll(deskSignal: .stopped)
        XCTAssertEqual(w2.state, .stopped)
        XCTAssertEqual(captured.count, 2)
    }

    // MARK: 等待手动确认

    func testTailEndsWithPendingCommand() {
        let pending = makeFile(contents: "[Tool result] read_file\n\n[Tool call] run_terminal_cmd\n  command: mvn compile\n")
        let w = SessionWatch(kind: .ideaTranscript, url: pending, label: "t")
        XCTAssertTrue(w.tailEndsWithPendingCommand())

        let done = makeFile("b.txt", contents: "[Tool call] run_terminal_cmd\n  command: mvn\n\n[Tool result] run_terminal_cmd\n")
        let w2 = SessionWatch(kind: .ideaTranscript, url: done, label: "t")
        XCTAssertFalse(w2.tailEndsWithPendingCommand())

        // 非命令类工具悬置不算
        let readPending = makeFile("c.txt", contents: "[Tool call] read_file\n  target_file: /tmp/a\n")
        let w3 = SessionWatch(kind: .ideaTranscript, url: readPending, label: "t")
        XCTAssertFalse(w3.tailEndsWithPendingCommand())
    }

    /// 命令悬置超过落定延迟 → 等待手动确认，且不再升级为疑似中断
    func testIdeaAwaitingConfirmFlow() {
        let f = makeFile(contents: "[Tool call] run_terminal_cmd\n  command: mvn compile\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "待确认会话")
        let t0 = Date()
        w.calibrate(now: t0)

        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay - 5))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay + 5))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("等待手动确认"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        // 超过 stuckThreshold 仍保持等待确认，不升级为疑似中断、不重复提醒
        w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 60))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)

        // 用户确认执行（有新写入）→ 回到执行中并重新武装
        append("[Tool result] run_terminal_cmd\n", to: f)
        w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 70))
        XCTAssertEqual(w.state, .running)
    }

    /// 删除类确认卡片（v0.10.29）：非命令工具（delete_file）悬置同样识别为等待确认——
    /// 原 tailEndsWithPendingCommand 仅匹配 run_terminal_cmd，且 CatPaw IDE 独立端
    /// 无 idea.log 回合事件（tab-turn 快路径缺失），删除卡片在两端都曾完全无提醒
    func testIdeaDeleteCardAwaitingConfirm() {
        let f = makeFile(contents: "[Tool call] delete_file\n  explanation: 用户要求删除。\n  target_file: /tmp/a.md\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "删除卡片会话")
        let t0 = Date()
        w.calibrate(now: t0)

        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay - 5))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay + 5))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("等待手动确认"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        // 用户确认后工具结果落盘 → 解除悬置回到执行中
        append("\n[Tool result] delete_file\n", to: f)
        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay + 10))
        XCTAssertEqual(w.state, .running)
    }

    /// 后台命令悬置无需确认：超阈值不提醒、不升级为疑似中断
    func testIdeaBackgroundCommandSilent() {
        let f = makeFile(contents: "[Tool call] run_terminal_cmd\n  command: mvn test\n  is_background: true\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "后台命令会话")
        let t0 = Date()
        w.calibrate(now: t0)

        w.poll(now: t0)
        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay + 5))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)

        w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 60))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)
    }

    /// 自动批准的工具仍在执行（agent-tools 有写入）→ 不按确认卡片误报
    func testIdeaPendingToolSuppressedByToolActivity() {
        let sessionDir = tmpDir.appendingPathComponent("session-guard")
        let transcripts = sessionDir.appendingPathComponent("agent-transcripts")
        let tools = sessionDir.appendingPathComponent("agent-tools")
        try! FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let t = transcripts.appendingPathComponent("transcript.txt")
        FileManager.default.createFile(atPath: t.path,
                                       contents: "[Tool call] delete_file\n  target_file: /tmp/a.md\n".data(using: .utf8))
        let w = SessionWatch(kind: .ideaTranscript, url: t, label: "自动执行会话", sessionDir: sessionDir)
        let t0 = Date()
        w.calibrate(now: t0)
        w.poll(now: t0)
        XCTAssertEqual(w.state, .running)

        // 工具执行写入发生在 lastActivity 之后（模拟：mtime 设到模拟时刻之后）
        let toolLog = tools.appendingPathComponent("tool.log")
        FileManager.default.createFile(atPath: toolLog.path, contents: "working\n".data(using: .utf8))
        let t1 = t0.addingTimeInterval(Config.cardSettleDelay + 50)
        try! FileManager.default.setAttributes([.modificationDate: t1.addingTimeInterval(50)],
                                               ofItemAtPath: toolLog.path)
        w.poll(now: t1) // 目录活动 → 活跃
        XCTAssertEqual(w.state, .running)

        // idleFor 超落定延迟，但 hasToolActivity 命中 → 保持静默
        w.poll(now: t1.addingTimeInterval(Config.cardSettleDelay + 10))
        XCTAssertEqual(w.state, .running)
        XCTAssertTrue(captured.isEmpty)
    }

    func testDeskPendingCommand() {
        let bash = makeFile("conv.jsonl",
                            contents: deskEvent(type: "assistant", contentTypes: [("tool_use", "")]))
        let w = SessionWatch(kind: .deskConversation, url: bash, label: "t")
        XCTAssertTrue(w.deskPendingCommand())

        let textOnly = makeFile("conv2.jsonl",
                                contents: deskEvent(type: "assistant", contentTypes: [("text", "已完成")]))
        let w2 = SessionWatch(kind: .deskConversation, url: textOnly, label: "t")
        XCTAssertFalse(w2.deskPendingCommand())

        let toolResult = makeFile("conv3.jsonl",
                                  contents: deskEvent(type: "tool", contentTypes: [("text", "result")]))
        let w3 = SessionWatch(kind: .deskConversation, url: toolResult, label: "t")
        XCTAssertFalse(w3.deskPendingCommand())
    }

    // MARK: 通知日志读取

    func testReadLogLinesReversed() {
        let f = makeFile("AgentNotifier.log",
                         contents: "2026-10-10 17:00:00 title=[A]\n2026-10-10 17:01:00 title=[B]\n2026-10-10 17:02:00 title=[C]\n")
        let lines = readLogLines(url: f, maxBytes: 16384, maxLines: 80)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("[C]")) // 最新在前
        XCTAssertTrue(lines[2].contains("[A]"))
    }

    // MARK: 来源前缀

    func testDisplayNameSourcePrefix() {
        let f = makeFile()
        let idea = SessionWatch(kind: .ideaTranscript, url: f, label: "health_medical_ai · 6fe48172",
                                title: "排查网络超时")
        XCTAssertEqual(idea.displayName, "IDE-CatPaw：排查网络超时")

        let desk = SessionWatch(kind: .deskConversation, url: f, label: "ws · abc12345",
                                title: "开发工具")
        XCTAssertEqual(desk.displayName, "CatDesk：开发工具")

        // 无标题时回退标签
        let noTitle = SessionWatch(kind: .ideaTranscript, url: f, label: "health_medical_ai · 6fe48172")
        XCTAssertEqual(noTitle.displayName, "IDE-CatPaw：health_medical_ai · 6fe48172")
    }

    // MARK: IDEA Tab 回合状态（等待确认信号）

    func testParseIdeaTabStatus() {
        let line = "2026-10-10 19:41:24,336 [119687815]   INFO - com.sankuai.mcopilot.components.chat.agent.toolwindow.AgentTabService - Tab状态已更新，ID: b61fc7f0-c52e-4141-9bb7-0aa549838aad, Status: completed"
        let r = parseIdeaTabStatus(line)
        XCTAssertEqual(r?.tabId, "b61fc7f0-c52e-4141-9bb7-0aa549838aad")
        XCTAssertEqual(r?.status, "completed")
        XCTAssertNil(parseIdeaTabStatus("2026-10-10 19:41:24,336 普通日志"))
        // 时间戳解析
        let ts = parseIdeaLogTimestamp(line)
        XCTAssertNotNil(ts)
    }

    /// running → completed 组成一个回合；未见 running 的结束事件被忽略
    func testIdeaTabTurnTracking() throws {
        let ideDir = tmpDir.appendingPathComponent("IntelliJIdea2025.3")
        try FileManager.default.createDirectory(at: ideDir, withIntermediateDirectories: true)
        let log = ideDir.appendingPathComponent("idea.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tracker = IdeaLogTracker(logsRoot: tmpDir)
        tracker.calibrate()

        append("2026-10-10 19:41:17,943 [1]   INFO - x - Tab状态已更新，ID: b61fc7f0-c52e-4141-9bb7-0aa549838aad, Status: running\n", to: log)
        append("2026-10-10 19:41:24,336 [2]   INFO - x - Tab状态已更新，ID: b61fc7f0-c52e-4141-9bb7-0aa549838aad, Status: completed\n", to: log)
        append("2026-10-10 19:41:25,000 [3]   INFO - x - Tab状态已更新，ID: aaaaaaaa-0000-0000-0000-000000000000, Status: completed\n", to: log)
        tracker.poll()

        let turns = tracker.takeFinishedTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].tabId, "b61fc7f0-c52e-4141-9bb7-0aa549838aad")
        XCTAssertEqual(turns[0].status, "completed")
        XCTAssertLessThan(turns[0].runningSince, turns[0].endedAt)
        // 取走后清空
        XCTAssertTrue(tracker.takeFinishedTurns().isEmpty)
    }

    /// 回归：completed 只是模型轮次边界（后面紧跟下一个 running）时不算回合结束
    /// （2026-10-12 19:30 真实事故：一个用户回合由几十对 running/completed 组成，
    /// 逐个评估导致对正在生成的会话反复误报「等待手动确认」）
    func testTabResumedDetection() throws {
        let ideDir = tmpDir.appendingPathComponent("IntelliJIdea2025.3")
        try FileManager.default.createDirectory(at: ideDir, withIntermediateDirectories: true)
        let log = ideDir.appendingPathComponent("idea.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tracker = IdeaLogTracker(logsRoot: tmpDir)
        tracker.calibrate()

        // 轮次 1：running → completed（轮次边界），随即轮次 2 running
        append("2026-10-12 19:30:20,000 [1]   INFO - x - Tab状态已更新，ID: 79e2526b-1306-41e4-a2cd-28b448ee68fb, Status: running\n", to: log)
        append("2026-10-12 19:30:23,517 [2]   INFO - x - Tab状态已更新，ID: 79e2526b-1306-41e4-a2cd-28b448ee68fb, Status: completed\n", to: log)
        tracker.poll()
        let turns = tracker.takeFinishedTurns()
        XCTAssertEqual(turns.count, 1)
        // 此刻尚未出现后续 running → 未取代
        XCTAssertFalse(tracker.tabResumed(turns[0].tabId, after: turns[0].endedAt))

        // 0.9 秒后轮次 2 running → 轮次 1 的 completed 被取代
        append("2026-10-12 19:30:24,391 [3]   INFO - x - Tab状态已更新，ID: 79e2526b-1306-41e4-a2cd-28b448ee68fb, Status: running\n", to: log)
        tracker.poll()
        XCTAssertTrue(tracker.tabResumed(turns[0].tabId, after: turns[0].endedAt))

        // 真正的回合结束：completed 后无后续 running
        append("2026-10-12 19:35:00,000 [4]   INFO - x - Tab状态已更新，ID: 79e2526b-1306-41e4-a2cd-28b448ee68fb, Status: completed\n", to: log)
        tracker.poll()
        let finalTurn = tracker.takeFinishedTurns()[0]
        XCTAssertFalse(tracker.tabResumed(finalTurn.tabId, after: finalTurn.endedAt))
    }

    /// 回合归因目标：取最近活跃的 IDEA 会话；无会话 → nil
    func testTabTurnTarget() {
        let old = makeFile("old.txt", contents: "\nassistant:\n早前的回复\n")
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let wOld = SessionWatch(kind: .ideaTranscript, url: old, label: "old")
        wOld.calibrate()

        let done = makeFile("done.txt", contents: "[Tool result] read_file\n\nassistant:\n搞定了\n")
        let wDone = SessionWatch(kind: .ideaTranscript, url: done, label: "done")
        wDone.calibrate()

        XCTAssertTrue(tabTurnTarget([wOld]) === wOld)
        XCTAssertTrue(tabTurnTarget([wOld, wDone]) === wDone)
        XCTAssertNil(tabTurnTarget([]))
    }

    /// 回归（v0.10.15）：会话钉在「等待手动确认」后用户点了停止/回合失败——
    /// transcript 尾部永久停在未完成的 [Tool call]，deepSweep（tailSaysFinished）
    /// 永远不触发，钉住必须由 cancelled/failed 回合事件解除，否则黄点永远挂着
    func testCancelledTurnReleasesStuckCardPin() {
        let f = makeFile(contents: "[Tool call] delete_file\n  target_file: /tmp/a.md\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "被停止的会话")
        w.calibrate(now: Date())
        w.markAwaitingConfirm(source: "CatPaw")
        XCTAssertEqual(w.state, .awaitingConfirm)
        let notifyCount = captured.count

        // 决策：尾部停在前台工具调用 + 钉住中 → cancelled 回合应解除
        XCTAssertTrue(cancelledTurnReleasesPin(
            awaiting: w.awaitingExternal,
            tail: w.ideaTailState(),
            toolActivity: false, complete: false))

        // 深扫（v0.10.13 路径）确实解不了：尾部未收尾
        XCTAssertFalse(w.deepSweep(now: Date().addingTimeInterval(300)))
        XCTAssertEqual(w.state, .awaitingConfirm)

        releaseCardPin(w, turnStatus: "cancelled")
        XCTAssertFalse(w.awaitingExternal)
        XCTAssertEqual(w.state, .stopped)
        // 解除不补发通知
        XCTAssertEqual(captured.count, notifyCount)
    }

    /// failed 回合同理解除钉住，状态落「异常中断」且不补发错误通知
    func testFailedTurnReleasesStuckCardPin() {
        let f = makeFile(contents: "[Tool call] run_terminal_cmd\n  command: mvn test\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "失败的会话")
        w.calibrate(now: Date())
        w.markAwaitingConfirm(source: "CatPaw")
        let notifyCount = captured.count

        releaseCardPin(w, turnStatus: "failed")
        XCTAssertFalse(w.awaitingExternal)
        XCTAssertEqual(w.state, .error)
        XCTAssertEqual(captured.count, notifyCount)
    }

    /// 决策边界：未钉住不处理；后台命令/已收尾/仍在推进不解除；unknown 保守判定
    func testCancelledTurnReleasesPinDecisionMatrix() {
        XCTAssertFalse(cancelledTurnReleasesPin(
            awaiting: false, tail: .pendingToolCall(background: false),
            toolActivity: false, complete: false))
        XCTAssertFalse(cancelledTurnReleasesPin(
            awaiting: true, tail: .pendingToolCall(background: true),
            toolActivity: false, complete: false))
        XCTAssertFalse(cancelledTurnReleasesPin(
            awaiting: true, tail: .complete, toolActivity: false, complete: true))
        XCTAssertFalse(cancelledTurnReleasesPin(
            awaiting: true, tail: .working, toolActivity: false, complete: false))
        XCTAssertTrue(cancelledTurnReleasesPin(
            awaiting: true, tail: .unknown, toolActivity: false, complete: false))
        XCTAssertFalse(cancelledTurnReleasesPin(
            awaiting: true, tail: .unknown, toolActivity: true, complete: false))
        XCTAssertFalse(cancelledTurnReleasesPin(
            awaiting: true, tail: .unknown, toolActivity: false, complete: true))
    }

    /// 回归（v0.10.16）：高风险拦截卡片（命令命中系统黑名单，如含 rm 的 git mv）——
    /// IDE 展示确认卡片期间 [Tool call] 不落 transcript，尾部永久停在上一轮
    /// [Tool result]（ideaTailState == .working），此前 deliverTabTurnsIfAny 对该分支
    /// 直接丢弃，卡片完全不提示。修复后：回合 completed 且无后续 running + 无工具活动
    /// + 已过落定时间 → 按确认卡片标记并通知；用户确认后 transcript 增长解除钉住
    func testBlockedCommandCardDetectedFromWorkingTail() {
        // 尾部停在上一轮 [Tool result]：被拦截的 git mv 不落 [Tool call]
        let f = makeFile(contents: "[Tool call] run_terminal_cmd\n  command: javac Stub.java\n\n[Tool result] run_terminal_cmd\nOK\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "高风险拦截")
        let t0 = Date()
        w.calibrate(now: t0)
        w.poll(now: t0)
        XCTAssertEqual(w.ideaTailState(), .working)

        // 决策矩阵：有工具活动（自动批准的长命令仍在跑）或未过落定时间 → 不按卡片
        XCTAssertFalse(workingTailTurnIsCard(toolActivity: true, settled: true))
        XCTAssertFalse(workingTailTurnIsCard(toolActivity: true, settled: false))
        XCTAssertFalse(workingTailTurnIsCard(toolActivity: false, settled: false))
        XCTAssertTrue(workingTailTurnIsCard(toolActivity: false, settled: true))

        // .working 分支落定后的动作：标记等待确认并通知
        let notifyCount = captured.count
        w.markAwaitingConfirm(source: "CatPaw")
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, notifyCount + 1)
        XCTAssertTrue(captured.last?.title.contains("等待手动确认") ?? false)

        // 悬置期间 transcript 零增长：钉住保持，不被状态机覆盖
        w.poll(now: t0.addingTimeInterval(60))
        XCTAssertEqual(w.state, .awaitingConfirm)

        // 用户点了「执行命令」：[Tool call] + [Tool result] 落盘 → 解除钉住回到执行中
        append("\n[Tool call] run_terminal_cmd\n  command: git mv trace/A.java remote/A.java\n\n[Tool result] run_terminal_cmd\ndone\n", to: f)
        w.poll(now: t0.addingTimeInterval(61))
        XCTAssertFalse(w.awaitingExternal)
        XCTAssertEqual(w.state, .running)
    }

    /// 尾部状态机：确认卡片（未完成 [Tool call]）与长思考轮次（[Tool result]/[Thinking] 收尾）
    /// 在文件信号上同构（都静默），靠尾部结构判别——v0.8.0 取代 240s 宽限的核心
    func testIdeaTailState() {
        // 确认卡片：尾部停在未完成的前台 [Tool call]
        let card = makeFile("card.txt", contents: "assistant:\n我来删这个文件\n\n[Tool call] delete_file\n  target_file: /tmp/a.md\n")
        let wCard = SessionWatch(kind: .ideaTranscript, url: card, label: "card")
        XCTAssertEqual(wCard.ideaTailState(), .pendingToolCall(background: false))

        // 后台命令悬置：无需确认，不算卡片
        let bg = makeFile("bg.txt", contents: "[Tool call] run_terminal_cmd\n  command: mvn test\n  is_background: true\n")
        let wBg = SessionWatch(kind: .ideaTranscript, url: bg, label: "bg")
        XCTAssertEqual(wBg.ideaTailState(), .pendingToolCall(background: true))

        // 长思考轮次：尾部是 [Tool result]（模型拿到结果后继续推理，期间零写入）
        let thinking = makeFile("thinking.txt", contents: "[Tool call] grep\n\n[Tool result] grep\n")
        let wThinking = SessionWatch(kind: .ideaTranscript, url: thinking, label: "thinking")
        XCTAssertEqual(wThinking.ideaTailState(), .working)

        // 尾部是 [Thinking] 标记 → 仍在推进
        let thinking2 = makeFile("thinking2.txt", contents: "assistant:\n先看看\n\n[Thinking] 分析一下现状\n")
        let wThinking2 = SessionWatch(kind: .ideaTranscript, url: thinking2, label: "thinking2")
        XCTAssertEqual(wThinking2.ideaTailState(), .working)

        // assistant 空段落（回复刚开始）→ working 而非 complete
        let emptyReply = makeFile("empty.txt", contents: "[Tool result] grep\n\nassistant:\n")
        let wEmpty = SessionWatch(kind: .ideaTranscript, url: emptyReply, label: "empty")
        XCTAssertEqual(wEmpty.ideaTailState(), .working)

        // 最终回复收尾 → 正常结束
        let done = makeFile("done.txt", contents: "[Tool result] read_file\n\nassistant:\n搞定了\n")
        let wDone = SessionWatch(kind: .ideaTranscript, url: done, label: "done")
        XCTAssertEqual(wDone.ideaTailState(), .complete)

        // 文件不可读 → unknown
        let missing = SessionWatch(kind: .ideaTranscript,
                                   url: tmpDir.appendingPathComponent("nope.txt"), label: "missing")
        XCTAssertEqual(missing.ideaTailState(), .unknown)
    }

    /// 工具执行区活动：agent-tools/terminals 在指定时间后有写入 → 工具执行中，非确认卡片
    func testHasToolActivity() throws {
        let sessionDir = tmpDir.appendingPathComponent("session-1")
        let toolsDir = sessionDir.appendingPathComponent("agent-tools")
        try FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        let transcript = makeFile("t.txt", contents: "[Tool call] run_terminal_cmd\n  command: mvn package\n  is_background: false\n")
        let w = SessionWatch(kind: .ideaTranscript, url: transcript, label: "t", sessionDir: sessionDir)

        // 无工具日志 → 无活动
        XCTAssertFalse(w.hasToolActivity(after: Date().addingTimeInterval(-60)))

        // 工具日志在回合结束后写入 → 有活动（前台命令执行中）
        let shellLog = toolsDir.appendingPathComponent("shell-1.log")
        FileManager.default.createFile(atPath: shellLog.path, contents: "BUILDING".data(using: .utf8))
        XCTAssertTrue(w.hasToolActivity(after: Date().addingTimeInterval(-60)))
        // 但在未来时间点之后无活动
        XCTAssertFalse(w.hasToolActivity(after: Date().addingTimeInterval(60)))
    }

    /// 启动回填：calibrate 即重建日志中近期的回合（覆盖应用启动前停下的确认卡片），
    /// 超出评估窗口的旧事件不回填
    func testIdeaLogTrackerBackfill() throws {
        let ideDir = tmpDir.appendingPathComponent("IntelliJIdea2025.3")
        try FileManager.default.createDirectory(at: ideDir, withIntermediateDirectories: true)
        let log = ideDir.appendingPathComponent("idea.log")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        func ts(_ ago: TimeInterval) -> String { fmt.string(from: Date().addingTimeInterval(-ago)) }
        // 旧回合（超出窗口）+ 近期回合（窗口内）
        let content = "\(ts(5 * 3600)) [1]   INFO - x - Tab状态已更新，ID: old00000-0000-0000-0000-000000000000, Status: running\n"
            + "\(ts(5 * 3600 - 5)) [2]   INFO - x - Tab状态已更新，ID: old00000-0000-0000-0000-000000000000, Status: completed\n"
            + "\(ts(120)) [3]   INFO - x - Tab状态已更新，ID: b61fc7f0-c52e-4141-9bb7-0aa549838aad, Status: running\n"
            + "\(ts(60)) [4]   INFO - x - Tab状态已更新，ID: b61fc7f0-c52e-4141-9bb7-0aa549838aad, Status: completed\n"
        FileManager.default.createFile(atPath: log.path, contents: content.data(using: .utf8))
        let tracker = IdeaLogTracker(logsRoot: tmpDir)
        tracker.calibrate()
        let turns = tracker.takeFinishedTurns()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].tabId, "b61fc7f0-c52e-4141-9bb7-0aa549838aad")
        XCTAssertEqual(turns[0].status, "completed")
        // 回填后增量 poll 不重复产出
        tracker.poll()
        XCTAssertTrue(tracker.takeFinishedTurns().isEmpty)
    }

    /// clearAwaiting：解除悬置并重新武装（下次悬置可再提醒）
    func testClearAwaitingRearms() {
        let f = makeFile(contents: "\nassistant:\n你好\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "t")
        w.calibrate()
        w.markAwaitingConfirm(source: "CatPaw")
        XCTAssertEqual(captured.count, 1)
        w.clearAwaiting()
        XCTAssertFalse(w.awaitingExternal)
        w.markAwaitingConfirm(source: "CatPaw")
        XCTAssertEqual(captured.count, 2)
    }

    /// 悬置期间目录级 mtime 噪声不解除，文件内容真正增长才解除
    func testAwaitingUnpinsOnlyOnContentGrowth() {
        let f = makeFile(contents: "[Tool result] read_file\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "t")
        let t0 = Date()
        w.calibrate(now: t0)
        w.poll(now: t0)
        w.markAwaitingConfirm(source: "CatPaw")
        XCTAssertEqual(w.state, .awaitingConfirm)

        // 仅 touch（大小不变）→ 保持悬置
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: f.path)
        w.poll(now: t0.addingTimeInterval(10))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertTrue(w.awaitingExternal)

        // 内容增长 → 解除并回到执行中（显式推进 mtime，避免与上面的 touch 时序冲突）
        append("\nassistant:\n已删除\n", to: f)
        try! FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: f.path)
        w.poll(now: t0.addingTimeInterval(11))
        XCTAssertFalse(w.awaitingExternal)
        XCTAssertEqual(w.state, .running)
    }

    /// 外部悬置标记：压住状态机不翻回已完成，活动后自动解除并恢复正常判定
    func testAwaitingExternalBlocksStateMachine() {
        let f = makeFile(contents: "\nassistant:\n你好，我在。\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "会话", title: "删除文件")
        let t0 = Date()
        w.calibrate(now: t0)
        // 收敛为 done（静默）
        w.poll(now: t0.addingTimeInterval(Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)

        // 外部信号：停在确认卡片 → 状态变更 + 一次提醒
        w.markAwaitingConfirm(source: "CatPaw")
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("等待手动确认"))
        XCTAssertEqual(captured[0].sound, "DogBark")

        // 长时间静默：不被状态机翻回 done，也不重复提醒
        w.poll(now: t0.addingTimeInterval(3600))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)

        // 用户确认后 transcript 出现新写入 → 解除悬置，恢复正常流程
        append("\nassistant:\n已删除。\n", to: f)
        w.poll(now: t0.addingTimeInterval(3601))
        XCTAssertEqual(w.state, .running)
        w.poll(now: t0.addingTimeInterval(3601 + Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 2) // done 通知重新武装后补发
        XCTAssertTrue(captured[1].title.contains("任务完成"))
    }

    // MARK: CatDesk app 日志确认事件

    func testParseDeskAppLogConversationId() {
        let line = "2026-09-24 11:09:49.766 huafengdeMacBook-Pro.local com.sankuai.mcopilot.cli [INFO] main tool-orchestrator #XMDT#{__traceId__=abc __spanId__=0 conversationId=9f3d5a51-e1d1-40d8-88d5-2863f3cc3ef5 permissionMode=unsafeBypassPermissions}#XMDT# #XMDJ#{\"tools\":[]}#XMDJ# 发现需要确认的工具调用"
        XCTAssertEqual(parseDeskAppLogConversationId(line), "9f3d5a51-e1d1-40d8-88d5-2863f3cc3ef5")
        XCTAssertNil(parseDeskAppLogConversationId("没有会话 id 的行"))
    }

    /// app.N.log 增量追踪：校准后新出现的确认事件被捕获
    func testDeskAppLogTracker() throws {
        let log = tmpDir.appendingPathComponent("app.3.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tracker = DeskAppLogTracker(logsDir: tmpDir)
        tracker.calibrate()

        append("2026-10-10 19:41:24.336 host cli [INFO] main tool-orchestrator #XMDT#{conversationId=9f3d5a51-e1d1-40d8-88d5-2863f3cc3ef5}#XMDT# #XMDJ#{}#XMDJ# 发现需要确认的工具调用\n", to: log)
        tracker.poll()
        let pcs = tracker.takePendingConfirms()
        XCTAssertEqual(pcs.count, 1)
        XCTAssertEqual(pcs[0].conversationId, "9f3d5a51-e1d1-40d8-88d5-2863f3cc3ef5")
        XCTAssertTrue(tracker.takePendingConfirms().isEmpty)
    }

    /// 提问卡（AskQuestion）悬置：app 日志 interaction_pending 元数据即时捕获（v0.10.30）
    func testDeskAppLogInteractionPending() throws {
        let log = tmpDir.appendingPathComponent("app.5.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tracker = DeskAppLogTracker(logsDir: tmpDir)
        tracker.calibrate()

        append("2026-10-21 10:52:24.282 host cli [DEBUG] main agent #XMDT#{__traceId__=x __spanId__=0 conversationId=43df8f2d-e2bc-4bf3-818b-a01bd5eae201 turn=1 status=interaction_pending}#XMDT# [Agent] turn execution completed\n", to: log)
        append("2026-10-21 10:52:24.545 host cli [DEBUG] main agent #XMDT#{__traceId__=x __spanId__=0 conversationId=43df8f2d-e2bc-4bf3-818b-a01bd5eae201 exitReason=interaction_pending totalTurns=1}#XMDT# [Agent] end\n", to: log)
        tracker.poll()
        let evts = tracker.takePendingInteractions()
        XCTAssertEqual(evts.count, 2)
        XCTAssertEqual(evts[0].conversationId, "43df8f2d-e2bc-4bf3-818b-a01bd5eae201")
        XCTAssertTrue(tracker.takePendingConfirms().isEmpty)
    }

    /// 用户手动停止：reason=user_stop / status=canceled 元数据捕获（v0.10.30）
    func testDeskAppLogUserStop() throws {
        let log = tmpDir.appendingPathComponent("app.5.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tracker = DeskAppLogTracker(logsDir: tmpDir)
        tracker.calibrate()

        append("2026-10-21 11:08:45.284 host cli [INFO] main turn-executor #XMDT#{__traceId__=x __spanId__=0 conversationId=aaa9244a-0a46-4b09-8d1f-69ebfed6f382 turn=17 reason=user_stop}#XMDT# [Turn] aborted during tool execution\n", to: log)
        append("2026-10-21 11:08:45.286 host cli [INFO] main agent-lifecycle #XMDT#{__traceId__=x __spanId__=0 conversationId=aaa9244a-0a46-4b09-8d1f-69ebfed6f382 status=canceled hasContext=true}#XMDT# [reportStatus] reporting conversation status to server\n", to: log)
        tracker.poll()
        let stops = tracker.takePendingStops()
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops[0].conversationId, "aaa9244a-0a46-4b09-8d1f-69ebfed6f382")
    }

    /// 手动停止解除确认悬置并落「已停止」；残留的 .done 流信号不得把状态翻回（v0.10.30 回归：
    /// 用户在确认卡片上终止会话，jsonl 尾部永久停在未完成的 bash 调用，
    /// status 字典残留的 success close 每轮重放，不闩住会永远挂「等待确认」）
    func testDeskUserStopReleasesConfirmAndLatches() {
        let f = makeFile("stop.jsonl", contents:
            deskEvent(type: "user", contentTypes: [("text", "干活")])
            + deskEvent(type: "assistant", contentTypes: [("tool_use", "")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "s", conversationId: "c9")
        let t0 = Date()
        w.calibrate(now: t0)
        w.poll(deskSignal: .running)
        w.markAwaitingConfirm(source: "CatDesk")
        XCTAssertEqual(w.state, .awaitingConfirm)
        let notifyCount = captured.count

        w.markUserStopped(source: "CatDesk")
        XCTAssertEqual(w.state, .stopped)
        XCTAssertFalse(w.awaitingExternal)
        XCTAssertEqual(captured.count, notifyCount) // 停止不补发通知

        // 残留的旧 .done 信号重放：仍保持已停止
        w.poll(deskSignal: .done)
        XCTAssertEqual(w.state, .stopped)

        // 用户继续提问：新流打开 → 解除门闩恢复监控
        w.poll(deskSignal: .running)
        XCTAssertEqual(w.state, .running)
        XCTAssertFalse(w.userStopped)
    }

    /// 带内兜底：jsonl 末帧停在 AskQuestion 工具调用 → 判定悬置待确认（v0.10.30）
    func testDeskPendingQuestionInBand() {
        let f = makeFile("q.jsonl", contents:
            deskEvent(type: "user", contentTypes: [("text", "问个问题")])
            + #"{"type":"assistant","message":{"content":[{"type":"tool_use","toolName":"AskQuestion","toolParams":"{}"}]}}"# + "\n")
        let w = SessionWatch(kind: .deskConversation, url: f, label: "q", conversationId: "cq")
        XCTAssertTrue(w.deskAwaitingConfirmation(now: Date().addingTimeInterval(Config.awaitConfirmThreshold + 1)))
        XCTAssertFalse(w.deskAwaitingConfirmation(now: Date()))
    }

    // MARK: 会话手动改名

    /// 手动改名：设置/持久化/重载/清除 全链路
    func testCustomTitleStore() throws {
        let url = tmpDir.appendingPathComponent("sub/custom-titles.json")
        let store = CustomTitleStore(url: url)
        let key = "/Users/x/.catpaw/projects/p/9e757345-5e3a/agent-transcripts/t.txt"

        store.set("blade接入与health", for: key)
        XCTAssertEqual(store.title(for: key), "blade接入与health")

        // 重载（模拟重启）后仍在
        let reloaded = CustomTitleStore(url: url)
        XCTAssertEqual(reloaded.title(for: key), "blade接入与health")

        // 空白 = 清除
        reloaded.set("   ", for: key)
        XCTAssertNil(reloaded.title(for: key))
        let again = CustomTitleStore(url: url)
        XCTAssertNil(again.title(for: key))
    }

    // MARK: 会话时间列

    /// 时间列：今天只显示时分秒；非今天带日期；跨年带年份
    func testSessionRowFormatTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let now = f.date(from: "2026-10-12 18:00:00")!
        // 今天 → HH:mm:ss
        XCTAssertEqual(SessionRow.formatTime(f.date(from: "2026-10-12 09:05:31")!, now: now, calendar: cal), "09:05:31")
        // 同年非今天 → MM-dd HH:mm
        XCTAssertEqual(SessionRow.formatTime(f.date(from: "2026-10-09 10:35:18")!, now: now, calendar: cal), "10-09 10:35")
        // 跨年 → yyyy-MM-dd HH:mm
        XCTAssertEqual(SessionRow.formatTime(f.date(from: "2025-12-31 23:59:00")!, now: now, calendar: cal), "2025-12-31 23:59")
    }

    // MARK: CatDesk 服务端会话标题

    /// 列表响应解析：提取 conversationId → 标题映射；空标题跳过；业务失败返回 nil
    func testDeskTitleParsing() {
        let json = """
        {"unifyCode":0,"code":0,"msg":"成功","data":{"total":3,"list":[
          {"conversationId":"3837db81-3476-4597-9a77-3512cc3fcce3","source":"CatPawDesk","title":"开发 Mac 办公工具：监控 CatPaw 插件会话状态","status":"running"},
          {"conversationId":"e5ae4b7f-c9c6-478a-b69a-ad44ada1f722","title":"  ","status":"completed"},
          {"conversationId":"d6f0dd8d-7f96-4e7b-84f5-f4891e2841cc","title":"会话经验沉淀巡检","status":"completed"}
        ]}}
        """
        let r = DeskTitleFetcher.parseTitles(from: Data(json.utf8))
        XCTAssertEqual(r?.total, 3)
        XCTAssertEqual(r?.titles.count, 2) // 空白标题被跳过
        XCTAssertEqual(r?.titles["3837db81-3476-4597-9a77-3512cc3fcce3"], "开发 Mac 办公工具：监控 CatPaw 插件会话状态")
        XCTAssertNil(r?.titles["e5ae4b7f-c9c6-478a-b69a-ad44ada1f722"])

        // 业务失败（如 ssoid 过期）→ nil
        let bad = Data(#"{"unifyCode":1004010001,"code":401,"msg":"未登录","success":false}"#.utf8)
        XCTAssertNil(DeskTitleFetcher.parseTitles(from: bad))
        XCTAssertNil(DeskTitleFetcher.parseTitles(from: Data("not json".utf8)))
    }

    /// ssoid 读取：解析 sso_config.json；文件缺失/字段缺失返回 nil
    func testReadSSOID() throws {
        let f = tmpDir.appendingPathComponent("sso_config.json")
        try #"{"ssoid":"AT_prod**abc**def","misId":"tester"}"#.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(DeskTitleFetcher.readSSOID(url: f), "AT_prod**abc**def")

        try #"{"misId":"tester"}"#.write(to: f, atomically: true, encoding: .utf8)
        XCTAssertNil(DeskTitleFetcher.readSSOID(url: f))
        XCTAssertNil(DeskTitleFetcher.readSSOID(url: tmpDir.appendingPathComponent("nope.json")))
    }

    /// 回归：多个 app.N.log 并行写入（多进程）时按文件独立尾随，
    /// 旧文件重新变「最新」不会重读历史导致旧确认事件重复告警
    /// （2026-10-12 19:42 真实事故：app.3↔app.4 跳动重读 21MB 历史，重发 9-24/10-10 旧事件）
    func testDeskAppLogMultiFileNoHistoryReplay() throws {
        // app.3.log 带一条历史确认事件（旧进程还在写）；app.4.log 是新进程的活跃文件
        let log3 = tmpDir.appendingPathComponent("app.3.log")
        let log4 = tmpDir.appendingPathComponent("app.4.log")
        FileManager.default.createFile(atPath: log3.path, contents:
            Data("2026-09-24 11:09:49.766 host cli [INFO] main tool-orchestrator #XMDT#{conversationId=9f3d5a51-e1d1-40d8-88d5-2863f3cc3ef5}#XMDT# #XMDJ#{}#XMDJ# 发现需要确认的工具调用\n".utf8))
        FileManager.default.createFile(atPath: log4.path, contents: Data())

        let tracker = DeskAppLogTracker(logsDir: tmpDir)
        tracker.calibrate() // 对齐到所有文件末尾

        // app.4 有新增（变成最新）→ 不应重放 app.3 的历史事件
        append("2026-10-12 19:42:00.000 host cli [INFO] main x 普通日志\n", to: log4)
        tracker.poll()
        XCTAssertTrue(tracker.takePendingConfirms().isEmpty)

        // app.3 又有新增（重新变成最新，旧逻辑的「换文件」触发点）→ 仍不应重放历史
        append("2026-10-12 19:42:30.000 host cli [INFO] main x 普通日志\n", to: log3)
        tracker.poll()
        XCTAssertTrue(tracker.takePendingConfirms().isEmpty)

        // 两个文件的新事件都要能捕获
        append("2026-10-12 19:43:00.000 host cli [INFO] main tool-orchestrator #XMDT#{conversationId=aaaaaaaa-1111-2222-3333-444444444444}#XMDT# #XMDJ#{}#XMDJ# 发现需要确认的工具调用\n", to: log3)
        append("2026-10-12 19:43:01.000 host cli [INFO] main tool-orchestrator #XMDT#{conversationId=bbbbbbbb-1111-2222-3333-444444444444}#XMDT# #XMDJ#{}#XMDJ# 发现需要确认的工具调用\n", to: log4)
        tracker.poll()
        let pcs = tracker.takePendingConfirms()
        XCTAssertEqual(pcs.count, 2)
        XCTAssertTrue(pcs.contains { $0.conversationId == "aaaaaaaa-1111-2222-3333-444444444444" })
        XCTAssertTrue(pcs.contains { $0.conversationId == "bbbbbbbb-1111-2222-3333-444444444444" })
    }

    /// 回归：Assistant 回复正文（turn-executor 记录）里引用这句话不算确认事件
    /// （2026-10-12 11:13 真实事故：解释监控机制的回复文本含「发现需要确认的工具调用」，
    /// 被误匹配导致会话钉死在等待手动确认）
    func testDeskAppLogIgnoresAssistantQuote() throws {
        let log = tmpDir.appendingPathComponent("app.3.log")
        FileManager.default.createFile(atPath: log.path, contents: Data())
        let tracker = DeskAppLogTracker(logsDir: tmpDir)
        tracker.calibrate()

        // turn-executor 记录的 Assistant 文本，正文引用了确认事件原话 → 不应命中
        append("2026-10-12 11:13:15.198 host cli [INFO] main turn-executor #XMDT#{conversationId=3837db81-3476-4597-9a77-3512cc3fcce3 turn=1}#XMDT# #XMDJ#{\"toolCalls\":[]}#XMDJ# Assistant: 第四路是 app.N.log，专抓「发现需要确认的工具调用」这种提案时事件\n", to: log)
        // 真实的 tool-orchestrator 事件 → 应命中
        append("2026-10-12 11:20:00.000 host cli [INFO] main tool-orchestrator #XMDT#{conversationId=3837db81-3476-4597-9a77-3512cc3fcce3 permissionMode=unsafeBypassPermissions}#XMDT# #XMDJ#{\"tools\":[{\"name\":\"delete_file\"}]}#XMDJ# 发现需要确认的工具调用\n", to: log)
        tracker.poll()

        let pcs = tracker.takePendingConfirms()
        XCTAssertEqual(pcs.count, 1)
        XCTAssertEqual(pcs[0].conversationId, "3837db81-3476-4597-9a77-3512cc3fcce3")
    }

    /// CatDesk 悬置期间流信号不覆盖等待确认状态
    func testDeskAwaitingExternalBlocksSignal() {
        let f = makeFile("conv.jsonl", contents: deskEvent(type: "user", contentTypes: [("text", "你好")]))
        let w = SessionWatch(kind: .deskConversation, url: f, label: "CatDesk", conversationId: "c1")
        w.calibrate(now: Date())
        w.poll(deskSignal: .running)

        w.markAwaitingConfirm(source: "CatDesk")
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)

        // 流 done 信号到达也不覆盖（确认悬置时 jsonl 末帧非最终回复，本就会视为运行间歇）
        w.poll(deskSignal: .done)
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)

        // 用户确认后 jsonl 写入 → 解除
        append(deskEvent(type: "tool", contentTypes: [("text", "result")]), to: f)
        w.poll(deskSignal: .running)
        XCTAssertEqual(w.state, .running)
    }

    // MARK: Dock 图标状态角标

    func testDockCompletedCounterAccumulates() {
        DockStatus.resetForTesting()
        let t0 = Date()
        DockStatus.noteCompleted(now: t0)
        DockStatus.noteCompleted(now: t0.addingTimeInterval(1))
        XCTAssertEqual(DockStatus.completedUnack, 2)
        XCTAssertEqual(DockStatus.effectiveDone(now: t0.addingTimeInterval(2)), 2)
    }

    /// 会话进入 done → 自动累计未读；重复赋值不重复累计
    func testDockCompletedCounterFromStateTransition() {
        DockStatus.resetForTesting()
        let f = makeFile(contents: "assistant: 完成\n")
        let w = SessionWatch(kind: .ideaTranscript, url: f, label: "t")
        w.state = .done
        w.state = .done
        XCTAssertEqual(DockStatus.completedUnack, 1)
        w.state = .running
        w.state = .done
        XCTAssertEqual(DockStatus.completedUnack, 2)
        DockStatus.resetForTesting()
    }

    /// 激活应用（acknowledge）→ 未读清零
    func testDockAcknowledgeClearsUnread() {
        DockStatus.resetForTesting()
        DockStatus.noteCompleted()
        DockStatus.noteCompleted()
        XCTAssertEqual(DockStatus.completedUnack, 2)
        DockStatus.acknowledge()
        XCTAssertEqual(DockStatus.completedUnack, 0)
        XCTAssertEqual(DockStatus.effectiveDone(), 0)
    }

    /// 超过过期时间未查看 → 自动清零
    func testDockUnreadExpires() {
        DockStatus.resetForTesting()
        let t0 = Date()
        DockStatus.noteCompleted(now: t0)
        XCTAssertEqual(DockStatus.effectiveDone(now: t0.addingTimeInterval(DockStatus.doneExpire - 10)), 1)
        XCTAssertEqual(DockStatus.effectiveDone(now: t0.addingTimeInterval(DockStatus.doneExpire + 10)), 0)
        XCTAssertEqual(DockStatus.completedUnack, 0)
    }

    /// 状态条带绘制：有数据时产出非空图像
    func testDockImageRendering() {
        let img = DockStatus.makeImage(running: 2, awaiting: 1, done: 2, size: NSSize(width: 128, height: 128))
        XCTAssertEqual(img.size, NSSize(width: 128, height: 128))
        XCTAssertFalse(img.representations.isEmpty)
    }

    // MARK: Codex 监控

    private func codexLine(_ payloadType: String, extra: String = "") -> String {
        #"{"timestamp":"2026-10-13T09:00:00Z","type":"event_msg","payload":{"type":""# + payloadType + extra + "\"}}\n"
    }

    private func codexToolCall(_ output: Bool, name: String = "shell") -> String {
        let t = output ? "custom_tool_call_output" : "custom_tool_call"
        return #"{"timestamp":"2026-10-13T09:00:01Z","type":"response_item","payload":{"type":""# + t + "\",\"name\":\"" + name + "\"}}\n"
    }

    /// 尾部状态：task_complete 收尾 → done；task_started 未完结 → running；
    /// 悬置工具调用 → pendingTool；output 落盘解除 pending
    func testCodexTailState() {
        let f = makeFile("rollout.jsonl", contents: codexLine("task_started") + codexToolCall(false) + codexToolCall(true) + codexLine("task_complete"))
        let w = SessionWatch(kind: .codexSession, url: f, label: "c")
        XCTAssertEqual(w.codexTailState(), .done)

        let f2 = makeFile("rollout2.jsonl", contents: codexLine("task_complete") + codexLine("task_started"))
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: f2, label: "c").codexTailState(), .running)

        // 悬置工具调用：等待审批或执行中（注意 function_call_output 不得误判为 function_call）
        let f3 = makeFile("rollout3.jsonl", contents: codexLine("task_started") + codexToolCall(false))
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: f3, label: "c").codexTailState(), .pendingTool)

        let f4 = makeFile("rollout4.jsonl", contents: codexLine("task_started") + codexToolCall(false) + codexToolCall(true))
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: f4, label: "c").codexTailState(), .running)
    }

    /// 回合结束通知：running → task_complete → 宽限后提醒一次；历史 idle 会话静默对齐不补发
    func testCodexDoneFlow() {
        let f = makeFile("rollout.jsonl", contents: codexLine("task_started"))
        let w = SessionWatch(kind: .codexSession, url: f, label: "c")
        let t0 = Date()
        w.calibrate(now: t0)
        XCTAssertEqual(w.state, .running)

        append(codexLine("task_complete"), to: f)
        w.poll(now: t0) // 有写入 → running
        w.poll(now: t0.addingTimeInterval(Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("Codex 回合结束"))

        // 历史已完成会话：calibrate 后 idle → 静默对齐 done，不通知
        let old = makeFile("rollout-old.jsonl", contents: codexLine("task_started") + codexLine("task_complete"))
        try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-7200)], ofItemAtPath: old.path)
        let wOld = SessionWatch(kind: .codexSession, url: old, label: "old")
        wOld.calibrate(now: t0)
wOld.poll(now: t0)
XCTAssertEqual(wOld.state, .done)
XCTAssertEqual(captured.count, 1)
}

/// 回归：会话文件被原样重写（内容不变仅刷 mtime，如 Claude Code 周期性会话维护）
/// 不得重新武装通知——否则会对早已结束的回合误报「回合结束」
func testCodexIdenticalRewriteNoNotify() {
let f = makeFile("rollout-rewrite.jsonl", contents: codexLine("task_started"))
let w = SessionWatch(kind: .codexSession, url: f, label: "c")
let t0 = Date()
w.calibrate(now: t0)
append(codexLine("task_complete"), to: f)
w.poll(now: t0)
w.poll(now: t0.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 1)

// 原样重写：逐字节相同、mtime 前进
let same = try! String(contentsOf: f, encoding: .utf8)
try! same.write(to: f, atomically: false, encoding: .utf8)
let t1 = t0.addingTimeInterval(3600)
try! FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: f.path)
w.poll(now: t1)
w.poll(now: t1.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 1) // 没有第二条「回合结束」
}

    /// 悬置工具调用超过阈值 → 等待手动确认
    func testCodexPendingToolAwaiting() {
        let f = makeFile("rollout.jsonl", contents: codexLine("task_started") + codexToolCall(false))
        let w = SessionWatch(kind: .codexSession, url: f, label: "c")
        let t0 = Date()
        w.calibrate(now: t0)
        w.poll(now: t0.addingTimeInterval(Config.awaitConfirmThreshold + 1))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("Codex 等待手动确认"))
    }

    /// 提问卡片：task_complete 收尾但最后一个调用是 request_user_input_async
    /// → awaitingUserInput（output 仅是受理回执，不代表已作答）
    func testCodexAwaitingUserInputState() {
        let card = makeFile("rollout.jsonl", contents:
            codexLine("task_started")
            + codexToolCall(false, name: "request_user_input_async")
            + codexToolCall(true, name: "request_user_input_async")
            + codexLine("task_complete"))
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: card, label: "c").codexTailState(), .awaitingUserInput)

        // 普通调用 + task_complete 仍是 done
        let normal = makeFile("rollout2.jsonl", contents:
            codexLine("task_started") + codexToolCall(false) + codexToolCall(true) + codexLine("task_complete"))
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: normal, label: "c").codexTailState(), .done)
    }

    /// 用户作答后：作答回合的 task_started 复位提问标志，回合正常判完成（不再误报等待确认）
    func testCodexQuestionAnsweredCompletes() {
        let answered = makeFile("rollout.jsonl", contents:
            codexLine("task_started")
            + codexToolCall(false, name: "request_user_input_async")
            + codexToolCall(true, name: "request_user_input_async")
            + codexLine("task_complete")              // 卡片悬置
            + codexLine("task_started")               // 用户作答开启新回合
            + #"{"timestamp":"2026-10-13T09:01:00Z","type":"response_item","payload":{"type":"message","content":[{"type":"output_text","text":"已取消，文件未删除。"}]}}"# + "\n"
            + codexLine("task_complete"))
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: answered, label: "c").codexTailState(), .done)
    }

    /// 提问卡片流程：running → 卡片落地 20s 后提醒等待确认（不再误报回合结束）；
    /// 历史 idle 会话静默对齐为悬置态不补发；用户作答后解除悬置恢复监控
    func testCodexAwaitingUserInputFlow() {
        let f = makeFile("rollout.jsonl", contents: codexLine("task_started"))
        let w = SessionWatch(kind: .codexSession, url: f, label: "c")
        let t0 = Date()
        w.calibrate(now: t0)

        append(codexToolCall(false, name: "request_user_input_async")
            + codexToolCall(true, name: "request_user_input_async")
            + codexLine("task_complete"), to: f)
        w.poll(now: t0) // 有写入 → running
        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay + 1))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("等待手动确认"))
        XCTAssertFalse(captured.contains { $0.title.contains("回合结束") })

        // 用户作答：新回合事件落盘 → 解除悬置
        append(codexLine("task_started"), to: f)
        w.poll(now: t0.addingTimeInterval(Config.cardSettleDelay + 2))
        XCTAssertEqual(w.state, .running)

        // 作答回合收尾（message + task_complete）→ 判定回合结束，不再误报等待确认
        captured = []
        append(#"{"timestamp":"2026-10-13T09:01:00Z","type":"response_item","payload":{"type":"message","content":[{"type":"output_text","text":"已取消，文件未删除。"}]}}"# + "\n" + codexLine("task_complete"), to: f)
        let t1 = t0.addingTimeInterval(Config.cardSettleDelay + 3)
        w.poll(now: t1) // 有写入 → running
        w.poll(now: t1.addingTimeInterval(Config.doneGrace + 1))
        XCTAssertEqual(w.state, .done)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("回合结束"))
        XCTAssertFalse(captured.contains { $0.title.contains("等待手动确认") })

        // 近 4 小时内的悬置卡片（重启 app）：回填提醒一次
        captured = []
        let recent = makeFile("rollout-recent.jsonl", contents:
            codexLine("task_started")
            + codexToolCall(false, name: "request_user_input_async")
            + codexToolCall(true, name: "request_user_input_async")
            + codexLine("task_complete"))
        try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-3600)], ofItemAtPath: recent.path)
        let wRecent = SessionWatch(kind: .codexSession, url: recent, label: "recent")
        wRecent.calibrate(now: t0)
        wRecent.poll(now: t0)
        XCTAssertEqual(wRecent.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("等待手动确认"))

        // 超过 4 小时的历史卡片：静默对齐，不补发
        captured = []
        let old = makeFile("rollout-old.jsonl", contents:
            codexLine("task_started")
            + codexToolCall(false, name: "request_user_input_async")
            + codexToolCall(true, name: "request_user_input_async")
            + codexLine("task_complete"))
        try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-(Config.tabTurnEvalWindow + 60))], ofItemAtPath: old.path)
        let wOld = SessionWatch(kind: .codexSession, url: old, label: "old")
        wOld.calibrate(now: t0)
        wOld.poll(now: t0)
        XCTAssertEqual(wOld.state, .awaitingConfirm)
        XCTAssertTrue(captured.isEmpty)
    }

    /// 回归：64KB 窗口起点切断中文字符时，尾部判定不得退化为 unknown
    ///（真实事故：rollout 含大量中文，严格解码失败 → 提问卡片漏判 → 300s stuck 误报）
    func testCodexTailStateUTF8Boundary() {
        let markers = codexLine("task_started")
            + codexToolCall(false, name: "request_user_input_async")
            + codexToolCall(true, name: "request_user_input_async")
            + codexLine("task_complete")
        // 中文 padding 撑过 64KB，并微调长度使窗口起点落在多字节字符中间
        var pad = String(repeating: "中", count: 22000)
        var content = pad + markers
        var tries = 0
        while String(data: Data(content.utf8.suffix(65536)), encoding: .utf8) != nil, tries < 10 {
            pad += "a" // +1 字节平移窗口起点，直至切断字符
            content = pad + markers
            tries += 1
        }
        // 前置条件：严格解码确实失败（窗口起点切断了字符）
        XCTAssertNil(String(data: Data(content.utf8.suffix(65536)), encoding: .utf8))
        let f = makeFile("rollout.jsonl", contents: content)
        XCTAssertEqual(SessionWatch(kind: .codexSession, url: f, label: "c").codexTailState(), .awaitingUserInput)
    }

    /// 索引解析与文件名 uuid 提取
    func testCodexSessionIndexParsing() {
        let text = #"{"id":"01a1340a-2bfa-7270-9cf3-d0105f0e8aed","thread_name":"设计多Agent协作系统","updated_at":"2026-10-13T06:54:17Z"}"# + "\n"
            + #"{"id":"x","thread_name":"","updated_at":"t"}"# + "\n" // 空标题跳过
        let map = parseCodexSessionIndex(text)
        XCTAssertEqual(map["01a1340a-2bfa-7270-9cf3-d0105f0e8aed"], "设计多Agent协作系统")
        XCTAssertNil(map["x"])

        let sid = codexSessionId(fromFile: "rollout-2026-10-13T14-54-06-01a1340a-2bfa-7270-9cf3-d0105f0e8aed.jsonl")
        XCTAssertEqual(sid, "01a1340a-2bfa-7270-9cf3-d0105f0e8aed")
    }

    // MARK: Claude Code 监控

    private func claudeAssistant(_ stop: String?) -> String {
        let stopField = stop.map { #""stop_reason":"\#($0)""# } ?? "null"
        return #"{"type":"assistant","message":{"content":[{"type":"text","text":"好"}],"stop_reason":"# + (stop.map { "\"\($0)\"" } ?? "null") + "}}\n"
    }

    /// 尾部状态：end_turn → finalReply；tool_use → pendingTool；user 在后 → working；
    /// ai-title/last-prompt 等会话事件不影响判定
    func testClaudeTailState() {
        let done = makeFile("c1.jsonl", contents:
            #"{"type":"user","message":{"content":"查个配置"}}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"text","text":"给你"}],"stop_reason":"end_turn"}}"# + "\n"
            + #"{"type":"ai-title","aiTitle":"获取 lion 配置","sessionId":"s1"}"# + "\n")
        XCTAssertEqual(SessionWatch(kind: .claudeSession, url: done, label: "c").claudeTailState(), .finalReply)

        let pending = makeFile("c2.jsonl", contents:
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n")
        XCTAssertEqual(SessionWatch(kind: .claudeSession, url: pending, label: "c").claudeTailState(), .pendingTool)

        let working = makeFile("c3.jsonl", contents:
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n"
            + #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"# + "\n")
XCTAssertEqual(SessionWatch(kind: .claudeSession, url: working, label: "c").claudeTailState(), .working)
}

/// 回归：v2.x 在最终回复后追加的大型 meta 记录（attachment/system 等，
/// 实测一个简单回合就有 ~300KB）会把 end_turn 挤出旧 64KB 窗口，
/// 导致已完成会话误判执行中——大窗口下应正确识别
func testClaudeTailStateLargeMetaRecords() {
let pad = String(repeating: "x", count: 200_000)
let f = makeFile("big.jsonl", contents:
#"{"type":"user","message":{"content":"hi"}}"# + "\n"
+ #"{"type":"assistant","message":{"content":[{"type":"text","text":"你好"}],"stop_reason":"end_turn"}}"# + "\n"
+ #"{"type":"attachment","attachment":{"type":"hook_success","payload":""# + pad + "\"}}\n"
+ #"{"type":"system","subtype":"turn_duration","payload":""# + pad + "\"}}\n"
+ #"{"type":"system","subtype":"away_summary","content":"会话摘要"}"# + "\n")
XCTAssertEqual(SessionWatch(kind: .claudeSession, url: f, label: "c").claudeTailState(), .finalReply)
}

/// 回归：v2.x 有的回合以 tool_use 收尾、之后没有 end_turn（典型：回答了
/// AskUserQuestion 的「取消」后执行长命令），文件以 tool_result + system
/// 记录结尾，旧逻辑恒判 working → 会话永远卡在执行中。
/// turn_duration 是每个回合结束必写的边界记录，应据此判 finalReply
func testClaudeTailStateToolUseTailTurnDuration() {
let f = makeFile("askcancel.jsonl", contents:
#"{"type":"user","message":{"content":"帮我删除文件"}}"# + "\n"
+ #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion"}],"stop_reason":"tool_use"}}"# + "\n"
+ #"{"type":"user","message":{"content":[{"type":"tool_result","content":"取消"}]}}"# + "\n"
+ #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n"
+ #"{"type":"user","message":{"content":[{"type":"tool_result","content":"Brewed for 3m 36s"}]}}"# + "\n"
+ #"{"type":"user","message":{"content":[{"type":"text","text":"ok"}]}}"# + "\n"
+ #"{"type":"system","subtype":"turn_duration","durationMs":216000}"# + "\n"
+ #"{"type":"system","subtype":"away_summary","content":"会话摘要"}"# + "\n")
XCTAssertEqual(SessionWatch(kind: .claudeSession, url: f, label: "c").claudeTailState(), .finalReply)
}

/// 完整流程：tool_use 收尾的回合凭借 turn_duration 收敛到已完成并通知一次
func testClaudeDoneFlowToolUseTail() {
let f = makeFile("c.jsonl", contents:
#"{"type":"user","message":{"content":"干活"}}"# + "\n")
let w = SessionWatch(kind: .claudeSession, url: f, label: "c")
let t0 = Date()
w.calibrate(now: t0)

append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n"
+ #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"# + "\n", to: f)
try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(1)], ofItemAtPath: f.path)
w.poll(now: t0.addingTimeInterval(1))
XCTAssertEqual(w.state, .running)

append(#"{"type":"system","subtype":"turn_duration","durationMs":3600}"# + "\n"
+ #"{"type":"system","subtype":"away_summary","content":"摘要"}"# + "\n", to: f)
try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(2)], ofItemAtPath: f.path)
w.poll(now: t0.addingTimeInterval(2))
w.poll(now: t0.addingTimeInterval(2 + Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 1)
XCTAssertTrue(captured[0].title.contains("Claude 回合结束"))
}

// MARK: 周期兜底深扫

/// 回归：Claude 压缩会话文件后 awaitMarkSize 增长检查永久失效，
/// 悬置钉住无法自愈；兜底深扫看到尾部 turn_duration（回合已结束）应解除钉住并收敛
func testDeepSweepClearsStaleAwaitingClaude() {
let pad = String(repeating: "x", count: 500)
let f = makeFile("c.jsonl", contents:
#"{"type":"user","message":{"content":"干活 \#(pad)"}}"# + "\n"
+ #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n")
let w = SessionWatch(kind: .claudeSession, url: f, label: "c")
let t0 = Date()
w.calibrate(now: t0)

append(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"# + "\n", to: f)
try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(1)], ofItemAtPath: f.path)
w.poll(now: t0.addingTimeInterval(1))
XCTAssertEqual(w.state, .running)

w.markAwaitingConfirm(source: "Claude")
XCTAssertEqual(w.state, .awaitingConfirm)

// 模拟压缩：文件重写变小（尾部已含 turn_duration = 回合结束），大小永远无法超过 awaitMarkSize
try! (#"{"type":"user","message":{"content":"干活"}}"# + "\n"
+ #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n"
+ #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"# + "\n"
+ #"{"type":"system","subtype":"turn_duration","durationMs":3600}"# + "\n")
.write(to: f, atomically: false, encoding: .utf8)
try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(2)], ofItemAtPath: f.path)
w.poll(now: t0.addingTimeInterval(2))
XCTAssertEqual(w.state, .running) // 内容变化（含压缩变小）已经主动解除旧钉住

XCTAssertFalse(w.deepSweep(now: t0.addingTimeInterval(3))) // 无需等待深扫修复
w.poll(now: t0.addingTimeInterval(3))
w.poll(now: t0.addingTimeInterval(3 + Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 2) // 等待手动确认 + 回合结束
XCTAssertTrue(captured.last?.title.contains("Claude 回合结束") == true)
}

/// 悬置钉住但尾部仍是 tool_use（问题未了结）→ 深扫不得误解除
func testDeepSweepKeepsPendingClaude() {
let f = makeFile("c.jsonl", contents:
#"{"type":"user","message":{"content":"干活"}}"# + "\n"
+ #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion"}],"stop_reason":"tool_use"}}"# + "\n")
let w = SessionWatch(kind: .claudeSession, url: f, label: "c")
let t0 = Date()
w.calibrate(now: t0)
w.markAwaitingConfirm(source: "Claude")
XCTAssertEqual(w.state, .awaitingConfirm)
XCTAssertFalse(w.deepSweep(now: t0.addingTimeInterval(60)))
XCTAssertEqual(w.state, .awaitingConfirm)
}

/// 回归：IDEA 会话被 tab-turn 信号钉在「等待手动确认」，用户确认后回合跑完
/// （transcript 尾部以 assistant 最终回复收尾）→ 兜底深扫解除钉住，随后正常收敛
func testDeepSweepClearsAwaitingIdeaWhenTailComplete() {
let f = makeFile(contents: "[Tool call] run_terminal_cmd\n  command: mvn compile\n")
let w = SessionWatch(kind: .ideaTranscript, url: f, label: "IDEA兜底")
let t0 = Date()
w.calibrate(now: t0)
w.poll(now: t0)
w.markAwaitingConfirm(source: "CatPaw")
XCTAssertEqual(w.state, .awaitingConfirm)

// 尾部仍是未完成工具调用：深扫不应解除
XCTAssertFalse(w.deepSweep(now: t0.addingTimeInterval(120)))
XCTAssertTrue(w.awaitingExternal)

// 用户确认后任务跑完：工具结果 + 最终回复落盘
append("[Tool result] run_terminal_cmd\nBUILD SUCCESS\n\nassistant: 编译完成，全部通过。\n", to: f)
XCTAssertTrue(w.deepSweep(now: t0.addingTimeInterval(180)))
XCTAssertFalse(w.awaitingExternal)

// 解除钉住后正常轮询收敛为已完成并通知
let t1 = t0.addingTimeInterval(181)
w.poll(now: t1) // 文件增长重新武装
w.poll(now: t1.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertTrue(captured.contains { $0.title.contains("任务完成") })
}

/// 匿名埋点：deviceId 生成后保持稳定；日期串格式为 yyyy-MM-dd（心跳按自然日去重的依据）
func testTelemetryDeviceIdStableAndDayString() {
    XCTAssertEqual(Telemetry.deviceId, Telemetry.deviceId)
    XCTAssertEqual(Telemetry.deviceId.count, 36) // UUID 格式
    let s = Telemetry.dayString(Date())
    XCTAssertEqual(s.count, 10)
    XCTAssertEqual(s[s.index(s.startIndex, offsetBy: 4)], "-")
}

/// 回归：CatDesk 流 close 信号丢失（app 崩溃/日志轮转），信号恒 running；
/// 兜底深扫按 jsonl 末帧判定回合已结束并收敛通知
/// 检查更新：语义化版本比较
func testUpdateVersionCompare() {
    XCTAssertTrue(UpdateChecker.isNewer("0.0.3", than: "0.0.2"))
    XCTAssertFalse(UpdateChecker.isNewer("0.0.2", than: "0.0.3"))
    XCTAssertTrue(UpdateChecker.isNewer("0.10.20", than: "0.10.19"))
    XCTAssertFalse(UpdateChecker.isNewer("0.10.19", than: "0.10.20"))
    XCTAssertTrue(UpdateChecker.isNewer("0.11.0", than: "0.10.99"))
    XCTAssertFalse(UpdateChecker.isNewer("0.10.19", than: "0.10.19"))
    XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.99.99"))
    XCTAssertFalse(UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
}

@MainActor
func testIndependentReleaseSkipsOriginalUpdateChannel() async {
    let updater = UpdateChecker()
    updater.start()
    updater.check(manual: false)
    XCTAssertFalse(updater.checking)
    XCTAssertNil(updater.latestVersion)
    XCTAssertNil(updater.tip)

    updater.check(manual: true)
    XCTAssertFalse(updater.checking)
    XCTAssertNil(updater.latestVersion)
    XCTAssertTrue(updater.tip?.contains("workAgent") == true)

    updater.performUpdate()
    XCTAssertFalse(updater.updating)
    XCTAssertNil(updater.latestVersion)
    XCTAssertTrue(updater.tip?.contains("workAgent") == true)
}

func testDeepSweepDeskSignalLost() {
let f = makeFile("d.jsonl", contents: deskEvent(type: "user", contentTypes: [("text", "干活")]))
let w = SessionWatch(kind: .deskConversation, url: f, label: "d")
let t0 = Date()
w.calibrate(now: t0)

w.poll(now: t0.addingTimeInterval(1), deskSignal: .running)
XCTAssertEqual(w.state, .running)

// 最终回复落盘，但 stream.close 事件丢失（信号仍是 running）
append(deskEvent(type: "assistant", contentTypes: [("text", "完成了")]), to: f)
try! FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(2)], ofItemAtPath: f.path)
w.poll(now: t0.addingTimeInterval(2), deskSignal: .running)
XCTAssertEqual(w.state, .running)

XCTAssertTrue(w.deepSweep(now: t0.addingTimeInterval(2 + Config.deskDoneGrace + 1)))
XCTAssertEqual(w.state, .done)
XCTAssertTrue(captured.last?.title.contains("CatDesk 回合结束") ?? false)
}

/// 回归：calibrate「假定运行且抑制提醒」的会话若再无动静（如 guardian 子线程
/// 瞬间夭折），状态迁移不能被通知门控挡住——应静默翻成疑似中断而非永远执行中
func testCodexCalibratedStallFlipsStuckSilently() {
let f = makeFile("g.jsonl", contents:
#"{"type":"session_meta","payload":{"id":"x"}}"# + "\n")
let w = SessionWatch(kind: .codexSession, url: f, label: "c")
let t0 = Date()
w.calibrate(now: t0) // 新鲜文件 → 假定运行 + 抑制中断提醒
XCTAssertEqual(w.state, .running)
w.poll(now: t0.addingTimeInterval(Config.stuckThreshold + 1))
XCTAssertEqual(w.state, .stuck)
XCTAssertTrue(captured.isEmpty) // 静默翻转，不补发中断提醒
}

/// 子代理线程（guardian_review 自动审查等）应被识别排除
func testCodexSubagentRolloutDetection() {
let guardian = makeFile("g.jsonl", contents:
#"{"type":"session_meta","payload":{"source":{"subagent":{"other":"guardian"}},"thread_source":"guardian_review"}}"# + "\n")
let normal = makeFile("n.jsonl", contents:
#"{"type":"session_meta","payload":{"source":"cli"}}"# + "\n")
XCTAssertTrue(codexIsSubagentRollout(guardian))
XCTAssertFalse(codexIsSubagentRollout(normal))
}

/// 回合结束通知：running → end_turn → 宽限后提醒一次；历史会话静默对齐
func testClaudeDoneFlow() {
        let f = makeFile("c.jsonl", contents: #"{"type":"user","message":{"content":"干活"}}"# + "\n")
        let w = SessionWatch(kind: .claudeSession, url: f, label: "c")
        let t0 = Date()
        w.calibrate(now: t0)

        append(#"{"type":"assistant","message":{"content":[{"type":"text","text":"完成"}],"stop_reason":"end_turn"}}"# + "\n", to: f)
        w.poll(now: t0)
w.poll(now: t0.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 1)
XCTAssertTrue(captured[0].title.contains("Claude 回合结束"))
}

/// 回归：Claude Code 周期性原样重写会话文件（内容不变仅刷 mtime）不得误报
/// 「回合结束」；真实新回合（内容增长）仍要正常通知
func testClaudeIdenticalRewriteNoNotify() {
let f = makeFile("c.jsonl", contents: #"{"type":"user","message":{"content":"干活"}}"# + "\n")
let w = SessionWatch(kind: .claudeSession, url: f, label: "c")
let t0 = Date()
w.calibrate(now: t0)

append(#"{"type":"assistant","message":{"content":[{"type":"text","text":"完成"}],"stop_reason":"end_turn"}}"# + "\n", to: f)
w.poll(now: t0)
w.poll(now: t0.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 1)

// 原样重写：逐字节相同、mtime 前进（复现 18:35 误报的触发条件）
let same = try! String(contentsOf: f, encoding: .utf8)
try! same.write(to: f, atomically: false, encoding: .utf8)
let t1 = t0.addingTimeInterval(3600)
try! FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: f.path)
w.poll(now: t1)
w.poll(now: t1.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 1) // 没有第二条「回合结束」

// 真实新回合：内容增长 → 重新武装并再次通知
//（显式推进 mtime 到 t1 之后，避免与上面重写阶段的未来 mtime 时序冲突）
append(#"{"type":"user","message":{"content":"再来一轮"}}"# + "\n", to: f)
let t2 = t1.addingTimeInterval(10)
try! FileManager.default.setAttributes([.modificationDate: t2], ofItemAtPath: f.path)
w.poll(now: t2)
append(#"{"type":"assistant","message":{"content":[{"type":"text","text":"好"}],"stop_reason":"end_turn"}}"# + "\n", to: f)
let t3 = t1.addingTimeInterval(20)
try! FileManager.default.setAttributes([.modificationDate: t3], ofItemAtPath: f.path)
w.poll(now: t3)
w.poll(now: t3.addingTimeInterval(Config.doneGrace + 1))
XCTAssertEqual(w.state, .done)
XCTAssertEqual(captured.count, 2)
}

    /// 等待权限：尾部停在 tool_use 超阈值 → 等待手动确认
    func testClaudePendingToolAwaiting() {
        let f = makeFile("c.jsonl", contents:
            #"{"type":"user","message":{"content":"删文件"}}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}],"stop_reason":"tool_use"}}"# + "\n")
        let w = SessionWatch(kind: .claudeSession, url: f, label: "c")
        let t0 = Date()
        w.calibrate(now: t0)
        w.poll(now: t0.addingTimeInterval(Config.awaitConfirmThreshold + 1))
        XCTAssertEqual(w.state, .awaitingConfirm)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured[0].title.contains("Claude 等待手动确认"))
    }

    /// 工作区短名与 ai-title 提取
    func testClaudeLabelAndTitle() {
        XCTAssertEqual(claudeWorkspaceLabel(from: "-Users-maohuafeng-IdeaProjects-health-5"), "health-5")
        XCTAssertEqual(claudeWorkspaceLabel(from: "-Users-maohuafeng-ai-workspace-catpaw-desk"), "catpaw-desk")

        let f = makeFile("c.jsonl", contents:
            #"{"type":"ai-title","aiTitle":"旧标题","sessionId":"s1"}"# + "\n"
            + #"{"type":"assistant","message":{"content":[],"stop_reason":"end_turn"}}"# + "\n"
            + #"{"type":"ai-title","aiTitle":"获取 wechat_cite_clean_patterns 的 lion 配置","sessionId":"s1"}"# + "\n")
        XCTAssertEqual(extractClaudeTitle(from: f), "获取 wechat_cite_clean_patterns 的 lion 配置")

        let none = makeFile("c2.jsonl", contents: #"{"type":"user","message":{"content":"hi"}}"# + "\n")
        XCTAssertNil(extractClaudeTitle(from: none))
    }

    // MARK: MIDE 界面状态库（globalCache.sqlite）

    /// 卡片状态解析：提问卡悬置/已回答、确认卡悬置/已了结、无关中间态
    func testMideCardStateParsing() {
        let asking = #"{"tooluseName":"AskQuestion","status":"asking","streamStatus":"streaming","toolAskStatus":"normal"}"#
        XCTAssertEqual(mideCardState(content: asking),
                       .pending(tool: "AskQuestion", question: true))
        let answered = #"{"tooluseName":"AskQuestion","status":"answered","streamStatus":"completed","toolAskStatus":"tool_execute_success"}"#
        XCTAssertEqual(mideCardState(content: answered), .resolved)
        let confirmPending = #"{"tooluseName":"delete_file","streamStatus":"streaming","toolAskStatus":"normal"}"#
        XCTAssertEqual(mideCardState(content: confirmPending),
                       .pending(tool: "delete_file", question: false))
        let confirmDone = #"{"tooluseName":"delete_file","streamStatus":"completed","toolAskStatus":"tool_execute_rejected"}"#
        XCTAssertEqual(mideCardState(content: confirmDone), .resolved)
        XCTAssertEqual(mideCardState(content: "not json"), .other)
        XCTAssertEqual(mideCardState(content: #"{"tooluseName":"read_file"}"#), .other)
    }

    /// 临时 sqlite 上跑 MideUICacheTracker：悬置 → 识别；了结 → 释放
    func testMideTrackerPollLifecycle() {
        let db = tmpDir.appendingPathComponent("cache.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let ddl = """
        CREATE TABLE t_ui_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL,
            message_id TEXT NOT NULL, message_type TEXT NOT NULL,
            content TEXT DEFAULT NULL, update_time INTEGER DEFAULT 0);
        CREATE TABLE t_conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL UNIQUE,
            title TEXT DEFAULT NULL, mis TEXT DEFAULT '', version TEXT DEFAULT '',
            workspace_id TEXT DEFAULT NULL, ide_type TEXT DEFAULT NULL, update_time INTEGER DEFAULT 0);
        """
        XCTAssertEqual(sqlite3_exec(handle, ddl, nil, nil, nil), SQLITE_OK)
        let cid = "11111111-2222-3333-4444-555555555555"
        let nowMs = Int64(Date().timeIntervalSince1970) * 1000
        let insertConv = """
        INSERT INTO t_conversations (conversation_id, title, ide_type, workspace_id, update_time)
        VALUES ('\(cid)', '测试选项选择', 'MIDE', '/Users/x/proj', \(nowMs));
        """
        XCTAssertEqual(sqlite3_exec(handle, insertConv, nil, nil, nil), SQLITE_OK)
        let pending = #"{"tooluseName":"AskQuestion","status":"asking","streamStatus":"streaming","toolAskStatus":"normal"}"#
        let insertMsg = """
        INSERT INTO t_ui_messages (conversation_id, message_id, message_type, content, update_time)
        VALUES ('\(cid)', 'm1', 'tool', '\(pending)', \(nowMs));
        """
        XCTAssertEqual(sqlite3_exec(handle, insertMsg, nil, nil, nil), SQLITE_OK)

        let tracker = MideUICacheTracker(dbURL: db)
        tracker.calibrate()
        tracker.poll()
        let card = tracker.pendingCards[cid]
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.isQuestion, true)
        XCTAssertEqual(card?.tool, "AskQuestion")
        // 元信息查询
        let meta = tracker.conversationMeta(cid)
        XCTAssertEqual(meta?.title, "测试选项选择")
        XCTAssertEqual(meta?.ideType, "MIDE")
        XCTAssertEqual(meta?.workspace, "/Users/x/proj")

        // 重复轮询不重复产生；了结后移除并进入 resolved
        tracker.poll()
        XCTAssertEqual(tracker.takeResolved(), [])
        let resolved = #"{"tooluseName":"AskQuestion","status":"answered","streamStatus":"completed","toolAskStatus":"tool_execute_success"}"#
        let update = "UPDATE t_ui_messages SET content='\(resolved)', update_time=\(nowMs + 1000) WHERE conversation_id='\(cid)';"
        XCTAssertEqual(sqlite3_exec(handle, update, nil, nil, nil), SQLITE_OK)
        tracker.poll()
        XCTAssertNil(tracker.pendingCards[cid])
        XCTAssertEqual(tracker.takeResolved(), [cid])
    }

    // MARK: Telemetry mis 解析

    /// sso_config.json 的 misId 解析：正常/缺字段/坏文件
    func testMisFromSSOConfig() {
        let good = makeFile("sso.json", contents: #"{"ssoid":"x","misId":"maohuafeng"}"#)
        XCTAssertEqual(Telemetry.misFromSSOConfig(good), "maohuafeng")
        let noKey = makeFile("sso2.json", contents: #"{"ssoid":"x"}"#)
        XCTAssertNil(Telemetry.misFromSSOConfig(noKey))
        let empty = makeFile("sso3.json", contents: #"{"misId":""}"#)
        XCTAssertNil(Telemetry.misFromSSOConfig(empty))
        XCTAssertNil(Telemetry.misFromSSOConfig(tmpDir.appendingPathComponent("nope.json")))
        // 本机账号兜底：开发机上 NSUserName 非空即出值
        XCTAssertNotNil(Telemetry.currentMis())
    }

    // MARK: Codex 额度解析

    /// rate_limits 快照（真实结构）：primary/secondary 窗口与 credits
    func testParseCodexRateLimits() {
        let line = #"{"timestamp":"2026-10-20T16:12:49.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1792501954},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1793088754},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus"}}}"#
        let r = parseCodexRateLimits(line)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.planType, "plus")
        XCTAssertEqual(r?.primaryUsedPercent, 1.0)
        XCTAssertEqual(r?.primaryWindowMinutes, 300)
        XCTAssertEqual(r?.primaryResetsAt, Date(timeIntervalSince1970: 1792501954))
        XCTAssertEqual(r?.secondaryUsedPercent, 0.0)
        XCTAssertEqual(r?.secondaryWindowMinutes, 10080)
        XCTAssertEqual(r?.creditsBalance, "0")
        XCTAssertEqual(r?.snapshotAt?.timeIntervalSince1970, 1792512769.0)
        // 非额度行 / 缺 payload 行
        XCTAssertNil(parseCodexRateLimits(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#))
        XCTAssertNil(parseCodexRateLimits("not json"))
    }

    /// 末尾快照优先（快照随回合追加）
    func testLastCodexRateLimits() {
        let first = #"{"payload":{"rate_limits":{"primary":{"used_percent":10.0}}}}"#
        let second = #"{"payload":{"rate_limits":{"primary":{"used_percent":20.0}}}}"#
        let text = "noise line\n\(first)\nmore noise\n\(second)\n"
        XCTAssertEqual(lastCodexRateLimits(in: text)?.primaryUsedPercent, 20.0)
        XCTAssertNil(lastCodexRateLimits(in: "nothing here"))
    }

    /// 窗口展示名：5 小时 / 本周 / 整小时化 / 兜底
    func testCodexWindowLabel() {
        XCTAssertEqual(CodexRateLimits.windowLabel(minutes: 300), "5 小时")
        XCTAssertEqual(CodexRateLimits.windowLabel(minutes: 10080), "本周")
        XCTAssertEqual(CodexRateLimits.windowLabel(minutes: 120), "2 小时")
        XCTAssertEqual(CodexRateLimits.windowLabel(minutes: 45), "45 分钟")
        XCTAssertEqual(CodexRateLimits.windowLabel(minutes: nil), "额度")
    }

    // MARK: Trae 工作区解析

    /// workspace.json 的 folder/workspace URI → 显示名：取末段、去 .code-workspace 后缀、
    /// 解析失败回退 fallback
    func testTraeWorkspaceNameFromFolderURI() {
        XCTAssertEqual(
            traeWorkspaceName(fromWorkspaceJSON: #"{"folder":"file:///Users/zhb/Desktop/Data"}"#,
                              fallback: "hash"),
            "Data")
        XCTAssertEqual(
            traeWorkspaceName(fromWorkspaceJSON:
                #"{"workspace":"file:///Users/zhb/项目/my.code-workspace"}"#,
                              fallback: "hash"),
            "my")
        XCTAssertEqual(
            traeWorkspaceName(fromWorkspaceJSON: #"{"folder":"not a uri"}"#, fallback: "hash"),
            "hash")
        XCTAssertEqual(
            traeWorkspaceName(fromWorkspaceJSON: "broken", fallback: "hash"),
            "hash")
    }

    // MARK: DeepSeek Harness（dsh）解析

    /// 事件流状态机：回合进行中 / 正常完成 / 异常中断 / 用户停止 / 等待确认
    func testDshTailStateTurnEnds() {
        // 执行中：turn/start 之后没有 turn/end
        let running = """
        {"type":"session","version":3,"id":"s1","cwd":"/Users/zhb/Desktop/tripIDE","delegationDepth":0}
        {"type":"user/message","data":{"content":[{"type":"text","text":"帮我修个bug"}]},"seq":1}
        {"type":"turn/start","data":{"turn":1},"seq":2}
        """
        var t = dshTailState(from: running)
        XCTAssertTrue(t.turnRunning)
        XCTAssertNil(t.turnEnd)
        XCTAssertNil(t.pendingApprovalTool)
        XCTAssertEqual(t.title, "帮我修个bug")
        XCTAssertEqual(t.delegationDepth, 0)

        // 正常完成
        t = dshTailState(from: running + "\n" + #"{"type":"turn/end","data":{"turn":1,"reason":{"kind":"completed"}},"seq":3}"# + "\n")
        XCTAssertFalse(t.turnRunning)
        XCTAssertEqual(t.turnEnd, .completed)

        // 异常中断：携带错误消息
        t = dshTailState(from: running + "\n" + #"{"type":"turn/end","data":{"reason":{"kind":"error","error":{"message":"network timeout","code":"ETIMEDOUT"}}},"seq":3}"# + "\n")
        XCTAssertEqual(t.turnEnd, .error("network timeout"))

        // 用户中止
        t = dshTailState(from: running + "\n" + #"{"type":"turn/end","data":{"reason":{"kind":"aborted","reason":{"kind":"user"}}},"seq":3}"# + "\n")
        XCTAssertEqual(t.turnEnd, .abortedByUser)
    }

    /// 等待手动确认：approval/asked 无对应 decided；决定后解除；
    /// 多次提问取第一个未决项的工具名
    func testDshTailPendingApproval() {
        let text = """
        {"type":"turn/start","data":{"turn":1},"seq":1}
        {"type":"approval/asked","data":{"id":"a1","toolName":"shell","callId":"c1"},"seq":2}
        {"type":"turn/start","data":{"turn":2},"seq":3}
        {"type":"approval/asked","data":{"id":"a2","toolName":"edit_file","callId":"c2"},"seq":4}
        """
        XCTAssertEqual(dshTailState(from: text).pendingApprovalTool, "shell")
        let decided = text + "\n" + #"{"type":"approval/decided","data":{"id":"a1","outcome":"allowed-once"},"seq":5}"# + "\n"
        XCTAssertEqual(dshTailState(from: decided).pendingApprovalTool, "edit_file")
        let allDecided = decided + "\n" + #"{"type":"approval/decided","data":{"id":"a2","outcome":"allowed-once"},"seq":6}"# + "\n"
        XCTAssertNil(dshTailState(from: allDecided).pendingApprovalTool)
    }

    /// 标题取首条 user/message 的 text，剥 XML 上下文块；子代理深度入档
    func testDshTailTitleAndDepth() {
        let text = """
        {"type":"session","delegationDepth":2,"id":"s"}
        {"type":"user/message","data":{"content":[{"type":"text","text":"<context>注入</context>真实提问"}]},"seq":1}
        """
        let t = dshTailState(from: text)
        XCTAssertEqual(t.delegationDepth, 2)
        XCTAssertEqual(t.title, "真实提问")
    }

    /// dsh 工作区目录名 → 可读名：去首尾 -- 壳，Users-<user>- 前缀剥掉
    func testDshWorkspaceLabel() {
        XCTAssertEqual(dshWorkspaceLabel(from: "--Users-zhb-Desktop-tripIDE--"), "Desktop-tripIDE")
        XCTAssertEqual(dshWorkspaceLabel(from: "plain"), workspaceLabel(from: "plain"))
    }

    /// 会话头部 cwd 提取（openDsh 用它打开项目文件夹）
    func testDshSessionCWD() {
        let text = """
        {"type":"session","version":3,"id":"s1","cwd":"/Users/zhb/Desktop/tripIDE","delegationDepth":0}
        {"type":"turn/start","data":{},"seq":1}
        """
        XCTAssertEqual(dshSessionCWD(from: text), "/Users/zhb/Desktop/tripIDE")
        XCTAssertNil(dshSessionCWD(from: "no header"))
    }

    /// zstd 解压往返（用系统 zstd 压一遍样本，解回原文）
    func testZstdDecompressRoundTrip() throws {
        let sample = String(repeating: "dsh event line\n", count: 500)
        let src = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dsh-test-\(UUID().uuidString).zst")
        defer { try? FileManager.default.removeItem(at: src) }
        try sample.write(to: src, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
        proc.arguments = ["-f", "-q", src.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let raw = try? Data(contentsOf: src) else {
            throw XCTSkip("zstd CLI 不可用，跳过解压往返")
        }
        guard let decoded = zstdDecompress(raw) else {
            throw XCTSkip("LibZSTD 未编入构建，跳过解压往返")
        }
        XCTAssertEqual(String(data: decoded, encoding: .utf8), sample)
        // 空输入 / 垃圾输入不崩
        XCTAssertNil(zstdDecompress(Data()))
        XCTAssertNil(zstdDecompress(Data([0x00, 0x01, 0x02, 0x03])))
    }

    // MARK: 桌宠事件分类

    /// 通知标题 → 桌宠事件：与 SessionWatch 各状态机的 Notify.send 文案对应
    func testPetEventClassify() {
        XCTAssertEqual(PetEvent.classify(title: "Claude 回合结束 ✅", context: ["kind": "Claude"]),
                       .celebrate(sessionTitle: "Claude：Claude 回合结束 ✅"))
        XCTAssertEqual(PetEvent.classify(title: "Codex 任务完成 ✅", context: [:]),
                       .celebrate(sessionTitle: "Codex 任务完成 ✅"))
        XCTAssertEqual(PetEvent.classify(title: "CatDesk 会话异常中断 ⛔️", context: [:]),
                       .sad(sessionTitle: "CatDesk 会话异常中断 ⛔️"))
        XCTAssertEqual(PetEvent.classify(title: "DeepSeek 疑似暂停/中断 ⚠️", context: [:]),
                       .confused(sessionTitle: "DeepSeek 疑似暂停/中断 ⚠️"))
        XCTAssertEqual(
            PetEvent.classify(title: "CatPaw 等待手动确认 🟡",
                              context: ["kind": "IDE-CatPaw", "path": "/tmp/t.txt"]),
            .alert(sessionTitle: "IDE-CatPaw：CatPaw 等待手动确认 🟡",
                   kind: "IDE-CatPaw", path: "/tmp/t.txt"))
        XCTAssertEqual(PetEvent.classify(title: "发送测试通知 🐾", context: [:]), .test)
        XCTAssertNil(PetEvent.classify(title: "手动改名：xxx", context: [:]))
    }

    /// 优先级与去重键：高优先级可打断低优先级
    func testPetEventPriorityAndDedupe() {
        XCTAssertTrue(PetEvent.celebrate(sessionTitle: nil).priority
                      > PetEvent.alert(sessionTitle: nil, kind: nil, path: nil).priority)
        XCTAssertTrue(PetEvent.alert(sessionTitle: nil, kind: nil, path: nil).priority
                      > PetEvent.confused(sessionTitle: nil).priority)
        XCTAssertEqual(PetEvent.celebrate(sessionTitle: "a").dedupeKey,
                       PetEvent.celebrate(sessionTitle: "a").dedupeKey)
        XCTAssertNotEqual(PetEvent.sad(sessionTitle: "a").dedupeKey,
                          PetEvent.sad(sessionTitle: "b").dedupeKey)
    }

    /// 大肥鱼白牌文案：事件触发与日常巡航/额度告警切换
    @MainActor
    func testPetSignContent() {
        let m = PetModel()
        // 默认待命玩梗文案
        XCTAssertEqual(m.currentSignContent.header, "已思考 (用时 1 秒)")
        XCTAssertEqual(m.currentSignContent.detail, "我操，我不思考了。")
        XCTAssertFalse(m.currentSignContent.isAlert)

        // 有任务运行中 + 正常额度
        m.activeRunningCount = 2
        m.latestQuotaRemaining = 80
        XCTAssertEqual(m.currentSignContent.header, "思考中 (2 个任务运行中)")
        XCTAssertTrue(m.currentSignContent.detail.contains("额度 80%"))

        // 触发等待手动确认事件（携带 body 具体会话提示）
        let ev = PetEvent.classify(title: "Claude 等待手动确认 🟡",
                                   body: "localAgent 需要确认 Bash 命令",
                                   context: ["kind": "Claude", "path": "/tmp/a.jsonl"])!
        m.react(to: ev)
        XCTAssertEqual(m.currentSignContent.header, "思考中断 (等待确认 🟡)")
        XCTAssertEqual(m.currentSignContent.detail, "localAgent 需要确认 Bash 命令")
        XCTAssertTrue(m.currentSignContent.isAlert)
    }
}
