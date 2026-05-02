import Foundation
import os
import NCUITestProtocol

public final class NCUIApplication: @unchecked Sendable {
    public let label: String
    public let productName: String?
    public var launchArguments: [String]
    public var launchEnvironment: [String: String]

    var probeClient: NCUIProbeClient?
    var socketPath: String?
    var resolvedBinary: String?
    var tmuxDriver: NCUITmuxDriver?
    /// Stdout+stderr tee log path for the spawned binary. Survives the
    /// pane's destruction (which happens when the binary exits) so the
    /// failure path has something to read on probe-handshake timeout.
    var launchLogPath: String?
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .notLaunched)

    public enum State: Sendable {
        case notLaunched
        case launching
        case running
        case terminated
    }

    public init(
        label: String = "default",
        productName: String? = nil,
        launchArguments: [String] = [],
        launchEnvironment: [String: String] = [:]
    ) {
        self.label = label
        self.productName = productName
        self.launchArguments = launchArguments
        self.launchEnvironment = launchEnvironment
    }

    public var state: State {
        stateLock.withLock { $0 }
    }

    private func setState(_ new: State) {
        stateLock.withLock { $0 = new }
    }

    public func launch(
        handshakeTimeout: TimeInterval = 10,
        terminalSize: (cols: Int, rows: Int) = (240, 60)
    ) async throws {
        let canStart = stateLock.withLock { (current: inout State) -> Bool in
            guard current == .notLaunched else { return false }
            current = .launching
            return true
        }
        guard canStart else { throw NCUIError.alreadyLaunched }
        try await performLaunch(handshakeTimeout: handshakeTimeout, terminalSize: terminalSize)
    }

    /// Restart the underlying tmux pane and re-handshake the probe with a
    /// fresh unix socket. Required for tests that crash + relaunch the app
    /// (e.g. orphan-recovery scenarios). Only valid from `.terminated`.
    public func relaunch(
        handshakeTimeout: TimeInterval = 10,
        terminalSize: (cols: Int, rows: Int) = (240, 60)
    ) async throws {
        let canRelaunch = stateLock.withLock { (current: inout State) -> Bool in
            guard current == .terminated else { return false }
            current = .launching
            return true
        }
        guard canRelaunch else { throw NCUIError.notLaunched }

        // Defensive: terminate() should have killed the prior session, but
        // re-kill in case a caller skipped it. Reset all per-session state.
        tmuxDriver?.kill()
        probeClient?.close()
        tmuxDriver = nil
        probeClient = nil
        if let path = socketPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        socketPath = nil

        try await performLaunch(handshakeTimeout: handshakeTimeout, terminalSize: terminalSize)
    }

    /// Shared launch core: resolves the binary, picks a fresh socket path +
    /// session name, spawns the tmux pane, awaits the probe handshake, and
    /// transitions to `.running`. Caller is responsible for transitioning
    /// the state to `.launching` first.
    private func performLaunch(
        handshakeTimeout: TimeInterval,
        terminalSize: (cols: Int, rows: Int)
    ) async throws {
        let binary = try BinaryResolver.resolve(productName: productName)
        self.resolvedBinary = binary

        let socketName = "ncuitest-\(getpid())-\(label)-\(UUID().uuidString.prefix(8)).sock"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(socketName)
        self.socketPath = path
        try? FileManager.default.removeItem(atPath: path)

        var env = launchEnvironment
        env["NCUITEST_SOCKET"] = path

        // Inherit the user's interactive-shell PATH unless the caller
        // pinned PATH explicitly. Without this, tests run from Xcode (or
        // any harness with a stripped PATH) spawn the binary into a
        // minimal environment where `claude`, `cloudflared`, brew-installed
        // tools, etc. aren't reachable — Doctor-style first-run gates exit
        // before our probe binds the socket and the test sees only a
        // probe-handshake timeout. Resolving the user's PATH once and
        // injecting it makes the spawned process behave the way it would
        // if the user ran it from their own terminal.
        if env["PATH"] == nil, let inherited = Self.userShellPath() {
            env["PATH"] = inherited
        }
        if env["HOME"] == nil, let home = ProcessInfo.processInfo.environment["HOME"] {
            env["HOME"] = home
        }

        let sessionName = "ncuitest-\(getpid())-\(label)-\(UUID().uuidString.prefix(6))"
        let driver = NCUITmuxDriver(sessionName: sessionName)

        // Tee the binary's stdout + stderr to a log file in addition to the
        // pane. tmux closes panes when their command exits — if the binary
        // crashes immediately the session is gone before `capture-pane`
        // can read it. The log file survives the pane's death so we can
        // still surface the failure reason. ncurses redraws still go to
        // the pane (stdout = the tty); the log carries a duplicate plus
        // anything written to stderr. Wrapping in `script -q` would also
        // capture the pty escape codes, but `tee` is enough for "what did
        // the binary print before exiting".
        let logPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(sessionName).log")
        try? FileManager.default.removeItem(atPath: logPath)
        self.launchLogPath = logPath
        let binaryQuoted = Self.shellQuote(binary)
        let argsQuoted = launchArguments.map(Self.shellQuote).joined(separator: " ")
        let logQuoted = Self.shellQuote(logPath)

        // Belt-and-suspenders env injection: prefix the env vars inline
        // in the shell command (`KEY=VAL ... binary args`) in addition to
        // tmux's `-e KEY=VAL` flags. Observed: with the chain
        // Xcode → swift-test → Process → tmux → sh → binary, tmux's `-e`
        // flag does NOT reliably propagate variables to the spawned
        // command (Doctor's `which claude` fails inside the binary even
        // when our resolved PATH contained ~/.local/bin). The inline form
        // is interpreted by sh -c right before exec'ing the binary, so
        // the binary's env is guaranteed regardless of tmux behavior.
        // We keep the tmux `-e` flags too — they're harmless when the
        // inline prefix already won.
        let envPrefix = env
            .sorted(by: { $0.key < $1.key })  // stable order for log readability
            .map { "\($0.key)=\(Self.shellQuote($0.value))" }
            .joined(separator: " ")
        let cmd = "\(envPrefix) \(binaryQuoted)\(argsQuoted.isEmpty ? "" : " \(argsQuoted)") 2>&1 | tee \(logQuoted)"

        _ = try driver.startSession(
            env: env,
            command: cmd,
            width: terminalSize.cols,
            height: terminalSize.rows
        )
        self.tmuxDriver = driver

        let client = NCUIProbeClient(socketPath: path)
        do {
            try await client.waitUntilReady(timeout: handshakeTimeout)
        } catch {
            // Pane content first (richest — has cursor + redrawn frames),
            // log file second (survives a crashed binary's pane death),
            // never both empty in practice.
            let paneCapture: String = (try? driver.capturePane(withEscapes: false))
                ?? "<capture-pane failed (pane likely already destroyed by binary exit)>"
            let logCapture: String = (try? String(contentsOfFile: logPath, encoding: .utf8))
                ?? ""
            let combinedDiagnostic: String
            if logCapture.isEmpty {
                combinedDiagnostic = paneCapture
            } else if paneCapture.contains("capture-pane failed") {
                combinedDiagnostic = "(via tee log — pane was already destroyed)\n\(logCapture)"
            } else {
                combinedDiagnostic = "PANE:\n\(paneCapture)\n\nTEE LOG:\n\(logCapture)"
            }
            let pathHint = env["PATH"] ?? "<unset>"
            driver.kill()
            setState(.terminated)
            if let e = error as? NCUIError, case .probeHandshakeTimeout = e {
                throw NCUIError.probeHandshakeTimeoutWithDiagnostics(
                    socketPath: path,
                    binary: binary,
                    pathEnv: pathHint,
                    paneOutput: combinedDiagnostic
                )
            }
            throw NCUIError.probeConnectFailed(socketPath: path, underlying: error)
        }

        let response = try await client.send(.ping)
        guard case .probeInfo(let info) = response.result else {
            throw NCUIError.probeError("unexpected ping response: \(response.result)")
        }
        guard info.protocolVersion == NCUIWireProtocol.version else {
            throw NCUIError.incompatibleProbeVersion(
                client: NCUIWireProtocol.version,
                server: info.protocolVersion
            )
        }

        self.probeClient = client
        setState(.running)
    }

    public func terminate() {
        let wasRunning = stateLock.withLock { (current: inout State) -> Bool in
            let was = current == .running || current == .launching
            current = .terminated
            return was
        }
        guard wasRunning else { return }

        probeClient?.close()
        tmuxDriver?.kill()
        if let path = socketPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let log = launchLogPath {
            try? FileManager.default.removeItem(atPath: log)
        }
    }

    public func ping() async throws -> NCUIProbeInfo {
        guard let client = probeClient else { throw NCUIError.notLaunched }
        let response = try await client.send(.ping)
        guard case .probeInfo(let info) = response.result else {
            throw NCUIError.probeError("unexpected ping response: \(response.result)")
        }
        return info
    }

    public func sendRaw(_ request: NCUIRequest) async throws -> NCUIResponse {
        guard let client = probeClient else { throw NCUIError.notLaunched }
        return try await client.send(request)
    }

    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "/" || $0 == "." || $0 == "-" || $0 == "_" || $0 == "=" }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Cached PATH resolved by spawning the user's login shell with
    /// `-ilc 'echo $PATH'`. Same path you'd see by opening a fresh
    /// Terminal.app tab. `-i` sources `~/.zshrc` / `~/.bashrc`, `-l` sources
    /// `~/.zprofile` / `~/.profile` — together they produce the canonical
    /// interactive PATH. Falls back to `nil` if the shell call fails.
    private static let _shellPath = OSAllocatedUnfairLock<String??>(initialState: nil)

    static func userShellPath() -> String? {
        if let cached = _shellPath.withLock({ $0 }) { return cached }
        let resolved = resolveUserShellPath()
        _shellPath.withLock { $0 = resolved }
        return resolved
    }

    private static func resolveUserShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-ilc", "printf '%s' \"$PATH\""]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
