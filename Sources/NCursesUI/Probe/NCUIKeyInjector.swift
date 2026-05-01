import Foundation
import NCUITestProtocol

/// Maintains a thread-safe queue of synthetic `TermEvent`s the probe wants
/// the run loop to deliver. Filled by the probe's request handler from a
/// background thread; drained by `WindowServer.run()` on the main thread.
final class NCUIKeyInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [TermEvent] = []

    func push(_ event: TermEvent) {
        lock.lock(); defer { lock.unlock() }
        queue.append(event)
    }

    func push(_ events: [TermEvent]) {
        lock.lock(); defer { lock.unlock() }
        queue.append(contentsOf: events)
    }

    func drain() -> TermEvent? {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return queue.isEmpty
    }
}

enum NCUIKeyTranslate {
    /// Convert a wire key spec into a single `TermEvent`. Returns nil for
    /// shapes we can't translate yet (rare — most are 1:1).
    static func event(for spec: NCUIKeySpec) -> TermEvent? {
        switch spec {
        case .char(let ch):
            // ASCII pass-through; multi-byte chars not yet supported by the
            // line editor's key dispatch anyway.
            guard let scalar = ch.asciiValue else {
                // Non-ASCII: try the first unicode scalar's value if it fits in Int32.
                if let s = ch.unicodeScalars.first, s.value <= 0x7FFFFFFF {
                    return .key(Int32(s.value))
                }
                return nil
            }
            return .key(Int32(scalar))
        case .code(let code, _):
            return .key(ncursesCode(for: code))
        }
    }

    /// Translate text into a sequence of key events. Newlines map to `\n` (10),
    /// which the input handlers interpret as Enter.
    static func events(for text: String) -> [TermEvent] {
        var out: [TermEvent] = []
        for ch in text {
            if let scalar = ch.asciiValue {
                out.append(.key(Int32(scalar)))
            } else if let s = ch.unicodeScalars.first, s.value <= 0x7FFFFFFF {
                out.append(.key(Int32(s.value)))
            }
            // Drop chars we can't represent as a single Int32.
        }
        return out
    }

    /// ncurses key-code mapping for the abstract `NCUIKeyCode` cases. Values
    /// match the constants defined in ncurses (KEY_UP, etc.) and the extended
    /// codes NCursesUI defines in Terminal.swift.
    static func ncursesCode(for code: NCUIKeyCode) -> Int32 {
        switch code {
        case .enter: return 10                  // '\n'
        case .escape: return 27                 // ESC
        case .tab: return 9                     // '\t'
        case .backspace: return 127             // DEL on macOS terminals
        case .delete: return 0o512              // KEY_DC = 330
        case .space: return 32
        case .up: return 0o403                  // KEY_UP = 259
        case .down: return 0o402                // KEY_DOWN = 258
        case .left: return 0o404                // KEY_LEFT = 260
        case .right: return 0o405               // KEY_RIGHT = 261
        case .home: return 0o406                // KEY_HOME = 262
        case .end: return 0o550                 // KEY_END = 360
        case .pageUp: return 0o523              // KEY_PPAGE = 339
        case .pageDown: return 0o522            // KEY_NPAGE = 338
        case .f1:  return 0o410                 // KEY_F0 + 1 = 264 + 1
        case .f2:  return 0o411
        case .f3:  return 0o412
        case .f4:  return 0o413
        case .f5:  return 0o414
        case .f6:  return 0o415
        case .f7:  return 0o416
        case .f8:  return 0o417
        case .f9:  return 0o420
        case .f10: return 0o421
        case .f11: return 0o422
        case .f12: return 0o423
        }
    }
}
