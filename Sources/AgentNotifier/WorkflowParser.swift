import Foundation

enum WorkflowParser {
    static func parse(_ records: [[String: Any]], source: String, partial: Bool = false) -> WorkflowSnapshot {
        var flow = WorkflowBuilder(partial: partial)
        for (index, object) in records.enumerated() {
            if object["isSidechain"] as? Bool == true { continue }
            let date = eventDate(object["timestamp"])
            let stable = object["uuid"] as? String ?? object["messageId"] as? String
                ?? object["ordinal"].map { String(describing: $0) } ?? stableKey(String(describing: object["timestamp"] ?? "") + ":\(index)")
            advance(object, source: source, id: stable, at: date, flow: &flow)
        }
        return flow.snapshot()
    }

    /// 增量历史复用当前解析语义；调用方负责稳定事件 ID、检查点和数据去重。
    static func advance(_ object: [String: Any], source: String, id: String, at date: Date?, flow: inout WorkflowBuilder) {
        guard object["isSidechain"] as? Bool != true else { return }
        if source == "Codex" {
            codex(object, id: id, at: date, flow: &flow)
        } else if source == "Claude" || source == "CatDesk" {
            conversation(object, id: id, at: date, source: source, flow: &flow)
        }
    }

    private static func codex(_ object: [String: Any], id: String, at date: Date?, flow: inout WorkflowBuilder) {
        let p = object["payload"] as? [String: Any] ?? object
        let type = p["type"] as? String ?? ""
        let turn = p["turn_id"] as? String
        if object["type"] as? String == "turn_context" {
            if let turn, turn != flow.runID { flow.begin(turn, at: nil, explicit: false) }
            return
        }
        if type == "task_started" {
            flow.begin(turn ?? id, at: date, explicit: true)
            return
        }
        if let turn, let current = flow.runID, turn != current { return }
        if ["task_complete", "task_failed", "turn_aborted"].contains(type) {
            flow.finish(at: date, status: type == "task_failed" ? .failed : type == "turn_aborted" ? .interrupted : .returned)
        } else if ["function_call", "custom_tool_call"].contains(type) {
            let call = p["call_id"] as? String ?? p["id"] as? String ?? id
            let name = p["name"] as? String ?? "tool"
            flow.tool(call, name: name, at: date, waiting: isQuestion(name))
            updatePlan(name: name, input: p["arguments"] ?? p["input"], flow: &flow)
        } else if ["function_call_output", "custom_tool_call_output"].contains(type) {
            guard let call = p["call_id"] as? String else { return }
            flow.result(call, name: "工具（起始事件未读到）", at: date, failed: failed(p["output"]), answered: hasAnswers(p["output"]))
        } else if type == "reasoning" {
            flow.add(kind: .model, id: "model:" + (p["id"] as? String ?? id), title: "模型处理", at: date)
        } else if type == "message", p["role"] as? String == "assistant" {
            // 不读取 analysis、reasoning summary 或 encrypted_content。
            if p["channel"] as? String == "commentary" {
                flow.add(kind: .model, id: "message:" + (p["id"] as? String ?? id), title: "模型更新进度", at: date)
            }
        } else if type == "item_started" || type == "item_completed" {
            guard let item = p["item"] as? [String: Any] else { return }
            let itemID = item["id"] as? String ?? id
            let kind = item["type"] as? String ?? ""
            let start = milliseconds(p["started_at_ms"])
            let end = milliseconds(p["completed_at_ms"]) ?? date
            let toolNames = ["CommandExecution": "终端命令", "FileChange": "文件修改", "McpToolCall": "MCP 工具", "WebSearch": "资料搜索", "ImageGeneration": "图像生成"]
            if let name = toolNames[kind] {
                if type == "item_started" { flow.tool(itemID, name: name, at: start ?? date, waiting: false) }
                else { flow.result(itemID, name: name, at: end, failed: failed(item), startedAt: start) }
            } else if kind == "Reasoning" || kind == "AgentMessage" {
                flow.add(kind: .model, id: "model:" + itemID, title: kind == "Reasoning" ? "模型处理" : "模型输出进度", at: start ?? date)
            } else if kind == "Plan", let plan = item["plan"] {
                updatePlan(name: "update_plan", input: ["plan": plan], flow: &flow)
            }
        }
    }

    private static func conversation(_ object: [String: Any], id: String, at date: Date?, source: String, flow: inout WorkflowBuilder) {
        let type = object["type"] as? String ?? ""
        let message = object["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []
        if type == "user", !content.contains(where: { $0["type"] as? String == "tool_result" }) {
            if object["isMeta"] as? Bool != true && object["isCompactSummary"] as? Bool != true {
                flow.begin(id, at: date, explicit: true)
            }
        } else if type == "assistant" {
            let tools = content.filter { $0["type"] as? String == "tool_use" }
            if tools.isEmpty {
                flow.add(kind: .model, id: "model:" + id, title: "模型处理", at: date)
            }
            for (index, tool) in tools.enumerated() {
                let call = tool["id"] as? String ?? tool["toolCallId"] as? String ?? id + ":\(index)"
                let name = tool["name"] as? String ?? tool["toolName"] as? String ?? "tool"
                flow.tool(call, name: name, at: date, waiting: isQuestion(name))
                updatePlan(name: name, input: tool["input"] ?? tool["toolParams"], flow: &flow)
            }
            let stop = message["stop_reason"] as? String
            let finished = source == "Claude" ? ["end_turn", "stop_sequence"].contains(stop ?? "")
                : message["finished"] as? Bool == true
            let hasText = content.contains { $0["type"] as? String == "text" && !(($0["text"] as? String ?? "").isEmpty) }
            if tools.isEmpty && finished && hasText { flow.finish(at: date, status: .returned) }
        } else if type == "system", object["subtype"] as? String == "turn_duration" {
            flow.finish(at: date, status: .returned)
        }
        if type == "user" || type == "tool" {
            for result in content where result["type"] as? String == "tool_result" {
                guard let call = result["tool_use_id"] as? String ?? result["toolCallId"] as? String else { continue }
                // Claude 的 tool_result 本身是交互返回证据；CatDesk 使用独立 tool 消息。
                flow.result(call, name: result["toolName"] as? String ?? "工具（起始事件未读到）", at: date,
                    failed: failed(result) || failed(result["toolResult"]), answered: true)
            }
        }
    }

    static func transcript(_ text: String, offset: Int = 0) -> WorkflowSnapshot {
        var flow = WorkflowBuilder(partial: true)
        var position = offset
        var calls: [(String, String)] = []
        for line in text.components(separatedBy: "\n") {
            defer { position += line.utf8.count + 1 }
            if line == "user:" || line.hasPrefix("[Human]") || line.hasPrefix("[User]") {
                flow.begin(nil, at: nil, explicit: false); calls = []
            } else if line.hasPrefix("[Tool call]") {
                let name = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let id = "transcript:\(position)"
                calls.append((id, name)); flow.tool(id, name: name, at: nil, waiting: isQuestion(name))
            } else if line.hasPrefix("[Tool result]") {
                let name = String(line.dropFirst(13)).trimmingCharacters(in: .whitespaces)
                if let i = calls.lastIndex(where: { $0.1 == name || name.isEmpty }) {
                    flow.result(calls[i].0, at: nil, failed: false); calls.remove(at: i)
                }
            } else if line.hasPrefix("[Thinking]") || line == "assistant:" {
                flow.add(kind: .model, id: "model:\(position)", title: "模型处理", at: nil)
            }
        }
        return flow.snapshot()
    }

    private static func isQuestion(_ name: String) -> Bool {
        name.contains("request_user_input") || ["AskUserQuestion", "AskQuestion"].contains(name)
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let d = value as? [String: Any] { return d }
        if let text = value as? String, let data = text.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        return nil
    }

    private static func failed(_ value: Any?) -> Bool {
        guard let d = dictionary(value) else { return false }
        if d["is_error"] as? Bool == true || d["isError"] as? Bool == true { return true }
        if let code = d["exit_code"] as? Int, code != 0 { return true }
        if let code = d["exitCode"] as? Int, code != 0 { return true }
        return ["failed", "error", "declined"].contains(d["status"] as? String ?? "")
    }

    private static func hasAnswers(_ value: Any?) -> Bool {
        guard let d = dictionary(value) else { return false }
        return d["answers"] != nil || dictionary(d["output"])?["answers"] != nil
    }

    private static func milliseconds(_ value: Any?) -> Date? {
        guard let number = value as? Double, number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }

    private static func updatePlan(name: String, input: Any?, flow: inout WorkflowBuilder) {
        guard name.hasSuffix("update_plan") || ["TodoWrite", "write_todos"].contains(name), let d = dictionary(input),
              let entries = d["plan"] as? [[String: Any]] ?? d["todos"] as? [[String: Any]] else { return }
        flow.plan = entries.prefix(20).enumerated().compactMap { index, item in
            guard let text = item["step"] as? String ?? item["content"] as? String, !text.isEmpty else { return nil }
            let status = item["status"] as? String ?? "pending"
            return WorkflowPlanStep(id: stableKey("\(index):" + text), title: String(text.prefix(120)),
                status: status == "completed" ? .completed : status == "in_progress" ? .inProgress : .pending)
        }
    }
}
