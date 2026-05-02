import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One tmux session per `NCUIApplication`. Each session contains a single
/// pane running the binary under test; sessions don't share state so concurrent
/// test runs don't compete for pane real estate.
public final class NCUITmuxDriver: @unchecked Sendable {
    public let sessionName: String
    private let lock = NSLock()
    private var paneId: String?
    private var panePid: Int32?
    private var sessionStarted = false

    public init(sessionName: String) {
        self.sessionName = sessionName
        NCUICleanupRegistry.shared.register(self)
    }

    deinit {
        NCUICleanupRegistry.shared.deregister(self)
    }

    /// Spawn the binary in a fresh, detached session. This is a one-shot —
    /// once the session is closed (via `kill()` or process exit), the driver
    /// is done.
    public func startSession(
        env: [String: String],
        command: String,
        width: Int = 240,
        height: Int = 60
    ) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !sessionStarted else {
            throw NCUIError.launchFailed(reason: "session already started")
        }
        // Kill any lingering session with this exact name. Safe — naming is
        // pid+label+UUID-prefix so collisions across processes are vanishing.
        _ = runTmux(["kill-session", "-t", sessionName])

        var args = [
            "new-session", "-d",
            "-s", sessionName,
            "-x", "\(width)", "-y", "\(height)",
            "-P", "-F", "#{pane_id}",
        ]
        for (k, v) in env {
            args.append("-e")
            args.append("\(k)=\(v)")
        }
        args.append(command)

        let result = runTmux(args)
        guard result.exit == 0 else {
            throw NCUIError.tmuxError("new-session failed: \(result.stderr)")
        }
        let pane = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        self.paneId = pane
        self.sessionStarted = true
        // Disable status bar so it doesn't eat a row of the terminal.
        _ = runTmux(["set-option", "-t", sessionName, "status", "off"])
        // Cache the pane's foreground PID so we can reap descendants
        // (e.g. `claude -p` subprocesses) on kill — tmux SIGHUP doesn't
        // always reach grandchildren.
        let pidResult = runTmux(["display-message", "-p", "-t", pane, "#{pane_pid}"])
        if pidResult.exit == 0,
           let pid = Int32(pidResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.panePid = pid
        }
        return pane
    }

    public func kill() {
        lock.lock(); defer { lock.unlock() }
        guard sessionStarted else { return }
        // Reap descendants first — tmux kill-session sends SIGHUP to the
        // pane's foreground process, but `claude -p` subprocesses spawned
        // by ClaudeCliDriver fork into their own process group and survive
        // the HUP. Walk the descendant tree from pane_pid and kill them
        // explicitly. Bash _lib.sh:smoke_teardown does the same with a
        // broader `pkill -9 -f "claude -p"`; we scope to actual descendants.
        if let pid = panePid {
            killDescendants(of: pid)
        }
        _ = runTmux(["kill-session", "-t", sessionName])
        paneId = nil
        panePid = nil
        sessionStarted = false
    }

    /// Recursively SIGTERM every process whose ancestor is `rootPid`. Used
    /// during teardown to reap subprocesses that survive `tmux kill-session`.
    private func killDescendants(of rootPid: Int32) {
        // Build the descendant set via repeated `pgrep -P`.
        var frontier: [Int32] = [rootPid]
        var all: Set<Int32> = []
        while let pid = frontier.popLast() {
            let result = runProcess("/usr/bin/pgrep", ["-P", "\(pid)"])
            guard result.exit == 0 else { continue }
            for line in result.stdout.split(separator: "\n") {
                if let child = Int32(line.trimmingCharacters(in: .whitespaces)),
                   !all.contains(child), child != rootPid {
                    all.insert(child)
                    frontier.append(child)
                }
            }
        }
        // Kill all gathered descendants. SIGTERM first to give cleanup
        // hooks a chance, then SIGKILL after a short grace period.
        for pid in all { _ = Darwin.kill(pid, SIGTERM) }
        usleep(200_000)  // 200ms grace
        for pid in all { _ = Darwin.kill(pid, SIGKILL) }
    }

    private func runProcess(_ path: String, _ args: [String]) -> (exit: Int32, stdout: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do { try task.run() } catch { return (-1, "") }
        task.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    public func sendKeys(_ keys: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let pane = paneId else {
            throw NCUIError.tmuxError("session not started")
        }
        let result = runTmux(["send-keys", "-t", pane, keys])
        guard result.exit == 0 else {
            throw NCUIError.tmuxError("send-keys failed: \(result.stderr)")
        }
    }

    public func capturePane(withEscapes: Bool = true) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let pane = paneId else {
            throw NCUIError.tmuxError("session not started")
        }
        var args = ["capture-pane", "-p", "-t", pane]
        if withEscapes { args.insert("-e", at: 1) }
        let result = runTmux(args)
        guard result.exit == 0 else {
            throw NCUIError.tmuxError("capture-pane failed: \(result.stderr)")
        }
        return result.stdout
    }

    public func resize(cols: Int, rows: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard let pane = paneId else {
            throw NCUIError.tmuxError("session not started")
        }
        let result = runTmux(["resize-pane", "-t", pane, "-x", "\(cols)", "-y", "\(rows)"])
        guard result.exit == 0 else {
            throw NCUIError.tmuxError("resize-pane failed: \(result.stderr)")
        }
    }

    func runTmux(_ args: [String]) -> (exit: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tmux"] + args
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            return (-1, "", "failed to spawn tmux: \(error)")
        }
        task.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            task.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
