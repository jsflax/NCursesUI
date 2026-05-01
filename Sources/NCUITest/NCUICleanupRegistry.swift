import Foundation
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide registry of active tmux drivers. Installs an `atexit`
/// handler and traps SIGINT/SIGTERM so panes get cleaned up even on test
/// crashes or user interrupts.
final class NCUICleanupRegistry: @unchecked Sendable {
    static let shared = NCUICleanupRegistry()

    private let lock = OSAllocatedUnfairLock<[ObjectIdentifier: WeakDriver]>(initialState: [:])

    private final class WeakDriver: @unchecked Sendable {
        weak var driver: NCUITmuxDriver?
        let sessionName: String
        init(_ d: NCUITmuxDriver) {
            self.driver = d
            self.sessionName = d.sessionName
        }
    }

    private init() {
        installHandlersOnce()
    }

    func register(_ driver: NCUITmuxDriver) {
        lock.withLock { dict in
            dict[ObjectIdentifier(driver)] = WeakDriver(driver)
        }
    }

    func deregister(_ driver: NCUITmuxDriver) {
        lock.withLock { dict in
            dict.removeValue(forKey: ObjectIdentifier(driver))
        }
    }

    /// Kill every registered session — called by atexit + signal handlers.
    /// Safe to call from any thread, including signal handler context (uses
    /// only execve via Process, which forks a fresh tmux client).
    func killAll() {
        let names: [String] = lock.withLock { dict in
            Array(dict.values.compactMap { $0.sessionName })
        }
        for name in names {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["tmux", "kill-session", "-t", name]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                // Best-effort: nothing more we can do.
            }
        }
    }

    // MARK: - Handler installation (once-only)

    private static let installedFlag = OSAllocatedUnfairLock<Bool>(initialState: false)

    private func installHandlersOnce() {
        let alreadyInstalled = Self.installedFlag.withLock { (flag: inout Bool) -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        if alreadyInstalled { return }

        atexit {
            NCUICleanupRegistry.shared.killAll()
        }
        signal(SIGINT, { _ in
            NCUICleanupRegistry.shared.killAll()
            // Re-raise default handler so the process actually exits.
            signal(SIGINT, SIG_DFL)
            raise(SIGINT)
        })
        signal(SIGTERM, { _ in
            NCUICleanupRegistry.shared.killAll()
            signal(SIGTERM, SIG_DFL)
            raise(SIGTERM)
        })
    }
}
