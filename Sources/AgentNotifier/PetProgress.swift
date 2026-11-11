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
    var selected: PetTaskProgress? { tasks.first { $0.id == selectedID } ?? tasks.first }
    func update(_ incoming: [PetTaskProgress]) {
        if tasks != incoming { tasks = incoming }
        if !incoming.contains(where: { $0.id == selectedID }) { selectedID = incoming.first?.id }
    }
}

struct PetProgressBubble: View {
    @ObservedObject var model: PetProgressModel
    var openTask: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task = model.selected {
                HStack {
                    Text(task.source).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Label(task.phase.label, systemImage: task.phase.symbol).font(.caption).foregroundColor(task.phase.color)
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
