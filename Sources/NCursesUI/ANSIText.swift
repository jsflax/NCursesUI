import Foundation

/// Linear SGR parser — converts a string with ANSI escape sequences
/// (`CSI Pn ; … m`) into a list of styled `Run`s. Internal because the
/// public surface is `Text(ansi:)`, mirroring the existing
/// `Text(markdown:)` initializer.
///
/// Scope (deliberate v1 minimum):
/// - Reset (`0`), bold (`1`), dim (`2`), italic (`3`), underline (`4`,
///   approximated via italic on terminals without `sitm`).
/// - Basic foreground (`30..37`) and bright foreground (`90..97`); the
///   bright variants collapse to `bold + basic` because the `Color`
///   enum doesn't distinguish bright vs. normal.
/// - 256-colour foreground (`38;5;<n>`) — quantised to the nearest
///   basic slot.
/// - Truecolour foreground (`38;2;<r>;<g>;<b>`) — same quantisation.
/// - Background colours (`40..47`, `100..107`, `48;…`) accepted
///   syntactically but ignored. Statusline-style use cases over-
///   whelmingly use foreground; cell backgrounds through the
///   compositor are their own project.
/// - Anything else (cursor moves, mode sets, OSC sequences) is dropped.
package enum ANSIText {

    /// Active SGR style at the parser cursor. Reset to `.init()` on `0`.
    private struct Sgr {
        var color: Color = .normal
        var bold: Bool = false
        var dim: Bool = false
        var italic: Bool = false

        /// Materialise as a public `Style`. Kept private so the parser
        /// internals stay confined to this file.
        var asStyle: Style {
            var s = Style(color: color, bold: bold, inverted: false)
            s.dim = dim
            s.italic = italic
            return s
        }
    }

    package static func parseRuns(_ s: String) -> [Text.Run] {
        guard !s.isEmpty else { return [Text.Run(content: "", style: Style())] }
        // Fast path: no escape character at all → emit a single
        // default-styled run, no parsing.
        if !s.contains("\u{1B}") {
            return [Text.Run(content: s, style: Style())]
        }

        var runs: [Text.Run] = []
        var sgr = Sgr()
        var pending = ""
        let chars = Array(s)
        var i = 0

        func flush() {
            guard !pending.isEmpty else { return }
            runs.append(Text.Run(content: pending, style: sgr.asStyle))
            pending.removeAll(keepingCapacity: true)
        }

        while i < chars.count {
            let c = chars[i]
            if c != "\u{1B}" {
                pending.append(c)
                i += 1
                continue
            }
            // Found ESC. We want `ESC [ … m` (CSI SGR). Anything else
            // (OSC, single-shift, malformed) we skip up to and including
            // the terminator so it doesn't litter the output.
            if i + 1 >= chars.count { break }
            if chars[i + 1] != "[" {
                // Non-CSI escape — skip ESC and the following byte. Any
                // multi-byte sequence beyond that just becomes literal
                // text, which is the safer failure mode.
                i += 2
                continue
            }
            // CSI starts. Walk forward to the final byte (in 0x40..0x7E).
            var j = i + 2
            while j < chars.count {
                let cc = chars[j]
                if let scalar = cc.unicodeScalars.first?.value,
                   (0x40...0x7E).contains(scalar) {
                    break
                }
                j += 1
            }
            guard j < chars.count else { i = chars.count; break }
            if chars[j] == "m" {
                // SGR — flush whatever text we'd accumulated under the
                // previous style, then update style from the params.
                flush()
                let paramStr = String(chars[(i + 2)..<j])
                applySgr(paramStr, to: &sgr)
            }
            // Unknown final byte ⇒ silently consumed (cursor moves,
            // mode sets, etc. don't translate to Text styling).
            i = j + 1
        }

        flush()
        return runs.isEmpty ? [Text.Run(content: "", style: Style())] : runs
    }

    private static func applySgr(_ params: String, to sgr: inout Sgr) {
        // Empty parameter list means "0" (full reset) per ECMA-48.
        let raw = params.isEmpty ? "0" : params
        let tokens = raw.split(separator: ";").map(String.init)
        var idx = 0
        while idx < tokens.count {
            let tok = tokens[idx]
            guard let n = Int(tok) else { idx += 1; continue }
            switch n {
            case 0:
                sgr = Sgr()
            case 1:
                sgr.bold = true
            case 2:
                sgr.dim = true
            case 3:
                sgr.italic = true
            case 4:
                // Underline — there's no direct underline modifier on
                // Text. `.italic()` falls back to underline on terminals
                // without `sitm`, which is a deliberate approximation:
                // we render underline correctly on those, italic on the
                // rest. Better than dropping it.
                sgr.italic = true
            case 22:
                sgr.bold = false; sgr.dim = false
            case 23, 24:
                sgr.italic = false
            case 30...37:
                sgr.color = ansi8ToColor(n - 30)
            case 39:
                sgr.color = .normal
            case 90...97:
                sgr.color = ansi8ToColor(n - 90)
                sgr.bold = true
            case 38:
                // Extended foreground: `38;5;<idx>` or `38;2;<r>;<g>;<b>`.
                // Quantise to one of the basic 8. Malformed params just
                // skip the mode token; remaining tokens fall through.
                guard idx + 1 < tokens.count, let mode = Int(tokens[idx + 1]) else {
                    idx += 1; break
                }
                if mode == 5, idx + 2 < tokens.count, let n256 = Int(tokens[idx + 2]) {
                    sgr.color = quantise256(n256)
                    idx += 2
                } else if mode == 2, idx + 4 < tokens.count,
                          let r = Int(tokens[idx + 2]),
                          let g = Int(tokens[idx + 3]),
                          let b = Int(tokens[idx + 4]) {
                    sgr.color = quantiseRGB(r: r, g: g, b: b)
                    idx += 4
                } else {
                    idx += 1
                }
            case 40...47, 49, 100...107:
                // Background slots — accepted, ignored. See scope above.
                break
            default:
                break
            }
            idx += 1
        }
    }

    /// Map ANSI fg index 0..7 to a `Color` slot. Black (0) renders as
    /// terminal default because rendering literal black on a dark
    /// terminal would be invisible.
    private static func ansi8ToColor(_ idx: Int) -> Color {
        switch idx {
        case 0: return .normal        // black → terminal default
        case 1: return .red
        case 2: return .green
        case 3: return .yellow
        case 4: return .blue
        case 5: return .magenta
        case 6: return .cyan
        case 7: return .white
        default: return .normal
        }
    }

    /// Best-effort xterm-256 → palette slot. 0..15 are standard ANSI;
    /// 16..231 form a 6×6×6 RGB cube; 232..255 are 24 grayscale steps
    /// mapped to `.dim` (darker) or `.white`.
    private static func quantise256(_ n: Int) -> Color {
        guard (0...255).contains(n) else { return .normal }
        if n < 16 {
            return ansi8ToColor(n & 0x07)
        }
        if n >= 232 {
            return n < 244 ? .dim : .white
        }
        let i = n - 16
        let r6 = (i / 36) % 6
        let g6 = (i / 6) % 6
        let b6 = i % 6
        // ramp[6] = 0, 95, 135, 175, 215, 255 (xterm convention)
        let ramp: [Int] = [0, 95, 135, 175, 215, 255]
        return quantiseRGB(r: ramp[r6], g: ramp[g6], b: ramp[b6])
    }

    /// Truecolour → nearest basic slot. Quantisation is intentionally
    /// crude — the goal is "recognisably represents the user's colour",
    /// not perceptual accuracy.
    private static func quantiseRGB(r: Int, g: Int, b: Int) -> Color {
        let r = max(0, min(255, r))
        let g = max(0, min(255, g))
        let b = max(0, min(255, b))
        // Very-dark total → dim grey (#404040 looks indistinguishable
        // from black in most palettes; rendering as .dim is closer).
        if r + g + b < 80 { return .dim }
        let candidates: [(name: Color, r: Int, g: Int, b: Int)] = [
            (.red,     220,  20,  20),
            (.green,    20, 200,  20),
            (.yellow,  220, 200,  20),
            (.blue,     20,  60, 220),
            (.magenta, 200,  60, 200),
            (.cyan,     20, 200, 200),
            (.white,   240, 240, 240),
        ]
        var best = candidates[0]
        var bestDist = Int.max
        for c in candidates {
            let dr = c.r - r, dg = c.g - g, db = c.b - b
            let d = dr * dr + dg * dg + db * db
            if d < bestDist { bestDist = d; best = c }
        }
        return best.name
    }
}

extension Text {
    /// Initialize a `Text` from a string with ANSI SGR escape sequences.
    /// Mirrors `Text(markdown:)` — wraps the SGR parser so callers don't
    /// touch the parser API directly.
    ///
    /// Useful for rendering output from external commands that emit
    /// `\033[…m` colouring (statusline scripts, `git diff`, etc.).
    /// See `ANSIText` for scope and quantisation details.
    public init(ansi text: String) {
        self.init(runs: ANSIText.parseRuns(text))
    }
}
