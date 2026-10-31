import AppKit
import SwiftUI

/// 每个任务复用一扇可缩放窗口，直接观察任务中心，避免展开后停留在旧快照。
@MainActor
final class WorkflowWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WorkflowWindowPresenter()
    private var windows: [String: NSWindow] = [:]

    func show(center: TaskCenterStore, taskID: String) {
        if let window = windows[taskID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: WorkflowExpandedView(center: center, taskID: taskID))
        let window = NSWindow(contentViewController: hosting)
        window.title = "\(center.task(taskID)?.title ?? "任务") · 执行工作流"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior.insert(.fullScreenPrimary)
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        window.setContentSize(CGSize(width: min(1440, max(800, screen.width - 100)),
                                     height: min(960, max(540, screen.height - 100))))
        window.contentMinSize = CGSize(width: 800, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        windows[taskID] = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: id)
    }
}

private struct WorkflowExpandedView: View {
    @ObservedObject var center: TaskCenterStore
    let taskID: String
    @AppStorage("ui.theme") private var theme = "dark"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let task = center.task(taskID) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title).font(.title3.bold()).lineLimit(2).textSelection(.enabled)
                        Text("\(task.source) · \(TaskCenterView.projectName(task.project))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Label(task.phase.label, systemImage: task.phase.symbol)
                        .font(.callout).foregroundColor(task.phase.color)
                }
                if !task.readable {
                    Label("来源暂不可读，以下为上次观察到的工作流。", systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundColor(.orange)
                }
                if let flow = task.workflow, !flow.steps.isEmpty {
                    WorkflowGraphView(snapshot: flow, phase: task.phase, fillsAvailableSpace: true)
                } else {
                    Text("等待来源写入可识别的工作流步骤。")
                        .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("该任务的来源数据暂不可用。")
                    .foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(minWidth: 800, minHeight: 500, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(UITheme(rawValue: theme)?.scheme)
    }
}
