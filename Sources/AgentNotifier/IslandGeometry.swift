import AppKit

/// 从 NSScreen 抽出的纯数据，便于几何计算单测。
struct IslandScreenMetrics: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat

    init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
    }

    init(screen: NSScreen) {
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
        self.safeAreaTop = screen.safeAreaInsets.top
    }

    var hasNotch: Bool { safeAreaTop > 0 }
}

enum IslandGeometry {
    static let width: CGFloat = 440
    static let rowHeight: CGFloat = 52
    static let headerHeight: CGFloat = 28
    static let gap: CGFloat = 6
    static let maxRows = 4
    static let singleHeight: CGFloat = 64
    static let bottomMargin: CGFloat = 6
    static let cornerRadius: CGFloat = 18

    /// 内容高度：单条 64；多条时头部 + 行（任务最多 4 行，其余滚动；通知额外占一行）。
    static func contentHeight(itemCount: Int, toastCount: Int = 0) -> CGFloat {
        let itemRows = min(max(0, itemCount), maxRows)
        let rows = itemRows + max(0, toastCount)
        guard rows > 1 else { return singleHeight }
        return 12 + headerHeight + CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap
    }

    /// 贴刘海时窗口需要额外覆盖菜单栏安全区。
    static func windowHeight(contentHeight: CGFloat, notch: Bool, safeAreaTop: CGFloat) -> CGFloat {
        notch ? max(0, safeAreaTop) + contentHeight : contentHeight
    }

    static func frame(metrics: IslandScreenMetrics, notch: Bool, contentHeight: CGFloat) -> CGRect {
        let width = min(Self.width, max(280, metrics.frame.width - 24))
        let height = windowHeight(contentHeight: contentHeight, notch: notch, safeAreaTop: metrics.safeAreaTop)
        let x = (metrics.frame.midX - width / 2).rounded()
        let y = notch
            ? metrics.frame.maxY - height
            : metrics.visibleFrame.maxY - height - bottomMargin
        return CGRect(x: x, y: y.rounded(), width: width, height: height)
    }

    /// 只有用户开启、屏幕确实有刘海、且安全区足够大时才贴刘海；否则退回胶囊。
    static func usesNotch(metrics: IslandScreenMetrics, preference: Bool) -> Bool {
        preference && metrics.hasNotch && metrics.safeAreaTop >= 20
    }
}
