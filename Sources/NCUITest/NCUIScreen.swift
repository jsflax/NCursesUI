import Foundation
import NCUITestProtocol

/// Parses ANSI-escaped pane output from `tmux capture-pane -ep` into a
/// `(rows × cols)` cell grid. Self-contained — no dependency on NCursesUI's
/// internal Text(ansi:) parser, since NCUITest is the test author's library
/// and shouldn't pull in the full TUI runtime.
public enum NCUIScreen {
    /// Coarse SGR mapping. We track the same fields NCUITest's wire layer
    /// exposes: a `Color` slot, plus bold/dim/italic/inverted flags. Bg is
    /// not parsed yet (we'd need a separate slot).
    public struct CellAttrs: Sendable, Equatable {
        public var fg: NCUIColorSlot = .normal
        public var bg: NCUIColorSlot? = nil
        public var bold: Bool = false
        public var dim: Bool = false
        public var italic: Bool = false
        public var inverted: Bool = false
    }

    public struct ParsedCell: Sendable, Equatable {
        public var character: Character
        public var attrs: CellAttrs
    }

    public struct Grid: Sendable {
        public let rows: Int
        public let cols: Int
        public let cells: [[ParsedCell]]

        public init(rows: Int, cols: Int, cells: [[ParsedCell]]) {
            self.rows = rows
            self.cols = cols
            self.cells = cells
        }
    }

    public static func parse(ansi: String) -> Grid {
        var rows: [[ParsedCell]] = []
        var current: [ParsedCell] = []
        var attrs = CellAttrs()
        var iter = ansi.makeIterator()

        while let ch = iter.next() {
            if ch == "\u{1B}" {
                guard let next = iter.next() else { break }
                if next == "[" {
                    // CSI - read params until final byte.
                    var params = ""
                    var finalByte: Character?
                    while let p = iter.next() {
                        if (p >= "@" && p <= "~") {
                            finalByte = p
                            break
                        }
                        params.append(p)
                    }
                    if finalByte == "m" {
                        applySGR(params: params, attrs: &attrs)
                    }
                    // Other CSI sequences (cursor moves etc.) are ignored;
                    // tmux capture-pane -e doesn't usually emit them, but
                    // we still consume them safely.
                }
                // Other escape forms (ESC X) silently consumed.
                continue
            }
            if ch == "\n" {
                rows.append(current)
                current = []
                continue
            }
            if ch == "\r" {
                continue
            }
            current.append(ParsedCell(character: ch, attrs: attrs))
        }
        if !current.isEmpty { rows.append(current) }

        let cols = rows.map { $0.count }.max() ?? 0
        // Pad each row to `cols` with default-attrs spaces, so callers can
        // index uniformly.
        let padded: [[ParsedCell]] = rows.map { row in
            if row.count >= cols { return row }
            return row + Array(
                repeating: ParsedCell(character: " ", attrs: CellAttrs()),
                count: cols - row.count
            )
        }
        return Grid(rows: padded.count, cols: cols, cells: padded)
    }

    private static func applySGR(params: String, attrs: inout CellAttrs) {
        let parts = params.isEmpty ? ["0"] : params.split(separator: ";").map(String.init)
        var i = 0
        while i < parts.count {
            guard let n = Int(parts[i]) else { i += 1; continue }
            switch n {
            case 0:
                attrs = CellAttrs()
            case 1:
                attrs.bold = true
            case 2:
                attrs.dim = true
            case 3:
                attrs.italic = true
            case 4:
                attrs.italic = true   // underline → italic in our model (TUIs blur the two)
            case 7:
                attrs.inverted = true
            case 22:
                attrs.bold = false; attrs.dim = false
            case 23:
                attrs.italic = false
            case 24:
                attrs.italic = false
            case 27:
                attrs.inverted = false
            case 30: attrs.fg = .normal     // black
            case 31: attrs.fg = .red
            case 32: attrs.fg = .green
            case 33: attrs.fg = .yellow
            case 34: attrs.fg = .blue
            case 35: attrs.fg = .magenta
            case 36: attrs.fg = .cyan
            case 37: attrs.fg = .white
            case 38:
                // 38;5;N or 38;2;r;g;b — quantize to nearest slot.
                if i + 1 < parts.count, parts[i + 1] == "5", i + 2 < parts.count,
                   let idx = Int(parts[i + 2]) {
                    attrs.fg = quantize256(idx)
                    i += 2
                } else if i + 1 < parts.count, parts[i + 1] == "2", i + 4 < parts.count,
                          let r = Int(parts[i + 2]),
                          let g = Int(parts[i + 3]),
                          let b = Int(parts[i + 4]) {
                    attrs.fg = quantizeRGB(r: r, g: g, b: b)
                    i += 4
                }
            case 39: attrs.fg = .normal
            case 90: attrs.fg = .dim          // bright black ≈ dim grey
            case 91: attrs.fg = .red
            case 92: attrs.fg = .green
            case 93: attrs.fg = .yellow
            case 94: attrs.fg = .blue
            case 95: attrs.fg = .magenta
            case 96: attrs.fg = .cyan
            case 97: attrs.fg = .white
            default:
                break
            }
            i += 1
        }
    }

    private static func quantize256(_ idx: Int) -> NCUIColorSlot {
        // Common xterm-256 → semantic slots NCursesUI uses.
        switch idx {
        case 99: return .purple
        case 220: return .gold
        case 37: return .teal
        case 0...7:
            return [.normal, .red, .green, .yellow, .blue, .magenta, .cyan, .white][idx]
        case 8: return .dim
        case 9...15:
            return [.red, .green, .yellow, .blue, .magenta, .cyan, .white][idx - 9]
        case 244: return .dim
        default: return .normal
        }
    }

    private static func quantizeRGB(r: Int, g: Int, b: Int) -> NCUIColorSlot {
        // Crude nearest-named-color. Sufficient for screenshots since the
        // probe-side palette already maps semantic slots → exact RGB.
        let candidates: [(NCUIColorSlot, Int, Int, Int)] = [
            (.red, 200, 60, 60),
            (.green, 60, 200, 60),
            (.yellow, 200, 200, 60),
            (.blue, 60, 60, 200),
            (.magenta, 200, 60, 200),
            (.cyan, 60, 200, 200),
            (.white, 220, 220, 220),
            (.dim, 120, 120, 120),
            (.purple, 135, 95, 255),
            (.gold, 255, 215, 0),
            (.teal, 0, 175, 175),
        ]
        var best: (NCUIColorSlot, Int) = (.normal, .max)
        for (slot, cr, cg, cb) in candidates {
            let d = (cr - r) * (cr - r) + (cg - g) * (cg - g) + (cb - b) * (cb - b)
            if d < best.1 { best = (slot, d) }
        }
        return best.0
    }
}

extension NCUIApplication {
    /// Capture the current pane content as a parsed cell grid. Real-time
    /// visual ground truth — what the user would see if they attached to
    /// the tmux session.
    public func captureScreen() throws -> NCUIScreen.Grid {
        guard let driver = tmuxDriver else { throw NCUIError.notLaunched }
        let raw = try driver.capturePane(withEscapes: true)
        return NCUIScreen.parse(ansi: raw)
    }

    /// Capture the pane as a raw ANSI string (with SGR escapes). Use for
    /// snapshot files and human inspection.
    public func captureANSI() throws -> String {
        guard let driver = tmuxDriver else { throw NCUIError.notLaunched }
        return try driver.capturePane(withEscapes: true)
    }
}
