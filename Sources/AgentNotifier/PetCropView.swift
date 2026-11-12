import AppKit
import SwiftUI

/// 导入/重新裁剪 GIF 时的框选窗口：预览首帧，自由框选或选择常用比例。
@MainActor
enum PetCropWindow {
    private static var current: NSWindow?

    static func present(data: Data, name: String, appearance: PetAppearance) {
        guard let image = PetGIFCodec.firstFrame(data) else {
            appearance.issue = "无法读取该 GIF 的第一帧。"
            return
        }
        current?.close()
        let view = PetCropView(
            image: image, sourceName: name,
            onSave: { rect in
                guard let cropped = PetGIFCodec.crop(data, normalized: rect) else {
                    appearance.issue = "裁剪失败，请调整选区后重试。"
                    return false
                }
                appearance.acceptCropped(cropped, name: name)
                return appearance.selectedAsset?.isCustom == true
            },
            onCancel: { current?.close() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "框选要展示的区域"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        current = window
    }
}

private enum CropRatio: String, CaseIterable, Identifiable {
    case free = "自由"
    case square = "1:1"
    case landscape = "4:3"
    case portrait = "3:4"

    var id: String { rawValue }
    var value: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .landscape: return 4.0 / 3.0
        case .portrait: return 3.0 / 4.0
        }
    }
}

struct PetCropView: View {
    let image: NSImage
    let sourceName: String
    let onSave: (CGRect) -> Bool
    let onCancel: () -> Void

    @State private var ratio: CropRatio = .free
    @State private var selection: CGRect = .zero
    @State private var imageRect: CGRect = .zero
    @State private var dragStart: CGPoint?
    @State private var moveOffset: CGSize?
    @State private var errorMessage: String?

    private let minimumSide: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("框选「\(sourceName)」要展示的区域").font(.headline)
                Text("拖动空白处重新框选，拖动选区可移动，拖动右下角圆点可缩放。确认后保存为独立 GIF。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geo.size))
                        path.addRect(selection)
                    }
                    .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                    Path { path in
                        path.addRect(selection)
                        path.move(to: CGPoint(x: selection.midX, y: selection.minY))
                        path.addLine(to: CGPoint(x: selection.midX, y: selection.maxY))
                        path.move(to: CGPoint(x: selection.minX, y: selection.midY))
                        path.addLine(to: CGPoint(x: selection.maxX, y: selection.midY))
                    }
                    .stroke(Color.white.opacity(0.65), lineWidth: 1)
                    Path { path in path.addRect(selection) }
                        .stroke(Color.accentColor, lineWidth: 2)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(x: selection.maxX, y: selection.maxY)
                        .gesture(resizeGesture)
                }
                .contentShape(Rectangle())
                .gesture(drawOrMoveGesture)
                .onAppear { layout(in: geo.size) }
                .onChange(of: geo.size) { layout(in: $0) }
            }
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Picker("比例", selection: $ratio) {
                    ForEach(CropRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 280)
                .onChange(of: ratio) { _ in selection = fitted(selection) }
                Text(pixelSizeText).font(.caption).foregroundColor(.secondary).monospacedDigit()
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存为我的宠物") {
                    guard selection.width >= minimumSide, selection.height >= minimumSide else { return }
                    if onSave(normalized) {
                        errorMessage = nil
                        currentClose()
                    } else {
                        errorMessage = "保存失败，GIF 可能已损坏或超出大小限制，请换一张图片重试。"
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.width < minimumSide || selection.height < minimumSide)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 560)
    }

    private var normalized: CGRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }
        let rect = selection.intersection(imageRect)
        return CGRect(x: (rect.minX - imageRect.minX) / imageRect.width,
                      y: (rect.minY - imageRect.minY) / imageRect.height,
                      width: rect.width / imageRect.width,
                      height: rect.height / imageRect.height)
    }

    private var pixelSizeText: String {
        guard imageRect.width > 0 else { return "" }
        let width = Int((image.size.width * selection.width / imageRect.width).rounded())
        let height = Int((image.size.height * selection.height / imageRect.height).rounded())
        return "\(max(width, 0)) × \(max(height, 0)) px"
    }

    private func currentClose() { onCancel() }

    private func layout(in size: CGSize) {
        guard size.width > 40, size.height > 40 else { return }
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : CGSize(width: 1, height: 1)
        let scale = min(size.width / imageSize.width, size.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        imageRect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                           width: width, height: height)
        if selection == .zero { resetSelection() }
        selection = fitted(selection.intersection(imageRect))
    }

    private func resetSelection() {
        guard imageRect.width > 0 else { return }
        let inset = min(imageRect.width, imageRect.height) * 0.1
        selection = fitted(imageRect.insetBy(dx: inset, dy: inset))
    }

    private func fitted(_ raw: CGRect) -> CGRect {
        var rect = raw
        if let value = ratio.value {
            rect.size.height = rect.width / value
        }
        rect.size.width = min(max(rect.width, minimumSide), imageRect.width)
        rect.size.height = min(max(rect.height, minimumSide), imageRect.height)
        if let value = ratio.value, rect.width > rect.height * value {
            rect.size.width = rect.height * value
        } else if let value = ratio.value, rect.height > rect.width / value {
            rect.size.height = rect.width / value
        }
        rect.origin.x = min(max(rect.origin.x, imageRect.minX), imageRect.maxX - rect.width)
        rect.origin.y = min(max(rect.origin.y, imageRect.minY), imageRect.maxY - rect.height)
        return rect
    }

    private var drawOrMoveGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                    if selection.insetBy(dx: -4, dy: -4).contains(value.startLocation) {
                        moveOffset = CGSize(width: value.startLocation.x - selection.minX,
                                            height: value.startLocation.y - selection.minY)
                    } else {
                        moveOffset = nil
                    }
                }
                guard let start = dragStart else { return }
                if let offset = moveOffset {
                    let origin = CGPoint(x: value.location.x - offset.width,
                                         y: value.location.y - offset.height)
                    selection = fitted(CGRect(origin: origin, size: selection.size))
                } else {
                    let rect = CGRect(x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                                      width: abs(value.location.x - start.x),
                                      height: abs(value.location.y - start.y))
                    selection = fitted(rect.intersection(imageRect))
                }
            }
            .onEnded { _ in
                dragStart = nil
                moveOffset = nil
                if selection.width < minimumSide || selection.height < minimumSide { resetSelection() }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                var width = max(minimumSide, value.location.x - selection.minX)
                var height = max(minimumSide, value.location.y - selection.minY)
                width = min(width, imageRect.maxX - selection.minX)
                height = min(height, imageRect.maxY - selection.minY)
                if let value = ratio.value {
                    height = width / value
                    if selection.minY + height > imageRect.maxY {
                        height = imageRect.maxY - selection.minY
                        width = height * value
                    }
                }
                selection.size = CGSize(width: width, height: height)
            }
    }
}
