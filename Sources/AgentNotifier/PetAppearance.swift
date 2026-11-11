import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 内置形象以原生路径绘制，动图来自同一套图形；不依赖外部下载。
enum PetSkin: String, CaseIterable, Identifiable {
    case cat = "哈基米猫", dog = "小柴犬", rabbit = "月亮兔", panda = "团子熊猫", fox = "小狐狸"
    var id: String { rawValue }
    var color: NSColor {
        switch self {
        case .cat: return .systemOrange
        case .dog: return NSColor(red: 0.77, green: 0.5, blue: 0.24, alpha: 1)
        case .rabbit: return NSColor(red: 0.96, green: 0.82, blue: 0.89, alpha: 1)
        case .panda: return .white
        case .fox: return NSColor(red: 0.95, green: 0.35, blue: 0.15, alpha: 1)
        }
    }
    func frame(_ frame: Int) -> NSImage {
        let size = NSSize(width: 180, height: 180)
        return NSImage(size: size, flipped: false) { _ in
            let bob = sin(Double(frame) / 8 * .pi * 2) * 3
            let y = 45.0 + bob
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: 35, y: 16, width: 110, height: 12)).fill()
            self.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: y - 16, width: 124, height: 68), xRadius: 32, yRadius: 32).fill()
            for x in [43.0, 112.0] {
                if self == .rabbit {
                    NSBezierPath(roundedRect: NSRect(x: x, y: y + 65, width: 25, height: 65), xRadius: 13, yRadius: 13).fill()
                } else if self == .panda || self == .dog {
                    if self == .panda { NSColor.darkGray.setFill() }
                    NSBezierPath(ovalIn: NSRect(x: x - 8, y: y + 68, width: 38, height: 40)).fill()
                    self.color.setFill()
                } else {
                    let ear = NSBezierPath()
                    ear.move(to: NSPoint(x: x - 8, y: y + 55)); ear.line(to: NSPoint(x: x + 5, y: y + 117))
                    ear.line(to: NSPoint(x: x + 38, y: y + 68)); ear.close(); ear.fill()
                }
            }
            self.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: y + 8, width: 124, height: 90), xRadius: 40, yRadius: 40).fill()
            NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 61, y: y + 17, width: 58, height: 38)).fill()
            NSColor.darkGray.setFill()
            for x in [61.0, 111.0] {
                if self == .panda { NSBezierPath(ovalIn: NSRect(x: x - 7, y: y + 49, width: 23, height: 28)).fill() }
                if frame == 4 {
                    let eye = NSBezierPath(); eye.move(to: NSPoint(x: x, y: y + 64)); eye.line(to: NSPoint(x: x + 8, y: y + 64)); eye.lineWidth = 3; eye.stroke()
                } else {
                    if self == .panda { NSColor.white.setFill() }
                    NSBezierPath(ovalIn: NSRect(x: x, y: y + 60, width: 8, height: 11)).fill()
                    NSColor.darkGray.setFill()
                }
            }
            NSBezierPath(ovalIn: NSRect(x: 85, y: y + 40, width: 10, height: 7)).fill()
            NSColor.systemPink.withAlphaComponent(0.4).setFill()
            for x in [44.0, 121.0] { NSBezierPath(ovalIn: NSRect(x: x, y: y + 43, width: 16, height: 8)).fill() }
            return true
        }
    }
    func gif() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 8, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<8 {
            guard let image = frame(i).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

@MainActor
final class PetAppearance: ObservableObject {
    static let shared = PetAppearance()
    @Published private(set) var skin: PetSkin
    @Published private(set) var custom: Bool
    @Published var issue: String?
    private var images: [String: NSImage] = [:]
    private var gifCache: [String: Data] = [:]
    private let customURL: URL
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard, customURL: URL = TaskCenterStore.dataDirectory.appendingPathComponent("pet-custom.gif")) {
        self.defaults = defaults
        self.customURL = customURL
        skin = PetSkin(rawValue: defaults.string(forKey: "pet.skin") ?? "") ?? .cat
        custom = defaults.bool(forKey: "pet.custom")
    }
    func select(_ skin: PetSkin) {
        self.skin = skin; custom = false
        defaults.set(skin.rawValue, forKey: "pet.skin")
        defaults.set(false, forKey: "pet.custom")
    }
    var staticImage: NSImage {
        let key = custom ? "custom.static" : skin.rawValue + ".static"
        if let cached = images[key] { return cached }
        let result: NSImage
        if custom, let data = try? Data(contentsOf: customURL), let still = NSBitmapImageRep(data: data) {
            still.setProperty(.currentFrame, withValue: 0)
            result = NSImage(size: still.size); result.addRepresentation(still)
        } else { result = skin.frame(0) }
        images[key] = result
        return result
    }
    var image: NSImage? {
        let key = custom ? "custom" : skin.rawValue
        if let image = images[key] { return image }
        let loaded = animationData.flatMap(NSImage.init(data:))
        if let loaded { images[key] = loaded }
        return loaded
    }
    var animationData: Data? {
        let key = custom ? "custom" : skin.rawValue
        if let data = gifCache[key] { return data }
        let data = custom ? try? Data(contentsOf: customURL) : skin.gif()
        if let data { gifCache[key] = data }
        return data
    }
    func importGIF() {
        let owner = NSApp.keyWindow
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.gif]; picker.allowsMultipleSelection = false
        defer { owner?.makeKeyAndOrderFront(nil) }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        _ = loadGIF(url)
    }
    @discardableResult
    func loadGIF(_ url: URL) -> Bool {
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            guard let size, size.intValue <= 20_000_000 else { issue = "GIF 文件不能超过 20 MB。"; return false }
            let data = try Data(contentsOf: url)
            guard data.count <= 20_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.gif.identifier,
                  (2...300).contains(CGImageSourceGetCount(source)),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 2048, height <= 2048,
                  width * height * CGImageSourceGetCount(source) <= 60_000_000 else {
                issue = "请选择不超过 20 MB、2–300 帧、尺寸适中的 GIF。"; return false
            }
            try FileManager.default.createDirectory(at: customURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: customURL, options: .atomic)
            images.removeValue(forKey: "custom"); images.removeValue(forKey: "custom.static"); gifCache.removeValue(forKey: "custom"); custom = true; issue = nil
            defaults.set(true, forKey: "pet.custom")
            return true
        } catch { issue = "导入失败：\(error.localizedDescription)"; return false }
    }
}

/// 显式按 GIF 帧时长播放，在非激活桌宠窗口中也可靠；离开即停止。
@MainActor
final class PetGIFImageView: NSImageView {
    private var bitmap: NSBitmapImageRep?
    private var source: CGImageSource?
    private var identity: ObjectIdentifier?
    private var still: NSImage?
    private var timer: Timer?
    private var label = ""
    private(set) var displayedFrame = 0
    private(set) var hovering = false
    var frameCount: Int { (bitmap?.value(forProperty: .frameCount) as? NSNumber)?.intValue ?? 1 }
    var timerIsActive: Bool { timer?.isValid == true }

    func configure(appearance: PetAppearance, hovered: Bool) {
        let current = appearance.image
        let newIdentity = current.map(ObjectIdentifier.init)
        let changed = identity != newIdentity
        if changed {
            timer?.invalidate(); timer = nil
            identity = newIdentity
            bitmap = appearance.animationData.flatMap(NSBitmapImageRep.init(data:))
            source = appearance.animationData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            still = appearance.staticImage
            displayedFrame = 0
        }
        label = appearance.custom ? "自定义宠物" : appearance.skin.rawValue
        let stateChanged = hovering != hovered
        hovering = hovered
        animates = false
        if !hovered {
            timer?.invalidate(); timer = nil
            displayedFrame = 0; image = still
        } else if changed || stateChanged {
            drawCurrentFrame()
            scheduleFrame()
        }
        setAccessibilityLabel(label + (hovered ? " · 动画播放中" : " · 静止"))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        if window != nil && hovering { scheduleFrame() }
    }
    func advanceFrame() {
        guard hovering, frameCount > 1 else { return }
        displayedFrame = (displayedFrame + 1) % frameCount
        drawCurrentFrame()
    }
    private func drawCurrentFrame() {
        guard let bitmap else { image = still; return }
        bitmap.setProperty(.currentFrame, withValue: displayedFrame)
        if let cg = bitmap.cgImage { image = NSImage(cgImage: cg, size: bitmap.size) }
        setAccessibilityValue("第 \(displayedFrame + 1) / \(frameCount) 帧")
    }
    private func scheduleFrame() {
        guard hovering, window != nil, frameCount > 1 else { return }
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, displayedFrame, nil) as? [CFString: Any] }
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        let next = Timer(timeInterval: max(0.02, min(delay, 10)), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.advanceFrame(); self.scheduleFrame()
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    deinit { timer?.invalidate() }
}

struct PetAnimatedImage: NSViewRepresentable {
    @ObservedObject var appearance: PetAppearance
    var hovered: Bool
    func makeNSView(context: Context) -> PetGIFImageView {
        let view = PetGIFImageView(); view.imageScaling = .scaleProportionallyUpOrDown; return view
    }
    func updateNSView(_ view: PetGIFImageView, context: Context) {
        view.configure(appearance: appearance, hovered: hovered)
    }
}
