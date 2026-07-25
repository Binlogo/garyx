import XCTest
@testable import GaryxMobileCore

/// Contract for the message-list fingerprint used to gate transcript work.
///
/// The fingerprint must notice real content changes while staying cheap on
/// resident multi-100 KiB tool payloads: the previous grapheme-view
/// implementation re-walked every long field on every streaming delta
/// (50.7 ms per delta, 44% of main-thread work — #TASK-2703).
final class GaryxMessageListSignatureTests: XCTestCase {
    private func message(id: String = "m1", text: String) -> GaryxMobileMessage {
        GaryxMobileMessage(
            id: id,
            role: .assistant,
            text: text,
            attachments: [],
            timestamp: nil,
            isStreaming: false
        )
    }

    func testIdenticalContentProducesIdenticalSignature() {
        let text = String(repeating: "alpha ", count: 10_000)
        let first = GaryxMessageListSignature.make(for: [message(text: text)])
        let second = GaryxMessageListSignature.make(for: [message(text: text)])
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.sampled, "a long field must report sampling")
    }

    func testShortFieldsAreHashedWholeAndNotSampled() {
        let signature = GaryxMessageListSignature.make(for: [message(text: "short body")])
        XCTAssertFalse(signature.sampled)

        // Any change inside a whole-hashed field is always observed.
        XCTAssertNotEqual(
            signature,
            GaryxMessageListSignature.make(for: [message(text: "short bodX")])
        )
    }

    func testStreamingAppendChangesSignature() {
        // The dominant real mutation: deltas append at the tail.
        let base = String(repeating: "token ", count: 40_000)
        let before = GaryxMessageListSignature.make(for: [message(text: base)])
        let after = GaryxMessageListSignature.make(for: [message(text: base + "next")])
        XCTAssertNotEqual(before, after)
    }

    func testHeadMiddleAndTailEditsAreAllObservedInLongFields() {
        let filler = String(repeating: "x", count: 60_000)
        let base = "HEAD" + filler + "MIDDLE" + filler + "TAIL"
        let baseline = GaryxMessageListSignature.make(for: [message(text: base)])

        let headEdited = base.replacingOccurrences(of: "HEAD", with: "head")
        let tailEdited = base.replacingOccurrences(of: "TAIL", with: "tail")
        let middleEdited = base.replacingOccurrences(of: "MIDDLE", with: "middlE")

        XCTAssertNotEqual(baseline, GaryxMessageListSignature.make(for: [message(text: headEdited)]))
        XCTAssertNotEqual(baseline, GaryxMessageListSignature.make(for: [message(text: tailEdited)]))
        XCTAssertNotEqual(
            baseline,
            GaryxMessageListSignature.make(for: [message(text: middleEdited)]),
            "the middle sample window must still cover same-length interior edits"
        )
    }

    func testLengthChangeAloneChangesSignature() {
        let base = String(repeating: "y", count: 5_000)
        XCTAssertNotEqual(
            GaryxMessageListSignature.make(for: [message(text: base)]),
            GaryxMessageListSignature.make(for: [message(text: base + "y")])
        )
    }

    func testNonContiguousStorageProducesTheSameSignatureAsNativeStorage() {
        // Bridged/foreign storage takes the fallback path; both paths must
        // agree so a signature never flips on storage form alone.
        let native = String(repeating: "élan ", count: 20_000)
        let bridged = String(NSString(string: native))
        XCTAssertEqual(
            GaryxMessageListSignature.make(for: [message(text: native)]),
            GaryxMessageListSignature.make(for: [message(text: bridged)])
        )
    }

    func testLargePayloadSignatureStaysConstantTime() {
        // Guard the regression that motivated the fix: cost must not scale
        // with payload size. 4 MiB is ~20x the p99 tool result; the old
        // grapheme-walking implementation needed tens of milliseconds per
        // field, so a generous ceiling still fails it.
        let payload = String(repeating: "z", count: 4 * 1_024 * 1_024)
        let messages = [message(text: payload)]
        let started = Date()
        for _ in 0..<20 {
            _ = GaryxMessageListSignature.make(for: messages)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed,
            0.5,
            "20 signatures over a 4 MiB field must stay far below one frame budget each"
        )
    }
}
