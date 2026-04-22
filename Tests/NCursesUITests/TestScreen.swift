import NCursesUI

/// No-op screen for tests — no ncurses, no terminal. Records pad target
/// pushes/pops and pad-refresh queueing so scroll-related tests can assert
/// on them without a live ncurses runtime.
final class TestScreen: Screen, @unchecked Sendable {
    var rows: Int = 24
    var cols: Int = 80

    /// Recorded operations for assertions.
    struct PushRecord { let target: OpaquePointer }
    struct PopRecord {}
    struct PadRefreshRecord {
        let pad: OpaquePointer
        let padY: Int, padX: Int
        let onY1: Int, onX1: Int, onY2: Int, onX2: Int
    }
    var targetStack: [OpaquePointer] = []
    var pushes: [PushRecord] = []
    var pops: [PopRecord] = []
    var padRefreshes: [PadRefreshRecord] = []
    var flushes = 0

    /// Queued input events for `getch()` — pop FIFO-style per call.
    var keyQueue: [Int32] = []

    func move(_ y: Int32, _ x: Int32) {}
    func addstr(_ s: String) {}
    func attron(_ attrs: Int32) {}
    func attroff(_ attrs: Int32) {}
    func erase() {}
    func refresh() { flushes += 1 }
    func getch() -> Int32 { keyQueue.isEmpty ? -1 : keyQueue.removeFirst() }

    func pushTarget(_ t: OpaquePointer) {
        targetStack.append(t)
        pushes.append(PushRecord(target: t))
    }
    func popTarget() {
        if !targetStack.isEmpty { _ = targetStack.popLast() }
        pops.append(PopRecord())
    }
    func queuePadRefresh(_ pad: OpaquePointer,
                        padY: Int, padX: Int,
                        onY1: Int, onX1: Int, onY2: Int, onX2: Int) {
        padRefreshes.append(PadRefreshRecord(
            pad: pad, padY: padY, padX: padX,
            onY1: onY1, onX1: onX1, onY2: onY2, onX2: onX2))
    }
    func flush() { flushes += 1 }
}
