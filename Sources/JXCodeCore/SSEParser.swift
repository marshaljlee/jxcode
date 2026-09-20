import Foundation

/// One dispatched server-sent event.
public struct SSEEvent: Sendable, Equatable {
    /// The `event:` field. Absent for OpenAI-style streams, which only send `data:`.
    public var name: String?
    public var data: String
    public var id: String?

    public init(name: String? = nil, data: String, id: String? = nil) {
        self.name = name
        self.data = data
        self.id = id
    }

    /// Whether this is OpenAI's end-of-stream sentinel.
    public var isDone: Bool { data == "[DONE]" }
}

/// Incremental `text/event-stream` parser.
///
/// Two things force this to work on **UTF-8 bytes rather than `String`s**, and
/// both produce silent failures rather than errors if you get them wrong:
///
///  1. **`"\r\n"` is a single `Character` in Swift.** CR+LF forms one extended
///     grapheme cluster, so in a CRLF stream `string.firstIndex(of: "\n")`
///     finds *nothing* — there is no standalone LF character to find. The parse
///     loop then never executes and every event is dropped, with no error. A
///     server using CRLF is perfectly legal and several do.
///  2. **A chunk boundary can split a multi-byte scalar.** Decoding per chunk
///     would corrupt that scalar. Buffering bytes and decoding only complete
///     lines means a split scalar is never decoded at all.
///
/// Feeding bytes and searching for the byte `0x0A` avoids both problems, and
/// `flush()` covers servers that omit the final blank line.
public struct SSEParser: Sendable {

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private var buffer: [UInt8] = []
    private var pendingName: String?
    private var pendingID: String?
    private var dataLines: [String] = []

    public init() {}

    /// Feed raw bytes. This is the entry point the router uses.
    public mutating func feed(_ data: Data) -> [SSEEvent] {
        feed(Array(data))
    }

    public mutating func feed(_ bytes: [UInt8]) -> [SSEEvent] {
        guard !bytes.isEmpty else { return [] }
        buffer.append(contentsOf: bytes)

        var events: [SSEEvent] = []
        while let index = buffer.firstIndex(of: Self.lineFeed) {
            var lineBytes = Array(buffer[0..<index])
            buffer.removeFirst(index + 1)

            // Tolerate CRLF, which some proxies emit.
            if lineBytes.last == Self.carriageReturn { lineBytes.removeLast() }

            if let event = consume(line: String(decoding: lineBytes, as: UTF8.self)) {
                events.append(event)
            }
        }
        return events
    }

    /// Convenience for callers that already have text.
    public mutating func feed(_ chunk: String) -> [SSEEvent] {
        feed(Array(chunk.utf8))
    }

    /// Emit any event left in the buffer when the connection closes.
    ///
    /// Some backends omit the final blank line. Without this the last event is
    /// dropped, which loses the `message_delta` carrying `stop_reason` and
    /// leaves the client waiting for a reason that never arrives.
    public mutating func flush() -> [SSEEvent] {
        var events: [SSEEvent] = []

        if !buffer.isEmpty {
            var lineBytes = buffer
            buffer = []
            if lineBytes.last == Self.carriageReturn { lineBytes.removeLast() }
            if let event = consume(line: String(decoding: lineBytes, as: UTF8.self)) {
                events.append(event)
            }
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    /// Handle one complete line. Returns an event when the line ends one.
    private mutating func consume(line: String) -> SSEEvent? {
        // Blank line terminates the event.
        if line.isEmpty { return dispatch() }

        // A line starting with ':' is a comment; servers use it as a keep-alive.
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            value = String(line[line.index(after: colon)...])
            // Exactly one optional leading space is stripped, per spec.
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "event": pendingName = value
        case "data":  dataLines.append(value)
        case "id":    pendingID = value
        case "retry": break // Reconnection policy; not ours to honour.
        default:      break // Unknown fields are ignored per spec.
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            pendingName = nil
            pendingID = nil
            dataLines = []
        }
        guard !dataLines.isEmpty || pendingName != nil else { return nil }
        // Multiple `data:` lines join with newlines.
        return SSEEvent(
            name: pendingName,
            data: dataLines.joined(separator: "\n"),
            id: pendingID
        )
    }
}

/// Frames `text/event-stream` responses.
public enum SSEWriter {

    /// Encode one event. The trailing blank line is what tells the client the
    /// event is complete; omitting it makes the client buffer indefinitely.
    public static func frame(name: String? = nil, data: String) -> String {
        var out = ""
        if let name { out += "event: \(name)\n" }
        // Split on the byte, not the Character: a payload containing CRLF would
        // not split on `"\n"` because CR+LF is one grapheme cluster.
        for line in data.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            out += "data: "
            out += String(decoding: line, as: UTF8.self)
            out += "\n"
        }
        out += "\n"
        return out
    }

    /// OpenAI's terminator, forwarded verbatim.
    public static var done: String { frame(data: "[DONE]") }

    /// A keep-alive comment. Useful while waiting on a slow upstream so
    /// intermediate proxies do not close an idle connection.
    public static var comment: String { ": ping\n\n" }
}
