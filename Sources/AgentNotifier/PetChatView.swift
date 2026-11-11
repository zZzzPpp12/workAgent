import SwiftUI
import AppKit

struct PetChatComposer: View {
    @ObservedObject var store: PetChatStore
    var compact = false
    var sent: (() -> Void)?
    @State private var prompt = ""
    @AppStorage("pet.chat.project") private var project = ""
    @State private var allowEdits = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if compact { Label("交给哈基米", systemImage: "bubble.left.and.text.bubble.right").font(.headline) }
            HStack {
                Text(project.isEmpty ? "先选择任务所在的项目" : URL(fileURLWithPath: project).lastPathComponent)
                    .font(.caption).lineLimit(1).help(project)
                Spacer()
                Button("选择项目…") {
                    let owner = NSApp.keyWindow
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { project = url.path }
                    owner?.makeKeyAndOrderFront(nil)
                }
            }
            if !compact, store.selected != nil {
                Text("继续当前对话；使用创建时的项目与权限。") .font(.caption).foregroundColor(.secondary)
            } else {
                Toggle("允许修改所选项目文件", isOn: $allowEdits).font(.caption)
            }
            TextField("输入任务，按回车发送", text: $prompt, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder).onSubmit(send)
            HStack {
                Text("通过本机 Codex 执行，默认只读；请先完成 Codex 登录。")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button("发送", action: send).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.isEmpty || (!compact && store.selected?.phase == .running))
            }
            if let issue = store.issue { Text(issue).font(.caption).foregroundColor(.orange) }
        }
    }
    private func send() {
        if store.send(prompt, project: project, allowEdits: allowEdits, new: compact) { prompt = ""; sent?() }
    }
}

struct PetChatPage: View {
    @ObservedObject var store: PetChatStore
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading) {
                Button("新建对话", systemImage: "plus") { store.selectedID = nil }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.chats) { chat in
                            Button { store.selectedID = chat.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chat.title).lineLimit(2)
                                    Text(chat.phase.label).font(.caption).foregroundColor(chat.phase.color)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(chat.id == store.selectedID ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.frame(width: 150)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let chat = store.selected {
                    HStack {
                        Text(chat.title).font(.headline).lineLimit(2)
                        Spacer()
                        if chat.phase == .running { Button("停止") { store.cancel(chat.id) } }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(chat.messages) { message in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(message.role == "user" ? "你" : "哈基米 · Codex").font(.caption).foregroundColor(.secondary)
                                        Text(message.text).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                                }
                                if let progress = chat.progress.last { Text(progress).font(.caption).foregroundColor(.secondary) }
                                Color.clear.frame(height: 1).id("latest")
                            }
                        }.onChange(of: chat.messages.count) { _ in proxy.scrollTo("latest", anchor: .bottom) }
                    }
                } else {
                    Text("把任务交给哈基米").font(.title2.bold())
                    Text("在这里发起和继续对话，桌宠会帮你盯着进展。") .foregroundColor(.secondary)
                    Spacer()
                }
                Divider()
                PetChatComposer(store: store)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
final class PetChatPresenter {
    static let shared = PetChatPresenter()
    private var panel: NSPanel?
    func show(near rect: NSRect?) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 410, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            p.title = "新建对话"; p.level = .floating; p.isReleasedWhenClosed = false
            p.contentView = NSHostingView(rootView: PetChatComposer(store: .shared, compact: true, sent: { [weak p] in p?.orderOut(nil) }).padding(18))
            panel = p
        }
        if let rect, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }), let panel {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: max(bounds.minX, min(rect.minX - 190, bounds.maxX - panel.frame.width)),
                                         y: max(bounds.minY, min(rect.maxY, bounds.maxY - panel.frame.height))))
        } else { panel?.center() }
        panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
