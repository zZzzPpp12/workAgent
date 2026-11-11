import XCTest
import ImageIO
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
            XCTAssertEqual(CGImageSourceGetCount(source), 8)
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
    }
    func testChatEventFilterNeverExposesReasoningOrCommandArguments() {
        XCTAssertEqual(PetChatEvent.parse(["type":"item.completed", "item":["type":"reasoning", "text":"PRIVATE_REASONING"]]), .ignored)
        XCTAssertEqual(PetChatEvent.parse(["type":"item.started", "item":["type":"command_execution", "command":"PRIVATE_COMMAND"]]), .progress("终端命令进行中"))
        XCTAssertEqual(PetChatEvent.parse(["type":"item.completed", "item":["type":"agent_message", "text":"公开回答"]]), .message("公开回答"))
        XCTAssertEqual(PetChatEvent.parse(["type":"turn.completed"]), .completed)
        XCTAssertEqual(PetChatEvent.parse(["type":"turn.failed"]), .failed)
    }
    func testNewChatUsesStdinAndRecordsOnlyConfirmedEnd() async throws {
        let fixture = root.appendingPathComponent("fake-codex")
        try Data("""
        #!/bin/sh
        cat > received.txt
        printf '%s\\n' '{"type":"thread.started","thread_id":"fixture-session"}' '{"type":"item.completed","item":{"type":"agent_message","text":"完成测试"}}' '{"type":"turn.completed"}'
        """.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let chatURL = root.appendingPathComponent("chats.json")
        let store = PetChatStore(url: chatURL, executable: fixture)
        let prompt = "测试中文与 $(touch should-not-exist)"
        XCTAssertTrue(store.send(prompt, project: root.path, new: true))
        for _ in 0..<100 where store.chats.first?.phase == .running { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.chats.first?.phase, .completed)
        XCTAssertEqual(store.chats.first?.sessionID, "fixture-session")
        XCTAssertEqual(store.chats.first?.messages.last?.text, "完成测试")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("received.txt")), prompt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
        XCTAssertEqual(PetChatStore(url: chatURL, executable: fixture).chats.first?.phase, .completed)
    }
    func testExitWithoutExplicitEndIsUnknownAndRestartNeverAssumesSuccess() async throws {
        let fixture = root.appendingPathComponent("fake-no-end")
        try Data("#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"incomplete\"}'\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let chatURL = root.appendingPathComponent("partial-chat.json")
        let store = PetChatStore(url: chatURL, executable: fixture)
        XCTAssertTrue(store.send("测试未结束", project: root.path, new: true))
        for _ in 0..<100 where store.chats.first?.phase == .running { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.chats.first?.phase, .unknown)
        XCTAssertEqual(PetChatStore(url: chatURL, executable: fixture).chats.first?.phase, .unknown)
    }

    func testCustomGIFIsCopiedAndRestoredAndInvalidReplacementPreservesIt() throws {
        let suite = "hakimi-pet-appearance-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let imported = root.appendingPathComponent("import.gif")
        let saved = root.appendingPathComponent("saved/custom.gif")
        let data = try XCTUnwrap(PetSkin.rabbit.gif())
        try data.write(to: imported)
        let appearance = PetAppearance(defaults: defaults, customURL: saved)
        XCTAssertTrue(appearance.loadGIF(imported))
        try FileManager.default.removeItem(at: imported)
        let restored = PetAppearance(defaults: defaults, customURL: saved)
        XCTAssertTrue(restored.custom)
        XCTAssertNotNil(restored.image)
        XCTAssertNotNil(restored.staticImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let invalid = root.appendingPathComponent("invalid.gif")
        try Data("invalid".utf8).write(to: invalid)
        XCTAssertFalse(restored.loadGIF(invalid))
        XCTAssertEqual(try Data(contentsOf: saved), data)
        restored.select(.fox)
        XCTAssertFalse(restored.custom)
        XCTAssertEqual(PetAppearance(defaults: defaults, customURL: saved).skin, .fox)
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
        let appearance = PetAppearance(defaults: defaults, customURL: root.appendingPathComponent("unused.gif"))
        let gif = try XCTUnwrap(PetSkin.cat.gif())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let blink = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 4, nil))
        XCTAssertNotEqual(first.dataProvider?.data as Data?, blink.dataProvider?.data as Data?)
        XCTAssertNotNil(appearance.staticImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let animated = try XCTUnwrap(appearance.image?.representations.first as? NSBitmapImageRep)
        XCTAssertEqual((animated.value(forProperty: .frameCount) as? NSNumber)?.intValue, 8)
    }

    func testHoverPlayerAdvancesPixelsAndRestoresStillImageOnExit() throws {
        let suite = "hakimi-pet-player-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = PetAppearance(defaults: defaults, customURL: root.appendingPathComponent("none.gif"))
        let view = PetGIFImageView()
        view.configure(appearance: appearance, hovered: true)
        let first = view.image?.tiffRepresentation
        for _ in 0..<4 { view.advanceFrame() }
        XCTAssertEqual(view.displayedFrame, 4)
        XCTAssertNotEqual(view.image?.tiffRepresentation, first)
        view.configure(appearance: appearance, hovered: false)
        XCTAssertEqual(view.displayedFrame, 0)
        XCTAssertFalse(view.timerIsActive)
        let stopped = view.image?.tiffRepresentation
        view.advanceFrame()
        XCTAssertEqual(view.image?.tiffRepresentation, stopped)
    }

}
