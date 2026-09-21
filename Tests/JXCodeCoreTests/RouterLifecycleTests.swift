import XCTest
import Darwin
@testable import JXCodeCore

/// The router's lifecycle state, read and written from more than one thread.
///
/// `port`, `isRunning` and `listener` used to be plain `var`s on an
/// `@unchecked Sendable` class: `start`/`stop` wrote them on whatever thread
/// called them, connection tasks read `port` for `/health`, and the UI reads
/// `baseURL`. Three fields describing one state, with no lock between them.
///
/// Two of these tests pin behaviour that only exists once the fields are
/// guarded — the claim that serialises concurrent starts, and the release of
/// that claim when a bind fails. The third drives the lifecycle underneath
/// concurrent readers, which is the shape that used to be a data race; it is
/// only meaningful under the thread sanitizer, where a race is a failure
/// rather than a silent stale read.
final class RouterLifecycleTests: XCTestCase {

    private func router() -> ModelRouter {
        ModelRouter(state: RouterState(.idle))
    }

    // MARK: Concurrent starts

    /// Four simultaneous starts: exactly one binds, the rest are refused.
    ///
    /// This is the test the fix exists for. With no claim — a `guard` on
    /// `isRunning` and an assignment after the bind — all four pass the guard,
    /// because none of them sets the flag until its own bind finishes. All four
    /// bind an ephemeral port and all four succeed, leaving three listeners
    /// with nothing holding them.
    func testConcurrentStartsAllButOneAreRefused() throws {
        for _ in 0..<24 {
            let router = self.router()
            let box = Tally()
            let gate = DispatchSemaphore(value: 0)

            // Released together, so the four starts genuinely overlap rather
            // than running one after another.
            for _ in 0..<4 { gate.signal() }

            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                gate.wait()
                do {
                    try router.start(preferredPort: 0)
                    box.add("started")
                } catch let error as RouterError {
                    if case .alreadyRunning = error {
                        box.add("refused")
                    } else {
                        box.add("other:\(error)")
                    }
                } catch {
                    box.add("other:\(error)")
                }
            }

            let counts = box.counts
            XCTAssertEqual(counts["started"], 1, "\(counts)")
            XCTAssertEqual(counts["refused"], 3, "\(counts)")
            XCTAssertNil(counts["other"], "\(counts)")
            router.stop()
        }
    }

    // MARK: A start that fails

    /// A bind that fails must give the claim back.
    ///
    /// The claim is what refuses the next `start()`. If a failed bind kept it,
    /// one bad port would make the router unstartable for the life of the
    /// process — and the failure would surface somewhere else entirely, as a
    /// second `start()` reporting "already running" on a router that is not.
    func testAFailedStartLeavesTheRouterStartable() throws {
        let occupied = try occupyLoopbackPort()
        defer { occupied.release() }

        let router = self.router()
        XCTAssertThrowsError(
            try router.start(preferredPort: occupied.port),
            "a port another process already listens on must not bind"
        )
        XCTAssertFalse(router.isRunning, "a start that failed must not report running")

        try router.start(preferredPort: 0)
        XCTAssertTrue(router.isRunning)
        router.stop()
        XCTAssertFalse(router.isRunning)
    }

    // MARK: Readers while the lifecycle moves

    /// Read the lifecycle from several threads while another thread starts and
    /// stops the router underneath them.
    ///
    /// Under the thread sanitizer this is a race report if any of the three
    /// fields is touched without the lock. Without it, the test can only assert
    /// that the reads stay consistent with each other — which is why the fix is
    /// a lock rather than something the suite proves on its own.
    func testLifecycleReadsWhileAnotherThreadStartsAndStops() throws {
        let router = self.router()
        let tally = Tally()
        let readerCount = 6
        let group = DispatchGroup()

        for _ in 0..<readerCount {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<5_000 {
                    // The three views of one state. A reader must never take a
                    // port from one generation and a running flag from another.
                    _ = router.port
                    _ = router.isRunning
                    _ = router.baseURL
                }
                tally.add("reader")
            }
        }

        // Driven from this thread rather than by `concurrentPerform`, which does
        // not promise to run its iterations in parallel — a writer waiting on
        // the readers inside one would hang on a single-core machine. Bounded,
        // so a stuck reader cannot hang the suite either.
        for _ in 0..<2_000 {
            try? router.start(preferredPort: 0)
            router.stop()
            if tally.count(of: "reader") >= readerCount { break }
        }
        group.wait()

        XCTAssertEqual(tally.count(of: "reader"), readerCount, "readers did not finish")
        XCTAssertFalse(router.isRunning)
    }

    // MARK: Fixtures

    /// A loopback port already held by a listening socket, so a bind on it
    /// fails. Ephemeral, so it cannot collide with a port something else uses.
    private func occupyLoopbackPort() throws -> OccupiedPort {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw RouterError.upstream("socket() failed") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw RouterError.upstream("bind() failed")
        }
        guard Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw RouterError.upstream("listen() failed")
        }

        var actual = sockaddr_in()
        var length = size
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw RouterError.upstream("getsockname() failed")
        }
        return OccupiedPort(fd: fd, port: UInt16(bigEndian: actual.sin_port))
    }

    private struct OccupiedPort {
        let fd: Int32
        let port: UInt16
        func release() { Darwin.close(fd) }
    }

    /// Counts outcomes recorded from several threads at once.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []

        func add(_ item: String) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        func count(of item: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return items.reduce(0) { $0 + ($1 == item ? 1 : 0) }
        }

        /// Keyed by outcome, with any `other:` collapsed so a stray error is
        /// visible in the assertion message rather than lost in a count.
        var counts: [String: Int] {
            lock.lock()
            defer { lock.unlock() }
            var result: [String: Int] = [:]
            for item in items {
                let key = item.hasPrefix("other:") ? "other" : item
                result[key, default: 0] += 1
            }
            return result
        }
    }
}
