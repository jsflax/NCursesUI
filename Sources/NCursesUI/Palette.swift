import Cncurses
import Foundation

// MARK: - Palette
//
// Semantic theme slots. Views don't pick concrete `Color` enum cases; they
// pull slots off the active `Palette` so the whole UI flips when the user
// switches theme. Ported from the JSX design bundle's PALETTES dict.
//
// Pair allocation: palette pairs live in [32..79] to avoid the legacy
// [1..9] range used by `Color` enum callers (Engram etc.). A fresh
// `activate()` call re-registers pairs — idempotent if the palette
// doesn't change.

public struct Palette: Sendable, Hashable {
    public struct RGB: Sendable, Hashable {
        public let r: UInt8
        public let g: UInt8
        public let b: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
        public init?(hex: String) {
            var s = hex
            if s.hasPrefix("#") { s.removeFirst() }
            guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
            self.r = UInt8((v >> 16) & 0xff)
            self.g = UInt8((v >> 8) & 0xff)
            self.b = UInt8(v & 0xff)
        }
        /// ncurses init_color expects 0..1000 scale.
        var ncursesScaled: (r: Int32, g: Int32, b: Int32) {
            (Int32(Int(r) * 1000 / 255),
             Int32(Int(g) * 1000 / 255),
             Int32(Int(b) * 1000 / 255))
        }
    }

    public let name: String
    public let bg: RGB
    public let panel: RGB
    public let fg: RGB
    public let dim: RGB
    public let mute: RGB
    public let accent: RGB
    public let accent2: RGB
    public let danger: RGB
    public let ok: RGB
    public let hl: RGB
    public let reverseFg: RGB
    public let reverseBg: RGB
    public let nicks: [RGB] // exactly 8
    public let codeKw: RGB
    public let codeStr: RGB
    public let codeCom: RGB
    public let codeNum: RGB
    public let codeIdent: RGB
    public let codePunct: RGB

    // MARK: - Role addressing

    public enum Role: Sendable, Hashable {
        case fg, dim, mute, accent, accent2, danger, ok, panel
        case hl                 // background fill for selected row; uses hl-bg
        case reverseBar         // top/status bars (bg color on fg color)
        case codeKw, codeStr, codeCom, codeNum, codeIdent, codePunct
        case nick(Int)          // 0..7
    }

    public func rgb(for role: Role) -> RGB {
        switch role {
        case .fg: return fg
        case .dim: return dim
        case .mute: return mute
        case .accent: return accent
        case .accent2: return accent2
        case .danger: return danger
        case .ok: return ok
        case .panel: return panel
        case .hl: return fg
        case .reverseBar: return reverseFg
        case .codeKw: return codeKw
        case .codeStr: return codeStr
        case .codeCom: return codeCom
        case .codeNum: return codeNum
        case .codeIdent: return codeIdent
        case .codePunct: return codePunct
        case .nick(let i): return nicks[((i % nicks.count) + nicks.count) % nicks.count]
        }
    }

    /// Stable hash into `nicks[0..7]` — port of `nickColorIndex` from tui-core.jsx.
    public func nickIndex(for nick: String) -> Int {
        var h: Int32 = 0
        for scalar in nick.unicodeScalars {
            h = (h &* 31) &+ Int32(scalar.value & 0xffff)
        }
        let n = nicks.count
        return Int((h.magnitude) % UInt32(n))
    }

    public func nickRGB(for nick: String) -> RGB { nicks[nickIndex(for: nick)] }
}

// MARK: - Built-in palettes
//
// RGB hex values lifted verbatim from tui-core.jsx PALETTES.

public extension Palette {
    static let phosphor = Palette(
        name: "phosphor",
        bg: RGB(hex: "#070a06")!,
        panel: RGB(hex: "#0b100a")!,
        fg: RGB(hex: "#b7e39a")!,
        dim: RGB(hex: "#4a7238")!,
        mute: RGB(hex: "#2c4420")!,
        accent: RGB(hex: "#ffcc5c")!,
        accent2: RGB(hex: "#6fd3ff")!,
        danger: RGB(hex: "#ff6b5a")!,
        ok: RGB(hex: "#8fe36a")!,
        hl: RGB(hex: "#20361a")!,
        reverseFg: RGB(hex: "#070a06")!,
        reverseBg: RGB(hex: "#b7e39a")!,
        nicks: [
            RGB(hex: "#8fe36a")!, RGB(hex: "#ffcc5c")!, RGB(hex: "#6fd3ff")!, RGB(hex: "#e68cff")!,
            RGB(hex: "#ff9b6a")!, RGB(hex: "#b7e39a")!, RGB(hex: "#d9f0b8")!, RGB(hex: "#ffd98a")!,
        ],
        codeKw: RGB(hex: "#ffcc5c")!,
        codeStr: RGB(hex: "#8fe36a")!,
        codeCom: RGB(hex: "#4a7238")!,
        codeNum: RGB(hex: "#6fd3ff")!,
        codeIdent: RGB(hex: "#d9f0b8")!,
        codePunct: RGB(hex: "#7a9a5a")!
    )

    static let amber = Palette(
        name: "amber",
        bg: RGB(hex: "#150b02")!,
        panel: RGB(hex: "#1c0f04")!,
        fg: RGB(hex: "#ffb454")!,
        dim: RGB(hex: "#8a5a1e")!,
        mute: RGB(hex: "#4a300f")!,
        accent: RGB(hex: "#ffd98a")!,
        accent2: RGB(hex: "#ff8a3c")!,
        danger: RGB(hex: "#ff5b3a")!,
        ok: RGB(hex: "#ffd98a")!,
        hl: RGB(hex: "#3a220a")!,
        reverseFg: RGB(hex: "#150b02")!,
        reverseBg: RGB(hex: "#ffb454")!,
        nicks: [
            RGB(hex: "#ffb454")!, RGB(hex: "#ffd98a")!, RGB(hex: "#ff8a3c")!, RGB(hex: "#ff6b3a")!,
            RGB(hex: "#e89a50")!, RGB(hex: "#ffcf7a")!, RGB(hex: "#c8802e")!, RGB(hex: "#ffb889")!,
        ],
        codeKw: RGB(hex: "#ffd98a")!,
        codeStr: RGB(hex: "#ffb454")!,
        codeCom: RGB(hex: "#8a5a1e")!,
        codeNum: RGB(hex: "#ff8a3c")!,
        codeIdent: RGB(hex: "#ffcf7a")!,
        codePunct: RGB(hex: "#a0662a")!
    )

    static let modern = Palette(
        name: "modern",
        bg: RGB(hex: "#0e1116")!,
        panel: RGB(hex: "#141820")!,
        fg: RGB(hex: "#d7dbe0")!,
        dim: RGB(hex: "#6a7280")!,
        mute: RGB(hex: "#2a3240")!,
        accent: RGB(hex: "#e6c384")!,
        accent2: RGB(hex: "#7fd4ff")!,
        danger: RGB(hex: "#ff7a7a")!,
        ok: RGB(hex: "#9cde8b")!,
        hl: RGB(hex: "#1f2733")!,
        reverseFg: RGB(hex: "#0e1116")!,
        reverseBg: RGB(hex: "#d7dbe0")!,
        nicks: [
            RGB(hex: "#7fd4ff")!, RGB(hex: "#e6c384")!, RGB(hex: "#ff9fbe")!, RGB(hex: "#9cde8b")!,
            RGB(hex: "#c8a8ff")!, RGB(hex: "#ffb27f")!, RGB(hex: "#9edcd0")!, RGB(hex: "#f3d06f")!,
        ],
        codeKw: RGB(hex: "#c8a8ff")!,
        codeStr: RGB(hex: "#9cde8b")!,
        codeCom: RGB(hex: "#6a7280")!,
        codeNum: RGB(hex: "#7fd4ff")!,
        codeIdent: RGB(hex: "#d7dbe0")!,
        codePunct: RGB(hex: "#8a93a3")!
    )

    static let claude = Palette(
        name: "claude",
        bg: RGB(hex: "#1a1512")!,
        panel: RGB(hex: "#221b16")!,
        fg: RGB(hex: "#ede4d3")!,
        dim: RGB(hex: "#8a7a68")!,
        mute: RGB(hex: "#3e342b")!,
        accent: RGB(hex: "#d97757")!,
        accent2: RGB(hex: "#c9a46a")!,
        danger: RGB(hex: "#e06a5a")!,
        ok: RGB(hex: "#a8c48a")!,
        hl: RGB(hex: "#2d241d")!,
        reverseFg: RGB(hex: "#1a1512")!,
        reverseBg: RGB(hex: "#ede4d3")!,
        nicks: [
            RGB(hex: "#d97757")!, RGB(hex: "#c9a46a")!, RGB(hex: "#a8c48a")!, RGB(hex: "#e8b9a0")!,
            RGB(hex: "#b8a58b")!, RGB(hex: "#e0c39a")!, RGB(hex: "#d48e6b")!, RGB(hex: "#c4b08c")!,
        ],
        codeKw: RGB(hex: "#d97757")!,
        codeStr: RGB(hex: "#a8c48a")!,
        codeCom: RGB(hex: "#8a7a68")!,
        codeNum: RGB(hex: "#c9a46a")!,
        codeIdent: RGB(hex: "#ede4d3")!,
        codePunct: RGB(hex: "#9d8a74")!
    )

    static let all: [Palette] = [.phosphor, .amber, .modern, .claude]

    static func byName(_ name: String) -> Palette {
        all.first(where: { $0.name == name }) ?? .phosphor
    }
}

// MARK: - ncurses activation
//
// When a palette is activated we register:
//   - 16 custom color indices in ncurses slots 32..47 (if can_change_color)
//   - 24 color pairs in slots 32..55:
//       32 fg           on bg
//       33 dim          on bg
//       34 mute         on bg
//       35 accent       on bg
//       36 accent2      on bg
//       37 danger       on bg
//       38 ok           on bg
//       39 panel        on bg          (dim edges of code blocks, etc.)
//       40 hl           on bg          (hl treated as a highlight fill — fg on hl)
//       41 reverse-bar  reverseFg on reverseBg
//       42..49 nicks[0..7] on bg
//       50 codeKw, 51 codeStr, 52 codeCom, 53 codeNum, 54 codeIdent, 55 codePunct
//
// On legacy terminals without can_change_color we fall back to the 16-color
// ANSI approximation — same pair IDs, concrete colors nearest-matched.

public struct PaletteRegistrar {
    public static let basePair: Int32 = 32
    public static let baseColor: Int32 = 32

    /// Pair ID for a given semantic role. Useful when a draw path needs the
    /// raw attr bits (e.g. StyledText runs compiled ahead of time).
    public static func pairId(for role: Palette.Role) -> Int32 {
        switch role {
        case .fg: return 32
        case .dim: return 33
        case .mute: return 34
        case .accent: return 35
        case .accent2: return 36
        case .danger: return 37
        case .ok: return 38
        case .panel: return 39
        case .hl: return 40
        case .reverseBar: return 41
        case .nick(let i): return 42 + Int32(((i % 8) + 8) % 8)
        case .codeKw: return 50
        case .codeStr: return 51
        case .codeCom: return 52
        case .codeNum: return 53
        case .codeIdent: return 54
        case .codePunct: return 55
        }
    }

    /// Register ncurses colors + pairs for `palette`. Safe to call multiple
    /// times — a re-registration just overwrites the same slots.
    public static func activate(_ palette: Palette) {
        guard has_colors() else { return }

        let canChange = tui_can_change_color() != 0 && tui_colors() >= 48

        // Assign color indices. Layout:
        //   32 bg
        //   33 fg
        //   34 dim
        //   35 mute
        //   36 accent
        //   37 accent2
        //   38 danger
        //   39 ok
        //   40 panel
        //   41 hl
        //   42 reverseFg (== bg for top bar inversion)
        //   43 reverseBg (== fg for top bar inversion)
        //   44..51 nicks[0..7]
        //   52 codeKw, 53 codeStr, 54 codeCom, 55 codeNum, 56 codeIdent, 57 codePunct
        let bg       = colorIndex(palette.bg,       at: 32, canChange: canChange, fallback: COLOR_BLACK)
        let fg       = colorIndex(palette.fg,       at: 33, canChange: canChange, fallback: COLOR_WHITE)
        let dim      = colorIndex(palette.dim,      at: 34, canChange: canChange, fallback: COLOR_WHITE)
        let mute     = colorIndex(palette.mute,     at: 35, canChange: canChange, fallback: COLOR_BLACK)
        let accent   = colorIndex(palette.accent,   at: 36, canChange: canChange, fallback: COLOR_YELLOW)
        let accent2  = colorIndex(palette.accent2,  at: 37, canChange: canChange, fallback: COLOR_CYAN)
        let danger   = colorIndex(palette.danger,   at: 38, canChange: canChange, fallback: COLOR_RED)
        let ok       = colorIndex(palette.ok,       at: 39, canChange: canChange, fallback: COLOR_GREEN)
        let panelCol = colorIndex(palette.panel,    at: 40, canChange: canChange, fallback: COLOR_BLACK)
        let hl       = colorIndex(palette.hl,       at: 41, canChange: canChange, fallback: COLOR_BLUE)
        let revFg    = colorIndex(palette.reverseFg, at: 42, canChange: canChange, fallback: COLOR_BLACK)
        let revBg    = colorIndex(palette.reverseBg, at: 43, canChange: canChange, fallback: COLOR_WHITE)
        var nickCols: [Int32] = []
        for i in 0..<8 {
            nickCols.append(colorIndex(palette.nicks[i], at: 44 + Int32(i),
                                       canChange: canChange,
                                       fallback: fallbackNick(i)))
        }
        let kw    = colorIndex(palette.codeKw,    at: 52, canChange: canChange, fallback: COLOR_YELLOW)
        let str   = colorIndex(palette.codeStr,   at: 53, canChange: canChange, fallback: COLOR_GREEN)
        let com   = colorIndex(palette.codeCom,   at: 54, canChange: canChange, fallback: COLOR_BLUE)
        let num   = colorIndex(palette.codeNum,   at: 55, canChange: canChange, fallback: COLOR_CYAN)
        let ident = colorIndex(palette.codeIdent, at: 56, canChange: canChange, fallback: COLOR_WHITE)
        let punct = colorIndex(palette.codePunct, at: 57, canChange: canChange, fallback: COLOR_WHITE)

        // Register pairs. Use -1 for "default terminal bg" if we're on a
        // legacy 16-color terminal (so the user's real terminal background
        // shows through); truecolor-capable terminals get our palette bg.
        let actualBg: Int32 = canChange ? bg : -1
        _ = tui_init_pair(pairId(for: .fg),      fg,       actualBg)
        _ = tui_init_pair(pairId(for: .dim),     dim,      actualBg)
        _ = tui_init_pair(pairId(for: .mute),    mute,     actualBg)
        _ = tui_init_pair(pairId(for: .accent),  accent,   actualBg)
        _ = tui_init_pair(pairId(for: .accent2), accent2,  actualBg)
        _ = tui_init_pair(pairId(for: .danger),  danger,   actualBg)
        _ = tui_init_pair(pairId(for: .ok),      ok,       actualBg)
        _ = tui_init_pair(pairId(for: .panel),   panelCol, actualBg)
        // .hl pair paints fg-on-hl (the hl value is a background fill color).
        _ = tui_init_pair(pairId(for: .hl),      fg,       hl)
        // .reverseBar pair paints reverseFg-on-reverseBg (inverted bar look).
        _ = tui_init_pair(pairId(for: .reverseBar), revFg, revBg)
        for i in 0..<8 {
            _ = tui_init_pair(pairId(for: .nick(i)), nickCols[i], actualBg)
        }
        _ = tui_init_pair(pairId(for: .codeKw),    kw,    actualBg)
        _ = tui_init_pair(pairId(for: .codeStr),   str,   actualBg)
        _ = tui_init_pair(pairId(for: .codeCom),   com,   actualBg)
        _ = tui_init_pair(pairId(for: .codeNum),   num,   actualBg)
        _ = tui_init_pair(pairId(for: .codeIdent), ident, actualBg)
        _ = tui_init_pair(pairId(for: .codePunct), punct, actualBg)
    }

    /// Either define a custom ncurses color at `slot` (truecolor path) or
    /// return the nearest ANSI-16 code (legacy path).
    private static func colorIndex(_ rgb: Palette.RGB, at slot: Int32,
                                    canChange: Bool, fallback: Int32) -> Int32 {
        if canChange {
            let s = rgb.ncursesScaled
            _ = tui_init_color(slot, s.r, s.g, s.b)
            return slot
        }
        return nearestAnsi(rgb) ?? fallback
    }

    /// 8-slot nearest-color fallback for nicks on legacy terminals — alternate
    /// across a wide hue spread so distinct nicks still render differently.
    private static func fallbackNick(_ i: Int) -> Int32 {
        let wheel: [Int32] = [
            COLOR_GREEN, COLOR_YELLOW, COLOR_CYAN, COLOR_MAGENTA,
            COLOR_RED, COLOR_WHITE, COLOR_GREEN, COLOR_YELLOW,
        ]
        return wheel[i % wheel.count]
    }

    /// Quick L² match against the ANSI-16 primary slots. Good enough for a
    /// legacy-terminal experience — the palette's character still reads.
    private static func nearestAnsi(_ rgb: Palette.RGB) -> Int32? {
        // Rough ANSI-16 RGB anchors.
        let anchors: [(c: Int32, r: Int, g: Int, b: Int)] = [
            (COLOR_BLACK,   0,   0,   0),
            (COLOR_RED,   187,   0,   0),
            (COLOR_GREEN,   0, 187,   0),
            (COLOR_YELLOW,187, 187,   0),
            (COLOR_BLUE,    0,   0, 187),
            (COLOR_MAGENTA,187,  0, 187),
            (COLOR_CYAN,    0, 187, 187),
            (COLOR_WHITE, 187, 187, 187),
        ]
        let r = Int(rgb.r), g = Int(rgb.g), b = Int(rgb.b)
        var best: (Int32, Int)? = nil
        for a in anchors {
            let dr = r - a.r, dg = g - a.g, db = b - a.b
            let d = dr * dr + dg * dg + db * db
            if best == nil || d < best!.1 { best = (a.c, d) }
        }
        return best?.0
    }
}

// MARK: - Environment key

private struct PaletteKey: EnvironmentKey {
    public static var defaultValue: Palette { .phosphor }
}

public extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
