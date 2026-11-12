import SwiftUI
import AppKit

struct PetTaskProgress: Identifiable, Equatable {
    var id: String
    var title: String
    var source: String
    var phase: TaskPhase
    var steps: [WorkflowStep]
    var activity: Date
    static func collect(_ tasks: [TaskRecord], now: Date, revealTitles: Bool) -> [PetTaskProgress] {
        tasks.filter { task in
            [.running, .approval, .input, .failed, .stalled].contains(task.phase) ||
            ([.completed, .stopped].contains(task.phase) && now.timeIntervalSince(task.changedAt) < 120)
        }.sorted { $0.activity > $1.activity }.map { task in
            PetTaskProgress(id: task.id, title: revealTitles ? task.title : "当前任务", source: task.source,
                            phase: task.phase, steps: Array((task.workflow?.steps ?? []).suffix(12)), activity: task.activity)
        }
    }
}

@MainActor
final class PetProgressModel: ObservableObject {
    @Published var tasks: [PetTaskProgress] = []
    @Published var selectedID: String?
    /// 用户手动关闭后不再自动弹出，直到出现新的执行中任务。
    private(set) var dismissed = false
    private var knownActive: Set<String> = []

    var selected: PetTaskProgress? { tasks.first { $0.id == selectedID } ?? tasks.first }

    func update(_ incoming: [PetTaskProgress]) {
        let active = Set(incoming.filter { PetProgressModel.isActive($0.phase) }.map(\.id))
        if !active.subtracting(knownActive).isEmpty { dismissed = false }
        knownActive = active
        if incoming.isEmpty { dismissed = false }
        if tasks != incoming { tasks = incoming }
        if !incoming.contains(where: { $0.id == selectedID }) { selectedID = incoming.first?.id }
    }

    /// 用户点击关闭：同一批任务继续推进时保持收起。
    func dismiss() { dismissed = true }
    /// 用户从菜单主动打开：强制恢复自动弹出。
    func forceShow() { dismissed = false }

    private static func isActive(_ phase: TaskPhase) -> Bool {
        [.running, .approval, .input, .suspected].contains(phase)
    }
}

struct PetProgressBubble: View {
    @ObservedObject var model: PetProgressModel
    var openTask: (String) -> Void
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task = model.selected {
                HStack(spacing: 6) {
                    Text(task.source).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Label(task.phase.label, systemImage: task.phase.symbol).font(.caption).foregroundColor(task.phase.color)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭任务栏并停止自动弹出")
                    .accessibilityLabel("关闭任务栏")
                }
                Text(task.title).font(.headline).lineLimit(2)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if task.steps.isEmpty { Text("等待来源写入执行进展…").foregroundColor(.secondary) }
                            ForEach(task.steps) { step in
                                HStack(alignment: .top) {
                                    Circle().fill(step.status.pending ? Color.blue : Color.secondary.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 5)
                                    Text(step.title).lineLimit(2)
                                }.id(step.id)
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 98)
                        .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                        .onChange(of: task.steps) { _ in withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
                        .onChange(of: task.id) { _ in proxy.scrollTo("latest", anchor: .bottom) }
                }.font(.caption)
                HStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.tasks) { item in
                                Button { model.selectedID = item.id } label: {
                                    Circle().fill(item.phase == .completed ? Color.green : item.phase == .failed ? Color.red : item.id == task.id ? Color.blue : Color.secondary.opacity(0.35)).frame(width: 9, height: 9).padding(3)
                                }.buttonStyle(.plain).help("\(item.title) · \(item.phase.label)")
                                    .accessibilityLabel("切换任务：\(item.title)")
                            }
                        }
                    }
                    Button("查看任务") { openTask(task.id) }.buttonStyle(.link).font(.caption)
                }
                Text("来源公开的执行进展").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }.padding(14).frame(width: 290)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
    }
}

@MainActor
final class PetProgressPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
