#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import SusuCore

/// Clock whose time moves only when the test says so.
final class FakeClock: SusuClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    private var _sleepers = 0

    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    var sleepers: Int { lock.lock(); defer { lock.unlock() }; return _sleepers }

    func advance(by seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }

    func sleep(seconds: TimeInterval) async throws {
        let deadline = lock.withLock { () -> TimeInterval in _sleepers += 1; return time + seconds }
        defer { lock.withLock { _sleepers -= 1 } }
        while now() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func waitForSleeper() async {
        for _ in 0..<2000 where sleepers == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}

func makePrivatePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
}

func pngData() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

@Suite struct PasteboardSnapshotTests {
    @Test func restoresTextImageAndFileWithoutLoss() throws {
        let pb = makePrivatePasteboard()
        let text = NSPasteboardItem()
        text.setString("Привет, мир", forType: .string)
        let image = NSPasteboardItem()
        let png = pngData()
        let tiff = NSBitmapImageRep(data: png)!.tiffRepresentation!
        image.setData(png, forType: .png)
        image.setData(tiff, forType: .tiff)
        let file = NSPasteboardItem()
        file.setString(URL(fileURLWithPath: "/tmp/some file.txt").absoluteString, forType: .fileURL)
        pb.clearContents()
        #expect(pb.writeObjects([text, image, file]))

        let snap = PasteboardSnapshot.capture(from: pb)
        #expect(snap.items.count == 3)

        pb.clearContents()
        pb.setString("something else", forType: .string)
        snap.restore(to: pb)

        #expect(PasteboardSnapshot.capture(from: pb) == snap)
        #expect(pb.pasteboardItems?[0].string(forType: .string) == "Привет, мир")
        #expect(pb.pasteboardItems?[1].data(forType: .png) == png)
        #expect(pb.pasteboardItems?[1].data(forType: .tiff) == tiff)
        #expect(pb.pasteboardItems?[2].string(forType: .fileURL) == URL(fileURLWithPath: "/tmp/some file.txt").absoluteString)
    }

    @Test func emptySnapshotClearsPasteboard() {
        let pb = makePrivatePasteboard()
        let snap = PasteboardSnapshot.capture(from: pb)
        pb.setString("x", forType: .string)
        snap.restore(to: pb)
        #expect(pb.pasteboardItems?.isEmpty ?? true)
    }
}

@Suite struct InserterTests {
    let ctx = ContextSnapshot(appName: "A", pid: 10, focusedElementID: "f1")

    /// Presser that behaves like an app: reads the pasteboard string when asked.
    func readingPresser(_ pb: NSPasteboard) -> @Sendable () -> Void {
        nonisolated(unsafe) let pb = pb
        return { _ = pb.string(forType: .string) }
    }

    @Test func requestedThenRestoredAfter150ms() async {
        let pb = makePrivatePasteboard()
        pb.setString("old clipboard", forType: .string)
        let clock = FakeClock()
        let inserter = Inserter(pasteboard: pb, clock: clock, pressPaste: readingPresser(pb), pressReturn: {})
        let t0 = clock.now()

        let task = Task { await inserter.insert(text: "hello", expected: ctx, current: ctx) }
        await clock.waitForSleeper()
        // App has taken the text; restore is waiting for 150 ms.
        #expect(pb.string(forType: .string) == "hello")
        #expect(pb.pasteboardItems?.first?.types.contains(Inserter.transientType) == true)
        #expect(pb.pasteboardItems?.first?.types.contains(Inserter.concealedType) == true)
        clock.advance(by: 0.149)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(pb.string(forType: .string) == "hello")
        clock.advance(by: 0.002)
        let result = await task.value

        #expect(result.status == .inserted)
        #expect(result.takenAt == t0)
        #expect(pb.string(forType: .string) == "old clipboard")
    }

    @Test func notRequestedWithin500msIsNotInsertedAndRestored() async {
        let pb = makePrivatePasteboard()
        pb.setString("old clipboard", forType: .string)
        let clock = FakeClock()
        let inserter = Inserter(pasteboard: pb, clock: clock, pressPaste: {}, pressReturn: {})

        let task = Task { await inserter.insert(text: "hello", expected: ctx, current: ctx) }
        await clock.waitForSleeper()
        clock.advance(by: 0.49)
        try? await Task.sleep(nanoseconds: 20_000_000)
        // Still waiting. Don't read the string: that would count as the app taking the text.
        #expect(pb.pasteboardItems?.first?.types.contains(Inserter.transientType) == true)
        clock.advance(by: 0.02)
        let result = await task.value

        #expect(result == InsertResult(status: .notInserted, takenAt: nil))
        #expect(pb.string(forType: .string) == "old clipboard")
    }

    @Test func foreignPasteboardChangeIsNotOverwritten() async {
        let pb = makePrivatePasteboard()
        pb.setString("old clipboard", forType: .string)
        let clock = FakeClock()
        let inserter = Inserter(pasteboard: pb, clock: clock, pressPaste: readingPresser(pb), pressReturn: {})

        let task = Task { await inserter.insert(text: "hello", expected: ctx, current: ctx) }
        await clock.waitForSleeper()
        pb.clearContents()
        pb.setString("user copied this", forType: .string)
        clock.advance(by: 0.2)
        let result = await task.value

        #expect(result.status == .inserted)
        #expect(pb.string(forType: .string) == "user copied this")
    }

    @Test func differentPidCopiesOnly() async {
        let pb = makePrivatePasteboard()
        pb.setString("old clipboard", forType: .string)
        let pressed = Counter()
        let inserter = Inserter(pasteboard: pb, clock: FakeClock(), pressPaste: { pressed.bump() }, pressReturn: {})
        var other = ctx; other.pid = 11

        let result = await inserter.insert(text: "hello", expected: ctx, current: other)

        #expect(result == InsertResult(status: .copiedOnly, takenAt: nil))
        #expect(pb.string(forType: .string) == "hello")
        #expect(pb.pasteboardItems?.first?.types.contains(Inserter.transientType) == false)
        #expect(pressed.value == 0)
    }

    @Test func differentFocusedFieldCopiesOnly() async {
        let pb = makePrivatePasteboard()
        let inserter = Inserter(pasteboard: pb, clock: FakeClock(), pressPaste: {}, pressReturn: {})
        var other = ctx; other.focusedElementID = "f2"
        let result = await inserter.insert(text: "hello", expected: ctx, current: other)
        #expect(result.status == .copiedOnly)
    }

    @Test func secureFieldCopiesOnlyAndNeverPastes() async {
        let pressed = Counter()
        let inserter = Inserter(pasteboard: makePrivatePasteboard(), clock: FakeClock(), pressPaste: { pressed.bump() }, pressReturn: {})
        var secure = ctx; secure.isSecureField = true
        let result = await inserter.insert(text: "hello", expected: ctx, current: secure)
        #expect(result.status == .copiedOnly)
        #expect(pressed.value == 0)
    }

    @Test func unknownCurrentTargetCopiesOnly() async {
        let pressed = Counter()
        let inserter = Inserter(pasteboard: makePrivatePasteboard(), clock: FakeClock(), pressPaste: { pressed.bump() }, pressReturn: {})
        #expect(await inserter.insert(text: "hello", expected: ctx, current: nil).status == .copiedOnly)
        #expect(await inserter.insert(text: "hello", expected: ctx, current: ContextSnapshot()).status == .copiedOnly)
        #expect(pressed.value == 0)
    }

    @Test func pressReturnCallsPresser() {
        let pressed = Counter()
        let inserter = Inserter(pasteboard: makePrivatePasteboard(), clock: FakeClock(), pressPaste: {}, pressReturn: { pressed.bump() })
        inserter.pressReturn()
        #expect(pressed.value == 1)
    }

    @Test func vKeyCodeIsFound() {
        // On any layout the lookup returns some valid key code (ANSI "v" = 9 on QWERTY).
        #expect(KeySynthesis.keyCodeForV() < 128)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
#endif
