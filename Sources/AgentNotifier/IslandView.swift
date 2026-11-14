import SwiftUI

struct IslandItem: Identifiable, Equatable {
    let id: String
    let taskID: String
    let title: String
    let source: String
    let phase: TaskPhase
    let createdAt: Date
}

struct IslandToast: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let createdAt: Date
}

struct IslandView: View {
    let items: [IslandItem]
    let toast: IslandToast?
    let notch: Bool
    let topInset: CGFloat
    let onOpen: (IslandItem) -> Void
    let onSnooze: (IslandItem, Int) -> Void
    let onSeen: (IslandItem) -> Void
    let onHandled: (IslandItem) -> Void
    let onDismissToast: () -> Void
    let onDismiss: () -> Void

    private var totalCount: Int { items.count + (toast == nil ? 0 : 1) }

    var body: some View {
        VStack(spacing: 0) {
            if let toast { toastRow(toast) }
            if !items.isEmpty {
                if totalCount > 1 { header }
                ForEach(Array(items.prefix(IslandGeometry.maxRows))) { item in
                    itemRow(item)
                    if item.id != items.prefix(IslandGeometry.maxRows).last?.id {
                        Divider().overlay(Color.white.opacity(0.08)).padding(.horizontal, 10)
                    }
                }
                if items.count > IslandGeometry.maxRows {
                    Text("还有 \(items.count - IslandGeometry.maxRows) 项")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
        }
        .padding(.top, topInset + 6)
        .padding(.bottom, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(background)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("等你处理")
    }

    private var background: some View {
        IslandShape(notch: notch, radius: IslandGeometry.cornerRadius)
            .fill(Color.black.opacity(notch ? 0.97 : 0.86))
            .overlay(
                IslandShape(notch: notch, radius: IslandGeometry.cornerRadius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: notch ? .clear : .black.opacity(0.32),
                    radius: notch ? 0 : 16,
                    y: notch ? 0 : 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(items.count) 项等你处理")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("暂时收起；有新事项时再显示")
        }
        .padding(.horizontal, 12)
        .frame(height: IslandGeometry.headerHeight)
    }

    private func itemRow(_ item: IslandItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.phase.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(item.phase.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("\(item.source) · \(item.phase.label)")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button { onOpen(item) } label: { actionLabel("打开", prominent: true) }
                .buttonStyle(.plain)

            if item.phase != .completed {
                Menu {
                    Button("5 分钟后") { onSnooze(item, 5) }
                    Button("15 分钟后") { onSnooze(item, 15) }
                    Button("30 分钟后") { onSnooze(item, 30) }
                } label: {
                    actionLabel("稍后")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if item.phase == .completed {
                Button { onSeen(item) } label: { actionLabel("已查看") }
                    .buttonStyle(.plain)
            } else if item.phase == .failed {
                Button { onHandled(item) } label: { actionLabel("已处理") }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: IslandGeometry.rowHeight)
    }

    private func toastRow(_ toast: IslandToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bell.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if !toast.body.isEmpty {
                    Text(toast.body)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(action: onDismissToast) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: IslandGeometry.rowHeight)
    }

    private func actionLabel(_ text: String, prominent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(prominent ? .black : .white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
    }
}

/// 贴刘海时只有下方两角圆角；胶囊模式四角圆角。
struct IslandShape: Shape {
    let notch: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if notch {
            let r = min(radius, rect.height / 2, rect.width / 2)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.closeSubpath()
        } else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        }
        return path
    }
}
