import Testing
import Foundation
import NCursesUI

/// Behaviour of `Text(ansi:)` and the underlying `ANSIText.parseRuns`.
/// Asserts on the resulting `[Text.Run]` shape — content + style per
/// run — rather than on rendered output, since the run list is what
/// the draw layer actually consumes.
///
/// Uses `package` access (no `@testable`) per project convention; the
/// parser, run, and style types are all `package`-exposed for this.
@Suite("ANSIText")
struct ANSITextTests {

    private func runs(_ s: String) -> [Text.Run] { ANSIText.parseRuns(s) }

    @Test("plain string passes through as a single default-styled run")
    func plainPassthrough() {
        let r = runs("hello world")
        #expect(r.count == 1)
        #expect(r.first?.content == "hello world")
        #expect(r.first?.style.color == .normal)
        #expect(r.first?.style.bold == false)
        #expect(r.first?.style.dim == false)
    }

    @Test("empty string yields a single empty default-styled run")
    func emptyInput() {
        let r = runs("")
        #expect(r.count == 1)
        #expect(r.first?.content == "")
    }

    @Test("basic 30..37 sets foreground colour")
    func basicForegroundColour() {
        // 30 (black) maps to .normal because rendering literal black on
        // a dark terminal is invisible. 31..37 hit the named slots.
        let cases: [(Int, Color)] = [
            (30, .normal), (31, .red), (32, .green), (33, .yellow),
            (34, .blue), (35, .magenta), (36, .cyan), (37, .white),
        ]
        for (code, expected) in cases {
            let r = runs("\u{1B}[\(code)mhi\u{1B}[0m")
            let coloured = r.first { $0.content == "hi" }
            #expect(coloured != nil, "code \(code) should produce a 'hi' run")
            #expect(coloured?.style.color == expected,
                "code \(code) should map to \(expected)")
        }
    }

    @Test("reset (0) clears style mid-string")
    func resetMidString() {
        let r = runs("\u{1B}[31mred\u{1B}[0mplain")
        let red = r.first { $0.content == "red" }
        let plain = r.first { $0.content == "plain" }
        #expect(red?.style.color == .red)
        #expect(plain?.style.color == .normal)
        #expect(plain?.style.bold == false)
        #expect(plain?.style.dim == false)
    }

    @Test("bold (1) and dim (2) attributes")
    func boldAndDim() {
        let bold = runs("\u{1B}[1mB\u{1B}[0m").first { $0.content == "B" }
        #expect(bold?.style.bold == true)

        let dim = runs("\u{1B}[2mD\u{1B}[0m").first { $0.content == "D" }
        #expect(dim?.style.dim == true)
    }

    @Test("bright fg (90..97) sets bold + basic colour")
    func brightForegroundCollapsesToBoldBasic() {
        let r = runs("\u{1B}[91mhi\u{1B}[0m").first { $0.content == "hi" }
        #expect(r?.style.color == .red)
        #expect(r?.style.bold == true)
    }

    @Test("256-colour grey above 244 maps to .white, below to .dim")
    func ansi256Grey() {
        let dark = runs("\u{1B}[38;5;235mx\u{1B}[0m").first { $0.content == "x" }
        #expect(dark?.style.color == .dim)
        let light = runs("\u{1B}[38;5;250mx\u{1B}[0m").first { $0.content == "x" }
        #expect(light?.style.color == .white)
    }

    @Test("truecolour quantises to nearest basic slot")
    func truecolour() {
        // Pure red (#FF0000) → .red.
        let red = runs("\u{1B}[38;2;255;0;0mx\u{1B}[0m").first { $0.content == "x" }
        #expect(red?.style.color == .red)
        // Pure green (#00FF00) → .green.
        let green = runs("\u{1B}[38;2;0;255;0mx\u{1B}[0m").first { $0.content == "x" }
        #expect(green?.style.color == .green)
    }

    @Test("unknown SGR params drop silently — text content preserved")
    func unknownParams() {
        // 99 is not a defined SGR code; the run should still emit "x".
        let r = runs("\u{1B}[99mx\u{1B}[0m")
        let x = r.first { $0.content == "x" }
        #expect(x != nil)
    }

    @Test("text before and after escapes is preserved")
    func surroundingText() {
        let r = runs("pre \u{1B}[31mred\u{1B}[0m post")
        let pre = r.first { $0.content == "pre " }
        let red = r.first { $0.content == "red" }
        let post = r.first { $0.content == " post" }
        #expect(pre != nil)
        #expect(red?.style.color == .red)
        #expect(post != nil)
    }

    @Test("non-CSI escapes skip cleanly (don't litter output)")
    func nonCsiEscape() {
        // ESC followed by `]` is OSC, not CSI. Our parser drops the
        // ESC + next byte and leaves the rest as text. We don't
        // assert exact content beyond "the result is non-empty"; OSC
        // semantics are out of scope.
        let r = runs("\u{1B}]0;hello\u{07}rest")
        #expect(r.contains { !$0.content.isEmpty })
    }

    @Test("Text(ansi:) initializer mirrors parseRuns output")
    func textInitializer() {
        let t = Text(ansi: "\u{1B}[31mred\u{1B}[0m")
        let direct = ANSIText.parseRuns("\u{1B}[31mred\u{1B}[0m")
        #expect(t.runs.count == direct.count)
        for (a, b) in zip(t.runs, direct) {
            #expect(a.content == b.content)
            #expect(a.style.color == b.style.color)
        }
    }
}
