import XCTest
@testable import JXCodeCore

/// 2.4 — the streaming path's own hygiene, at the socket.
///
/// Three claims that only a real connection can settle, because each one is
/// about *when* bytes move rather than about what they say:
///
///  1. The keep-alive deadline resets on any upstream byte, not on a parsed
///     event. A large `input_json_delta` arrives as hundreds of bytes and no
///     newline, and a router that measured silence by parsed events would inject
///     a ping into the middle of the frame — corrupting the JSON the client is
///     assembling.
///  2. A genuinely silent upstream still gets a ping, or the first claim would
///     be satisfied by removing the feature.
///  3. A multi-byte scalar split across two upstream *chunks* survives. The
///     existing boundary tests split a scalar at the router's own volume flush;
///     this is the other half of the same hazard, one layer down, and it is the
///     ordinary case rather than a corner — TCP is free to cut anywhere.
final class StreamHygieneTests: XCTestCase {

    /// A native Anthropic stream, so the router forwards the upstream's own
    /// frames rather than re-framing them. That keeps the transcript readable
    /// and the ping's position unambiguous.
    private func nativeHarness(keepAlive: TimeInterval) throws -> RouterHarness {
        try RouterHarness(kind: .anthropic, keepAliveInterval: keepAlive)
    }

    private func request(streaming: Bool = true) -> String {
        """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"say hello"}]}
        """
    }

    /// Split a frame into pieces, cutting after each byte offset given.
    ///
    /// Offsets are byte offsets on purpose: the point of several of these tests
    /// is to land a cut *inside* a scalar, which a `Character`-based split
    /// cannot express.
    private func pieces(of frame: String, cuttingAfter offsets: [Int]) -> [Data] {
        let bytes = Array(frame.utf8)
        var out: [Data] = []
        var start = 0
        for offset in offsets {
            out.append(Data(Array(bytes[start..<offset])))
            start = offset
        }
        out.append(Data(Array(bytes[start...])))
        return out
    }

    // MARK: - The keep-alive deadline

    /// A frame that takes eight times the keep-alive interval to arrive, in
    /// pieces, must produce no ping at all.
    ///
    /// The pieces are all part of one frame, so at no point is there a complete
    /// event to parse — which is exactly the state a naive "reset on parsed
    /// event" implementation would read as silence.
    func testAPingIsNotInjectedWhileAFrameIsStillArriving() async throws {
        let harness = try nativeHarness(keepAlive: 0.25)

        // A large `input_json_delta` is the real-world case: one event, a big
        // payload, no newline until it ends.
        let payload = String(repeating: "a", count: 400)
        let frame = "event: content_block_delta\n"
            + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\#(payload)"}}"#
            + "\n\n"
        let closing = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

        harness.upstream.alwaysStream = true
        // Eight pieces, 100 ms apart: 700 ms of arriving bytes against a 250 ms
        // deadline. Every piece resets it; none of them is a parsed event.
        let cut = frame.utf8.count / 8
        harness.upstream.streamPieces =
            pieces(of: frame, cuttingAfter: [cut, cut * 2, cut * 3, cut * 4, cut * 5, cut * 6, cut * 7])
            + [Data(closing.utf8)]
        harness.upstream.dripDelay = 0.1

        let transcript = try await harness.streamPost("/v1/messages", body: request())

        XCTAssertFalse(
            transcript.contains("event: ping"),
            "a ping was injected while the frame was still arriving — the deadline is being "
                + "reset on parsed events rather than on bytes"
        )
        XCTAssertTrue(transcript.contains("event: message_stop"), transcript.suffix(300).description)
        XCTAssertFalse(transcript.contains("\u{FFFD}"), "the frame was corrupted in transit")
    }

    /// The other half of the pair: when the upstream really does go quiet for
    /// longer than the interval, a ping must be written.
    ///
    /// Without this, the test above would pass on a router with no keep-alive at
    /// all — and Claude Code aborts a stream after 300 seconds of silence, which
    /// a local model loading a long context exceeds.
    func testAPingIsWrittenWhenTheUpstreamIsGenuinelySilent() async throws {
        let harness = try nativeHarness(keepAlive: 0.25)

        let opening = "event: content_block_start\n"
            + #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
            + "\n\n"
        let closing = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

        harness.upstream.alwaysStream = true
        // One frame, then 900 ms of nothing, then the terminator.
        harness.upstream.streamPieces = [Data(opening.utf8), Data(closing.utf8)]
        harness.upstream.dripDelay = 0.9

        let transcript = try await harness.streamPost("/v1/messages", body: request())

        XCTAssertTrue(
            transcript.contains("event: ping"),
            "900 ms of silence at a 250 ms interval produced no ping:\n\(transcript)"
        )
        // And the barrier holds: `stop()` runs before the reader writes the
        // terminal frame, so no ping can follow it. A ping after `message_stop`
        // is a frame the client rejects, and the race that produces it is
        // invisible whenever the upstream is fast.
        let afterStop = transcript.components(separatedBy: "event: message_stop").dropFirst()
        XCTAssertTrue(
            afterStop.allSatisfy { !$0.contains("event: ping") },
            "a ping was written after the terminal event:\n\(transcript)"
        )
    }

    // MARK: - A cut inside a scalar, from the socket

    /// A four-byte scalar split across two upstream chunks, on the route that
    /// forwards the client's own bytes.
    ///
    /// `testAMultiByteScalarStraddlingTheAnthropicPassthroughBoundarySurvives`
    /// covers a cut at the router's 8192-byte volume flush, which is a cut the
    /// router *chooses*. This is a cut the network chooses, and it needs no
    /// large payload — so it is the one that happens in ordinary use.
    func testAScalarSplitAcrossTwoUpstreamChunksSurvivesTheNativeRoute() async throws {
        let harness = try nativeHarness(keepAlive: 0)

        let frame = "event: content_block_delta\n"
            + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#("\u{1F642}")"}}"#
            + "\n\n"
        let closing = "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

        // Cut two bytes into the emoji: two of its four bytes go in the first
        // chunk, two in the second.
        let emojiByteOffset = "event: content_block_delta\n"
            .count + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""#.count
        harness.upstream.alwaysStream = true
        harness.upstream.streamPieces =
            pieces(of: frame, cuttingAfter: [emojiByteOffset + 2]) + [Data(closing.utf8)]

        let transcript = try await harness.streamPost("/v1/messages", body: request())

        XCTAssertFalse(
            transcript.contains("\u{FFFD}"),
            "a scalar cut across two chunks decoded to U+FFFD:\n\(transcript)"
        )
        XCTAssertTrue(transcript.contains("\u{1F642}"), "the character did not arrive:\n\(transcript)")
    }

    /// The same cut, on the route that re-frames the upstream's events.
    ///
    /// Different code, same hazard: here the router accumulates into `pending`
    /// and only decodes at a newline, so the bytes must survive the *parser's*
    /// buffer rather than the forwarder's.
    func testAScalarSplitAcrossTwoUpstreamChunksSurvivesTheTranslatedRoute() async throws {
        let harness = try RouterHarness(keepAliveInterval: 0)

        let payload = #"{"id":"c","choices":[{"index":0,"delta":{"content":"\#("\u{1F642}")"}}]}"#
        let frame = "data: \(payload)\r\n\r\n"
        let closing = "data: {\"id\":\"c\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\n"

        let emojiByteOffset = "data: ".count
            + #"{"id":"c","choices":[{"index":0,"delta":{"content":""#.count
        harness.upstream.streamPieces =
            pieces(of: frame, cuttingAfter: [emojiByteOffset + 2]) + [Data(closing.utf8)]

        let transcript = try await harness.streamPost("/v1/messages", body: request())

        XCTAssertFalse(
            transcript.contains("\u{FFFD}"),
            "a scalar cut across two chunks decoded to U+FFFD:\n\(transcript)"
        )
        XCTAssertTrue(transcript.contains("\u{1F642}"), "the character did not arrive:\n\(transcript)")
        XCTAssertTrue(transcript.contains("event: message_stop"), transcript.suffix(300).description)
    }
}
