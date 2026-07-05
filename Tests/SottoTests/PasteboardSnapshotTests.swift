import AppKit
import Testing
@testable import Sotto

/// The one piece of M0 logic worth a check: borrowing the clipboard for a paste
/// must leave the user's original contents exactly as they were. Runs against a
/// private, uniquely-named pasteboard so it never touches the real system
/// clipboard and never shares state between tests.
///
/// `.serialized`: `NSPasteboard(name:)` returns a process-shared object, and the
/// pasteboard's internal type cache is not safe under the concurrent access that
/// Swift Testing uses by default — parallel runs corrupt it. Unique names per
/// test plus serialized execution keep each case isolated.
@Suite(.serialized)
struct PasteboardSnapshotTests {
    /// A fresh, isolated pasteboard for a single test.
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.chrismckenna.sotto.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func restoresPlainStringAfterBorrowing() {
        let pb = makePasteboard()
        pb.setString("user's original clipboard", forType: .string)

        let snapshot = PasteboardSnapshot.capture(pb)

        // Borrow it for our transcript, as OutputInjector does.
        pb.clearContents()
        pb.setString("dictated transcript", forType: .string)
        #expect(pb.string(forType: .string) == "dictated transcript")

        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "user's original clipboard")
    }

    @Test func restoresEmptyClipboardAsEmpty() {
        let pb = makePasteboard() // nothing on it

        let snapshot = PasteboardSnapshot.capture(pb)

        pb.setString("dictated transcript", forType: .string)
        snapshot.restore(to: pb)

        #expect(pb.string(forType: .string) == nil)
    }

    @Test func preservesMultipleDataTypesOnOneItem() {
        let pb = makePasteboard()
        let custom = NSPasteboard.PasteboardType("com.chrismckenna.sotto.custom")
        let original = NSPasteboardItem()
        original.setString("as text", forType: .string)
        original.setData(Data([0x01, 0x02, 0x03]), forType: custom)
        pb.writeObjects([original])

        let snapshot = PasteboardSnapshot.capture(pb)

        pb.clearContents()
        pb.setString("dictated transcript", forType: .string)

        snapshot.restore(to: pb)
        #expect(pb.string(forType: .string) == "as text")
        #expect(pb.data(forType: custom) == Data([0x01, 0x02, 0x03]))
    }

    @Test func restoreGuardOnlyFiresWhenClipboardUntouched() {
        // Same changeCount as when we wrote the transcript → safe to restore.
        #expect(OutputInjector.shouldRestore(writtenChangeCount: 42, currentChangeCount: 42) == true)
        // The user (or another injection) changed the clipboard → don't clobber it.
        #expect(OutputInjector.shouldRestore(writtenChangeCount: 42, currentChangeCount: 43) == false)
    }
}
