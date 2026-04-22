import Cncurses
import Foundation

// MARK: - Screen protocol (1:1 ncurses primitive abstraction)

public protocol Screen: AnyObject, Sendable {
    var rows: Int { get }
    var cols: Int { get }
    func move(_ y: Int32, _ x: Int32)
    func addstr(_ s: String)
    func attron(_ attrs: Int32)
    func attroff(_ attrs: Int32)
    func erase()
    func refresh()
    /// Raw next input event — ncurses getch result, `KEY_MOUSE` is decoded
    /// upstream by `Term.nextEvent`.
    func getch() -> Int32

    // Draw-target stack: ScrollView pushes a pad so child draws land in the
    // pad's coordinate space instead of stdscr. Bottom of the stack is always
    // stdscr; popTarget is a no-op when only stdscr remains.
    func pushTarget(_ target: OpaquePointer)
    func popTarget()

    // Refresh pipeline — we need wnoutrefresh + pnoutrefresh + doupdate so
    // pad viewports and stdscr overlays (e.g. scrollbars) composite in one
    // pass. `queuePadRefresh` defers the blit until `flush`.
    func queuePadRefresh(_ pad: OpaquePointer,
                         padY: Int, padX: Int,
                         onY1: Int, onX1: Int, onY2: Int, onX2: Int)
    func flush()
}

// MARK: - Color

public enum Color: Int32, Sendable {
    case green = 1, red = 2, yellow = 3, cyan = 4, selected = 5, dim = 6, magenta = 7
}

// MARK: - Mouse / unified event

public struct MouseEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case wheelUp, wheelDown, click, release
    }
    public let y: Int
    public let x: Int
    public let kind: Kind
    public init(y: Int, x: Int, kind: Kind) { self.y = y; self.x = x; self.kind = kind }
}

public enum TermEvent: Sendable, Equatable {
    case key(Int32)
    case mouse(MouseEvent)
    case none
}

// MARK: - NCursesScreen (production)
//
// Class (was struct) because the draw-target stack is mutable per-frame and
// we want reference semantics — `Term.screen` is a single shared sink for
// every view's `draw(in:)` call.

public final class NCursesScreen: Screen, @unchecked Sendable {
    private var targetStack: [OpaquePointer] = []
    private var pendingPadRefreshes: [PadRefresh] = []

    private struct PadRefresh {
        let pad: OpaquePointer
        let padY: Int32
        let padX: Int32
        let sy1: Int32
        let sx1: Int32
        let sy2: Int32
        let sx2: Int32
    }

    public init() {}

    private var target: OpaquePointer {
        // `tui_stdscr()` is valid only after `initscr()`. We lazily seed the
        // stack here instead of at init time so tests that instantiate the
        // class without a live ncurses session don't crash.
        if targetStack.isEmpty {
            targetStack.append(tui_stdscr())
        }
        return targetStack.last!
    }

    public var rows: Int { Int(tui_lines()) }
    public var cols: Int { Int(tui_cols()) }
    public func move(_ y: Int32, _ x: Int32) { wmove(target, y, x) }
    public func addstr(_ s: String) { waddstr(target, s) }
    public func attron(_ attrs: Int32) { tui_wattron(target, attrs) }
    public func attroff(_ attrs: Int32) { tui_wattroff(target, attrs) }
    public func erase() { werase(target) }
    public func refresh() { flush() }
    public func getch() -> Int32 { wgetch(tui_stdscr()) }

    public func pushTarget(_ t: OpaquePointer) {
        if targetStack.isEmpty { targetStack.append(tui_stdscr()) }
        targetStack.append(t)
    }
    public func popTarget() {
        if targetStack.count > 1 { _ = targetStack.popLast() }
    }

    public func queuePadRefresh(_ pad: OpaquePointer,
                                padY: Int, padX: Int,
                                onY1: Int, onX1: Int, onY2: Int, onX2: Int) {
        pendingPadRefreshes.append(PadRefresh(
            pad: pad,
            padY: Int32(padY), padX: Int32(padX),
            sy1: Int32(onY1), sx1: Int32(onX1),
            sy2: Int32(onY2), sx2: Int32(onX2)))
    }

    public func flush() {
        _ = tui_wnoutrefresh(tui_stdscr())
        for r in pendingPadRefreshes {
            _ = tui_pnoutrefresh(r.pad, r.padY, r.padX, r.sy1, r.sx1, r.sy2, r.sx2)
        }
        pendingPadRefreshes.removeAll(keepingCapacity: true)
        _ = tui_doupdate()
    }

    public func setup() {
        setlocale(LC_ALL, "")
        initscr()
        cbreak()
        noecho()
        curs_set(0)
        // `keypad(true)` would have ncurses translate escape sequences
        // (`\033[A`, `\033[<Pb;Px;PyM`, …) into named KEY_* codes. That
        // works fine for arrows but DROPS button-5 mouse reports on
        // macOS, since macOS ships ncurses 6.0 with no BUTTON5_PRESSED
        // definition. Disable keypad so escape sequences flow through
        // getch byte-by-byte and our Swift parser decodes them (mouse
        // via `tryDecodeSGRMouse`, arrow keys via `tryDecodeCSIKey`).
        keypad(tui_stdscr(), false)
        wtimeout(tui_stdscr(), 16)
        // `mousemask` handles the terminfo write that Terminal.app needs
        // to enter mouse-reporting mode. We still need it even with
        // keypad off. SGR (?1006h) is enabled separately so coords past
        // col 223 and both wheel directions arrive with stable encoding.
        mousemask(tui_all_mouse_events(), nil)
        fputs("\033[?1006h", stdout)
        fflush(stdout)
        Term._mouseLog("setup: keypad=off, mousemask=ALL_MOUSE_EVENTS, SGR enabled — Swift parses escape sequences")

        if has_colors() {
            start_color()
            use_default_colors()
            init_pair(Int16(Color.green.rawValue),   Int16(COLOR_GREEN),   -1)
            init_pair(Int16(Color.red.rawValue),     Int16(COLOR_RED),     -1)
            init_pair(Int16(Color.yellow.rawValue),  Int16(COLOR_YELLOW),  -1)
            init_pair(Int16(Color.cyan.rawValue),    Int16(COLOR_CYAN),    -1)
            init_pair(Int16(Color.selected.rawValue),Int16(COLOR_WHITE),   Int16(COLOR_BLUE))
            init_pair(Int16(Color.dim.rawValue),     Int16(COLOR_WHITE),   -1)
            init_pair(Int16(Color.magenta.rawValue), Int16(COLOR_MAGENTA), -1)
        }
    }

    public func teardown() {
        tui_disable_mouse()
        endwin()
    }
}

// MARK: - Term (high-level drawing API, delegates to Screen)

public struct Term {
    nonisolated(unsafe) public static var screen: any Screen = NCursesScreen()

    public static var rows: Int { screen.rows }
    public static var cols: Int { screen.cols }

    public static func setup() { (screen as? NCursesScreen)?.setup() }
    public static func teardown() { (screen as? NCursesScreen)?.teardown() }

    public static func put(_ y: Int, _ x: Int, _ s: String) {
        screen.move(Int32(y), Int32(x))
        screen.addstr(s)
    }

    public static func put(_ y: Int, _ x: Int, _ s: String,
                           color: Color, bold: Bool = false, inverted: Bool = false) {
        var attrs = tui_color_pair(color.rawValue)
        if bold { attrs |= tui_a_bold() }
        if inverted { attrs |= tui_a_reverse() }
        screen.attron(attrs)
        screen.move(Int32(y), Int32(x))
        screen.addstr(s)
        screen.attroff(attrs)
    }

    public static func putDim(_ y: Int, _ x: Int, _ s: String) {
        let attrs = tui_a_dim()
        screen.attron(attrs)
        screen.move(Int32(y), Int32(x))
        screen.addstr(s)
        screen.attroff(attrs)
    }

    public static func hline(_ y: Int, _ x: Int, _ width: Int) {
        screen.move(Int32(y), Int32(x))
        let count = min(width, cols - x)
        if count > 0 { screen.addstr(String(repeating: "─", count: count)) }
    }

    public static func fill(_ y: Int, _ x: Int, _ width: Int, color: Color) {
        let attrs = tui_color_pair(color.rawValue)
        screen.attron(attrs)
        screen.move(Int32(y), Int32(x))
        let count = min(width, cols - x)
        if count > 0 { screen.addstr(String(repeating: " ", count: count)) }
        screen.attroff(attrs)
    }

    public static func clearRect(_ rect: Rect) {
        for row in rect.y..<min(rect.y + rect.height, rows) {
            screen.move(Int32(row), Int32(rect.x))
            let count = min(rect.width, cols - rect.x)
            if count > 0 { screen.addstr(String(repeating: " ", count: count)) }
        }
    }

    public static func clear() { screen.erase() }

    /// Flush the frame: queued pad viewports + stdscr → the user sees output.
    /// Replaces the old single-`wrefresh` model; call once per frame at end.
    public static func flush() { screen.flush() }
    /// Legacy alias for callers that still say `Term.refresh()`.
    public static func refresh() { screen.flush() }

    // MARK: draw-target stack (used by ScrollView / pads)

    public static func pushTarget(_ t: OpaquePointer) { screen.pushTarget(t) }
    public static func popTarget() { screen.popTarget() }
    public static func queuePadRefresh(_ pad: OpaquePointer,
                                       padY: Int, padX: Int,
                                       on rect: Rect) {
        screen.queuePadRefresh(
            pad,
            padY: padY, padX: padX,
            onY1: rect.y, onX1: rect.x,
            onY2: rect.y + rect.height - 1,
            onX2: rect.x + rect.width - 1)
    }

    // MARK: events

    /// Poll once for a key or mouse event.
    ///
    /// We handle two mouse-decoding paths:
    /// 1. `KEY_MOUSE` from ncurses' built-in decoder (X10/UTF-8 modes).
    /// 2. **SGR mouse reports** parsed inline. macOS ships ncurses 5.7,
    ///    which doesn't decode SGR (`\033[<Pb;Px;PyM`); each byte leaks
    ///    through as a keypress. Modern terminals (iTerm2, kitty, alacritty)
    ///    default to SGR mode and ignore `?1006l`, so we have to parse it.
    /// Poll for the next input event. `timeoutMs` = 0 returns immediately
    /// if nothing is queued (used by the run loop's drain pass to
    /// coalesce wheel-event bursts); the default 16ms paces the run loop
    /// when idle.
    public static func nextEvent(timeoutMs: Int32 = 16) -> TermEvent {
        wtimeout(tui_stdscr(), timeoutMs)
        let ch = screen.getch()
        if ch == -1 { return .none }
        _mouseLog("getch ch=\(ch) (0x\(String(ch, radix: 16))) name=\(_keyName(ch))")
        if ch == tui_key_mouse() {
            return decodeNcursesMouse()
        }
        if ch == 27 {
            // Widen the getch timeout while reading the escape tail so
            // a 6-byte X10 mouse report arrives whole. 20ms is plenty —
            // Terminal.app emits the full sequence in a single TTY write,
            // so the follow-up bytes are already in the kernel buffer;
            // the timeout only covers the rare case where the first byte
            // and the rest straddle a read() boundary. 100ms added
            // noticeable per-event lag when many wheel events queued;
            // 20ms feels instant while still catching split bursts.
            wtimeout(tui_stdscr(), 20)
            defer { wtimeout(tui_stdscr(), 16) }
            return decodeAfterEsc()
        }
        return .key(ch)
    }

    /// We've just read ESC. Figure out what CSI or mouse sequence
    /// follows. Handles three cases:
    ///   1. `ESC [ <Pb;Px;Py M/m`  — SGR mouse report
    ///   2. `ESC [ A/B/C/D/H/F` / `ESC [ 5~ / 6~`  — arrow + page keys
    ///   3. `ESC <Cb> <Cx> <Cy>`  — LEAKED X10 mouse tail. Happens when
    ///      ncurses' built-in mouse decoder consumed the `[M` prefix of
    ///      an X10 report but couldn't recognise the button code (e.g.
    ///      macOS ncurses 6.0 doesn't know about button 5 / wheel-down).
    ///      The remaining 3 encoded bytes leak through; we decode them
    ///      ourselves.
    private static func decodeAfterEsc() -> TermEvent {
        let c1 = screen.getch()
        _mouseLog("  decodeAfterEsc c1=\(c1)")
        if c1 == -1 { return .key(27) }   // bare ESC
        // Case 3: leaked X10 mouse tail. X10 encodes Cb/Cx/Cy as raw
        // bytes with 32 added (so they're always ≥ 32). Button byte bit 6
        // (0x40, decimal 64) set means "wheel/extended button". So any
        // Cb in ['`' (96) .. 0xff] that has the wheel bit set is a wheel
        // event. We additionally require the next two bytes (Cx, Cy) to
        // also be ≥ 32 so we don't misinterpret a legitimate `ESC a` =
        // Alt-a as a mouse event.
        if c1 != 91 {   // not '['
            // Fallback: if ncurses ate the `[M` prefix but we still got
            // the payload (happens with some ncurses/button-code combos),
            // treat an Cb-like byte as truncated X10.
            if c1 >= 96 && c1 <= 127 {
                let cx = screen.getch()
                let cy = screen.getch()
                _mouseLog("  decodeAfterEsc x10-leak c1=\(c1) cx=\(cx) cy=\(cy)")
                if cx >= 32 && cy >= 32 {
                    return .mouse(decodeX10(cb: c1, cx: cx, cy: cy))
                }
            }
            return .key(27)
        }
        let c2 = screen.getch()
        _mouseLog("  decodeAfterEsc c2=\(c2)")
        if c2 == -1 { return .key(27) }
        // SGR mouse: `[<...M/m` — variable-length, Pb/Px/Py as decimal.
        if c2 == 60 {   // '<'
            if let ev = tryDecodeSGRMousePayload() { return .mouse(ev) }
            return .none
        }
        // X10 mouse: `[M<Cb><Cx><Cy>` — 3 raw bytes with +32 offset. Still
        // used by Terminal.app and older xterms.
        if c2 == 77 {   // 'M'
            let cb = screen.getch()
            let cx = screen.getch()
            let cy = screen.getch()
            _mouseLog("  decodeAfterEsc x10-full cb=\(cb) cx=\(cx) cy=\(cy)")
            guard cb >= 32, cx >= 32, cy >= 32 else { return .none }
            return .mouse(decodeX10(cb: cb, cx: cx, cy: cy))
        }
        // Plain CSI: single-byte suffixes → ncurses' KEY_* codes
        switch c2 {
        case 65: return .key(Int32(KEY_UP))     // 'A'
        case 66: return .key(Int32(KEY_DOWN))   // 'B'
        case 67: return .key(Int32(KEY_RIGHT))  // 'C'
        case 68: return .key(Int32(KEY_LEFT))   // 'D'
        case 72: return .key(Int32(KEY_HOME))   // 'H'
        case 70: return .key(Int32(KEY_END))    // 'F'
        default: break
        }
        // Multi-byte CSI: `[5~` (PgUp), `[6~` (PgDn)
        if c2 >= 48 && c2 <= 57 {
            let c3 = screen.getch()
            if c3 == 126 {
                switch c2 {
                case 53: return .key(Int32(KEY_PPAGE))
                case 54: return .key(Int32(KEY_NPAGE))
                default: break
                }
            }
        }
        return .none
    }

    /// Already consumed `ESC [ <` — read the rest of an SGR mouse report.
    private static func tryDecodeSGRMousePayload() -> MouseEvent? {
        var buf: [UInt8] = []
        var terminator: Int32 = 0
        for _ in 0..<32 {
            let c = screen.getch()
            if c == -1 { return nil }
            if c == 77 || c == 109 {   // 'M' or 'm'
                terminator = c
                break
            }
            if (c >= 48 && c <= 57) || c == 59 {
                buf.append(UInt8(c))
            } else {
                return nil
            }
        }
        if terminator == 0 { return nil }
        guard let s = String(bytes: buf, encoding: .ascii) else { return nil }
        let parts = s.split(separator: ";").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let pb = parts[0], px = parts[1], py = parts[2]
        let x = max(0, px - 1), y = max(0, py - 1)
        let kind: MouseEvent.Kind
        if (pb & 64) != 0 {
            kind = (pb & 1) == 0 ? .wheelUp : .wheelDown
        } else if terminator == 77 && (pb & 3) == 0 {
            kind = .click
        } else {
            kind = .release
        }
        _mouseLog("SGR pb=\(pb) y=\(y) x=\(x) term=\(terminator == 77 ? "M" : "m") kind=\(kind)")
        return MouseEvent(y: y, x: x, kind: kind)
    }

    /// Human-readable name for ncurses key codes we care about when
    /// diagnosing mouse/scroll routing. Covers the codes Terminal.app and
    /// iTerm2 are most likely to emit for wheel events if they fall back
    /// to arrow / scroll-region keys instead of KEY_MOUSE.
    private static func _keyName(_ ch: Int32) -> String {
        switch ch {
        case 9: return "TAB"
        case 10: return "ENTER"
        case 27: return "ESC"
        case 127: return "BACKSPACE"
        case KEY_MOUSE: return "KEY_MOUSE"
        case KEY_UP: return "KEY_UP"
        case KEY_DOWN: return "KEY_DOWN"
        case KEY_LEFT: return "KEY_LEFT"
        case KEY_RIGHT: return "KEY_RIGHT"
        case KEY_PPAGE: return "KEY_PPAGE"
        case KEY_NPAGE: return "KEY_NPAGE"
        case KEY_HOME: return "KEY_HOME"
        case KEY_END: return "KEY_END"
        case KEY_SR: return "KEY_SR"         // scroll reverse — rare
        case KEY_SF: return "KEY_SF"         // scroll forward — rare
        case KEY_RESIZE: return "KEY_RESIZE"
        default:
            if ch >= 32 && ch < 127 {
                return "'\(Character(UnicodeScalar(UInt8(ch))))'"
            }
            if ch > 255 { return "KEY_\(ch)" }  // unknown named key
            return "ctrl-\(ch)"
        }
    }

    /// Read the rest of a `KEY_MOUSE` event via `getmouse`.
    private static func decodeNcursesMouse() -> TermEvent {
        var ev = MEVENT()
        let ok = withUnsafeMutablePointer(to: &ev) { tui_getmouse($0) }
        guard ok == OK else { return .none }
        let bstate = UInt(ev.bstate)
        // Check button5 by hard-coded bit patterns so we catch both
        // ncurses 6.x (button 5 press = 0x2000000) and potential
        // button-4-with-release-flag encodings some terminals emit for
        // wheel-down. The hard masks are stable across ncurses versions
        // that export the constants at all.
        let kind: MouseEvent.Kind
        let btn4Press: UInt = 0x80000     // BUTTON4_PRESSED
        let btn4Release: UInt = 0x40000   // BUTTON4_RELEASED (rare wheel-down variant)
        let btn5Press: UInt = 0x2000000   // BUTTON5_PRESSED (ncurses 6.x)
        let btn5Release: UInt = 0x1000000 // BUTTON5_RELEASED
        if bstate & btn4Press != 0 {
            kind = .wheelUp
        } else if bstate & (btn5Press | btn5Release | btn4Release) != 0 {
            kind = .wheelDown
        } else if bstate & UInt(tui_button1_pressed()) != 0 {
            kind = .click
        } else {
            kind = .release
        }
        _mouseLog("ncurses KEY_MOUSE y=\(ev.y) x=\(ev.x) bstate=0x\(String(bstate, radix: 16)) kind=\(kind)")
        return .mouse(MouseEvent(y: Int(ev.y), x: Int(ev.x), kind: kind))
    }

    /// Try to parse a CSI sequence after a leading ESC. Specifically looks
    /// for SGR mouse: `[<Pb;Px;PyM` (press) or `[<Pb;Px;Pym` (release).
    /// Returns nil if the sequence isn't a mouse report (caller treats the
    /// ESC as a bare ESC keypress).
    ///
    /// Caveat: if the sequence is some other CSI (e.g. an unrecognised
    /// function key), the bytes after the ESC are consumed and dropped.
    /// In keypad mode ncurses already maps the keys we care about to
    /// `KEY_*` codes, so unrecognised CSI is rare in practice.
    /// Decode an X10 mouse report. Cb / Cx / Cy are raw bytes with 32
    /// added (so they're always ≥ 32). Wheel events have bit 6 (0x40)
    /// set in Cb; low bit distinguishes up (0) vs down (1). Button 1
    /// press is Cb == 32.
    private static func decodeX10(cb: Int32, cx: Int32, cy: Int32) -> MouseEvent {
        let pb = Int(cb) - 32
        let x = max(0, Int(cx) - 32 - 1)
        let y = max(0, Int(cy) - 32 - 1)
        let kind: MouseEvent.Kind
        if (pb & 64) != 0 {
            kind = (pb & 1) == 0 ? .wheelUp : .wheelDown
        } else if (pb & 3) == 0 {
            kind = .click
        } else if (pb & 3) == 3 {
            kind = .release
        } else {
            kind = .click
        }
        _mouseLog("X10 pb=\(pb) y=\(y) x=\(x) kind=\(kind)")
        return MouseEvent(y: y, x: x, kind: kind)
    }

    /// Diagnostic log for mouse-path debugging. Writes to ncurses.log so
    /// mouse events can be correlated with view dispatch entries.
    /// Internal rather than private so `NCursesScreen.setup` can probe
    /// `mousemask` capabilities at startup.
    /// Route through `FileLogHandler` (persistent handle, single lock)
    /// instead of opening+closing per call. The old impl did a full
    /// `FileHandle(forWritingTo:) + seekToEndOfFile + write + close`
    /// sequence every time — ~50µs/call × 5–7 calls per wheel event
    /// × tens of events per scroll burst added up to seconds of lag,
    /// AND it fought with `FileLogHandler`'s persistent handle for
    /// the same file, leaving sparse/null gaps in the log.
    static func _mouseLog(_ s: String) {
        logger.debug("[Term.mouse] \(s)")
    }
    /// Legacy alias — extracts key from `nextEvent` and drops mouse events.
    /// New code should use `nextEvent()` directly.
    public static func key() -> Int32 {
        if case .key(let ch) = nextEvent() { return ch }
        return -1
    }
}

// MARK: - Formatting helpers

public func pad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return s + String(repeating: " ", count: width - s.count)
}

public func rpad(_ s: String, _ width: Int) -> String {
    if s.count >= width { return String(s.prefix(width)) }
    return String(repeating: " ", count: width - s.count) + s
}

public func sparkline(_ values: [Float], width: Int) -> String {
    let blocks: [Character] = ["▁","▂","▃","▄","▅","▆","▇","█"]
    guard !values.isEmpty else { return String(repeating: " ", count: width) }
    let sampled: [Float]
    if values.count > width {
        sampled = (0..<width).map { i in values[i * values.count / width] }
    } else { sampled = values }
    guard let lo = sampled.min(), let hi = sampled.max() else {
        return String(repeating: "▄", count: sampled.count)
    }
    let range = hi - lo
    return String(sampled.map { v in
        if range == 0 { return blocks[3] }
        let idx = Int((v - lo) / range * Float(blocks.count - 1))
        return blocks[min(idx, blocks.count - 1)]
    })
}

public func signalColor(_ signal: String) -> Color {
    switch signal.uppercased() {
    case "BUY", "BUY_VOL": return .green
    case "SELL", "SELL_VOL": return .red
    default: return .yellow
    }
}

public func changeColor(_ pct: Float) -> Color { pct >= 0 ? .green : .red }

public func formatChange(_ pct: Float) -> String {
    "\(pct >= 0 ? "+" : "")\(String(format: "%.2f", pct))%"
}

public func formatPrice(_ p: Float) -> String {
    if p >= 1000 { return String(format: "%.0f", p) }
    if p >= 100 { return String(format: "%.1f", p) }
    return String(format: "%.2f", p)
}
