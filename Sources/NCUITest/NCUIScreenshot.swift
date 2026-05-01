import Foundation
import NCUITestProtocol
#if os(macOS)
import AppKit
import CoreGraphics
import CoreText
#endif

public struct ScreenshotFont: Sendable {
    public let name: String
    public let size: CGFloat

    public init(name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public static let `default` = ScreenshotFont(name: "Menlo", size: 14)
}

public struct ScreenshotOptions: Sendable {
    public let font: ScreenshotFont
    public let backgroundColor: (UInt8, UInt8, UInt8)

    public init(font: ScreenshotFont = .default, backgroundColor: (UInt8, UInt8, UInt8) = (16, 16, 16)) {
        self.font = font
        self.backgroundColor = backgroundColor
    }

    public static let `default` = ScreenshotOptions()
}

extension NCUIApplication {
    /// Render the current pane to a PNG. Artifact-only — never an assertion
    /// target. Use to attach a "what did the UI look like at failure"
    /// screenshot to test artifacts.
    public func screenshot(options: ScreenshotOptions = .default) async throws -> Data {
        #if os(macOS)
        let grid = try captureScreen()
        return try NCUIScreenshotRenderer.render(grid: grid, options: options)
        #else
        throw NCUIError.unsupportedOnPlatform("PNG screenshots require macOS (CoreText/AppKit)")
        #endif
    }

    /// Convenience: render and write to disk.
    public func saveScreenshot(to path: String, options: ScreenshotOptions = .default) async throws {
        let data = try await screenshot(options: options)
        try data.write(to: URL(fileURLWithPath: path))
    }
}

#if os(macOS)
enum NCUIScreenshotRenderer {
    static func render(grid: NCUIScreen.Grid, options: ScreenshotOptions) throws -> Data {
        let font = NSFont(name: options.font.name, size: options.font.size)
            ?? NSFont.userFixedPitchFont(ofSize: options.font.size)
            ?? NSFont.systemFont(ofSize: options.font.size)

        // Cell metrics: use a representative monospace glyph width.
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let probeChar = NSAttributedString(string: "M", attributes: attrs)
        let charSize = probeChar.size()
        let cellWidth = ceil(charSize.width)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        let pixelWidth = max(1, Int(cellWidth) * grid.cols)
        let pixelHeight = max(1, Int(lineHeight) * grid.rows)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else {
            throw NCUIError.ioError("could not allocate bitmap rep")
        }

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NCUIError.ioError("could not create graphics context")
        }
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = saved }

        let cgContext = context.cgContext

        // Background fill.
        let (br, bg, bb) = options.backgroundColor
        cgContext.setFillColor(red: CGFloat(br) / 255, green: CGFloat(bg) / 255, blue: CGFloat(bb) / 255, alpha: 1)
        cgContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Cells.
        for (rowIdx, row) in grid.cells.enumerated() {
            for (colIdx, cell) in row.enumerated() {
                draw(
                    cell: cell,
                    row: rowIdx,
                    col: colIdx,
                    cellWidth: cellWidth,
                    lineHeight: lineHeight,
                    totalRows: grid.rows,
                    font: font,
                    in: cgContext
                )
            }
        }

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NCUIError.ioError("PNG encoding failed")
        }
        return data
    }

    private static func draw(
        cell: NCUIScreen.ParsedCell,
        row: Int,
        col: Int,
        cellWidth: CGFloat,
        lineHeight: CGFloat,
        totalRows: Int,
        font: NSFont,
        in cgContext: CGContext
    ) {
        let charString = String(cell.character)
        let (fgR, fgG, fgB) = rgbFor(slot: cell.attrs.fg)

        var attrs: [NSAttributedString.Key: Any] = [
            .font: cell.attrs.bold
                ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                : font
        ]
        // Foreground color (or background swap if inverted).
        var (textR, textG, textB) = (fgR, fgG, fgB)
        if cell.attrs.dim {
            textR /= 2; textG /= 2; textB /= 2
        }
        attrs[.foregroundColor] = NSColor(
            red: CGFloat(textR) / 255,
            green: CGFloat(textG) / 255,
            blue: CGFloat(textB) / 255,
            alpha: 1
        )
        if cell.attrs.italic {
            attrs[.obliqueness] = 0.18
        }

        // CG origin is bottom-left, so rows count from bottom up.
        let y = CGFloat(totalRows - row - 1) * lineHeight
        let x = CGFloat(col) * cellWidth
        let rect = CGRect(x: x, y: y, width: cellWidth, height: lineHeight)

        if cell.attrs.inverted {
            // Filled background block in fg color, then draw glyph in bg color.
            cgContext.setFillColor(red: CGFloat(fgR) / 255, green: CGFloat(fgG) / 255, blue: CGFloat(fgB) / 255, alpha: 1)
            cgContext.fill(rect)
            attrs[.foregroundColor] = NSColor.black
        }

        let drawn = NSAttributedString(string: charString, attributes: attrs)
        drawn.draw(at: CGPoint(x: x, y: y))
    }

    private static func rgbFor(slot: NCUIColorSlot) -> (Int, Int, Int) {
        switch slot {
        case .normal: return (220, 220, 220)
        case .dim: return (120, 120, 120)
        case .selected: return (255, 255, 255)
        case .red: return (220, 60, 60)
        case .green: return (80, 220, 80)
        case .yellow: return (220, 200, 60)
        case .blue: return (80, 100, 220)
        case .magenta: return (220, 80, 220)
        case .cyan: return (80, 220, 220)
        case .white: return (240, 240, 240)
        case .purple: return (135, 95, 255)
        case .gold: return (255, 215, 0)
        case .teal: return (0, 175, 175)
        }
    }
}
#endif
