import AppKit
import Combine
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 内置形象以原生路径绘制，动图来自同一套图形；不依赖外部下载。
enum PetSkin: String, CaseIterable, Identifiable {
    case xiaobai = "小白"
    case xiaohong = "小红"
    case spiderman = "小蜘蛛侠"
    case zombie = "小僵尸"
    case shinchan = "小新"

    var id: String { rawValue }
    var fileStem: String { "内置-" + rawValue }
    var hint: String {
        switch self {
        case .xiaobai: return "白色小狗，耳朵软软的"
        case .xiaohong: return "戴红帽的小红帽"
        case .spiderman: return "吐丝的小蜘蛛侠"
        case .zombie: return "慢半拍的小僵尸"
        case .shinchan: return "爱跳屁屁舞的小新"
        }
    }

    var bodyColor: NSColor {
        switch self {
        case .xiaobai: return NSColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
        case .xiaohong: return NSColor(red: 0.84, green: 0.20, blue: 0.22, alpha: 1)
        case .spiderman: return NSColor(red: 0.86, green: 0.14, blue: 0.17, alpha: 1)
        case .zombie: return NSColor(red: 0.55, green: 0.72, blue: 0.45, alpha: 1)
        case .shinchan: return NSColor(red: 0.99, green: 0.86, blue: 0.71, alpha: 1)
        }
    }

    func frame(_ frame: Int) -> NSImage {
        let size = NSSize(width: 180, height: 180)
        let closed = frame == 4
        return NSImage(size: size, flipped: false) { _ in
            let bob = sin(Double(frame) / 8 * .pi * 2) * 3
            let y = 45.0 + bob
            NSColor.black.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: 35, y: 16, width: 110, height: 12)).fill()
            self.drawBehind(y: y)
            // 身体
            if self == .shinchan {
                NSColor(red: 0.85, green: 0.16, blue: 0.16, alpha: 1).setFill()
            } else {
                self.bodyColor.setFill()
            }
            NSBezierPath(roundedRect: NSRect(x: 28, y: y - 16, width: 124, height: 68),
                         xRadius: 32, yRadius: 32).fill()
            // 头部
            self.bodyColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 28, y: y + 8, width: 124, height: 90),
                         xRadius: 40, yRadius: 40).fill()
            self.drawHood(y: y)
            self.drawFace(y: y, closed: closed)
            self.drawExtras(y: y)
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

    // MARK: - 绘制

    private func drawBehind(y: CGFloat) {
        switch self {
        case .xiaobai:
            NSColor(red: 0.84, green: 0.79, blue: 0.72, alpha: 1).setFill()
            for x in [16.0, 130.0] {
                NSBezierPath(roundedRect: NSRect(x: x, y: y + 10, width: 34, height: 84),
                             xRadius: 17, yRadius: 17).fill()
            }
        case .zombie:
            NSColor(red: 0.36, green: 0.52, blue: 0.30, alpha: 1).setFill()
            for x in [46.0, 118.0] {
                let tuft = NSBezierPath()
                tuft.move(to: NSPoint(x: x - 10, y: y + 92))
                tuft.line(to: NSPoint(x: x, y: y + 110))
                tuft.line(to: NSPoint(x: x + 10, y: y + 92))
                tuft.close(); tuft.fill()
            }
        default:
            break
        }
    }

    private func drawHood(y: CGFloat) {
        guard self == .xiaohong else { return }
        bodyColor.setFill()
        let hood = NSBezierPath(roundedRect: NSRect(x: 16, y: y + 28, width: 148, height: 84),
                                xRadius: 42, yRadius: 42)
        hood.fill()
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: 82, y: y + 104))
        tip.line(to: NSPoint(x: 90, y: y + 130))
        tip.line(to: NSPoint(x: 98, y: y + 104))
        tip.close(); tip.fill()
    }

    private func drawFace(y: CGFloat, closed: Bool) {
        switch self {
        case .xiaobai:
            NSColor(red: 0.72, green: 0.55, blue: 0.38, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 53, y: y + 54, width: 27, height: 30)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 61, y: y + 17, width: 58, height: 38)).fill()
            eye(63, y + 58, closed: closed)
            eye(105, y + 58, closed: closed)
            NSColor(red: 0.15, green: 0.13, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 84, y: y + 42, width: 12, height: 8)).fill()
        case .xiaohong:
            NSColor(red: 0.99, green: 0.87, blue: 0.77, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 44, y: y + 24, width: 92, height: 64)).fill()
            eye(68, y + 54, closed: closed)
            eye(100, y + 54, closed: closed)
            NSColor(red: 0.72, green: 0.24, blue: 0.24, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 84, y: y + 36, width: 12, height: 6)).fill()
        case .spiderman:
            NSColor.black.withAlphaComponent(0.85).setStroke()
            for (x0, y0, x1, y1) in [(90.0, y + 98, 90.0, y + 46),
                                     (30.0, y + 72, 150.0, y + 72),
                                     (48.0, y + 24, 82.0, y + 98),
                                     (132.0, y + 24, 98.0, y + 98)] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: x0, y: y0)); path.line(to: NSPoint(x: x1, y: y1))
                path.lineWidth = 2; path.stroke()
            }
            for (x, _) in [(56.0, 0), (96.0, 0)] {
                let mask = NSBezierPath(ovalIn: NSRect(x: x, y: y + 50, width: 28, height: 36))
                NSColor.white.setFill(); mask.fill()
                NSColor.black.setStroke(); mask.lineWidth = 3; mask.stroke()
            }
            if closed {
                NSColor(red: 0.86, green: 0.14, blue: 0.17, alpha: 1).setFill()
                for x in [56.0, 96.0] { NSBezierPath(rect: NSRect(x: x - 2, y: y + 62, width: 32, height: 6)).fill() }
            }
        case .zombie:
            NSColor(red: 0.47, green: 0.63, blue: 0.38, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 40, y: y + 28, width: 34, height: 30)).fill()
            NSColor(red: 0.97, green: 0.96, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 58, y: y + 56, width: 16, height: 18)).fill()
            NSColor.darkGray.setFill()
            NSBezierPath(ovalIn: NSRect(x: 63, y: y + 60, width: 7, height: 9)).fill()
            NSColor.darkGray.setStroke()
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: 102, y: y + 56)); cross.line(to: NSPoint(x: 118, y: y + 72))
            cross.move(to: NSPoint(x: 118, y: y + 56)); cross.line(to: NSPoint(x: 102, y: y + 72))
            cross.lineWidth = 3.2; cross.stroke()
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 66, y: y + 30)); mouth.line(to: NSPoint(x: 114, y: y + 30))
            mouth.lineWidth = 2; mouth.stroke()
            for x in stride(from: 72.0, through: 108.0, by: 12.0) {
                let stitch = NSBezierPath()
                stitch.move(to: NSPoint(x: x, y: y + 26)); stitch.line(to: NSPoint(x: x, y: y + 34))
                stitch.lineWidth = 2; stitch.stroke()
            }
        case .shinchan:
            // 碗盖头
            NSColor(red: 0.10, green: 0.09, blue: 0.09, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: y + 74, width: 120, height: 34),
                         xRadius: 16, yRadius: 16).fill()
            NSBezierPath(rect: NSRect(x: 28, y: y + 56, width: 12, height: 36)).fill()
            NSBezierPath(rect: NSRect(x: 140, y: y + 56, width: 12, height: 36)).fill()
            // 粗眉毛
            NSBezierPath(rect: NSRect(x: 52, y: y + 50, width: 26, height: 7)).fill()
            NSBezierPath(rect: NSRect(x: 102, y: y + 50, width: 26, height: 7)).fill()
            eye(64, y + 36, closed: closed)
            eye(108, y + 36, closed: closed)
            NSColor(red: 0.90, green: 0.42, blue: 0.42, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: 44, y: y + 36, width: 18, height: 9)).fill()
            NSBezierPath(ovalIn: NSRect(x: 118, y: y + 36, width: 18, height: 9)).fill()
        }
    }

    private func drawExtras(y: CGFloat) {
        switch self {
        case .xiaobai:
            NSColor(red: 0.94, green: 0.52, blue: 0.56, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 82, y: y + 30, width: 16, height: 10),
                         xRadius: 5, yRadius: 5).fill()
        case .zombie:
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: 46, y: y + 82, width: 64, height: 14),
                         xRadius: 5, yRadius: 5).fill()
            NSColor(red: 0.72, green: 0.72, blue: 0.68, alpha: 1).setStroke()
            for x in [58.0, 78.0, 98.0] {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: y + 83)); line.line(to: NSPoint(x: x, y: y + 95))
                line.lineWidth = 1.5; line.stroke()
            }
        default:
            break
        }
    }

    private func eye(_ x: CGFloat, _ y: CGFloat, closed: Bool) {
        NSColor(red: 0.12, green: 0.11, blue: 0.11, alpha: 1).setFill()
        if closed {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: y + 5)); line.line(to: NSPoint(x: x + 9, y: y + 5))
            line.lineWidth = 3; line.stroke()
        } else {
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 8, height: 11)).fill()
        }
    }
}

enum PetSelection: Equatable {
    case builtin(PetSkin)
    case custom(String)   // 自定义形象的文件名

    var key: String {
        switch self {
        case .builtin(let skin): return "builtin:" + skin.rawValue
        case .custom(let name): return "custom:" + name
        }
    }

    init?(key: String) {
        if key.hasPrefix("builtin:"), let skin = PetSkin(rawValue: String(key.dropFirst(8))) {
            self = .builtin(skin)
        } else if key.hasPrefix("custom:"), !key.dropFirst(7).isEmpty {
            self = .custom(String(key.dropFirst(7)))
        } else {
            return nil
        }
    }
}

@MainActor
final class PetAppearance: ObservableObject {
    static let shared = PetAppearance()
    static let defaultSkin: PetSkin = .xiaobai

    @Published private(set) var selection: PetSelection
    let storage: PetStorage
    private let defaults: UserDefaults
    private var loadedCache: [String: Loaded] = [:]
    private var cancellables = Set<AnyCancellable>()

    private struct Loaded {
        let data: Data
        let image: NSImage?
        let still: NSImage?
    }

    var issue: String? {
        get { storage.issue }
        set { storage.issue = newValue }
    }

    init(defaults: UserDefaults = .standard, storage: PetStorage? = nil) {
        self.defaults = defaults
        let storage = storage ?? PetStorage.shared
        self.storage = storage
        selection = PetSelection(key: defaults.string(forKey: "pet.selection") ?? "") ?? .builtin(Self.defaultSkin)
        storage.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        storage.$assets
            .sink { [weak self] _ in self?.reconcileSelection() }
            .store(in: &cancellables)
        migrateLegacySelection()
        reconcileSelection()
    }

    // MARK: - 选择与读取

    var custom: Bool {
        if case .custom = selection { return true }
        return false
    }

    /// 兼容旧调用：当前如果是自定义形象，返回最近的内置形象（用于图标回退）。
    var skin: PetSkin {
        if case .builtin(let skin) = selection { return skin }
        return Self.defaultSkin
    }

    var label: String { selectedAsset?.name ?? selection.key }

    var selectedAsset: PetAsset? {
        switch selection {
        case .builtin(let skin):
            return storage.assets.first { $0.builtin == skin } ?? storage.assets.first { $0.builtin == Self.defaultSkin }
        case .custom(let name):
            return storage.assets.first { $0.id == "custom:" + name }
        }
    }

    var currentURL: URL? { selectedAsset?.url }
    var animationData: Data? { loaded()?.data }
    var image: NSImage? { loaded()?.image }
    var staticImage: NSImage { loaded()?.still ?? skin.frame(0) }
    var sidebarIcon: NSImage { staticImage }

    func preview(for asset: PetAsset) -> NSImage? {
        let key = "preview:" + cacheKey(for: asset.url)
        if let hit = loadedCache[key] { return hit.still }
        guard let data = try? Data(contentsOf: asset.url), let still = PetGIFCodec.firstFrame(data) else { return nil }
        loadedCache[key] = Loaded(data: data, image: nil, still: still)
        return still
    }

    func select(_ skin: PetSkin) { select(.builtin(skin)) }

    func select(_ asset: PetAsset) {
        if let skin = asset.builtin {
            select(.builtin(skin))
        } else {
            select(.custom(asset.fileName))
        }
    }

    func select(_ selection: PetSelection) {
        guard selection != self.selection else { return }
        self.selection = selection
        defaults.set(selection.key, forKey: "pet.selection")
        issue = nil
    }

    // MARK: - 导入与删除

    /// UI 入口：选择 GIF 后先框选展示区域，再保存为自定义形象。
    func importGIF() {
        let owner = NSApp.keyWindow
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.gif]
        picker.allowsMultipleSelection = false
        picker.message = "选择 GIF，下一步可框选要展示的区域。"
        defer { owner?.makeKeyAndOrderFront(nil) }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard let data = try? Data(contentsOf: url), PetGIFCodec.inspect(data) != nil else {
            issue = "请选择不超过 20 MB、2–300 帧、尺寸适中的 GIF。"
            return
        }
        PetCropWindow.present(data: data, name: url.deletingPathExtension().lastPathComponent,
                              appearance: self)
    }

    /// 直接导入（不裁剪）。测试也使用此入口。
    @discardableResult
    func loadGIF(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), PetGIFCodec.inspect(data) != nil else {
            issue = "请选择不超过 20 MB、2–300 帧、尺寸适中的 GIF。"
            return false
        }
        guard let asset = storage.importGIF(from: url, data: data) else { return false }
        select(asset)
        return true
    }

    /// 对已有自定义形象重新框选（生成新文件，原文件保留）。
    func crop(_ asset: PetAsset) {
        guard let data = try? Data(contentsOf: asset.url), PetGIFCodec.inspect(data) != nil else {
            issue = "无法读取该 GIF。"
            return
        }
        PetCropWindow.present(data: data, name: asset.name + "-裁剪", appearance: self)
    }

    func acceptCropped(_ data: Data, name: String) {
        guard let asset = storage.saveCustom(data: data, preferredName: name) else { return }
        select(asset)
    }

    @discardableResult
    func delete(_ asset: PetAsset) -> Bool {
        let wasSelected = selectedAsset?.id == asset.id
        guard storage.delete(asset) else { return false }
        if wasSelected { select(.builtin(Self.defaultSkin)) }
        return true
    }

    func openFolder() { storage.openFolder() }
    func refresh() { storage.rescan() }

    // MARK: - 私有

    private func loaded() -> Loaded? {
        guard let url = currentURL else {
            // 自定义文件可能已在 Finder 中删除，但目录事件因 App Nap 尚未送达。
            if custom { storage.rescan() }
            return nil
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            storage.rescan()
            if custom { return nil }
        }
        let key = cacheKey(for: url)
        if let hit = loadedCache[key] { return hit }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let value = Loaded(data: data, image: NSImage(data: data), still: PetGIFCodec.firstFrame(data))
        loadedCache[key] = value
        if loadedCache.count > 24 { loadedCache.removeAll() }
        return value
    }

    private func cacheKey(for url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        return url.path + "#" + mtime
    }

    private func reconcileSelection() {
        guard case .custom(let name) = selection else { return }
        if !storage.assets.contains(where: { $0.id == "custom:" + name }) {
            selection = .builtin(Self.defaultSkin)
            defaults.set(selection.key, forKey: "pet.selection")
        }
    }

    /// 旧版本只保存一只 pet-custom.gif；迁移到新目录后继续生效。
    private func migrateLegacySelection() {
        guard defaults.string(forKey: "pet.selection") == nil else { return }
        let legacyURL = TaskCenterStore.dataDirectory.appendingPathComponent("pet-custom.gif")
        if defaults.bool(forKey: "pet.custom"), let data = try? Data(contentsOf: legacyURL),
           let asset = storage.saveCustom(data: data, preferredName: "自定义形象") {
            selection = .custom(asset.fileName)
            defaults.set(selection.key, forKey: "pet.selection")
        }
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
        label = appearance.label
        let stateChanged = hovering != hovered
        hovering = hovered
        animates = false
        if !hovered {
            timer?.invalidate(); timer = nil
            displayedFrame = 0; image = still
        } else if changed || stateChanged {
            drawCurrentFrame()
            // 悬浮后立即推进一帧，避免停在首帧造成“没有反应”的错觉。
            advanceFrame()
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
