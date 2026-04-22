import Testing
import Foundation
@testable import NCursesUI

// `Term.nextEvent` reads bytes via `screen.getch()`. TestScreen has a
// `keyQueue` FIFO we can seed with bytes, so we can drive the X10 / SGR
// parsers without a real ncurses runtime.

@MainActor
@Suite("X10 mouse parsing", .serialized)
struct X10MouseDecodeTests {
    private func screen() -> TestScreen {
        let s = TestScreen()
        Term.screen = s
        return s
    }

    /// Feed the 6-byte X10 sequence `ESC [ M Cb Cx Cy` through getch.
    /// Cb / Cx / Cy are offset by 32 in X10 (so the minimum valid value
    /// for each is 32 / 0x20, representing position 0).
    private func queueX10(_ screen: TestScreen, cb: Int32, cx: Int32, cy: Int32) {
        screen.keyQueue.append(contentsOf: [27, 91, 77, cb, cx, cy])
    }

    @Test("Wheel-down (X10 button 5) decodes as .wheelDown")
    func wheelDown() {
        let s = screen()
        // Cb = 32 + 65 = 97, Cx/Cy put the event at (y=10, x=50)
        queueX10(s, cb: 97, cx: 32 + 51, cy: 32 + 11)
        let ev = Term.nextEvent()
        guard case .mouse(let m) = ev else {
            Issue.record("expected .mouse, got \(ev)")
            return
        }
        #expect(m.kind == .wheelDown)
        #expect(m.y == 10)
        #expect(m.x == 50)
    }

    @Test("Wheel-up (X10 button 4) decodes as .wheelUp")
    func wheelUp() {
        let s = screen()
        // Cb = 32 + 64 = 96 — wheel-up (button 4)
        queueX10(s, cb: 96, cx: 32 + 21, cy: 32 + 6)
        let ev = Term.nextEvent()
        guard case .mouse(let m) = ev else {
            Issue.record("expected .mouse")
            return
        }
        #expect(m.kind == .wheelUp)
        #expect(m.y == 5)
        #expect(m.x == 20)
    }

    @Test("Button 1 press decodes as .click")
    func leftClickPress() {
        let s = screen()
        // Cb = 32 + 0 = 32 — button 1 press (no wheel bit set)
        queueX10(s, cb: 32, cx: 32 + 11, cy: 32 + 6)
        let ev = Term.nextEvent()
        guard case .mouse(let m) = ev else {
            Issue.record("expected .mouse")
            return
        }
        #expect(m.kind == .click)
        #expect(m.y == 5)
        #expect(m.x == 10)
    }

    @Test("Button release decodes as .release")
    func release() {
        let s = screen()
        // Cb = 32 + 3 = 35 — release marker (button == 3)
        queueX10(s, cb: 35, cx: 32 + 11, cy: 32 + 6)
        let ev = Term.nextEvent()
        guard case .mouse(let m) = ev else {
            Issue.record("expected .mouse")
            return
        }
        #expect(m.kind == .release)
    }
}

@MainActor
@Suite("Bare ESC and unrecognised CSI pass through as keys", .serialized)
struct EscapeKeyPassthroughTests {
    private func screen() -> TestScreen {
        let s = TestScreen()
        Term.screen = s
        return s
    }

    @Test("Solo ESC returns .key(27)")
    func soloEsc() {
        let s = screen()
        s.keyQueue.append(27)
        let ev = Term.nextEvent()
        #expect(ev == .key(27))
    }

    @Test("CSI arrow (ESC [ A) returns KEY_UP")
    func csiArrow() {
        let s = screen()
        s.keyQueue.append(contentsOf: [27, 91, 65])  // ESC [ A
        let ev = Term.nextEvent()
        #expect(ev == .key(Int32(KEY_UP)))
    }

    @Test("CSI page key (ESC [ 6 ~) returns KEY_NPAGE")
    func csiPgDn() {
        let s = screen()
        s.keyQueue.append(contentsOf: [27, 91, 54, 126])  // ESC [ 6 ~
        let ev = Term.nextEvent()
        #expect(ev == .key(Int32(KEY_NPAGE)))
    }
}
