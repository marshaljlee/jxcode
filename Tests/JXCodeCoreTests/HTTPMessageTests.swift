import XCTest
import Darwin
@testable import JXCodeCore

/// The request parser's bounds.
///
/// A `Content-Length` is a claim made by the peer, and the parser used to
/// honour it without a limit — so one connection could make the router hold
/// arbitrary memory waiting for bytes that might never arrive.
final class HTTPMessageTests: XCTestCase {

    private func parser(
        maxBodyBytes: Int = HTTPRequestParser.defaultMaxBodyBytes,
        maxHeadBytes: Int = HTTPRequestParser.defaultMaxHeadBytes
    ) -> HTTPRequestParser {
        HTTPRequestParser(maxBodyBytes: maxBodyBytes, maxHeadBytes: maxHeadBytes)
    }

    private func parse(_ raw: String, _ p: HTTPRequestParser) throws -> HTTPRequest? {
        var parser = p
        parser.consume(Data(raw.utf8))
        return try parser.nextRequest()
    }

    private func head(length: String) -> String {
        "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(length)\r\n\r\n"
    }

    // MARK: Still works

    func testADeclaredBodyIsRead() throws {
        var p = parser()
        p.consume(Data((head(length: "5") + "hello").utf8))
        let request = try XCTUnwrap(try p.nextRequest())
        XCTAssertEqual(request.bodyText, "hello")
    }

    func testZeroContentLengthYieldsAnEmptyBody() throws {
        let request = try XCTUnwrap(try parse(head(length: "0"), parser()))
        XCTAssertTrue(request.body.isEmpty)
    }

    func testAnAbsentContentLengthYieldsAnEmptyBody() throws {
        let request = try XCTUnwrap(
            try parse("GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n", parser())
        )
        XCTAssertTrue(request.body.isEmpty)
        XCTAssertEqual(request.method, "GET")
    }

    func testARealisticHeadIsWellUnderTheHeadLimit() throws {
        // Forty headers of a plausible size: the limit must not be so tight
        // that an ordinary request falls foul of it.
        var raw = "POST /v1/messages HTTP/1.1\r\nHost: localhost\r\n"
        for i in 0..<40 {
            raw += "X-Request-Note-\(i): \(String(repeating: "v", count: 200))\r\n"
        }
        raw += "Content-Length: 0\r\n\r\n"
        XCTAssertNoThrow(try parse(raw, parser()))
    }

    // MARK: Refused

    func testANegativeContentLengthIsRefused() {
        XCTAssertThrowsError(try parse(head(length: "-1"), parser())) { error in
            guard case HTTPParseError.invalidContentLength(let value) = error else {
                return XCTFail("expected invalidContentLength, got \(error)")
            }
            XCTAssertEqual(value, "-1")
            XCTAssertEqual((error as? HTTPParseError)?.statusCode, 400)
        }
    }

    func testANonNumericContentLengthIsRefused() {
        XCTAssertThrowsError(try parse(head(length: "lots"), parser()))
        XCTAssertThrowsError(try parse(head(length: "12 34"), parser()))
        XCTAssertThrowsError(try parse(head(length: "+5"), parser()))
        XCTAssertThrowsError(try parse(head(length: ""), parser()))
    }

    /// A run of digits too long for an `Int`. It must not overflow into a small
    /// or negative number and be treated as an ordinary length.
    func testAContentLengthThatOverflowsIsRefusedAsTooLarge() {
        XCTAssertThrowsError(try parse(head(length: "99999999999999999999999"), parser())) { error in
            guard case HTTPParseError.contentTooLarge = error else {
                return XCTFail("expected contentTooLarge, got \(error)")
            }
            XCTAssertEqual((error as? HTTPParseError)?.statusCode, 413)
        }
    }

    func testAContentLengthOverTheLimitIsRefused() {
        XCTAssertThrowsError(try parse(head(length: "1000"), parser(maxBodyBytes: 999))) { error in
            guard case HTTPParseError.contentTooLarge(let declared, let limit) = error else {
                return XCTFail("expected contentTooLarge, got \(error)")
            }
            XCTAssertEqual(declared, 1000)
            XCTAssertEqual(limit, 999)
        }
    }

    /// The point of the whole fix: the refusal has to come from the head alone.
    /// A peer that declares a gigabyte and sends nothing must be turned away
    /// before a single body byte is buffered.
    func testAnOversizedLengthIsRefusedBeforeAnyBodyIsBuffered() {
        var p = parser(maxBodyBytes: 100)
        p.consume(Data(head(length: "1000000000").utf8))
        XCTAssertThrowsError(try p.nextRequest()) { error in
            guard case HTTPParseError.contentTooLarge = error else {
                return XCTFail("expected contentTooLarge, got \(error)")
            }
        }
    }

    func testAHeadThatNeverEndsIsRefused() {
        var p = parser(maxHeadBytes: 200)
        p.consume(Data(String(repeating: "X-Header: padding\r\n", count: 40).utf8))
        XCTAssertThrowsError(try p.nextRequest()) { error in
            guard case HTTPParseError.headTooLarge(let limit) = error else {
                return XCTFail("expected headTooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 200)
            XCTAssertEqual((error as? HTTPParseError)?.statusCode, 413)
        }
    }

    // MARK: On the wire

    /// 413 has to reach the client, not just be thrown inside the parser.
    func testAContentLengthOverTheLimitIsAnswered413() async throws {
        let harness = try RouterHarness()
        let response = try rawExchange(port: harness.router.port, bytes: Data(head(length: "999999999").utf8))
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413"), response)
        XCTAssertTrue(response.contains("exceeds"), response)
    }

    /// And a refusal must not be confused with a broken request.
    func testAMalformedHeadIsAnswered400() async throws {
        let harness = try RouterHarness()
        let response = try rawExchange(
            port: harness.router.port,
            bytes: Data("GET\r\nnot a request at all\r\n\r\n".utf8)
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"), response)
    }
}

// MARK: - Raw socket

/// Send raw bytes to a port and read whatever comes back.
///
/// Deliberately not `URLSession`: the whole point is to write a head that no
/// well-behaved client would produce.
private func rawExchange(port: UInt16, bytes: Data) throws -> String {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw RawSocketError.couldNotOpenSocket }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = Darwin.setsockopt(
        fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout<timeval>.stride)
    )
    defer { Darwin.close(fd) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
        }
    }
    guard connected == 0 else { throw RawSocketError.couldNotConnect }

    _ = bytes.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return Darwin.send(fd, base, bytes.count, 0)
    }

    var collected = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while collected.count < 1 << 16 {
        let read = Darwin.recv(fd, &chunk, chunk.count, 0)
        if read <= 0 { break }
        collected.append(chunk, count: read)
    }
    return String(decoding: collected, as: UTF8.self)
}

private enum RawSocketError: Error {
    case couldNotOpenSocket
    case couldNotConnect
}
