import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("NCUITest screenshots", .serialized)
struct ScreenshotTests {
    @Test("captureANSI returns non-empty pane content")
    func captureANSIShape() async throws {
        let app = NCUIApplication(label: "wd-snap-1", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let raw = try app.captureANSI()
        #expect(raw.contains("widgets demo"), "expected pane content to contain 'widgets demo'; got \(raw.prefix(200))")
        // Should have ANSI escapes since we capture with -e.
        #expect(raw.contains("\u{1B}["))

        app.terminate()
    }

    @Test("captureScreen parses into a non-trivial cell grid")
    func captureScreenGrid() async throws {
        let app = NCUIApplication(label: "wd-snap-2", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let grid = try app.captureScreen()
        #expect(grid.rows > 0)
        #expect(grid.cols > 0)

        // Find a cell containing 'd' (from "widgets demo") to confirm parsing.
        var foundD = false
        for row in grid.cells {
            for cell in row where cell.character == "d" {
                foundD = true
                break
            }
            if foundD { break }
        }
        #expect(foundD)

        app.terminate()
    }

    @Test("saveScreenshot writes a non-empty PNG")
    func savePNG() async throws {
        let app = NCUIApplication(label: "wd-snap-3", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // Stash one PNG at a stable location for human inspection (developer
        // debugging only; not asserted against). Will be overwritten each run.
        let inspectPath = "/tmp/ncuitest-self-test-snap.png"

        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ncuitest-snap-\(UUID().uuidString.prefix(8)).png")
        try await app.saveScreenshot(to: path)
        try? FileManager.default.removeItem(atPath: inspectPath)
        try? FileManager.default.copyItem(atPath: path, toPath: inspectPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 1024, "PNG should be at least 1KB; got \(size) bytes")

        // Verify PNG magic bytes.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 8)
        let magic = Array(data.prefix(8))
        #expect(magic == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        try? FileManager.default.removeItem(atPath: path)
        app.terminate()
    }
}
