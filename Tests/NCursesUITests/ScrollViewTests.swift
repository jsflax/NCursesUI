import Testing
import Foundation
@testable import NCursesUI

// These tests exercise ScrollView without a live ncurses runtime. The
// `Pad` type talks to ncurses directly on construction (`newpad`), which
// returns nil when ncurses hasn't been initscr'd — so we verify the bits
// that don't require a real pad: offset clamping, key handling gated by
// the external-binding switch, wheel event handling, scroll-step sizing.

private struct LongContent: View, PrimitiveView {
    let lines: Int
    typealias Body = Never
    var body: Never { fatalError() }
    func measure(children: [any ViewNode], proposedWidth: Int) -> Size {
        Size(width: proposedWidth, height: lines)
    }
    func draw(in rect: Rect) {}
}

@MainActor
@Suite("ScrollView key + mouse handling", .serialized)
struct ScrollViewKeyTests {
    init() { Term.screen = TestScreen() }

    @Test("Arrow keys scroll when no external binding is attached")
    func arrowsScrollInternal() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        // Simulate a prior draw having measured content.
        sv.box.lastContentHeight = 50

        #expect(sv.handles(Int32(KEY_DOWN)))
        _ = sv.handleKey(Int32(KEY_DOWN))
        #expect(sv.box.offset == 1)

        _ = sv.handleKey(Int32(KEY_DOWN))
        _ = sv.handleKey(Int32(KEY_DOWN))
        #expect(sv.box.offset == 3)

        _ = sv.handleKey(Int32(KEY_UP))
        #expect(sv.box.offset == 2)
    }

    @Test("Offset clamps to [0, content - visible] on repeated Down")
    func clampAtBottom() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50
        // maxOff = 50 - 10 = 40. Press Down 100 times; should stop at 40.
        for _ in 0..<100 { _ = sv.handleKey(Int32(KEY_DOWN)) }
        #expect(sv.box.offset == 40)
    }

    @Test("KEY_HOME jumps to 0; KEY_END jumps to maxOffset")
    func homeEnd() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50
        _ = sv.handleKey(Int32(KEY_END))
        #expect(sv.box.offset == 40)
        _ = sv.handleKey(Int32(KEY_HOME))
        #expect(sv.box.offset == 0)
    }

    @Test("Page keys scroll by visibleHeight - 1")
    func pageStep() {
        let sv = ScrollView(height: 10) { LongContent(lines: 100) }
        sv.box.lastContentHeight = 100
        _ = sv.handleKey(Int32(KEY_NPAGE))
        #expect(sv.box.offset == 9, "one page = visibleHeight - 1 = 9")
        _ = sv.handleKey(Int32(KEY_PPAGE))
        #expect(sv.box.offset == 0)
    }

    @Test("With external offset binding, ScrollView does NOT consume arrows")
    func bindingDisablesArrowKeys() {
        // Caller owns the offset state (e.g. for selection-coupled scroll).
        // ScrollView declines to handle arrows so the caller's onKeyPress
        // modifier can intercept them.
        final class Cell { var value = 0 }
        let cell = Cell()
        let binding = Binding<Int>(get: { cell.value }, set: { cell.value = $0 })
        let sv = ScrollView(height: 10, offset: binding) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50

        #expect(!sv.handles(Int32(KEY_UP)),
                "arrow keys must not be claimed when binding is provided")
        #expect(!sv.handles(Int32(KEY_DOWN)))
        #expect(!sv.handles(Int32(KEY_PPAGE)))
    }

    @Test("Wheel events scroll in steps of 3, regardless of external binding")
    func wheelScrollsEvenWithBinding() {
        final class Cell { var value = 0 }
        let cell = Cell()
        let binding = Binding<Int>(get: { cell.value }, set: { cell.value = $0 })
        let sv = ScrollView(height: 10, offset: binding) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50

        let down = MouseEvent(y: 5, x: 5, kind: .wheelDown)
        #expect(sv.handles(down))
        _ = sv.handleMouse(down)
        #expect(cell.value == 3, "wheelDown step = 3")

        _ = sv.handleMouse(down)
        #expect(cell.value == 6)

        let up = MouseEvent(y: 5, x: 5, kind: .wheelUp)
        _ = sv.handleMouse(up)
        #expect(cell.value == 3)
    }

    @Test("Wheel clamps at bottom of content")
    func wheelClamps() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50
        let down = MouseEvent(y: 0, x: 0, kind: .wheelDown)
        for _ in 0..<100 { _ = sv.handleMouse(down) }
        #expect(sv.box.offset == 40)
    }
}

@MainActor
@Suite("ScrollView does not claim keys it doesn't handle", .serialized)
struct ScrollViewKeyPassthroughTests {
    init() { Term.screen = TestScreen() }

    @Test("Random letter key is not claimed")
    func nonScrollKey() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        #expect(!sv.handles(Int32(Character("a").asciiValue!)))
    }

    @Test("Enter is not claimed — caller's Enter handler can fire")
    func enterNotClaimed() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        #expect(!sv.handles(10))  // \n
    }

    @Test("ESC is not claimed — caller's back-handler fires")
    func escNotClaimed() {
        let sv = ScrollView(height: 10) { LongContent(lines: 50) }
        #expect(!sv.handles(27))
    }
}

// MARK: - Regression: ScrollView no-op setOffset guard
//
// Bug: wheel events past the content boundary (e.g. `setOffset(40)` when
// offset is already 40) still wrote the same value to `box.offset`. Each
// write to an @Observable fires `markDirty` whether or not the value
// changed — 50 wheel events past the edge → 50 useless redraws, which
// the user perceived as lag. Fix: guard against same-value writes in
// `setOffset`.
@MainActor
@Suite("ScrollView setOffset no-op guard", .serialized)
struct ScrollViewNoOpGuardTests {
    init() { Term.screen = TestScreen() }

    @Test("Wheel past the bottom does not re-write the offset box")
    func wheelPastBottomIsNoOp() {
        final class Counter { var writes = 0 }
        let counter = Counter()
        let backing = Binding<Int>(
            get: { 40 },            // already at max offset
            set: { _ in counter.writes += 1 })
        let sv = ScrollView(height: 10, offset: backing) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50   // maxOff = 50 - 10 = 40

        let down = MouseEvent(y: 5, x: 5, kind: .wheelDown)
        for _ in 0..<20 { _ = sv.handleMouse(down) }
        #expect(counter.writes == 0,
                "wheelDown at the bottom must not write — each write triggers markDirty → redraw")
    }

    @Test("Wheel past the top does not re-write the offset box")
    func wheelPastTopIsNoOp() {
        final class Counter { var writes = 0 }
        let counter = Counter()
        let backing = Binding<Int>(
            get: { 0 },             // already at top
            set: { _ in counter.writes += 1 })
        let sv = ScrollView(height: 10, offset: backing) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50

        let up = MouseEvent(y: 5, x: 5, kind: .wheelUp)
        for _ in 0..<20 { _ = sv.handleMouse(up) }
        #expect(counter.writes == 0,
                "wheelUp at the top must not write — no-op guard prevents redraw storms")
    }

    @Test("First wheel that actually moves the offset still writes")
    func movingWheelWrites() {
        final class Backing { var value = 10 }
        let backing = Backing()
        let binding = Binding<Int>(get: { backing.value }, set: { backing.value = $0 })
        let sv = ScrollView(height: 10, offset: binding) { LongContent(lines: 50) }
        sv.box.lastContentHeight = 50

        let down = MouseEvent(y: 5, x: 5, kind: .wheelDown)
        _ = sv.handleMouse(down)
        #expect(backing.value == 13,
                "wheelDown step is 3; must actually write when value changes")
    }
}
