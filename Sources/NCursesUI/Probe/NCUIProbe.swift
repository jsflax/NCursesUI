import Foundation
import NCUITestProtocol
import Logging

private let probeLogger = Logger(label: "ncursesui.probe")

public final class NCUIProbe: @unchecked Sendable {
    public static let shared = NCUIProbe()

    private let frameHook = NCUIFrameHook()
    private let injector = NCUIKeyInjector()
    private var server: NCUIProbeServer?
    private weak var windowServer: WindowServer?
    private let lock = NSLock()
    private var started = false

    private init() {}

    public static let frameworkVersion = "0.1.0"

    /// Called from NCursesUI's `WindowServer.run()` when `NCUITEST_SOCKET` is set.
    /// The window server reference lets the probe walk the live view tree on
    /// request. We hold a weak reference to avoid leaking the run loop owner.
    func start(socketPath: String, windowServer: WindowServer) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        self.windowServer = windowServer
        lock.unlock()

        let s = NCUIProbeServer(
            socketPath: socketPath,
            frameHook: frameHook,
            injector: injector,
            windowServer: windowServer
        )
        do {
            try s.start()
            self.server = s
            probeLogger.info("[NCUIProbe] listening on \(socketPath)")
        } catch {
            probeLogger.error("[NCUIProbe] failed to start: \(error)")
        }
    }

    public func frameDidRender() {
        guard server != nil else { return }
        frameHook.tick()
    }

    var currentFrame: UInt64 { frameHook.current }
    var hook: NCUIFrameHook { frameHook }
    var liveServer: WindowServer? { windowServer }

    /// Drains one synthetic event from the injector queue. Called from
    /// `WindowServer.run()` once per loop iteration before `Term.nextEvent()`.
    func injectIfPending() -> TermEvent? {
        return injector.drain()
    }

    var hasPendingInjections: Bool { !injector.isEmpty }
}
