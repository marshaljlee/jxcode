import Foundation

// MARK: - Request

public struct HTTPRequest: Sendable {
    public var method: String
    /// Path only — no query string.
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var json: JSONValue? {
        guard !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: body)
    }

    public var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }
}

public enum HTTPParseError: Error, CustomStringConvertible {
    case malformedHead
    case unsupportedTransferEncoding(String)
    /// A `Content-Length` that is not a plain run of digits.
    case invalidContentLength(String)
    /// A `Content-Length` above what the parser will buffer.
    case contentTooLarge(declared: Int, limit: Int)
    /// Bytes with no blank line ending a head, past the head limit.
    case headTooLarge(limit: Int)

    /// The status to answer with.
    ///
    /// All of these are the peer's fault, so all are 4xx. The size ones are
    /// 413 rather than 400 so that a client — an agent retrying a long prompt,
    /// say — can tell "too big" from "not understood" and react differently
    /// instead of retrying a request that can never succeed.
    public var statusCode: Int {
        switch self {
        case .contentTooLarge, .headTooLarge: return 413
        default: return 400
        }
    }

    public var description: String {
        switch self {
        case .malformedHead:
            return "malformed request head"
        case .unsupportedTransferEncoding(let value):
            return "unsupported Transfer-Encoding: \(value)"
        case .invalidContentLength(let value):
            return "invalid Content-Length: \(value)"
        case .contentTooLarge(let declared, let limit):
            return "Content-Length \(declared) exceeds the \(limit)-byte limit"
        case .headTooLarge(let limit):
            return "request head exceeds the \(limit)-byte limit"
        }
    }
}

// MARK: - Incremental request parser

/// Parses HTTP/1.1 requests off a byte stream.
///
/// Requests arrive in arbitrary pieces, so this buffers until it has a complete
/// head, then until it has the full body, and only then hands back a request.
/// It is a struct with mutating methods rather than a class because each
/// connection owns exactly one, and there is no reason to share.
public struct HTTPRequestParser {

    private enum State {
        case head
        case body(remaining: Int)
    }

    private static let crlfTerminator = Data("\r\n\r\n".utf8)
    private static let lfTerminator = Data("\n\n".utf8)

    /// The largest `Content-Length` honoured: 32 MiB.
    ///
    /// A declared length is a claim, not a measurement. The bytes may dribble
    /// in, or never arrive at all, and nothing else bounds how much is held
    /// while waiting for them — so the bound has to be here.
    public static let defaultMaxBodyBytes = 32 * 1024 * 1024

    /// The largest head accepted: 64 KiB.
    ///
    /// Same reasoning, for a peer that sends bytes but never the blank line
    /// that ends a head. Generous for real headers, which are kilobytes.
    public static let defaultMaxHeadBytes = 64 * 1024

    public let maxBodyBytes: Int
    public let maxHeadBytes: Int

    private var buffer = Data()
    private var state: State = .head
    private var pendingHead: ParsedHead?

    public init(
        maxBodyBytes: Int = Self.defaultMaxBodyBytes,
        maxHeadBytes: Int = Self.defaultMaxHeadBytes
    ) {
        self.maxBodyBytes = maxBodyBytes
        self.maxHeadBytes = maxHeadBytes
    }

    private struct ParsedHead {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
    }

    public mutating func consume(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete request, or `nil` if more bytes are needed.
    public mutating func nextRequest() throws -> HTTPRequest? {
        switch state {
        case .head:
            guard let terminator = findHeadTerminator() else {
                // No blank line yet. The wait has to be bounded: a peer that
                // keeps sending without ever ending a head would otherwise
                // grow this buffer for as long as it cared to.
                guard buffer.count <= maxHeadBytes else {
                    throw HTTPParseError.headTooLarge(limit: maxHeadBytes)
                }
                return nil
            }
            let headData = buffer.subdata(in: buffer.startIndex..<terminator.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<terminator.upperBound)

            guard let head = Self.parseHead(headData) else {
                throw HTTPParseError.malformedHead
            }

            if let encoding = head.headers["transfer-encoding"],
               encoding.lowercased() != "identity" {
                throw HTTPParseError.unsupportedTransferEncoding(encoding)
            }

            let length = try contentLength(from: head.headers["content-length"])
            if length > maxBodyBytes {
                throw HTTPParseError.contentTooLarge(declared: length, limit: maxBodyBytes)
            }
            if length == 0 {
                return HTTPRequest(
                    method: head.method,
                    path: head.path,
                    query: head.query,
                    headers: head.headers,
                    body: Data()
                )
            }

            pendingHead = head
            state = .body(remaining: length)
            return try nextRequest()

        case .body(let remaining):
            guard buffer.count >= remaining else { return nil }
            let body = buffer.prefix(remaining)
            buffer.removeFirst(remaining)
            state = .head

            guard let head = pendingHead else { throw HTTPParseError.malformedHead }
            pendingHead = nil

            return HTTPRequest(
                method: head.method,
                path: head.path,
                query: head.query,
                headers: head.headers,
                body: Data(body)
            )
        }
    }

    /// Read a `Content-Length` header.
    ///
    /// Strict, because this value decides how many bytes are taken as the body
    /// and how many are left for the next request. Anything that is not a plain
    /// run of ASCII digits — negative, signed, spaced, hexadecimal — is refused
    /// rather than defaulted to zero: defaulting leaves the real body in the
    /// buffer, where the next pass reads it as a request head.
    private func contentLength(from raw: String?) throws -> Int {
        guard let raw else { return 0 }
        guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw HTTPParseError.invalidContentLength(raw)
        }
        // Digits, but more of them than an `Int` holds. Still a number, and
        // still far over the limit, so it is reported as oversized rather than
        // being allowed to overflow into something small.
        guard let length = Int(raw) else {
            throw HTTPParseError.contentTooLarge(declared: Int.max, limit: maxBodyBytes)
        }
        return length
    }

    /// Locate the end of the head, accepting either CRLF or bare LF.
    ///
    /// Bare LF turns up from hand-rolled clients and from anything piping
    /// through `nc`. Rejecting it would be technically correct and practically
    /// annoying.
    private func findHeadTerminator() -> Range<Data.Index>? {
        if let range = buffer.range(of: Self.crlfTerminator) { return range }
        return buffer.range(of: Self.lfTerminator)
    }

    private static func parseHead(_ data: Data) -> ParsedHead? {
        // Split on the **byte**, not the Character.
        //
        // In Swift, CR+LF forms a single extended grapheme cluster, so
        // `String.split(separator: "\n")` does not split a CRLF-terminated
        // request head at all — it returns the entire head as one line. The
        // request line still parses by luck (the method and path are followed
        // by a space), but every header is lost, including Content-Length, and
        // the body is silently dropped. URLSession and every real HTTP client
        // send CRLF, so this is the common path, not an edge case.
        var lines: [String] = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { lineBytes -> String in
                var bytes = Array(lineBytes)
                if bytes.last == 0x0D { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }

        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst()
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }

        let method = String(components[0]).uppercased()
        let target = String(components[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // Repeated headers join with a comma, per RFC 7230.
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        // Split the target into path and query. An absolute-form target
        // ("http://host/path") also turns up from proxies; take its path.
        var path = target
        var query: [String: String] = [:]

        if let schemeRange = target.range(of: "://") {
            let afterScheme = target[schemeRange.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                path = String(afterScheme[slash...])
            } else {
                path = "/"
            }
        }

        if let questionMark = path.firstIndex(of: "?") {
            let queryString = String(path[path.index(after: questionMark)...])
            path = String(path[path.startIndex..<questionMark])
            for pair in queryString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = parts.first, !key.isEmpty else { continue }
                let raw = parts.count > 1 ? String(parts[1]) : ""
                query[String(key)] = raw.removingPercentEncoding ?? raw
            }
        }

        return ParsedHead(method: method, path: path, query: query, headers: headers)
    }
}

// MARK: - Response

/// Status line, headers, and either a complete body or a stream.
public enum HTTPResponse: Sendable {
    case buffered(status: Int, headers: [String: String], body: Data)
    case stream(status: Int, headers: [String: String])

    public static func json(
        _ value: JSONValue,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        var merged = headers
        merged["Content-Type"] = "application/json"
        return .buffered(status: status, headers: merged, body: body)
    }

    public static func text(
        _ message: String,
        status: Int = 200,
        contentType: String = "text/plain; charset=utf-8"
    ) -> HTTPResponse {
        .buffered(
            status: status,
            headers: ["Content-Type": contentType],
            body: Data(message.utf8)
        )
    }

    /// An error shaped the way the calling API expects it.
    ///
    /// Getting this wrong matters: Claude Code decides whether to retry by
    /// reading `error.type`, and a bare status code with an HTML body makes it
    /// treat a fixable misconfiguration as a hard failure.
    public static func apiError(_ message: String, status: Int, anthropicStyle: Bool) -> HTTPResponse {
        let payload: JSONValue = anthropicStyle
            ? .object([
                "type": .string("error"),
                "error": .object([
                    "type": .string(status == 401 ? "authentication_error" : "api_error"),
                    "message": .string(message),
                ]),
            ])
            : .object([
                "error": .object([
                    "type": .string(status == 401 ? "authentication_error" : "api_error"),
                    "message": .string(message),
                ]),
            ])
        return .json(payload, status: status)
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default:  return "Status"
        }
    }

    /// Serialise the head, and the body when there is one.
    func serializedHead(extraHeaders: [String: String] = [:]) -> Data {
        let status: Int
        var headers: [String: String]
        var bodyLength: Int?

        switch self {
        case .buffered(let code, let supplied, let body):
            status = code
            headers = supplied
            bodyLength = body.count
        case .stream(let code, let supplied):
            status = code
            headers = supplied
        }

        for (key, value) in extraHeaders { headers[key] = value }

        // The router is loopback-only and short-lived per request, so closing
        // the connection is both simplest and safest.
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        if let bodyLength {
            headers["Content-Length"] = String(bodyLength)
        } else {
            headers["Transfer-Encoding"] = "chunked"
        }
        // Sorted so responses are byte-stable and easy to diff in a log.
        for key in headers.keys.sorted() {
            head += "\(key): \(headers[key]!)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }

    /// Wrap a streamed payload in one chunked-encoding frame.
    static func chunk(_ text: String) -> Data {
        let payload = Data(text.utf8)
        guard !payload.isEmpty else { return Data() }
        var out = Data(String(payload.count, radix: 16).utf8)
        out.append(Data("\r\n".utf8))
        out.append(payload)
        out.append(Data("\r\n".utf8))
        return out
    }

    /// The terminating zero-length chunk.
    static var chunkTerminator: Data { Data("0\r\n\r\n".utf8) }
}
