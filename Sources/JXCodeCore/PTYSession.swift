import Foundation
import Darwin

public enum PTYError: Error, CustomStringConvertible {
    case forkFailed(errno: Int32)
    case executableNotFound(String)

    public var description: String {
        switch self {
        case .forkFailed(let code):
            return "forkpty failed (errno \(code): \(String(cString: strerror(code))))"
        case .executableNotFound(let path):
            return "not an executable file: \(path)"
        }
    }
}

/// A pseudo-terminal running one child process.
///
/// Used for every interactive tab in the app, and by the CLI's `run` command,
/// so the isolation path exercised by the tests is the same one the UI uses.
///
/// Implementation notes:
///
/// - `forkpty` is used rather than `posix_spawn` because the child must become
///   a session leader with the pty as its controlling terminal. Without that,
///   job control breaks and interactive TUIs (Claude Code among them) misbehave
///   on Ctrl-C and Ctrl-Z.
/// - `argv` and `envp` are marshalled to C arrays **before** the fork. Between
///   `fork` and `execve` only async-signal-safe calls are permitted, and
///   allocating memory there risks deadlocking on the allocator lock held by
///   another thread.
public final class PTYSession {

    public private(set) var pid: pid_t = -1
    public private(set) var isRunning = false

    private var masterFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var didFinish = false

    private let queue = DispatchQueue(label: "app.jxcode.pty.read")
    private let writeQueue = DispatchQueue(label: "app.jxcode.pty.write")

    /// Bytes produced by the child. Fires on an internal queue — hop to the
    /// main queue before touching UI.
    public var onData: ((Data) -> Void)?

    /// Child exited. Fires on an internal queue.
    public var onExit: ((Int32) -> Void)?

    public init() {}

    deinit {
        // Best effort. If the child has already exited, collect it now so it
        // does not linger as a zombie for the life of the process — dropping
        // the last reference used to close the pty and leave the child
        // unreaped, because the only `waitpid` lived in a source that died
        // with this object. A child still running is the caller's to
        // terminate; this must not kill it.
        if pid > 0, !didFinish {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
        }
        closeMaster()
    }

    // MARK: - Lifecycle

    /// Launch a process inside the pty.
    ///
    /// - Parameter environment: pass `SandboxEnvironment.build()` here. This is
    ///   the only thing that puts the child inside the sandbox.
    public func start(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectory: String,
        columns: Int = 120,
        rows: Int = 32
    ) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw PTYError.executableNotFound(executable)
        }

        let argvStrings = [executable] + arguments
        let envStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()

        let argv = Self.cArray(argvStrings)
        let envp = Self.cArray(envStrings)
        let execPath = strdup(executable)
        let cwdPath = strdup(workingDirectory)

        var master: Int32 = -1
        var size = winsize(
            ws_row: UInt16(rows), ws_col: UInt16(columns),
            ws_xpixel: 0, ws_ypixel: 0
        )

        let child = forkpty(&master, nil, nil, &size)

        if child == -1 {
            let code = errno
            Self.freeCArray(argv, count: argvStrings.count)
            Self.freeCArray(envp, count: envStrings.count)
            free(execPath); free(cwdPath)
            throw PTYError.forkFailed(errno: code)
        }

        if child == 0 {
            // Child. Async-signal-safe calls only until execve.
            if let cwdPath { _ = chdir(cwdPath) }
            if let execPath { _ = execve(execPath, argv, envp) }
            _exit(127)
        }

        // Parent.
        Self.freeCArray(argv, count: argvStrings.count)
        Self.freeCArray(envp, count: envStrings.count)
        free(execPath); free(cwdPath)

        self.pid = child
        self.masterFD = master
        self.isRunning = true
        self.didFinish = false

        startReadSource(master: master, pid: child)
    }

    /// Send bytes to the child's stdin.
    public func write(_ data: Data) {
        guard isRunning, masterFD >= 0, !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(self.masterFD, base.advanced(by: offset), raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN {
                        usleep(500)
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func write(_ string: String) {
        write(Data(string.utf8))
    }

    /// Tell the pty the window changed. The kernel raises SIGWINCH for the
    /// foreground process group, which is what makes TUIs reflow.
    public func resize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var size = winsize(
            ws_row: UInt16(max(rows, 1)), ws_col: UInt16(max(columns, 1)),
            ws_xpixel: 0, ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    /// Ask the child's process group to exit, escalating if it ignores us.
    public func terminate(gracePeriod: TimeInterval = 2.0) {
        guard pid > 0, isRunning else { return }
        kill(-pid, SIGHUP)
        let target = pid
        queue.asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
            guard let self, self.isRunning else { return }
            kill(-target, SIGKILL)
        }
    }

    // MARK: - Internals

    private func startReadSource(master: Int32, pid: pid_t) {
        let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        read.setEventHandler { [weak self] in self?.drain() }
        // No cancel handler: `finish` owns closing the descriptor. When the
        // cancel handler closed it, a read source that cancelled itself on EOF
        // took the master fd with it.
        read.resume()
        self.readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            guard let self, !self.didFinish else { return }
            // The process is gone, so the pty holds at most its final output.
            // Read that *before* finishing: `finish` cancels the read source,
            // and any bytes not yet delivered would go with it.
            self.drain()
            // `drain` ends the session when it reaches EOF and the status is
            // available, which is the usual outcome; `reap` is the fallback for
            // when it returns on a short read instead. Safe to block there
            // because the process source only fires once the child has exited.
            self.reap()
        }
        exit.resume()
        self.exitSource = exit
    }

    /// Darwin's `WIFEXITED` / `WEXITSTATUS` / `WIFSIGNALED` / `WTERMSIG` are
    /// function-like macros, which Swift cannot import. Reimplemented from
    /// `<sys/wait.h>`:
    ///
    ///     _WSTATUS(x)   = x & 0177
    ///     WIFEXITED(x)  = _WSTATUS(x) == 0
    ///     WEXITSTATUS(x)= (x >> 8) & 0xff
    ///     WIFSIGNALED(x)= _WSTATUS(x) != 0177 && _WSTATUS(x) != 0
    ///     WTERMSIG(x)   = _WSTATUS(x)
    ///
    /// Signal deaths are reported as `128 + signal`, the shell convention.
    private static func decodeStatus(_ status: Int32) -> Int32 {
        let signalBits = status & 0o177
        if signalBits == 0 {
            return (status >> 8) & 0xff
        }
        if signalBits != 0o177 {
            return 128 + signalBits
        }
        return 0
    }

    /// Read whatever the child has produced, without blocking.
    ///
    /// Note what this does *not* do: end the session. An earlier revision
    /// finished with a hardcoded `exitCode: 0` on EOF, which was wrong twice
    /// over — it reported success for a command that failed, and `finish`
    /// cancels the process source, so the `waitpid` that would have supplied
    /// the real status (and reaped the child) never ran. On a short command
    /// the two sources become ready at the same instant, so the outcome was a
    /// coin flip: `testAFailingCommandReportsItsExitStatus` saw a command that
    /// exited 7 reported as 0, and `testNoZombieIsLeftBehind` found the child
    /// still waiting to be reaped on ten runs out of twelve.
    ///
    /// The exit status can only come from `waitpid`, so the session ends when
    /// a status is available — that is `reachedEOF`'s job, below, not this
    /// one's.
    ///
    /// Worth being precise about which source does it, because it is not the
    /// one the shape of this code suggests. Coverage over 66 sessions: the read
    /// source ended every single one, and the process source's handler fired
    /// **once**. A pty master reports EOF when the session leader exits, which
    /// is also the first moment `waitpid` has a status, so the two become ready
    /// together and the read source is simply dequeued first — the process
    /// source is usually cancelled by `finish` before it ever runs.
    ///
    /// It still earns its place, for the one case the read source cannot
    /// handle: the pty closing while the child is still alive. Then
    /// `reachedEOF` has no status to take and steps aside, and the process
    /// source is the only thing left that can end the session.
    private func drain() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                onData?(Data(buffer[0..<count]))
                // In practice this always returns: the pty's own buffer is far
                // smaller than 64 KiB, so a read never comes back full. The
                // loop is correct for a platform where it might, and harmless
                // on one where it cannot.
                if count < buffer.count { return }
                continue
            }
            // A zero-length read is how a pty master reports "child is gone"
            // here. EIO is the textbook answer and is handled below, but over
            // every session in the suite `read` has always returned 0, never
            // -1/EIO — so this is the branch that matters, and it is the one
            // that is actually exercised.
            if count == 0 { return reachedEOF() }
            // count < 0
            if errno == EINTR { continue }
            // Unreachable with a blocking descriptor, which is what `forkpty`
            // gives us. Kept because making the fd non-blocking would make it
            // load-bearing, and because the cost of being wrong is a busy loop.
            if errno == EAGAIN { return }
            // EIO: the same end-of-session signal, delivered as an error.
            return reachedEOF()
        }
    }

    /// The pty will produce no more output.
    ///
    /// The child may still be alive for a moment — closing the last descriptor
    /// is not the same as exiting — so this only takes the status when there is
    /// one to take. Otherwise it steps aside and lets the process source do it.
    ///
    /// Both halves are real. Measured over 67 sessions: 66 found the status and
    /// finished, and one — a child that closed its own pty descriptors and kept
    /// running — stepped aside, which is what
    /// `testAPtyThatClosesBeforeTheChildExitsStillEndsWithTheRealStatus` pins.
    private func reachedEOF() {
        readSource?.cancel()
        readSource = nil

        guard !didFinish, pid > 0 else { return }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
            finish(exitCode: Self.decodeStatus(status))
        }
    }

    /// Reap the child and end the session.
    ///
    /// Only safe once the process is known to be gone: at that point it is a
    /// zombie and `waitpid` returns immediately rather than blocking.
    ///
    /// Honest scope: this body has never executed in the suite. It is reached
    /// only if the process source fires while `drain` still has buffered output
    /// to read, in which case `drain` returns on a short read instead of
    /// reaching EOF, and something has to end the session. Across 66 sessions
    /// the handler fired once and `drain` had already finished by then, so the
    /// `guard` above returned early. The ordering that would reach it — the
    /// process event dequeued before the read event for the same bytes — is not
    /// forceable from outside, the same limitation documented on
    /// `testTheFinalOutputIsNotTruncated`. It stays because the alternative, if
    /// that ordering ever happens, is a session that never ends.
    private func reap() {
        guard !didFinish, pid > 0 else { return }
        var status: Int32 = 0
        if waitpid(pid, &status, 0) == pid {
            finish(exitCode: Self.decodeStatus(status))
        } else {
            // ECHILD: already collected, or never ours. Nothing to report, but
            // the session still has to end.
            finish(exitCode: 0)
        }
    }

    private func finish(exitCode: Int32) {
        guard !didFinish else { return }
        didFinish = true
        isRunning = false
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        // The fd is closed here rather than in the read source's cancel
        // handler, so there is exactly one owner. When the cancel handler did
        // it, a source that cancelled itself on EOF closed the master fd and
        // any later read would have hit a closed — possibly reused — number.
        closeMaster()
        onExit?(exitCode)
    }

    private func closeMaster() {
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    // MARK: - C array marshalling

    private static func cArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            buffer[index] = strdup(string)
        }
        buffer[strings.count] = nil
        return buffer
    }

    private static func freeCArray(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0..<count {
            free(buffer[index])
        }
        buffer.deallocate()
    }
}
