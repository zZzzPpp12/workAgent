import Foundation
import Combine

/// 记录和提醒共用同一份本地数据，避免勾选完成后仍被旧提醒唤起。
enum PetNoteKind: String, CaseIterable, Codable, Identifiable {
    case note = "📝 随手记", todo = "☑️ 待办", idea = "💡 灵感", question = "❓ 问题"
    var id: String { rawValue }
}

struct PetNote: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var kind: PetNoteKind
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var completed = false
    var pinned = false
    var remindAt: Date?
    var remindedAt: Date?

    static func defaultReminder(now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
    }
    var notificationID: String { "hakimi.note." + id }
}

@MainActor
final class PetNoteStore: ObservableObject {
    @Published private(set) var notes: [PetNote] = []
    @Published private(set) var issue: String?
    private let url: URL
    private var readOnly = false
    /// 系统通知由控制器负责；测试只验证本地状态，不投递真实通知。
    var didChange: (([PetNote]) -> Void)?
    struct Document: Codable { var version = 1; var notes: [PetNote] }

    init(url: URL = TaskCenterStore.dataDirectory.appendingPathComponent("pet-notes-v1.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw CocoaError(.coderReadCorrupt) }
            notes = document.notes
        } catch {
            readOnly = true
            issue = "记录无法读取，原文件已保留；为保护数据，暂时停止写入。"
        }
    }

    @discardableResult
    func save(id: String? = nil, kind: PetNoteKind, text: String, reminder: Date?, now: Date = Date()) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var next = notes
        if let id, let index = next.firstIndex(where: { $0.id == id }) {
            if next[index].remindAt != reminder { next[index].remindedAt = nil }
            next[index].kind = kind
            next[index].text = text
            next[index].updatedAt = now
            next[index].remindAt = reminder ?? (kind == .todo ? PetNote.defaultReminder(now: now) : nil)
        } else {
            next.append(PetNote(kind: kind, text: text, createdAt: now, updatedAt: now,
                                remindAt: reminder ?? (kind == .todo ? PetNote.defaultReminder(now: now) : nil)))
        }
        return commit(next)
    }

    func toggleDone(_ id: String, now: Date = Date()) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        setCompleted(id, completed: !note.completed, now: now)
    }
    func setCompleted(_ id: String, completed: Bool, now: Date = Date()) {
        var next = notes
        guard let index = next.firstIndex(where: { $0.id == id }), next[index].completed != completed else { return }
        next[index].completed = completed
        next[index].updatedAt = now
        if !completed { next[index].remindedAt = nil }
        _ = commit(next)
    }
    func togglePin(_ id: String) {
        var next = notes
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].pinned.toggle()
        _ = commit(next)
    }
    func delete(_ id: String) { _ = commit(notes.filter { $0.id != id }) }

    /// 唤醒后补查到期事项，已完成或已提醒的事项不重复弹卡。
    func due(at now: Date) -> [PetNote] {
        notes.filter { !$0.completed && $0.remindedAt == nil && ($0.remindAt.map { $0 <= now } ?? false) }
            .sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
    }
    @discardableResult
    func acknowledge(_ ids: Set<String>, at now: Date) -> Bool {
        var next = notes
        for index in next.indices where ids.contains(next[index].id) { next[index].remindedAt = now }
        return commit(next)
    }
    func filtered(search: String, kind: PetNoteKind?, date: Date?, calendar: Calendar = .current) -> [PetNote] {
        notes.filter { note in
            (kind == nil || kind == note.kind) && (search.isEmpty || note.text.localizedCaseInsensitiveContains(search)) &&
            (date == nil || calendar.isDate(note.createdAt, inSameDayAs: date!))
        }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }
    func reportNotificationIssue() { issue = "系统提醒未能安排；应用运行时仍会检查到期事项，请检查通知权限。" }
    private func commit(_ next: [PetNote]) -> Bool {
        guard !readOnly else { return false }
        do {
            let data = try JSONEncoder().encode(Document(notes: next))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            notes = next
            issue = nil
            didChange?(next)
            return true
        } catch {
            issue = "记录保存失败：\(error.localizedDescription)"
            return false
        }
    }
}
