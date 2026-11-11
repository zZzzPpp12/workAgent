import SwiftUI
import AppKit
import UserNotifications

struct PetNotesView: View {
    @ObservedObject var store: PetNoteStore
    @State private var search = ""
    @ObservedObject var route: PetNotesRoute
    @State private var filter = "全部"
    @State private var day = Date()
    @State private var dateOnly = false
    @State private var editingID: String?
    @State private var kind = PetNoteKind.note
    @State private var text = ""
    @State private var reminderEnabled = false
    @State private var reminder = PetNote.defaultReminder(now: Date())
    @State private var deleteID: String?
    @State private var editor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("日常记录").font(.title2.bold())
                Spacer()
                Button("新增记录", systemImage: "plus") { reset(); editor = true }
            }
            if let issue = store.issue { Text(issue).font(.caption).foregroundColor(.orange) }
            TextField("搜索记录", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Picker("类型", selection: $filter) {
                    Text("全部").tag("全部")
                    ForEach(PetNoteKind.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("按日期", isOn: $dateOnly).toggleStyle(.checkbox)
                if dateOnly { DatePicker("日期", selection: $day, displayedComponents: .date).labelsHidden() }
            }.controlSize(.small)
            if editor {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("记录类型", selection: $kind) { ForEach(PetNoteKind.allCases) { Text($0.rawValue).tag($0) } }
                    TextEditor(text: $text).font(.body).frame(minHeight: 80, maxHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2)))
                    Toggle("到时提醒", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("提醒时间", selection: $reminder, displayedComponents: [.date, .hourAndMinute])
                    }
                    Text("待办不指定时间时默认当天 18:00；时间已过会在保存后提醒。")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("保存") {
                            if store.save(id: editingID, kind: kind, text: text,
                                          reminder: reminderEnabled ? reminder : nil) { editor = false; reset() }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("取消") { editor = false; reset() }
                    }
                }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            }
            let rows = store.filtered(search: search, kind: PetNoteKind(rawValue: filter), date: dateOnly ? day : nil).filter { !route.remindersOnly || $0.remindAt != nil }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty { Text("记下一点想法，哈基米替你保管。") .foregroundColor(.secondary).padding(.vertical, 24) }
                    ForEach(rows) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                if note.kind == .todo {
                                    Toggle("完成待办", isOn: Binding(get: {
                                        store.notes.first { $0.id == note.id }?.completed ?? note.completed
                                    }, set: { store.setCompleted(note.id, completed: $0) }))
                                        .toggleStyle(.checkbox).labelsHidden()
                                        .accessibilityLabel("完成待办：" + note.text)
                                        .help(note.completed ? "重新打开待办" : "完成待办")
                                }
                                Text(note.kind.rawValue).font(.caption).foregroundColor(.secondary)
                                if note.pinned { Image(systemName: "pin.fill").font(.caption).foregroundColor(.orange) }
                                Spacer()
                                Menu {
                                    Button("编辑") { edit(note) }
                                    Button(note.pinned ? "取消置顶" : "置顶") { store.togglePin(note.id) }
                                    Button("删除", role: .destructive) { deleteID = note.id }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            Text(note.text).strikethrough(note.completed).textSelection(.enabled)
                                .foregroundColor(note.completed ? .secondary : .primary)
                            HStack {
                                Text(note.createdAt, format: .dateTime.year().month().day().hour().minute())
                                if let date = note.remindAt {
                                    Image(systemName: "bell")
                                    Text(date, format: .dateTime.month().day().hour().minute())
                                    if note.remindedAt != nil { Text("已提醒") }
                                }
                            }.font(.caption2).foregroundColor(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }.onAppear { filter = "全部" }
            .onChange(of: route.remindersOnly) { _ in filter = "全部" }
            .padding(18).frame(minWidth: 420, minHeight: 420)
            .alert("删除这条记录？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
                Button("删除", role: .destructive) { if let id = deleteID { store.delete(id) }; deleteID = nil }
                Button("取消", role: .cancel) { deleteID = nil }
            }
    }
    private func reset() {
        editingID = nil; text = ""; kind = .note; reminderEnabled = false
        reminder = PetNote.defaultReminder(now: Date())
    }
    private func edit(_ note: PetNote) {
        editingID = note.id; text = note.text; kind = note.kind
        reminderEnabled = note.remindAt != nil; reminder = note.remindAt ?? PetNote.defaultReminder(now: Date())
        editor = true
    }
}

struct PetReminderCard: View {
    @ObservedObject var store: PetNoteStore
    let ids: Set<String>
    let dismiss: () -> Void
    private var remaining: [PetNote] {
        store.notes.filter { ids.contains($0.id) && !$0.completed && ($0.remindAt.map { $0 <= Date() } ?? false) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("哈基米提醒你", systemImage: "bell.badge.fill").font(.headline)
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            ForEach(remaining) { note in
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.text).lineLimit(5)
                    HStack {
                        if note.kind == .todo { Button("完成") { store.toggleDone(note.id) } }
                        Button("稍后 10 分钟") {
                            _ = store.save(id: note.id, kind: note.kind, text: note.text,
                                           reminder: Date().addingTimeInterval(600))
                        }
                    }.controlSize(.small)
                }
            }
            }
            }.frame(maxHeight: 220)
            HStack {
                Button("打开记录") { PetCompanion.shared.showNotes() }
                Spacer()
                Button("知道了") { dismiss() }
            }
        }.padding(18).frame(width: 310)
            .onChange(of: remaining.map(\.id)) { if $0.isEmpty { dismiss() } }
    }
}

@MainActor
final class PetNotesRoute: ObservableObject { @Published var remindersOnly = false }

@MainActor
final class PetCompanion {
    static let shared = PetCompanion()
    private(set) var store: PetNoteStore?
    private var notesWindow: NSWindow?
    private let route = PetNotesRoute()
    private var shownThisLaunch = Set<String>()
    private var reminderWindow: NSPanel?
    var isPresentingReminder: Bool { reminderWindow?.isVisible == true }
    var anchor: (() -> NSRect?)?
    var presentReminder: (() -> Void)?
    private var revision = 0

    func start() {
        guard store == nil else { return }
        let opened = PetNoteStore()
        store = opened
        opened.didChange = { [weak self] notes in self?.schedule(notes) }
        schedule(opened.notes)
    }
    func showNotes(remindersOnly: Bool = false) {
        start()
        guard let store else { return }
        route.remindersOnly = remindersOnly
        if notesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "哈基米 · 日常记录与提醒"
            window.minSize = NSSize(width: 440, height: 460)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.contentView = NSHostingView(rootView: PetNotesView(store: store, route: route))
            window.setFrameAutosaveName("hakimi.pet.notes")
            place(window)
            notesWindow = window
        }
        notesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func showReminders() {
        if let reminderWindow, reminderWindow.isVisible { reminderWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { showNotes(remindersOnly: true) }
    }
    func tick(now: Date = Date()) {
        guard let store else { return }
        guard reminderWindow?.isVisible != true else { return }
        let due = Array(store.due(at: now).filter { !shownThisLaunch.contains($0.id + String($0.remindAt?.timeIntervalSince1970 ?? 0)) }.prefix(5))
        guard !due.isEmpty else { return }
        let ids = Set(due.map(\.id))
        // 弹卡成功后才标记；写入失败时不循环刷屏。
        let panel = reminderWindow ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 340),
                                             styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "事项提醒"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: PetReminderCard(store: store, ids: ids, dismiss: { [weak panel] in panel?.orderOut(nil) }))
        place(panel)
        panel.orderFrontRegardless()
        reminderWindow = panel
        presentReminder?()
        if !store.acknowledge(ids, at: now) {
            // 只有落盘失败时才在本次启动内抑制重复弹卡；正常记录允许完成后重新打开。
            shownThisLaunch.formUnion(due.map { $0.id + String($0.remindAt?.timeIntervalSince1970 ?? 0) })
        }
    }
    private func place(_ window: NSWindow) {
        guard let rect = anchor?(), let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) else { window.center(); return }
        let bounds = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: max(bounds.minX, min(rect.minX - window.frame.width + 80, bounds.maxX - window.frame.width)),
                                      y: max(bounds.minY, min(rect.maxY + 8, bounds.maxY - window.frame.height))))
    }
    private func schedule(_ notes: [PetNote]) {
        revision += 1
        let generation = revision
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [weak self] requests in
            Task { @MainActor in
                guard let self, self.revision == generation else { return }
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: requests.filter { $0.identifier.hasPrefix("hakimi.note.") }.map(\.identifier))
                for note in notes where !note.completed && note.remindedAt == nil {
                    guard let date = note.remindAt, date > Date() else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "哈基米 · 事项到点了"
                    content.body = "打开日常记录查看提醒。"
                    content.userInfo = ["petNoteID": note.id]
                    content.sound = .default
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                    center.add(UNNotificationRequest(identifier: note.notificationID, content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))) { error in
                        if error != nil { Task { @MainActor in self.store?.reportNotificationIssue() } }
                    }
                }
            }
        }
    }
}
