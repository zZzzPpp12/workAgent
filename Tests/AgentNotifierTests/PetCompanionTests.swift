import XCTest
import ImageIO
import SwiftUI
@testable import AgentNotifier

@MainActor
final class PetCompanionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private var url: URL { root.appendingPathComponent("notes.json") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCRUDPersistsAllKindsAndPinCompletionSearch() throws {
        let store = PetNoteStore(url: url)
        for kind in PetNoteKind.allCases { XCTAssertTrue(store.save(kind: kind, text: "测试" + kind.rawValue, reminder: nil, now: now)) }
        let todo = try XCTUnwrap(store.notes.first { $0.kind == .todo })
        store.toggleDone(todo.id, now: now)
        store.togglePin(todo.id)
        XCTAssertTrue(store.save(id: todo.id, kind: .todo, text: "已编辑待办", reminder: now.addingTimeInterval(60), now: now))
        let restored = PetNoteStore(url: url)
        XCTAssertEqual(restored.notes.count, 4)
        XCTAssertEqual(restored.filtered(search: "编辑", kind: .todo, date: now).first?.id, todo.id)
        XCTAssertEqual(restored.filtered(search: "", kind: nil, date: nil).first?.id, todo.id)
        XCTAssertEqual(restored.notes.first { $0.id == todo.id }?.completed, true)
        restored.delete(todo.id)
        XCTAssertEqual(PetNoteStore(url: url).notes.count, 3)
    }
    func testReminderDefaultAndWakeCatchupAndSnooze() throws {
        let store = PetNoteStore(url: url)
        XCTAssertTrue(store.save(kind: .todo, text: "默认待办", reminder: nil, now: now))
        let note = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(Calendar.current.component(.hour, from: try XCTUnwrap(note.remindAt)), 18)
        XCTAssertTrue(store.due(at: now.addingTimeInterval(86400)).contains { $0.id == note.id })
        XCTAssertTrue(store.acknowledge([note.id], at: now.addingTimeInterval(86400)))
        XCTAssertTrue(PetNoteStore(url: url).due(at: now.addingTimeInterval(86400)).isEmpty)
        XCTAssertTrue(store.save(id: note.id, kind: .todo, text: note.text, reminder: now.addingTimeInterval(90000), now: now))
        XCTAssertEqual(store.due(at: now.addingTimeInterval(90001)).count, 1)
        store.toggleDone(note.id)
        XCTAssertTrue(store.due(at: now.addingTimeInterval(90001)).isEmpty)
    }
    func testCorruptNotesAreNeverOverwritten() throws {
        let broken = Data("not JSON".utf8)
        try broken.write(to: url)
        let store = PetNoteStore(url: url)
        XCTAssertNotNil(store.issue)
        XCTAssertFalse(store.save(kind: .note, text: "new", reminder: nil))
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }
    func testFiveBuiltinsEncodeAnimatedGIFsWithTransparentFrames() throws {
        XCTAssertEqual(PetSkin.allCases.count, 5)
        for skin in PetSkin.allCases {
            let data = try XCTUnwrap(skin.gif())
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), PetSkin.frameCount)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
    }

    func testBuiltinArtUpgradeReplacesStaleGIFs() throws {
        let directory = root.appendingPathComponent("upgrade-pets")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(PetSkin.xiaobai.fileStem + ".gif")
        try Data("stale".utf8).write(to: target)
        try Data("1".utf8).write(to: directory.appendingPathComponent(".art-version"))
        let storage = PetStorage(directory: directory)
        let upgraded = try Data(contentsOf: target)
        XCTAssertNotEqual(upgraded, Data("stale".utf8))
        XCTAssertNotNil(PetGIFCodec.inspect(upgraded))
        storage.seedBuiltins()
        XCTAssertEqual(try Data(contentsOf: target), upgraded)
        XCTAssertFalse(storage.assets.contains { $0.fileName.contains("art-version") })
    }

    func testSidebarPagesExcludeConversationsAndNormalizeLegacySelection() {
        XCTAssertFalse(TaskCenterView.pages.contains { $0.0 == "conversations" || $0.1 == "对话与执行" })
        XCTAssertEqual(TaskCenterView.normalizedPage("conversations"), "overview")
        XCTAssertEqual(TaskCenterView.normalizedPage("pets"), "pets")
        XCTAssertEqual(TaskCenterView.normalizedPage("settings"), "settings")
        XCTAssertLessThan(TaskCenterView.sidebarCollapsedWidth, TaskCenterView.sidebarExpandedWidth)
    }

    func testSidebarDrawerPushesContentInlineWithoutOverlaying() {
        let icon = NSImage(size: NSSize(width: 18, height: 18))
        func host(expanded: Bool) -> NSHostingView<some View> {
            let view = HStack(spacing: 0) {
                TaskCenterSidebarDrawer(
                    page: .constant("overview"),
                    activePage: "overview",
                    expanded: expanded,
                    actionableCount: 2,
                    quiet: false,
                    petIcon: icon
                )
                Rectangle().fill(Color.clear).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
            hosting.layoutSubtreeIfNeeded()
            return hosting
        }

        let collapsed = host(expanded: false)
        let expanded = host(expanded: true)
        let collapsedWidth = TaskCenterSidebarDrawer(
            page: .constant("overview"), activePage: "overview", expanded: false,
            actionableCount: 0, quiet: false, petIcon: icon
        )
        let collapsedSizing = NSHostingView(rootView: collapsedWidth)
        let expandedSizing = NSHostingView(rootView: TaskCenterSidebarDrawer(
            page: .constant("overview"), activePage: "overview", expanded: true,
            actionableCount: 0, quiet: false, petIcon: icon
        ))
        XCTAssertEqual(collapsedSizing.fittingSize.width, TaskCenterView.sidebarCollapsedWidth, accuracy: 0.5)
        XCTAssertEqual(expandedSizing.fittingSize.width, TaskCenterView.sidebarExpandedWidth, accuracy: 0.5)
        XCTAssertEqual(collapsed.frame.width, 960, accuracy: 0.5)
        XCTAssertEqual(expanded.frame.width, 960, accuracy: 0.5)
    }

    func testCustomGIFIsCopiedIntoPetFolderAndRestoredAndInvalidReplacementPreservesIt() throws {
        let suite = "hakimi-pet-appearance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = root.appendingPathComponent("AgentPets")
        let storage = PetStorage(directory: directory)
        let appearance = PetAppearance(defaults: defaults, storage: storage)
        let imported = root.appendingPathComponent("import.gif")
        let data = try XCTUnwrap(PetSkin.xiaohong.gif())
        try data.write(to: imported)
        XCTAssertTrue(appearance.loadGIF(imported), appearance.issue ?? "no issue")
        try FileManager.default.removeItem(at: imported)
        let custom = try XCTUnwrap(appearance.selectedAsset)
        XCTAssertTrue(custom.isCustom)
        XCTAssertEqual(custom.url.resolvingSymlinksInPath().deletingLastPathComponent().path,
                       directory.resolvingSymlinksInPath().path)
        let restored = PetAppearance(defaults: defaults, storage: PetStorage(directory: directory))
        XCTAssertTrue(restored.custom)
        XCTAssertNotNil(restored.image)
        XCTAssertNotNil(restored.staticImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let invalid = root.appendingPathComponent("invalid.gif")
        try Data("invalid".utf8).write(to: invalid)
        XCTAssertFalse(restored.loadGIF(invalid))
        XCTAssertEqual(try Data(contentsOf: custom.url), data)
        restored.select(.xiaohong)
        XCTAssertFalse(restored.custom)
        XCTAssertEqual(PetAppearance(defaults: defaults, storage: storage).skin, .xiaohong)
    }

    func testStorageSeedsFiveBuiltinsAndDetectsGIFsDroppedIntoFolder() throws {
        let directory = root.appendingPathComponent("dropped-pets")
        let storage = PetStorage(directory: directory)
        let builtins = storage.assets.filter { $0.builtin != nil }
        XCTAssertEqual(builtins.count, 5)
        XCTAssertEqual(Set(builtins.compactMap(\.builtin)), Set(PetSkin.allCases))
        for asset in builtins { XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path)) }
        let dropped = directory.appendingPathComponent("我的宠物.gif")
        try XCTUnwrap(PetSkin.zombie.gif()).write(to: dropped)
        storage.rescan()
        XCTAssertTrue(storage.assets.contains { $0.fileName == "我的宠物.gif" })
    }

    func testDeletingCustomAssetRemovesFileAndFallsBackToBuiltin() throws {
        let suite = "hakimi-pet-delete-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = PetStorage(directory: root.appendingPathComponent("delete-pets"))
        let appearance = PetAppearance(defaults: defaults, storage: storage)
        let imported = root.appendingPathComponent("temporary.gif")
        try XCTUnwrap(PetSkin.spiderman.gif()).write(to: imported)
        XCTAssertTrue(appearance.loadGIF(imported), appearance.issue ?? "no issue")
        let asset = try XCTUnwrap(appearance.selectedAsset)
        let url = asset.url
        XCTAssertTrue(appearance.delete(asset))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(appearance.custom)
        XCTAssertEqual(appearance.skin, .xiaobai)
    }

    func testGIFCropProducesExpectedPixelSizeAndKeepsFrames() throws {
        let data = try XCTUnwrap(PetSkin.xiaobai.gif())
        let info = try XCTUnwrap(PetGIFCodec.inspect(data))
        let cropped = try XCTUnwrap(PetGIFCodec.crop(
            data, normalized: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        let output = try XCTUnwrap(PetGIFCodec.inspect(cropped))
        XCTAssertEqual(output.pixelWidth, Int(Double(info.pixelWidth) * 0.5))
        XCTAssertEqual(output.pixelHeight, Int(Double(info.pixelHeight) * 0.5))
        XCTAssertEqual(output.frameCount, info.frameCount)
    }

    func testPetImageViewKeepsDesignSizeInsteadOfGIFPixelSize() throws {
        let view = PetGIFImageView()
        XCTAssertEqual(view.intrinsicContentSize, NSSize(width: 120, height: 120))
        let suite = "hakimi-pet-layout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = PetAppearance(defaults: defaults,
                                       storage: PetStorage(directory: root.appendingPathComponent("layout-pets")))
        let hosting = NSHostingView(rootView: PetAnimatedImage(appearance: appearance, hovered: false)
            .frame(width: 120, height: 120))
        hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 180)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        func findImageView(_ view: NSView) -> PetGIFImageView? {
            if let image = view as? PetGIFImageView { return image }
            for subview in view.subviews { if let found = findImageView(subview) { return found } }
            return nil
        }
        let imageView = try XCTUnwrap(findImageView(hosting))
        XCTAssertEqual(imageView.frame.width, 120, accuracy: 0.5)
        XCTAssertEqual(imageView.frame.height, 120, accuracy: 0.5)
    }

    func testProgressPopupPolicyShowsForNewRunningTaskAndHonorsDismissal() {
        let model = PetProgressModel()
        func task(_ id: String, _ phase: TaskPhase) -> PetTaskProgress {
            PetTaskProgress(id: id, title: "任务 " + id, source: "测试", phase: phase, steps: [], activity: now)
        }
        model.update([task("a", .running)])
        XCTAssertFalse(model.dismissed)
        model.dismiss()
        XCTAssertTrue(model.dismissed)
        // 同一任务继续推进时不重新弹出
        model.update([task("a", .running)])
        XCTAssertTrue(model.dismissed)
        model.update([task("a", .completed)])
        XCTAssertTrue(model.dismissed)
        // 有新任务开始执行 → 默认重新弹出
        model.update([task("a", .completed), task("b", .running)])
        XCTAssertFalse(model.dismissed)
        model.dismiss()
        XCTAssertTrue(model.dismissed)
        // 菜单主动打开可强制恢复
        model.forceShow()
        XCTAssertFalse(model.dismissed)
        // 任务清空后重置，后续新任务照常弹出
        model.update([])
        XCTAssertFalse(model.dismissed)
    }

    func testCropWindowPresentsWithSaveAndCancelActions() throws {        let suite = "hakimi-pet-crop-window-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = PetAppearance(defaults: defaults,
                                       storage: PetStorage(directory: root.appendingPathComponent("crop-pets")))
        let data = try XCTUnwrap(PetSkin.xiaohong.gif())
        PetCropWindow.present(data: data, name: "裁剪窗口测试", appearance: appearance)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "框选要展示的区域" })
        XCTAssertNotNil(window.contentView)
        window.close()
        XCTAssertNil(NSApp.windows.first { $0.title == "框选要展示的区域" && $0.isVisible })
    }

    func testCompletionBindingIsIdempotentAndReopeningRearmsReminder() throws {
        let store = PetNoteStore(url: url)
        XCTAssertTrue(store.save(kind: .todo, text: "定时事项", reminder: now, now: now))
        let id = try XCTUnwrap(store.notes.first?.id)
        XCTAssertTrue(store.acknowledge([id], at: now))
        store.setCompleted(id, completed: true, now: now)
        store.setCompleted(id, completed: true, now: now)
        XCTAssertTrue(store.due(at: now).isEmpty)
        store.setCompleted(id, completed: false, now: now)
        XCTAssertEqual(store.due(at: now).map(\.id), [id])
        XCTAssertEqual(PetNoteStore(url: url).due(at: now).map(\.id), [id])
    }

    func testBuiltinAnimationHasDifferentFramesAndStaticUsesFirstFrame() throws {
        let suite = "hakimi-pet-frames-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = PetAppearance(defaults: defaults,
                                       storage: PetStorage(directory: root.appendingPathComponent("frames-pets")))
        let gif = try XCTUnwrap(PetSkin.xiaobai.gif())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let blink = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 4, nil))
        XCTAssertNotEqual(first.dataProvider?.data as Data?, blink.dataProvider?.data as Data?)
        XCTAssertNotNil(appearance.staticImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let animated = try XCTUnwrap(appearance.image?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual((animated.value(forProperty: .frameCount) as? NSNumber)?.intValue, PetSkin.frameCount)
    }

    func testIdleLoopKeepsAnimatingAndHoverSpeedsUp() throws {
        let suite = "hakimi-pet-player-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = PetAppearance(defaults: defaults,
                                       storage: PetStorage(directory: root.appendingPathComponent("player-pets")))
        let view = PetGIFImageView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 180),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.configure(appearance: appearance, hovered: false)
        // 静止状态也保持缓慢的空闲动作，不再是一张冻结的图。
        XCTAssertTrue(view.timerIsActive)
        XCTAssertFalse(view.hovering)
        XCTAssertEqual(view.frameCount, PetSkin.frameCount)
        view.configure(appearance: appearance, hovered: true)
        // 悬浮后立即推进一帧，响应不等待首个定时器。
        XCTAssertEqual(view.displayedFrame, 1)
        let first = view.image?.tiffRepresentation
        for _ in 0..<4 { view.advanceFrame() }
        XCTAssertEqual(view.displayedFrame, (1 + 4) % view.frameCount)
        XCTAssertNotEqual(view.image?.tiffRepresentation, first)
        view.configure(appearance: appearance, hovered: false)
        XCTAssertTrue(view.timerIsActive)
        XCTAssertTrue(view.image != nil)
        window.contentView = NSView()
        window.close()
    }

}
