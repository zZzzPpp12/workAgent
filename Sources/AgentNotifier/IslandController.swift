import AppKit
import SwiftUI

/// 顶部通知的窗口生命周期与状态映射。所有内容都从 TaskCenterStore 派生，不新增持久化。
final class IslandController {
    static let shared = IslandController()

    private var panel: IslandPanel?
    private var hosting: NSHostingView<IslandView>?
    private weak var center: TaskCenterStore?
    private var openTask: ((String, String?) -> Void)?

    private var items: [IslandItem] = []
    private var toast: IslandToast?
    private var toastTimer: Timer?
    private var soundPlayer: NSSound?
    private var lastSignature = ""
    private var dismissedSignature: String?
    private var geometryKey = ""
    private var started = false
    private var visibilityGeneration = 0
    private var needsShowLog = false

    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    var isEnabled: Bool { MonitorPreferences.shared.value.islandEnabled }

    func start(center: TaskCenterStore, openTask: @escaping (String, String?) -> Void) {
        self.center = center
        self.openTask = openTask
        guard !started else { refresh(); return }
        started = true
        observeEnvironment()
        refresh()
    }

    func stop() {
        started = false
        toastTimer?.invalidate()
        toastTimer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        screenObserver = nil
        sleepObserver = nil
        wakeObserver = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        center = nil
        openTask = nil
        items = []
        toast = nil
        lastSignature = ""
        dismissedSignature = nil
    }

    /// 主循环调用；内容未变化时只做轻量比较。
    func refresh() {
        guard started, let center else { return }
        guard isEnabled else { hide(animated: false); return }

        let revealTitles = MonitorPreferences.shared.value.revealTitles
        let next = Self.makeItems(from: center.visibleItems(), tasks: center.tasks, revealTitles: revealTitles)
        let signature = Self.signature(items: next, toast: toast)
        let key = currentGeometryKey()
        var needsRebuild = false

        if signature != lastSignature {
            lastSignature = signature
            items = next
            needsRebuild = true
            if dismissedSignature != signature { dismissedSignature = nil }
        }
        if key != geometryKey {
            geometryKey = key
            needsRebuild = true
        }
        if needsRebuild { rebuild() }

        guard !next.isEmpty || toast != nil else { hide(animated: true); return }
        if dismissedSignature == signature { hide(animated: false); return }

        show(animated: true)
        relayout(animated: true)
    }

    /// 返回 true 表示通知已由顶部区域承接，调用方不要再发系统通知。
    @discardableResult
    func handleNotification(title: String, body: String, audible: Bool, sound: String,
                            context: [String: String]) -> Bool {
        guard started, isEnabled, NSApp != nil else { return false }
        // 全屏时选择不显示顶部通知：交回系统通知，不能吞掉这条消息。
        if !MonitorPreferences.shared.value.islandOverFullScreen,
           hasFullScreenWindow(on: currentMetrics()) {
            return false
        }

        let toast = IslandToast(
            id: context["attentionID"] ?? UUID().uuidString,
            title: title,
            body: body,
            createdAt: Date()
        )
        self.toast = toast
        dismissedSignature = nil
        scheduleToastDismiss()
        rebuild()
        geometryKey = currentGeometryKey()
        lastSignature = Self.signature(items: items, toast: toast)
        show(animated: true)
        relayout(animated: true)
        if audible { play(soundName: sound) }
        return true
    }

    func preview() {
        _ = handleNotification(
            title: "任务中心测试 🐾",
            body: "这是一条灵动岛预览通知",
            audible: false,
            sound: "",
            context: [:]
        )
    }

    private func dismissTemporarily() {
        dismissedSignature = lastSignature
        hide(animated: true)
    }

    // MARK: - 视图

    private func rebuild() {
        let view = makeView()
        if let hosting {
            hosting.rootView = view
        } else if let panel {
            let host = NSHostingView(rootView: view)
            panel.contentView = host
            hosting = host
        }
    }

    private func makeView() -> IslandView {
        let metrics = currentMetrics()
        let notch = IslandGeometry.usesNotch(
            metrics: metrics,
            preference: MonitorPreferences.shared.value.islandNotchMode
        )
        return IslandView(
            items: items,
            toast: toast,
            notch: notch,
            topInset: notch ? metrics.safeAreaTop : 0,
            onOpen: { [weak self] item in self?.open(item) },
            onSnooze: { [weak self] item, minutes in
                self?.center?.snooze(item.id, minutes: minutes)
                self?.refresh()
            },
            onSeen: { [weak self] item in
                self?.center?.see(item.taskID, attentionID: item.id)
                self?.refresh()
            },
            onHandled: { [weak self] item in
                self?.center?.handleFailure(item.id)
                self?.refresh()
            },
            onDismissToast: { [weak self] in
                self?.toast = nil
                self?.toastTimer?.invalidate()
                self?.refresh()
            },
            onDismiss: { [weak self] in self?.dismissTemporarily() }
        )
    }

    private func open(_ item: IslandItem) {
        center?.see(item.taskID, attentionID: item.id)
        dismissedSignature = nil
        openTask?(item.taskID, item.id)
        refresh()
    }

    // MARK: - 窗口

    private func show(animated: Bool) {
        let panel = ensurePanel()
        visibilityGeneration += 1
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = panel.isVisible
        if !wasVisible {
            needsShowLog = true
            panel.alphaValue = animated && !reduceMotion ? 0 : 1
            panel.orderFrontRegardless()
            if animated && !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            // 可能正处于淡出动画中：把透明度拉回 1，新的动画会覆盖旧的属性动画。
            panel.orderFrontRegardless()
            if panel.alphaValue < 1 {
                if animated && !reduceMotion {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        panel.animator().alphaValue = 1
                    }
                } else {
                    panel.alphaValue = 1
                }
            }
        }

    }

    private func hide(animated: Bool) {
        guard let panel, panel.isVisible else { return }
        Notify.log("顶部通知：隐藏 · \(items.count) 项 · 通知=\(toast != nil ? 1 : 0) · 当前空间=\(panel.isOnActiveSpace)")
        needsShowLog = false
        visibilityGeneration += 1
        let generation = visibilityGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && !reduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.visibilityGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            })
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    private func relayout(animated: Bool) {
        guard started, let panel else { return }
        let metrics = currentMetrics()
        if !MonitorPreferences.shared.value.islandOverFullScreen, hasFullScreenWindow(on: metrics) {
            hide(animated: animated)
            return
        }

        let notch = IslandGeometry.usesNotch(
            metrics: metrics,
            preference: MonitorPreferences.shared.value.islandNotchMode
        )
        let content = IslandGeometry.contentHeight(
            itemCount: items.count,
            toastCount: toast == nil ? 0 : 1
        )
        let frame = IslandGeometry.frame(metrics: metrics, notch: notch, contentHeight: content)

        if panel.frame != frame {
            if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }

        if needsShowLog {
            needsShowLog = false
            Notify.log("顶部通知：显示 · \(items.count) 项 · 通知=\(toast != nil ? 1 : 0) · 当前空间=\(panel.isOnActiveSpace) · 可见=\(panel.isVisible) · 尺寸=\(Int(frame.width))x\(Int(frame.height))")
        }
    }

    private func ensurePanel() -> IslandPanel {
        if let panel { return panel }
        let panel = IslandPanel()
        let host = NSHostingView(rootView: makeView())
        panel.contentView = host
        hosting = host
        self.panel = panel
        return panel
    }

    // MARK: - 环境

    private func observeEnvironment() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.hide(animated: false) }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    private func currentGeometryKey() -> String {
        let metrics = currentMetrics()
        let notch = IslandGeometry.usesNotch(
            metrics: metrics,
            preference: MonitorPreferences.shared.value.islandNotchMode
        )
        return "\(notch)|\(metrics.safeAreaTop)|\(metrics.frame.width)x\(metrics.frame.height)"
    }

    private func currentMetrics() -> IslandScreenMetrics {        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first {
            return IslandScreenMetrics(screen: screen)
        }
        return IslandScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
            safeAreaTop: 0
        )
    }

    private func hasFullScreenWindow(on metrics: IslandScreenMetrics) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        let ownPID = getpid()
        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                  let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  owner != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else { continue }
            if abs(width - metrics.frame.width) < 2, abs(height - metrics.frame.height) < 2 {
                return true
            }
        }
        return false
    }

    private func scheduleToastDismiss() {
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.toast = nil
            self.refresh()
        }
    }

    private func play(soundName: String) {
        let player: NSSound?
        if soundName == Notify.completionSoundName,
           let path = Bundle.main.path(forResource: Notify.completionSoundName, ofType: "caf") {
            player = NSSound(contentsOfFile: path, byReference: false)
        } else {
            player = NSSound(named: NSSound.Name("Ping"))
        }
        soundPlayer = player
        player?.play()
    }

    // MARK: - 纯映射（供测试）

    static func makeItems(from visible: [AttentionRecord],
                          tasks: [TaskRecord],
                          revealTitles: Bool) -> [IslandItem] {
        var seen = Set<String>()
        var result: [IslandItem] = []
        for attention in visible {
            guard let task = tasks.first(where: { $0.id == attention.taskID }) else { continue }
            guard seen.insert(task.id).inserted else { continue }
            result.append(IslandItem(
                id: attention.id,
                taskID: task.id,
                title: revealTitles ? task.title : "有任务需要处理",
                source: task.source,
                phase: attention.phase,
                createdAt: attention.createdAt
            ))
        }
        return result
    }

    static func signature(items: [IslandItem], toast: IslandToast?) -> String {
        let rows = items.map { "\($0.id)|\($0.phase.rawValue)|\($0.title)" }.joined(separator: "~")
        return rows + "|toast:" + (toast?.id ?? "")
    }
}
