import Foundation
import Cncurses

/// Single-line text input with a visible cursor.
///
/// Key handling claims printable ASCII, arrows, home/end, backspace/delete,
/// and enter while `isFocused` is true; lets ESC and Tab bubble up so the
/// owning view can dismiss overlays or cycle focus. Multi-byte UTF-8 input
/// is not yet supported — bytes above 0x7E are ignored.
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
    /// Cursor blink frame index — 0..4 cycle: empty, dim, full, dim,
    /// empty. Drives a "breathing" fade rather than a hard on/off
    /// toggle. Starts at `2` so the cursor is at peak intensity the
    /// instant the field gains focus (blinking-in is jarring).
    @State private var blinkFrame: Int = 2

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
    /// filled → plain text. Focused → text with the char at the cursor
    /// rendered as a 5-frame breathing block (empty → dim → full → dim
    /// → empty), driven by `blinkFrame`.
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
        let cursorChar: String
        let after: String
        if c < text.count {
            let at = text.index(text.startIndex, offsetBy: c)
            let next = text.index(after: at)
            cursorChar = String(text[at..<next])
            after = String(text[next...])
        } else {
            cursorChar = " "
            after = ""
        }
        let cursorRender: Text = {
            switch blinkFrame {
            case 0, 4: return Text(cursorChar)                              // empty
            case 1, 3: return Text(cursorChar).reverse().foregroundColor(.dim) // dim
            default:   return Text(cursorChar).reverse()                    // full
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
            return ch >= 32 && ch <= 126
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
            onSubmit()
            return true
        default:
            guard ch >= 32, ch <= 126,
                  let scalar = Unicode.Scalar(UInt32(ch)) else {
                return false
            }
            let c = clampedCursor()
            let idx = text.index(text.startIndex, offsetBy: c)
            text.insert(Character(scalar), at: idx)
            cursor = c + 1
            return true
        }
    }
}
