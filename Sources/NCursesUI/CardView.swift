import Foundation
import Cncurses

/// Inline-flow card with a 1-col-inset frame, reverse-video header chip,
/// optional divider + single-line footer, and bottom rule.
///
/// Differs from `BoxView` in two ways: this card sits inline in scrollback
/// VStacks (BoxView is a modal-overlay primitive with a 2-col inset), and
/// the title renders as a reverse-video chip on the top border instead of
/// inline as plain text. Designed to match the Anthropic-Design IRC mockup
/// where chat cards have a "tab"-style header bar:
///
/// ```
/// ┌── ⟦ claude is asking ⟧ ─────────────── pending (1/2) ──┐
/// │ Where should the project live?                          │
/// │                                                         │
/// │ ▸ [x] New repo at ~/Projects/<name>             jason   │
/// │   [ ] Subdirectory under canary-sdks                    │
/// │   [ ] Other… (type answer)                              │
/// ├─────────────────────────────────────────────────────────┤
/// │ quorum: 3/3   ↑/↓ move · Enter vote · Esc unfocus       │
/// └─────────────────────────────────────────────────────────┘
/// ```
///
/// Width is taken from the layout pass — placing a CardView inside any
/// container that hands it a width drives the box width. The card never
/// hard-codes a column count, so terminal resize naturally reflows it.
public struct CardView<Content: View>: View, ContainerRendering {
    public let title: Text
    public let trailing: Text?
    public let footer: Text?
    public let accent: Palette.Role
    public let content: Content

    /// - Parameters:
    ///   - title: rendered reverse-video on the header bar.
    ///   - trailing: optional right-side annotation in the top border
    ///     (e.g. `"pending (1/2)"`, `"answered"`); rendered with the
    ///     accent role so status colour propagates.
    ///   - footer: optional single-line footer; when non-nil, an inner
    ///     divider precedes it.
    ///   - accent: palette role used for borders + trailing colour.
    ///     Defaults to `.mute` (decided / inactive cards). Pending /
    ///     active cards typically pass `.accent`.
    public init(
        title: Text,
        trailing: Text? = nil,
        footer: Text? = nil,
        accent: Palette.Role = .mute,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.footer = footer
        self.accent = accent
        self.content = content()
    }

    public var body: some View { content }

    // MARK: - Layout

    /// Inset child rect — leaves 1 col of padding on each side, 1 row
    /// for the top border, and (1 + footer ? 1 : 0) rows at the bottom
    /// for the divider + footer + bottom border.
    private func contentRect(in rect: Rect) -> Rect {
        let bottomChrome = footer != nil ? 3 : 1   // divider + footer + bottom OR just bottom
        return Rect(
            x: rect.x + 1,
            y: rect.y + 1,
            width: max(0, rect.width - 2),
            height: max(0, rect.height - 1 - bottomChrome)
        )
    }

    public func childRects(children: [any ViewNode], in rect: Rect) -> [Rect] {
        guard !children.isEmpty, rect.width >= 4 else { return [] }
        let inner = contentRect(in: rect)
        var out: [Rect] = []
        var y = inner.y
        for child in children {
            let s = child.measure(proposedWidth: inner.width)
            let h = max(0, min(s.height, inner.maxY - y))
            out.append(Rect(x: inner.x, y: y, width: inner.width, height: h))
            y += s.height
        }
        return out
    }

    public func measure(children: [any ViewNode], proposedWidth: Int) -> Size {
        let innerW = max(0, proposedWidth - 2)
        var h = 0
        for child in children {
            h += child.measure(proposedWidth: innerW).height
        }
        let chrome = 1 /*top*/ + 1 /*bottom*/ + (footer != nil ? 2 : 0)
        return Size(width: proposedWidth, height: h + chrome)
    }

    // MARK: - Draw

    public func draw(in rect: Rect) {
        guard rect.width >= 4, rect.height >= 2 else { return }
        let pair = PaletteRegistrar.pairId(for: accent)
        drawTopBorder(rect: rect, accentPair: pair)
        drawSides(rect: rect, accentPair: pair)
        drawBottomChrome(rect: rect, accentPair: pair)
    }

    private func drawTopBorder(rect: Rect, accentPair: Int32) {
        // Layout: ┌─⟦ <title> ⟧─…─⟨ <trailing> ⟩─┐
        // Title gets reverse-video + bold; trailing renders in accent.
        // Fill the gap with `─`.
        let chipPrefix = "──┤ "                 // 4 cols
        let chipSuffix = " ├──"                 // 4 cols
        let titleText = title.content
        let chipWidth = chipPrefix.count + titleText.count + chipSuffix.count
        let trailingText = trailing?.content ?? ""
        let trailingChunk = trailingText.isEmpty ? "" : " " + trailingText + " ─"
        let cornersAndSpacing = 1 /*┌*/ + 1 /*┐*/
        let fillCount = max(0, rect.width - cornersAndSpacing - chipWidth - trailingChunk.count)

        // Left corner + first stretch of `─`
        let attrs = tui_color_pair(accentPair)
        Term.screen.attron(attrs)
        Term.screen.move(Int32(rect.y), Int32(rect.x))
        Term.screen.addstr("┌")
        Term.screen.addstr(chipPrefix)  // includes ┤ at the right edge of chip-open
        Term.screen.attroff(attrs)

        // Reverse-video title chip — use reverseBar palette pair so
        // the chip uses the palette's `reverseBg` background regardless
        // of the active surface bg.
        let chipPair = PaletteRegistrar.pairId(for: .reverseBar)
        let chipAttrs = tui_color_pair(chipPair) | tui_a_bold()
        Term.screen.attron(chipAttrs)
        Term.screen.addstr(titleText)
        Term.screen.attroff(chipAttrs)

        Term.screen.attron(attrs)
        Term.screen.addstr(chipSuffix)
        Term.screen.addstr(String(repeating: "─", count: fillCount))
        Term.screen.attroff(attrs)

        // Trailing annotation in accent colour. The leading `─` stays
        // accent; the trailing text itself renders in the accent role
        // (status colour). For status semantics callers can pass an
        // already-coloured Text — but for now use accent.
        if !trailingText.isEmpty {
            Term.screen.attron(attrs)
            Term.screen.addstr(" ")
            Term.screen.attroff(attrs)
            // Trailing text inherits styling from the caller — paint
            // it via foregroundColor on `trailing` directly. Render
            // through Text.draw to honour any styling.
            trailing?.draw(in: Rect(
                x: rect.x + 1 + chipPrefix.count + titleText.count + chipSuffix.count + fillCount + 1,
                y: rect.y,
                width: trailingText.count,
                height: 1))
            Term.screen.attron(attrs)
            Term.screen.addstr(" ─┐")
            Term.screen.attroff(attrs)
        } else {
            Term.screen.attron(attrs)
            Term.screen.addstr("┐")
            Term.screen.attroff(attrs)
        }
    }

    private func drawSides(rect: Rect, accentPair: Int32) {
        let attrs = tui_color_pair(accentPair)
        Term.screen.attron(attrs)
        let bottomChrome = footer != nil ? 3 : 1
        for row in 1..<(rect.height - bottomChrome) {
            Term.screen.move(Int32(rect.y + row), Int32(rect.x))
            Term.screen.addstr("│")
            Term.screen.move(Int32(rect.y + row), Int32(rect.x + rect.width - 1))
            Term.screen.addstr("│")
        }
        Term.screen.attroff(attrs)
    }

    private func drawBottomChrome(rect: Rect, accentPair: Int32) {
        let attrs = tui_color_pair(accentPair)
        if let footer {
            // Inner divider row.
            let dividerY = rect.y + rect.height - 3
            Term.screen.attron(attrs)
            Term.screen.move(Int32(dividerY), Int32(rect.x))
            Term.screen.addstr("├" + String(repeating: "─", count: rect.width - 2) + "┤")
            Term.screen.attroff(attrs)

            // Footer row — `│ <footer> │`. Footer Text renders with
            // its own styling (callers stylise before passing).
            let footerY = rect.y + rect.height - 2
            Term.screen.attron(attrs)
            Term.screen.move(Int32(footerY), Int32(rect.x))
            Term.screen.addstr("│ ")
            Term.screen.attroff(attrs)
            footer.draw(in: Rect(
                x: rect.x + 2, y: footerY,
                width: rect.width - 4, height: 1))
            // Closing `│` — print to the rightmost column.
            Term.screen.attron(attrs)
            Term.screen.move(Int32(footerY), Int32(rect.x + rect.width - 1))
            Term.screen.addstr("│")
            Term.screen.attroff(attrs)
        }
        // Bottom border.
        Term.screen.attron(attrs)
        Term.screen.move(Int32(rect.y + rect.height - 1), Int32(rect.x))
        Term.screen.addstr("└" + String(repeating: "─", count: rect.width - 2) + "┘")
        Term.screen.attroff(attrs)
    }

    public func afterChildren(children: [any ViewNode], in rect: Rect) {
        // Children rendered into contentRect by the framework's pass.
        // Right `│` borders on each body row are painted in
        // `drawSides` once before children draw — but `drawSides`
        // runs in `draw(in:)` which is `before` children, and
        // children write OVER those columns if their content
        // exceeds inner width. Repaint sides AFTER children to win.
        let pair = PaletteRegistrar.pairId(for: accent)
        drawSides(rect: rect, accentPair: pair)
    }
}
