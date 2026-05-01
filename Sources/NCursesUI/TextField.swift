import Foundation
import Cncurses

/// Single-line text input with a visible cursor.
///
/// Key handling claims printable ASCII, arrows, home/end, backspace/delete,
/// enter, and multi-byte UTF-8 sequences (Latin-extended, CJK, BMP / SMP
/// emoji) while `isFocused` is true; lets ESC and Tab bubble up so the
/// owning view can dismiss overlays or cycle focus.
///
/// UTF-8 input model: ncurses' `getch` returns each byte of a multi-byte
/// codepoint as a separate Int32. We accumulate the lead + continuation
/// bytes in `utf8Buffer`, decode the codepoint once the sequence is
/// complete, and insert it as a single `Character`. Invalid sequences
/// (orphan continuation, lead followed by non-continuation) are dropped
/// and the buffer reset.
///
/// State model: `text` is a `@Binding`, so the caller owns the buffer.
/// `isFocused` is also a `@Binding` — the caller (or a focus coordinator)
/// decides which TextField currently holds the keyboard.
public struct TextField: View, KeyHandling {
    public let placeholder: String
    @Binding public var text: String
    @Binding public var isFocused: Bool
    public let onSubmit: () -> Void

    @State private var cursor: Int = 0
    /// Cursor blink frame index — 0..4 cycle: off, dim block, full
    /// block, bold block, dim block. Drives a "breathing" fade
    /// through 4 visible intensities. Starts at `3` so the cursor
    /// is at peak intensity the instant the field gains focus
    /// (blinking-in is jarring).
    @State private var blinkFrame: Int = 3
    /// Pending UTF-8 byte accumulator. ncurses' `getch` delivers each
    /// byte of a multi-byte codepoint as a separate keystroke; we buffer
    /// the lead + continuation bytes here until we've got a full
    /// sequence, then decode and insert. Only ever holds the bytes of a
    /// single in-progress codepoint (1..4 bytes). Reset on any decode
    /// failure or non-UTF-8 input.
    @State private var utf8Buffer: [UInt8] = []

    public init(_ placeholder: String = "",
                text: Binding<String>,
                isFocused: Binding<Bool> = .constant(true),
                onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        self._text = text
        self._isFocused = isFocused
        self.onSubmit = onSubmit
    }

    public var body: some View {
        renderText()
            // Re-fires whenever focus toggles — when defocused, the
            // task body returns immediately (the `guard isFocused`
            // below) so no animation runs in the background.
            .task(id: isFocused) {
                guard isFocused else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(130))
                    if Task.isCancelled { return }
                    blinkFrame = (blinkFrame + 1) % 5
                }
            }
    }

    /// Draws the line. Unfocused + empty → placeholder dimmed. Unfocused +
    /// filled → plain text. Focused → text with the cursor rendered as
    /// a 5-frame breathing block: off → dim █ → █ → bold █ → dim █.
    ///
    /// The block uses `"█"` (U+2588 FULL BLOCK) as a real foreground
    /// glyph rather than `.reverse()` on a space cell. They look
    /// identical at peak (a solid fg-colored block), but reversing a
    /// space leaves nothing for `A_DIM` to dim — the new fg is the
    /// terminal background, already at minimum brightness — so the
    /// breath collapsed to a 2-state hard blink. Drawing a real glyph
    /// gives `.dim()` and `.bold()` an actual color to modulate.
    private func renderText() -> Text {
        let focused = isFocused
        if text.isEmpty && !focused {
            return Text(placeholder).foregroundColor(.dim)
        }
        guard focused else {
            return Text(text)
        }
        let c = clampedCursor()
        let before = String(text.prefix(c))
        let after: String
        if c < text.count {
            let next = text.index(text.startIndex, offsetBy: c + 1)
            after = String(text[next...])
        } else {
            after = ""
        }
        let cursorRender: Text = {
            switch blinkFrame {
            case 0:  return Text(" ")                  // off
            case 1:  return Text("█").dim()            // low (rising)
            case 2:  return Text("█")                  // mid
            case 3:  return Text("█").bold()           // peak
            default: return Text("█").dim()            // low (descending) — frame 4
            }
        }()
        return Text(before) + cursorRender + Text(after)
    }

    private func clampedCursor() -> Int {
        min(max(0, cursor), text.count)
    }

    /// Index of the start of the word immediately before `from`. Skips any
    /// trailing whitespace first, then the non-whitespace word before that.
    /// Returns 0 when already at the start.
    private func previousWordBoundary(from start: Int) -> Int {
        let chars = Array(text)
        var i = min(start, chars.count)
        while i > 0, chars[i - 1].isWhitespace { i -= 1 }
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        return i
    }

    /// Index of the start of the next word after `from`. Skips the current
    /// word's non-whitespace, then the whitespace that follows. Returns
    /// `text.count` when already past the last word.
    private func nextWordBoundary(from start: Int) -> Int {
        let chars = Array(text)
        var i = max(0, start)
        let end = chars.count
        while i < end, !chars[i].isWhitespace { i += 1 }
        while i < end, chars[i].isWhitespace { i += 1 }
        return i
    }

    public func handles(_ ch: Int32) -> Bool {
        guard isFocused else { return false }
        switch ch {
        case 27, 9:
            // ESC, Tab — bubble to parent so overlays can dismiss + focus
            // coordinators can cycle. TextField doesn't own either.
            return false
        case 10, 13, 8, 127:
            return true
        case Int32(KEY_BACKSPACE), Int32(KEY_DC), Int32(KEY_LEFT),
             Int32(KEY_RIGHT), Int32(KEY_HOME), Int32(KEY_END):
            return true
        case KEY_ALT_LEFT, KEY_ALT_RIGHT, KEY_ALT_BACKSPACE:
            // Option+Arrow word-nav and Option+Backspace word-delete.
            return true
        default:
            // ASCII printable (32..126) plus the UTF-8 byte range
            // (0x80..0xF7). Continuation bytes (0x80..0xBF) and lead
            // bytes (0xC0..0xF7) both need to be claimed so they don't
            // bubble to a parent handler that interprets them as
            // ncurses key codes. ncurses key constants on macOS sit at
            // 0x100+ — well above 0xF7 — so there's no overlap.
            if ch >= 32 && ch <= 126 { return true }
            if ch >= 0x80 && ch <= 0xF7 { return true }
            return false
        }
    }

    public func handleKey(_ ch: Int32) -> Bool {
        guard isFocused else { return false }
        switch ch {
        case Int32(KEY_LEFT):
            cursor = max(0, clampedCursor() - 1)
            return true
        case Int32(KEY_RIGHT):
            cursor = min(text.count, clampedCursor() + 1)
            return true
        case Int32(KEY_HOME):
            cursor = 0
            return true
        case Int32(KEY_END):
            cursor = text.count
            return true
        case Int32(KEY_BACKSPACE), 127, 8:
            let c = clampedCursor()
            guard c > 0 else { return true }
            let idx = text.index(text.startIndex, offsetBy: c - 1)
            let next = text.index(after: idx)
            text.removeSubrange(idx..<next)
            cursor = c - 1
            return true
        case Int32(KEY_DC):
            let c = clampedCursor()
            guard c < text.count else { return true }
            let idx = text.index(text.startIndex, offsetBy: c)
            let next = text.index(after: idx)
            text.removeSubrange(idx..<next)
            return true
        case KEY_ALT_LEFT:
            // Option+Left — jump to start of previous word. Skip any
            // trailing whitespace immediately before the cursor, then
            // back through the preceding non-whitespace run.
            cursor = previousWordBoundary(from: clampedCursor())
            return true
        case KEY_ALT_RIGHT:
            // Option+Right — jump past the current word: skip any
            // non-whitespace, then skip following whitespace.
            cursor = nextWordBoundary(from: clampedCursor())
            return true
        case KEY_ALT_BACKSPACE:
            // Option+Backspace — delete the word to the left of the
            // cursor (same range Option+Left would move over).
            let end = clampedCursor()
            let start = previousWordBoundary(from: end)
            guard start < end else { return true }
            let sIdx = text.index(text.startIndex, offsetBy: start)
            let eIdx = text.index(text.startIndex, offsetBy: end)
            text.removeSubrange(sIdx..<eIdx)
            cursor = start
            return true
        case 10, 13:
            // A complete-but-unconsumed UTF-8 prefix at submit time
            // would otherwise leak into the next keystroke. Drop it.
            utf8Buffer.removeAll()
            onSubmit()
            return true
        default:
            // Mid-UTF-8 continuation byte — append, decode if complete.
            if !utf8Buffer.isEmpty,
               ch >= 0x80, ch <= 0xBF {
                utf8Buffer.append(UInt8(ch))
                if utf8Buffer.count >= utf8ExpectedLength(leadByte: utf8Buffer[0]) {
                    flushUtf8Buffer()
                }
                return true
            }
            // ASCII printable — keep the original fast path; also reset
            // any in-progress sequence in case a stray prefix is sitting.
            if ch >= 32, ch <= 126,
               let scalar = Unicode.Scalar(UInt32(ch)) {
                utf8Buffer.removeAll()
                let c = clampedCursor()
                let idx = text.index(text.startIndex, offsetBy: c)
                text.insert(Character(scalar), at: idx)
                cursor = c + 1
                return true
            }
            // UTF-8 lead byte — start a new sequence. (0xC0..0xF7 covers
            // 2-, 3-, and 4-byte forms; we don't accept overlong/invalid
            // 0xC0..0xC1 or 0xF5..0xF7 sequences here, but accumulating
            // them is harmless — the decode will simply fail and the
            // buffer resets.)
            if ch >= 0xC0, ch <= 0xF7 {
                utf8Buffer = [UInt8(ch)]
                return true
            }
            // Anything else (orphan continuation, ncurses key code we
            // don't claim, …) — drop and reset any partial sequence.
            utf8Buffer.removeAll()
            return false
        }
    }

    /// UTF-8 lead-byte → total expected byte count (lead + continuations).
    /// 0x00..0x7F → 1 (pure ASCII; never enters our buffer).
    /// 0xC0..0xDF → 2.  0xE0..0xEF → 3.  0xF0..0xF7 → 4.
    /// Returns 1 for invalid lead bytes so `flushUtf8Buffer` triggers
    /// immediately and the bad byte is discarded by `Unicode.Scalar`'s
    /// init failing.
    private func utf8ExpectedLength(leadByte: UInt8) -> Int {
        switch leadByte {
        case 0xC0...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF7: return 4
        default:          return 1
        }
    }

    /// Decode the buffered UTF-8 bytes into a `Character` and insert at
    /// the cursor. Resets the buffer regardless of success — a malformed
    /// sequence is dropped silently rather than rendered as replacement
    /// chars (the user just sees their keystroke vanish, same as the
    /// pre-fix behaviour for any non-ASCII byte).
    private func flushUtf8Buffer() {
        defer { utf8Buffer = [] }
        guard let str = String(bytes: utf8Buffer, encoding: .utf8),
              let char = str.first
        else { return }
        let c = clampedCursor()
        let idx = text.index(text.startIndex, offsetBy: c)
        text.insert(char, at: idx)
        cursor = c + 1
    }
}
