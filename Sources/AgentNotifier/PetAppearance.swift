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

    // MARK: - 动画

    /// 内置形象 24 帧、约 1.7 秒一循环；[artVersion] 变化时启动后会覆盖旧文件。
    static let frameCount = 24
    static let frameDuration = 0.07
    static let artVersion = 2

    /// 单帧姿态：整体跳跃/摆动/挤压 + 头部、耳朵、手臂等次级动作。
    struct Pose {
        var hop: CGFloat = 0
        var swayX: CGFloat = 0
        var tilt: CGFloat = 0
        var squash: CGFloat = 1
        var headDy: CGFloat = 0
        var headTilt: CGFloat = 0
        var earFlop: CGFloat = 0
        var armSwing: CGFloat = 0
        var hoodSwing: CGFloat = 0
        var lookX: CGFloat = 0
        var squint: CGFloat = 0
        var blink: Bool = false
    }

    func pose(at index: Int) -> Pose {
        let t = Double(index % Self.frameCount) / Double(Self.frameCount)
        let a = t * 2 * .pi
        let breathe: CGFloat = CGFloat(sin(a)) * 1.1
        func landing(_ center: Double, _ width: Double) -> CGFloat {
            let d = (t - center) / width
            return CGFloat(exp(-d * d))
        }
        func blinks(_ centers: [Double]) -> Bool {
            centers.contains { abs(t - $0) < 0.035 || abs(t - $0 - 1) < 0.035 || abs(t - $0 + 1) < 0.035 }
        }
        var p = Pose()
        switch self {
        case .xiaobai:
            // 轻快小跳：起跳拉伸、落地压扁，耳朵和头跟着甩
            let hop: CGFloat = CGFloat(max(0, sin(a))) * 12
            p.hop = hop + breathe
            p.swayX = CGFloat(sin(a)) * 2.2
            p.tilt = CGFloat(sin(a + 0.55)) * 2.8
            p.squash = 1 - 0.08 * landing(0.5, 0.06) + 0.035 * CGFloat(max(0, sin(a)))
            p.headDy = -hop * 0.10
            p.headTilt = CGFloat(sin(a + 1.2)) * 3.5
            p.earFlop = CGFloat(sin(a + 0.35)) * 11
            p.armSwing = CGFloat(sin(a + 0.2)) * 8
            p.lookX = CGFloat(sin(a + 0.9)) * 1.5
            p.blink = blinks([0.60])
        case .xiaohong:
            // 提着小篮子左右晃，帽尖慢半拍
            let hop: CGFloat = CGFloat(max(0, sin(a + 0.35))) * 8
            p.hop = hop + breathe
            p.swayX = CGFloat(sin(a + 0.4)) * 4.5
            p.tilt = CGFloat(sin(a + 0.9)) * 4.2
            p.squash = 1 - 0.06 * landing(0.444, 0.07)
            p.headDy = -hop * 0.12
            p.headTilt = CGFloat(sin(a + 1.5)) * 4
            p.hoodSwing = CGFloat(sin(a + 0.15)) * 9
            p.armSwing = CGFloat(sin(a + 0.5)) * 7
            p.lookX = CGFloat(sin(a + 1.3)) * 1.5
            p.blink = blinks([0.58, 0.90])
        case .spiderman:
            // 蹲伏—弹跳—落地，幅度最大；面具眼睛随动作眯起
            let jump: CGFloat = CGFloat(max(0, sin(a)))
            let hop: CGFloat = CGFloat(pow(Double(jump), 0.85)) * 20
            p.hop = hop + breathe * 0.6
            p.swayX = CGFloat(sin(a)) * 1.5
            p.tilt = CGFloat(sin(a + 0.5)) * 4.5
            p.squash = 1 - 0.11 * landing(0.52, 0.055) + 0.05 * jump
            p.headDy = -hop * 0.08
            p.headTilt = CGFloat(sin(a + 1.3)) * 3.5
            p.armSwing = CGFloat(sin(a * 2 + 0.7)) * 14
            p.squint = CGFloat(max(0, sin(a + 0.4))) * 0.7
        case .zombie:
            // 一步一晃的趔趄，头慢半拍，双臂前伸
            let lurch: CGFloat = CGFloat(sin(a))
            p.hop = CGFloat(max(0, sin(a * 2))) * 2.5 + breathe
            p.swayX = lurch * 7
            p.tilt = lurch * 6.5
            p.squash = 1 - 0.03 * CGFloat(max(0, -cos(a)))
            p.headDy = CGFloat(sin(a - 0.7)) * 2
            p.headTilt = CGFloat(sin(a - 0.7)) * 7
            p.armSwing = lurch * 15
            p.lookX = CGFloat(sin(a - 0.9)) * 1.5
            p.blink = blinks([0.72])
        case .shinchan:
            // 扭屁屁舞：左右扭、眉毛一上一下
            let wiggle: CGFloat = CGFloat(sin(a * 2))
            p.hop = CGFloat(max(0, sin(a))) * 9 + breathe
            p.swayX = wiggle * 6
            p.tilt = wiggle * 5.5
            p.squash = 1 - 0.05 * landing(0.5, 0.08)
            p.headDy = CGFloat(sin(a + 1.5)) * 1.5
            p.headTilt = -wiggle * 4
            p.armSwing = wiggle * 11
            p.lookX = CGFloat(sin(a + 0.4)) * 1.5
            p.blink = blinks([0.56, 0.86])
        }
        return p
    }

    func frame(_ index: Int) -> NSImage {
        let size = NSSize(width: 180, height: 180)
        let pose = pose(at: index)
        return NSImage(size: size, flipped: false) { _ in
            let y = 45.0
            let lift = min(1, pose.hop / 20)
            // 影子：跳得越高越小越淡
            NSColor.black.withAlphaComponent(0.14 - 0.06 * lift).setFill()
            let shadowWidth = 112 - 26 * lift
            NSBezierPath(ovalIn: NSRect(x: 90 - shadowWidth / 2, y: 16, width: shadowWidth, height: 12)).fill()

            NSGraphicsContext.saveGraphicsState()
            // 全身：以脚底为支点做位移、旋转和挤压/拉伸
            let body = NSAffineTransform()
            body.translateX(by: 90 + pose.swayX, yBy: 30 + pose.hop)
            body.rotate(byDegrees: pose.tilt)
            body.scaleX(by: 1 / max(0.85, pose.squash), yBy: pose.squash)
            body.translateX(by: -90, yBy: -30 - pose.hop)
            body.concat()

            self.drawBehind(y: y, pose: pose)
            // 身体
            if self == .shinchan {
                NSColor(red: 0.85, green: 0.16, blue: 0.16, alpha: 1).setFill()
            } else {
                self.bodyColor.setFill()
            }
            NSBezierPath(roundedRect: NSRect(x: 28, y: y - 16, width: 124, height: 68),
                         xRadius: 32, yRadius: 32).fill()
            self.drawArms(y: y, pose: pose)

            // 头部：绕颈部枢轴做次级摆动
            let hy = y + pose.headDy
            self.rotated(pose.headTilt, around: NSPoint(x: 90, y: hy + 6)) {
                self.bodyColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 28, y: hy + 8, width: 124, height: 90),
                             xRadius: 40, yRadius: 40).fill()
                self.drawHood(y: hy, pose: pose)
                self.drawFace(y: hy, pose: pose)
                self.drawExtras(y: hy, pose: pose)
            }

            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    func gif() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, Self.frameCount, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<Self.frameCount {
            guard let image = frame(i).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: Self.frameDuration]] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 在绘制上下文中围绕指定支点旋转执行一段绘制。
    private func rotated(_ degrees: CGFloat, around point: NSPoint, _ draw: () -> Void) {
        guard abs(degrees) > 0.01 else { draw(); return }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: point.x, yBy: point.y)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -point.x, yBy: -point.y)
        transform.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 绘制

    private func drawBehind(y: CGFloat, pose: Pose) {
        switch self {
        case .xiaobai:
            NSColor(red: 0.84, green: 0.79, blue: 0.72, alpha: 1).setFill()
            let left = NSBezierPath(roundedRect: NSRect(x: 16, y: y + 10, width: 34, height: 84),
                                    xRadius: 17, yRadius: 17)
            let right = NSBezierPath(roundedRect: NSRect(x: 130, y: y + 10, width: 34, height: 84),
                                     xRadius: 17, yRadius: 17)
            rotated(-pose.earFlop, around: NSPoint(x: 33, y: y + 14)) { left.fill() }
            rotated(pose.earFlop, around: NSPoint(x: 147, y: y + 14)) { right.fill() }
        case .zombie:
            NSColor(red: 0.36, green: 0.52, blue: 0.30, alpha: 1).setFill()
            for (index, x) in [46.0, 118.0].enumerated() {
                let tuft = NSBezierPath()
                tuft.move(to: NSPoint(x: x - 10, y: y + 92))
                tuft.line(to: NSPoint(x: x, y: y + 110))
                tuft.line(to: NSPoint(x: x + 10, y: y + 92))
                tuft.close()
                rotated((index == 0 ? -1 : 1) * pose.headTilt * 0.5,
                        around: NSPoint(x: x, y: y + 92)) { tuft.fill() }
            }
        default:
            break
        }
    }

    /// 让角色有四肢参与动作，而不是只有一个整体在平移。
    private func drawArms(y: CGFloat, pose: Pose) {
        let swing = pose.armSwing
        switch self {
        case .xiaobai:
            NSColor(red: 0.86, green: 0.82, blue: 0.76, alpha: 1).setFill()
            for (index, x) in [24.0, 138.0].enumerated() {
                let angle = (index == 0 ? -1 : 1) * swing * 0.7
                rotated(angle, around: NSPoint(x: index == 0 ? 46 : 134, y: y + 30)) {
                    NSBezierPath(roundedRect: NSRect(x: x, y: y - 6, width: 18, height: 40),
                                 xRadius: 9, yRadius: 9).fill()
                }
            }
        case .xiaohong:
            NSColor(red: 0.99, green: 0.87, blue: 0.77, alpha: 1).setFill()
            for (index, x) in [28.0, 136.0].enumerated() {
                let angle = (index == 0 ? -1 : 1) * swing * 0.8
                rotated(angle, around: NSPoint(x: index == 0 ? 48 : 132, y: y + 28)) {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y - 2, width: 16, height: 20)).fill()
                }
            }
        case .spiderman:
            NSColor(red: 0.86, green: 0.14, blue: 0.17, alpha: 1).setFill()
            for (index, x) in [20.0, 140.0].enumerated() {
                let angle = (index == 0 ? -1 : 1) * swing
                rotated(angle, around: NSPoint(x: index == 0 ? 44 : 136, y: y + 30)) {
                    NSBezierPath(roundedRect: NSRect(x: x, y: y - 8, width: 16, height: 44),
                                 xRadius: 8, yRadius: 8).fill()
                }
            }
        case .zombie:
            NSColor(red: 0.47, green: 0.63, blue: 0.38, alpha: 1).setFill()
            for (index, x) in [10.0, 152.0].enumerated() {
                let angle = (index == 0 ? -1 : 1) * (10 + swing * 0.5)
                rotated(angle, around: NSPoint(x: index == 0 ? 44 : 136, y: y + 24)) {
                    NSBezierPath(roundedRect: NSRect(x: x, y: y + 2, width: 24, height: 16),
                                 xRadius: 8, yRadius: 8).fill()
                }
            }
        case .shinchan:
            NSColor(red: 0.99, green: 0.86, blue: 0.71, alpha: 1).setFill()
            for (index, x) in [24.0, 138.0].enumerated() {
                let angle = (index == 0 ? -1 : 1) * swing * 0.9
                rotated(angle, around: NSPoint(x: index == 0 ? 46 : 134, y: y + 26)) {
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 18, height: 18)).fill()
                }
            }
        }
    }

    private func drawHood(y: CGFloat, pose: Pose) {
        guard self == .xiaohong else { return }
        bodyColor.setFill()
        let hood = NSBezierPath(roundedRect: NSRect(x: 16, y: y + 28, width: 148, height: 84),
                                xRadius: 42, yRadius: 42)
        hood.fill()
        let tipX = pose.hoodSwing
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: 82 + tipX, y: y + 104))
        tip.line(to: NSPoint(x: 90 + tipX * 1.4, y: y + 130))
        tip.line(to: NSPoint(x: 98 + tipX, y: y + 104))
        tip.close(); tip.fill()
    }

    private func drawFace(y: CGFloat, pose: Pose) {
        switch self {
        case .xiaobai:
            NSColor(red: 0.72, green: 0.55, blue: 0.38, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 53, y: y + 54, width: 27, height: 30)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 61, y: y + 17, width: 58, height: 38)).fill()
            eye(63, y + 58, closed: pose.blink, lookX: pose.lookX)
            eye(105, y + 58, closed: pose.blink, lookX: pose.lookX)
            NSColor(red: 0.15, green: 0.13, blue: 0.12, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 84, y: y + 42, width: 12, height: 8)).fill()
        case .xiaohong:
            NSColor(red: 0.99, green: 0.87, blue: 0.77, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 44, y: y + 24, width: 92, height: 64)).fill()
            eye(68, y + 54, closed: pose.blink, lookX: pose.lookX)
            eye(100, y + 54, closed: pose.blink, lookX: pose.lookX)
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
            let eyeHeight = 36 * (1 - pose.squint * 0.5)
            for x in [56.0, 96.0] {
                let mask = NSBezierPath(ovalIn: NSRect(x: x, y: y + 50 + (36 - eyeHeight) / 2,
                                                       width: 28, height: eyeHeight))
                NSColor.white.setFill(); mask.fill()
                NSColor.black.setStroke(); mask.lineWidth = 3; mask.stroke()
            }
            if pose.blink {
                NSColor(red: 0.86, green: 0.14, blue: 0.17, alpha: 1).setFill()
                for x in [56.0, 96.0] { NSBezierPath(rect: NSRect(x: x - 2, y: y + 62, width: 32, height: 6)).fill() }
            }
        case .zombie:
            NSColor(red: 0.47, green: 0.63, blue: 0.38, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 40, y: y + 28, width: 34, height: 30)).fill()
            NSColor(red: 0.97, green: 0.96, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 58, y: y + 56, width: 16, height: 18)).fill()
            NSColor.darkGray.setFill()
            NSBezierPath(ovalIn: NSRect(x: 63 + pose.lookX, y: y + 60, width: 7, height: 9)).fill()
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
            // 粗眉毛：随屁屁舞一上一下
            let browDy = pose.armSwing * 0.16
            NSBezierPath(rect: NSRect(x: 52, y: y + 50 + browDy, width: 26, height: 7)).fill()
            NSBezierPath(rect: NSRect(x: 102, y: y + 50 - browDy, width: 26, height: 7)).fill()
            eye(64, y + 36, closed: pose.blink, lookX: pose.lookX)
            eye(108, y + 36, closed: pose.blink, lookX: pose.lookX)
            NSColor(red: 0.90, green: 0.42, blue: 0.42, alpha: 0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: 44, y: y + 36, width: 18, height: 9)).fill()
            NSBezierPath(ovalIn: NSRect(x: 118, y: y + 36, width: 18, height: 9)).fill()
        }
    }

    private func drawExtras(y: CGFloat, pose: Pose) {
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

    private func eye(_ x: CGFloat, _ y: CGFloat, closed: Bool, lookX: CGFloat, squint: CGFloat = 0) {
        NSColor(red: 0.12, green: 0.11, blue: 0.11, alpha: 1).setFill()
        if closed {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: y + 5)); line.line(to: NSPoint(x: x + 9, y: y + 5))
            line.lineWidth = 3; line.stroke()
        } else {
            let height = 11 * (1 - squint * 0.6)
            NSBezierPath(ovalIn: NSRect(x: x + lookX, y: y + (11 - height) / 2,
                                        width: 8, height: height)).fill()
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

/// 显式按 GIF 帧时长播放，在非激活桌宠窗口中也可靠；静止时保持缓慢的空闲动作，悬浮后提速。
@MainActor
final class PetGIFImageView: NSImageView {
    /// 固定设计尺寸：Retina 下 GIF 像素是 360×360，若由图片尺寸决定固有大小，
    /// SwiftUI 会把视图按 360×360 布置并被窗口裁成只露出脸部。
    /// 尺寸对齐参考稿：画布内的角色约占 2/3，120pt 画布对应视觉约 80pt 的小桌宠。
    static let designSize = NSSize(width: 120, height: 120)
    override var intrinsicContentSize: NSSize { Self.designSize }

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
    /// 静止时以 1.7 倍帧间隔慢慢呼吸；悬浮后提速到 0.8 倍，立刻有反应。
    private var speedFactor: Double { hovering ? 0.8 : 1.7 }

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
        if changed { drawCurrentFrame() }
        if changed || stateChanged {
            timer?.invalidate(); timer = nil
            // 悬浮后立即推进一帧，避免停在首帧造成“没有反应”的错觉。
            if hovered && stateChanged { advanceFrame() }
            scheduleFrame()
        } else if timer == nil {
            scheduleFrame()
        }
        setAccessibilityLabel(label + (hovered ? " · 动画播放中" : " · 悠闲待机"))
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        if window == nil {
            displayedFrame = 0
            image = still
        } else {
            scheduleFrame()
        }
    }
    func advanceFrame() {
        guard frameCount > 1 else { return }
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
        guard window != nil, frameCount > 1 else { return }
        timer?.invalidate()
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, displayedFrame, nil) as? [CFString: Any] }
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
        let next = Timer(timeInterval: max(0.02, min(delay, 10) * speedFactor), repeats: false) { [weak self] _ in
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
        let view = PetGIFImageView(frame: NSRect(origin: .zero, size: PetGIFImageView.designSize))
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }
    func updateNSView(_ view: PetGIFImageView, context: Context) {
        view.configure(appearance: appearance, hovered: hovered)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PetGIFImageView, context: Context) -> CGSize? {
        PetGIFImageView.designSize
    }
}
