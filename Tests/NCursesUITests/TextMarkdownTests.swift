import Testing
@testable import NCursesUI

/// Tests for `Text.init(markdown:)` — line-scope markdown parser.
/// Verifies recognised marker round-tripping (bold / italic / code /
/// heading) and graceful fall-through on malformed input.
@MainActor
@Suite("Text(markdown:) parser")
struct TextMarkdownTests {

    @Test func plainTextSingleRun() {
        let t = Text(markdown: "hello world")
        #expect(t.runs.count == 1)
        #expect(t.runs[0].content == "hello world")
        #expect(t.runs[0].style.bold == false)
        #expect(t.runs[0].style.italic == false)
    }

    @Test func boldRoundTrip() {
        let t = Text(markdown: "say **hi** there")
        // pre / bold / post
        #expect(t.runs.map(\.content) == ["say ", "hi", " there"])
        #expect(t.runs[0].style.bold == false)
        #expect(t.runs[1].style.bold == true)
        #expect(t.runs[2].style.bold == false)
    }

    @Test func italicRoundTrip() {
        let t = Text(markdown: "an *emphasised* phrase")
        #expect(t.runs.map(\.content) == ["an ", "emphasised", " phrase"])
        #expect(t.runs[1].style.italic == true)
        #expect(t.runs[0].style.italic == false)
    }

    @Test func codeRoundTrip() {
        let t = Text(markdown: "use `foo()` here")
        #expect(t.runs.map(\.content) == ["use ", "foo()", " here"])
        #expect(t.runs[1].style.color == .cyan)
        #expect(t.runs[0].style.color != .cyan)
    }

    @Test func headingPrefixBoldsLine() {
        let t = Text(markdown: "# Title")
        #expect(t.runs.count == 1)
        #expect(t.runs[0].content == "Title")
        #expect(t.runs[0].style.bold == true)
    }

    @Test func headingHashHashHash() {
        let t = Text(markdown: "### Sub-section")
        #expect(t.runs.count == 1)
        #expect(t.runs[0].content == "Sub-section")
        #expect(t.runs[0].style.bold == true)
    }

    @Test func headingDoesNotConsumeNonSpaceFollow() {
        // `#tag` (no space after) is NOT a heading; should render plain.
        let t = Text(markdown: "#tag")
        #expect(t.runs[0].content == "#tag")
        #expect(t.runs[0].style.bold == false)
    }

    @Test func mixedMarkers() {
        let t = Text(markdown: "**bold** and *italic* and `code`")
        let parts = t.runs.map(\.content)
        #expect(parts.contains("bold"))
        #expect(parts.contains("italic"))
        #expect(parts.contains("code"))
        let bold  = t.runs.first { $0.content == "bold" }!
        let it    = t.runs.first { $0.content == "italic" }!
        let code  = t.runs.first { $0.content == "code" }!
        #expect(bold.style.bold)
        #expect(it.style.italic)
        #expect(code.style.color == .cyan)
    }

    @Test func emptyInputProducesEmptyRun() {
        let t = Text(markdown: "")
        #expect(t.runs.count == 1)
        #expect(t.runs[0].content == "")
    }

    @Test func unbalancedBoldSwallowsRest() {
        // Open `**` with no closer → all subsequent text is bold.
        // Acceptable behaviour per the parser docs (simpler than
        // backing-out on imbalance).
        let t = Text(markdown: "**oops")
        #expect(t.runs.count == 1)
        #expect(t.runs[0].content == "oops")
        #expect(t.runs[0].style.bold == true)
    }

    @Test func boldInsideHeading() {
        // `# title with **emphasis**` → whole line bold, but
        // `emphasis` toggles bold OFF (then back ON at the close,
        // which has no trailing text). Result: heading still bold,
        // emphasis is rendered NOT bold (visual contrast within
        // an already-bold heading).
        let t = Text(markdown: "# title **with** more")
        let titleRun = t.runs.first { $0.content == "title " }!
        let emphRun  = t.runs.first { $0.content == "with" }!
        let tailRun  = t.runs.first { $0.content == " more" }!
        #expect(titleRun.style.bold == true)
        #expect(emphRun.style.bold == false)
        #expect(tailRun.style.bold == true)
    }
}
