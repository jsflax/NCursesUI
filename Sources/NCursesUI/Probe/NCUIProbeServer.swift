import Foundation
import NCUITestProtocol
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private let serverLogger = Logger(label: "ncursesui.probe.server")

final class NCUIProbeServer: @unchecked Sendable {
    private let socketPath: String
    private let frameHook: NCUIFrameHook
    private let injector: NCUIKeyInjector
    private weak var windowServer: WindowServer?
    private var listenFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "ncui.probe.accept", qos: .userInitiated)
    private var stopRequested = false

    init(
        socketPath: String,
        frameHook: NCUIFrameHook,
        injector: NCUIKeyInjector,
        windowServer: WindowServer
    ) {
        self.socketPath = socketPath
        self.frameHook = frameHook
        self.injector = injector
        self.windowServer = windowServer
    }

    func start() throws {
        // Unlink any stale socket file.
        unlink(socketPath)

        let fd = socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { throw NCUIProbeError.socketCreate(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= pathCapacity else {
            close(fd)
            throw NCUIProbeError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { p in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(p, src.baseAddress, src.count)
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                bind(fd, sap, addrLen)
            }
        }
        guard bindResult == 0 else {
            let e = errno
            close(fd)
            throw NCUIProbeError.bind(path: socketPath, errno: e)
        }

        guard listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            throw NCUIProbeError.listen(errno: e)
        }

        self.listenFd = fd
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        stopRequested = true
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while !stopRequested {
            var clientAddr = sockaddr()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listenFd, &clientAddr, &clientAddrLen)
            if client < 0 {
                if stopRequested { return }
                if errno == EINTR { continue }
                serverLogger.error("[NCUIProbe] accept failed errno=\(errno)")
                return
            }
            let connQueue = DispatchQueue(label: "ncui.probe.conn.\(client)")
            connQueue.async { [weak self] in
                self?.serveConnection(fd: client)
            }
        }
    }

    private func serveConnection(fd: Int32) {
        defer { close(fd) }
        while !stopRequested {
            guard let payload = readFrame(fd: fd) else { return }
            let response: NCUIResponse
            do {
                let request = try NCUIWire.decodeRequest(payload)
                response = handle(request)
            } catch {
                response = NCUIResponse(
                    frame: frameHook.current,
                    result: .error("decode failure: \(error)")
                )
            }
            do {
                let bytes = try NCUIWire.encode(response)
                if !writeAll(fd: fd, data: bytes) { return }
            } catch {
                serverLogger.error("[NCUIProbe] encode failure: \(error)")
                return
            }
        }
    }

    private func handle(_ request: NCUIRequest) -> NCUIResponse {
        switch request {
        case .ping:
            let info = NCUIProbeInfo(
                protocolVersion: NCUIWireProtocol.version,
                frameworkVersion: NCUIProbe.frameworkVersion,
                frame: frameHook.current
            )
            return NCUIResponse(frame: frameHook.current, result: .probeInfo(info))

        case .tree:
            return runOnMainCapturingTree { tree in
                NCUIResponse(frame: self.frameHook.current, result: .tree(tree))
            }

        case .query(let spec):
            return runOnMainCapturingTree { tree in
                let matches = NCUIQuery.run(spec: spec, in: tree)
                return NCUIResponse(frame: self.frameHook.current, result: .nodes(matches))
            }

        case .snapshot:
            return runOnMainCapturingTree { tree in
                // Real cell-grid capture is a future task (NCUIScreen via tmux);
                // for now return an empty grid alongside the tree so clients
                // can rely on the tree portion immediately.
                let grid = NCUICellGrid(rows: 0, cols: 0, cells: [], cursor: nil, palette: NCUIPaletteRGBMap())
                return NCUIResponse(frame: self.frameHook.current, result: .snapshot(grid, tree))
            }

        case .sendKey(let spec):
            guard let event = NCUIKeyTranslate.event(for: spec) else {
                return NCUIResponse(
                    frame: frameHook.current,
                    result: .error("untranslatable key spec")
                )
            }
            injector.push(event)
            wakeRunLoop()
            // Wait until the next frame renders so the caller observes
            // the post-keystroke state. Falls through after a short timeout
            // if nothing redraws (rare; key may have been consumed silently).
            let postFrame = waitForNextFrame(timeoutMs: 1000)
            return NCUIResponse(frame: postFrame, result: .ok)

        case .sendKeys(let text):
            let events = NCUIKeyTranslate.events(for: text)
            injector.push(events)
            wakeRunLoop()
            let postFrame = waitForNextFrame(timeoutMs: 2000)
            return NCUIResponse(frame: postFrame, result: .ok)

        case .awaitPredicate(let spec, let timeoutMs):
            return runAwait(spec: spec, timeoutMs: timeoutMs)

        case .setFocus(let ref):
            return runSetFocus(ref: ref)

        case .scrollToMakeVisible(let ref):
            return runScrollToMakeVisible(ref: ref)
        }
    }

    /// Resolve `ref` to a node, then ask its view to take focus.
    /// Best-effort: returns OK if focus was set, error if no matching node
    /// or the view doesn't conform to `ProbeFocusable`.
    private func runSetFocus(ref: NCUINodeRef) -> NCUIResponse {
        guard let server = windowServer else {
            return NCUIResponse(frame: frameHook.current, result: .error("no window server"))
        }
        let resultBox = NCUIFocusResult()
        let walk = {
            MainActor.assumeIsolated {
                guard let root = server.rootViewNode else {
                    resultBox.error = "no root view"
                    return
                }
                if let target = NCUIRefResolver.resolve(ref: ref, in: root) {
                    if let focusable = target.anyView as? any ProbeFocusable {
                        if focusable._probeSetFocused(true) {
                            server.setNeedsWork()
                            resultBox.success = true
                        } else {
                            resultBox.error = "view rejected focus"
                        }
                    } else {
                        resultBox.error = "view '\(type(of: target.anyView))' is not ProbeFocusable — conform it to that protocol or use sendKey(.tab)"
                    }
                } else {
                    resultBox.error = "no node matched ref"
                }
            }
        }
        if Thread.isMainThread { walk() } else { DispatchQueue.main.sync(execute: walk) }
        if resultBox.success {
            return NCUIResponse(frame: frameHook.current, result: .ok)
        }
        return NCUIResponse(
            frame: frameHook.current,
            result: .error(resultBox.error ?? "setFocus failed")
        )
    }

    /// Resolve `ref`, walk parents looking for a ScrollView, ask it to
    /// scroll the target's frame into view.
    private func runScrollToMakeVisible(ref: NCUINodeRef) -> NCUIResponse {
        guard let server = windowServer else {
            return NCUIResponse(frame: frameHook.current, result: .error("no window server"))
        }
        let resultBox = NCUIFocusResult()
        let walk = {
            MainActor.assumeIsolated {
                guard let root = server.rootViewNode else {
                    resultBox.error = "no root view"
                    return
                }
                guard let target = NCUIRefResolver.resolve(ref: ref, in: root) else {
                    resultBox.error = "no node matched ref"
                    return
                }
                // Walk up through parents looking for a ScrollView host.
                var cursor: (any ViewNode)? = target.parent
                while let node = cursor {
                    if let scroller = node.anyView as? any ProbeScrollable {
                        if scroller._probeScrollIntoView(child: target) {
                            server.setNeedsWork()
                            resultBox.success = true
                            return
                        }
                    }
                    cursor = node.parent
                }
                resultBox.error = "no ProbeScrollable ancestor"
            }
        }
        if Thread.isMainThread { walk() } else { DispatchQueue.main.sync(execute: walk) }
        if resultBox.success {
            return NCUIResponse(frame: frameHook.current, result: .ok)
        }
        return NCUIResponse(
            frame: frameHook.current,
            result: .error(resultBox.error ?? "scrollToMakeVisible failed")
        )
    }

    /// Re-evaluates `spec` against the live tree on every frame tick until at
    /// least one match exists or `timeoutMs` elapses. Returns the matching
    /// nodes (response.result = .nodes) on success, or .error("timeout") on
    /// failure. Frame counter in the response reflects the frame the
    /// predicate became true (or the latest if we timed out).
    private func runAwait(spec: NCUIQuerySpec, timeoutMs: Int) -> NCUIResponse {
        // Fast path: maybe it's already satisfied.
        if let immediate = matchOnce(spec: spec) {
            return NCUIResponse(frame: frameHook.current, result: .nodes(immediate))
        }

        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        let resultBox = NCUIAwaitBox()
        let sem = DispatchSemaphore(value: 0)

        // Register a frame callback that re-evaluates and signals on match.
        // The hook fires once per registration, so we re-register inside.
        @Sendable func arm() {
            frameHook.onNextFrame { _ in
                if resultBox.stopped { return }
                if let matches = self.matchOnce(spec: spec) {
                    resultBox.lock.lock()
                    if !resultBox.stopped {
                        resultBox.stopped = true
                        resultBox.matches = matches
                        resultBox.frame = self.frameHook.current
                        sem.signal()
                    }
                    resultBox.lock.unlock()
                } else {
                    arm()  // wait another frame
                }
            }
        }
        arm()

        let waited = sem.wait(timeout: deadline)
        resultBox.lock.lock()
        resultBox.stopped = true
        resultBox.lock.unlock()

        switch waited {
        case .success:
            return NCUIResponse(
                frame: resultBox.frame ?? frameHook.current,
                result: .nodes(resultBox.matches ?? [])
            )
        case .timedOut:
            // One last try in case a frame fired right at the deadline.
            if let matches = matchOnce(spec: spec) {
                return NCUIResponse(frame: frameHook.current, result: .nodes(matches))
            }
            return NCUIResponse(
                frame: frameHook.current,
                result: .error("timeout: predicate not satisfied within \(timeoutMs)ms")
            )
        }
    }

    /// Walk the tree once and return matches, or nil if none found.
    /// May be called from the main thread (frame callback) or a background
    /// thread (request handler) — handles both.
    private func matchOnce(spec: NCUIQuerySpec) -> [NCUINodeSnapshot]? {
        guard let server = windowServer else { return nil }
        let nodeBox = NodeBox()
        let walk = {
            MainActor.assumeIsolated {
                guard let root = server.rootViewNode else { return }
                let focused = NCUIFocusTracker.shared.focusedID(for: server)
                nodeBox.value = NCUITreeWalker.snapshot(from: root, focused: focused)
            }
        }
        if Thread.isMainThread {
            walk()
        } else {
            DispatchQueue.main.sync(execute: walk)
        }
        guard let snap = nodeBox.value else { return nil }
        let matches = NCUIPredicateMatcher.evaluateOnce(spec: spec, tree: snap)
        return matches.isEmpty ? nil : matches
    }

    /// Best-effort wake of the WindowServer loop after pushing synthetic input,
    /// so the loop notices the queue without waiting out its idle timeout.
    private func wakeRunLoop() {
        guard let server = windowServer else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                server.setNeedsWork()
            }
        }
    }

    /// Block the connection thread until the frame counter ticks at least once,
    /// or `timeoutMs` elapses. Returns the post-tick frame number (or current
    /// if we timed out — caller can still proceed, just with weaker sync).
    private func waitForNextFrame(timeoutMs: Int) -> UInt64 {
        let target = frameHook.current + 1
        let sem = DispatchSemaphore(value: 0)
        let postedBox = NCUIFrameWaitBox()
        frameHook.onNextFrame { current in
            postedBox.frame = current
            sem.signal()
        }
        let timeout: DispatchTime = .now() + .milliseconds(timeoutMs)
        _ = sem.wait(timeout: timeout)
        return postedBox.frame ?? max(frameHook.current, target)
    }

    /// Hops to MainActor to walk the live tree, returning a response built
    /// from the resulting snapshot. Connection threads are background; tree
    /// traversal must happen on the main thread because views are MainActor.
    private func runOnMainCapturingTree(
        _ build: @escaping @Sendable (NCUINodeSnapshot) -> NCUIResponse
    ) -> NCUIResponse {
        guard let server = windowServer else {
            return NCUIResponse(
                frame: frameHook.current,
                result: .error("window server unavailable")
            )
        }
        let nodeBox = NodeBox()
        let walk = {
            MainActor.assumeIsolated {
                guard let root = server.rootViewNode else {
                    nodeBox.value = nil
                    return
                }
                let focused = NCUIFocusTracker.shared.focusedID(for: server)
                nodeBox.value = NCUITreeWalker.snapshot(from: root, focused: focused)
            }
        }
        if Thread.isMainThread {
            walk()
        } else {
            DispatchQueue.main.sync(execute: walk)
        }
        guard let snap = nodeBox.value else {
            return NCUIResponse(
                frame: frameHook.current,
                result: .error("no root view")
            )
        }
        return build(snap)
    }

    private func readFrame(fd: Int32) -> Data? {
        var lenBuf = [UInt8](repeating: 0, count: 4)
        guard readExact(fd: fd, into: &lenBuf, count: 4) else { return nil }
        let len = (UInt32(lenBuf[0]) << 24) | (UInt32(lenBuf[1]) << 16)
            | (UInt32(lenBuf[2]) << 8) | UInt32(lenBuf[3])
        if len == 0 { return Data() }
        if len > 16 * 1024 * 1024 {
            serverLogger.error("[NCUIProbe] oversized frame: \(len)")
            return nil
        }
        var payload = [UInt8](repeating: 0, count: Int(len))
        guard readExact(fd: fd, into: &payload, count: Int(len)) else { return nil }
        return Data(payload)
    }

    private func readExact(fd: Int32, into buf: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        var got = 0
        while got < count {
            let n = read(fd, buf.advanced(by: got), count - got)
            if n == 0 { return false }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            got += n
        }
        return true
    }

    private func readExact(fd: Int32, into buf: inout [UInt8], count: Int) -> Bool {
        return buf.withUnsafeMutableBufferPointer { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return readExact(fd: fd, into: base, count: count)
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            var written = 0
            while written < data.count {
                let n = write(fd, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                written += n
            }
            return true
        }
    }
}

/// Thread-safe one-shot box used to carry a non-Sendable value back from a
/// `DispatchQueue.main.sync` block. Single-writer/single-reader pattern.
final class NodeBox: @unchecked Sendable {
    var value: NCUINodeSnapshot?
}

/// Same idea for frame-counter wait results (UInt64 IS Sendable but we still
/// need a heap container so the semaphore producer can write through a closure).
final class NCUIFrameWaitBox: @unchecked Sendable {
    var frame: UInt64?
}

/// Holds the result of `awaitPredicate` so the matching frame's data survives
/// past the producer closure.
final class NCUIAwaitBox: @unchecked Sendable {
    var matches: [NCUINodeSnapshot]?
    var frame: UInt64?
    var stopped: Bool = false
    let lock = NSLock()
}

/// Non-Sendable result box for setFocus / scrollToMakeVisible main-thread
/// operations.
final class NCUIFocusResult: @unchecked Sendable {
    var success: Bool = false
    var error: String?
}

/// Marker protocol for views that participate in scroll-to-visible. The
/// probe walks up from a target node to find the nearest conformer and
/// asks it to bring `child.frame` into the viewport.
@MainActor
public protocol ProbeScrollable {
    /// Scroll content so `child.frame` is visible. Returns true if the
    /// scroll was applied; false if the child is not a descendant or the
    /// container can't satisfy the request.
    func _probeScrollIntoView(child: any ViewNode) -> Bool
}

enum NCUIProbeError: Error, CustomStringConvertible {
    case socketCreate(errno: Int32)
    case bind(path: String, errno: Int32)
    case listen(errno: Int32)
    case pathTooLong(String)

    var description: String {
        switch self {
        case .socketCreate(let e): return "socket() failed errno=\(e)"
        case .bind(let p, let e): return "bind(\(p)) failed errno=\(e)"
        case .listen(let e): return "listen() failed errno=\(e)"
        case .pathTooLong(let p): return "socket path too long: \(p)"
        }
    }
}
