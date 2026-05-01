import Foundation

final class NCUIFrameHook: @unchecked Sendable {
    private let lock = NSLock()
    private var _frame: UInt64 = 0
    private var waiters: [(UInt64) -> Void] = []

    var current: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _frame
    }

    func tick() {
        lock.lock()
        _frame &+= 1
        let snapshot = _frame
        let toFire = waiters
        waiters.removeAll()
        lock.unlock()
        for w in toFire { w(snapshot) }
    }

    func onNextFrame(_ block: @escaping (UInt64) -> Void) {
        lock.lock()
        waiters.append(block)
        lock.unlock()
    }
}
