import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// 一个可用的宠物形象：内置形象或用户放进宠物文件夹的 GIF。
struct PetAsset: Identifiable, Equatable {
    /// "builtin:<名字>" 或 "custom:<文件名>"
    let id: String
    let name: String
    let url: URL
    /// 内置形象对应的枚举；自定义 GIF 为 nil。
    let builtin: PetSkin?

    var isCustom: Bool { builtin == nil }
    var fileName: String { url.lastPathComponent }
}

/// ~/Downloads/AgentPets 是所有宠物形象的统一存放目录：内置形象在启动时补齐为 GIF，
/// 用户直接拖进文件夹（或通过导入按钮）的 GIF 也会被识别。删除只针对自定义形象。
@MainActor
final class PetStorage: ObservableObject {
    static let shared = PetStorage()

    @Published private(set) var assets: [PetAsset] = []
    @Published var issue: String?

    let directory: URL
    private let fileManager = FileManager.default
    private var watcher: DispatchSourceFileSystemObject?

    nonisolated static var defaultDirectory: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("AgentPets", isDirectory: true)
    }

    init(directory: URL = PetStorage.defaultDirectory) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        seedBuiltins()
        rescan()
        watchDirectory()
    }

    deinit { watcher?.cancel() }

    func fileURL(for skin: PetSkin) -> URL {
        directory.appendingPathComponent(skin.fileStem + ".gif")
    }

    /// 内置形象落盘为 GIF，缺失时补回；用户删除自定义形象不受影响。
    func seedBuiltins() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for skin in PetSkin.allCases {
            let target = fileURL(for: skin)
            guard !fileManager.fileExists(atPath: target.path), let data = skin.gif() else { continue }
            do { try data.write(to: target, options: .atomic) }
            catch { issue = "内置形象写入失败：\(error.localizedDescription)" }
        }
    }

    /// 重新扫描目录。内置形象始终可用，自定义形象按文件名排序。
    func rescan() {
        seedBuiltins()
        var next: [PetAsset] = PetSkin.allCases.map { skin in
            PetAsset(id: "builtin:" + skin.rawValue, name: skin.rawValue,
                     url: fileURL(for: skin), builtin: skin)
        }
        let builtinNames = Set(PetSkin.allCases.map { $0.fileStem + ".gif" })
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard file.pathExtension.lowercased() == "gif",
                  !builtinNames.contains(file.lastPathComponent),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            next.append(PetAsset(id: "custom:" + file.lastPathComponent, name: name, url: file, builtin: nil))
        }
        if next != assets { assets = next }
    }

    /// 把外部 GIF 复制进宠物目录，重名时自动追加序号。
    @discardableResult
    func importGIF(from source: URL, data: Data? = nil) -> PetAsset? {
        let name = source.deletingPathExtension().lastPathComponent
        guard let payload = data ?? (try? Data(contentsOf: source)) else {
            issue = "无法读取所选 GIF。"
            return nil
        }
        guard PetGIFCodec.inspect(payload) != nil else {
            issue = "请选择不超过 20 MB、2–300 帧、尺寸适中的 GIF。"
            return nil
        }
        guard let target = uniqueURL(for: sanitized(name)) else {
            issue = "无法在宠物文件夹中创建文件。"
            return nil
        }
        do {
            try payload.write(to: target, options: .atomic)
            issue = nil
            rescan()
            // 目录枚举会解析 /var → /private/var，按文件名匹配更稳妥。
            return assets.first { $0.url.lastPathComponent == target.lastPathComponent }
        } catch {
            issue = "导入失败：\(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func saveCustom(data: Data, preferredName: String) -> PetAsset? {
        guard PetGIFCodec.inspect(data) != nil else {
            issue = "请选择不超过 20 MB、2–300 帧、尺寸适中的 GIF。"
            return nil
        }
        guard let target = uniqueURL(for: sanitized(preferredName)) else {
            issue = "无法在宠物文件夹中创建文件。"
            return nil
        }
        do {
            try data.write(to: target, options: .atomic)
            issue = nil
            rescan()
            return assets.first { $0.url.lastPathComponent == target.lastPathComponent }
        } catch {
            issue = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 删除自定义形象（移入废纸篓，失败时直接删除）。内置形象不可删除。
    @discardableResult
    func delete(_ asset: PetAsset) -> Bool {
        guard asset.isCustom else {
            issue = "内置形象不可删除，可在管理页切换。"
            return false
        }
        do {
            try fileManager.trashItem(at: asset.url, resultingItemURL: nil)
        } catch {
            try? fileManager.removeItem(at: asset.url)
        }
        rescan()
        issue = nil
        return true
    }

    func openFolder() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    func reveal(_ asset: PetAsset) {
        NSWorkspace.shared.activateFileViewerSelecting([asset.url])
    }

    // MARK: - 私有

    private func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: invalid).joined(separator: "-")
        return trimmed.isEmpty ? "自定义形象" : String(trimmed.prefix(60))
    }

    private func uniqueURL(for name: String) -> URL? {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var candidate = directory.appendingPathComponent(name + ".gif")
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) (\(index)).gif")
            index += 1
            if index > 200 { return nil }
        }
        return candidate
    }

    /// 监听目录内容变化：用户直接在 Finder 中添加或删除 GIF 时自动刷新。
    private func watchDirectory() {
        watcher?.cancel()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}

/// GIF 校验、首帧提取与区域裁剪。裁剪结果重新编码为独立 GIF 帧。
enum PetGIFCodec {
    struct Info: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        let frameCount: Int
        var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    }

    static let maximumBytes = 20_000_000
    static let maximumPixelsPerFrame = 2_048
    static let maximumFrameBudget = 60_000_000

    static func inspect(_ data: Data) -> Info? {
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier else { return nil }
        let count = CGImageSourceGetCount(source)
        guard (2...300).contains(count),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= maximumPixelsPerFrame, height <= maximumPixelsPerFrame,
              width * height * count <= maximumFrameBudget else { return nil }
        return Info(pixelWidth: width, pixelHeight: height, frameCount: count)
    }

    static func firstFrame(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// normalized 使用显示坐标（原点在左上角，取值 0…1）。
    static func crop(_ data: Data, normalized: CGRect) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let clamped = CGRect(x: normalized.minX.clamped01, y: normalized.minY.clamped01,
                             width: normalized.width.clamped01, height: normalized.height.clamped01)
        guard clamped.width > 0.02, clamped.height > 0.02 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.gif.identifier as CFString, count, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        var outputSize: CGSize = .zero
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let width = CGFloat(image.width), height = CGFloat(image.height)
            var rect = CGRect(x: clamped.minX * width, y: clamped.minY * height,
                              width: clamped.width * width, height: clamped.height * height).integral
            rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard rect.width >= 8, rect.height >= 8, let cropped = image.cropping(to: rect) else { continue }
            if outputSize == .zero { outputSize = rect.size }
            let frame = scaled(cropped, to: outputSize) ?? cropped
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay
                ]
            ] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func scaled(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard Int(size.width) != image.width || Int(size.height) != image.height else { return image }
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}

private extension CGFloat {
    var clamped01: CGFloat { Swift.min(Swift.max(self, 0), 1) }
}
