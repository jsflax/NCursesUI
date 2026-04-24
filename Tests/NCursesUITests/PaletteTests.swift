import Testing
import Foundation
@testable import NCursesUI

@Suite("Palette")
struct PaletteTests {
    @Test("RGB parses lowercase + uppercase + with/without leading #")
    func rgbHex() {
        let a = Palette.RGB(hex: "#ff6a3c")
        #expect(a?.r == 0xff && a?.g == 0x6a && a?.b == 0x3c)
        let b = Palette.RGB(hex: "FF6A3C")
        #expect(b?.r == 0xff && b?.g == 0x6a && b?.b == 0x3c)
        #expect(Palette.RGB(hex: "#fff") == nil)
        #expect(Palette.RGB(hex: "not-a-hex") == nil)
    }

    @Test("nickIndex is deterministic and stable across palettes for the same nick")
    func nickIndexStable() {
        let nicks = ["alice", "bob", "carol", "mira", "devon", "claude"]
        for palette in Palette.all {
            for nick in nicks {
                let a = palette.nickIndex(for: nick)
                let b = palette.nickIndex(for: nick)
                #expect(a == b, "same nick should hash identically on repeat call")
            }
        }
        for nick in nicks {
            let idx = Palette.phosphor.nickIndex(for: nick)
            #expect(Palette.claude.nickIndex(for: nick) == idx,
                    "nick slot index should match across palettes — concrete color differs, slot doesn't")
        }
    }

    @Test("nickIndex stays in-range for arbitrary strings")
    func nickIndexRange() {
        for nick in ["", "a", "ABCDEFGHIJKLMNOP", "🐈", "Zëphyr-07"] {
            let i = Palette.phosphor.nickIndex(for: nick)
            #expect(i >= 0 && i < 8)
        }
    }

    @Test("All four palettes have the required semantic slots populated")
    func palettesComplete() {
        for p in Palette.all {
            #expect(p.nicks.count == 8)
            // Accent and dim should differ from fg so mentions/metadata read distinctly.
            #expect(p.accent != p.fg)
            #expect(p.dim != p.fg)
            #expect(p.reverseFg != p.reverseBg)
        }
    }

    @Test("byName falls back to phosphor for unknown names")
    func byNameFallback() {
        #expect(Palette.byName("phosphor").name == "phosphor")
        #expect(Palette.byName("claude").name == "claude")
        #expect(Palette.byName("does-not-exist").name == "phosphor")
    }
}
