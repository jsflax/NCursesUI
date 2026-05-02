import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("NCUITest diagnostics + snapshots", .serialized)
struct DiagnosticsTests {
    @Test("waitForExistenceWithDiagnostics writes artifact bundle on timeout")
    func diagnosticsBundle() async throws {
        let app = NCUIApplication(label: "wd-diag-1", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let tempArtifacts = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ncuitest-artifacts-\(UUID().uuidString.prefix(8))")
        setenv("NCUITEST_ARTIFACTS_DIR", tempArtifacts, 1)
        defer {
            unsetenv("NCUITEST_ARTIFACTS_DIR")
            try? FileManager.default.removeItem(atPath: tempArtifacts)
        }

        let ghost = app.staticTexts.matching(.label(contains: "definitely never appears")).firstMatch
        do {
            _ = try await ghost.waitForExistence(timeout: 0.3, captureScope: "diag-test")
            Issue.record("expected timeout to throw")
        } catch let error as NCUIError {
            if case .waitTimeout(_, _, let dir) = error {
                #expect(dir != nil, "expected artifactsDir to be populated")
                if let dir {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: dir)
                    let names = Set(entries)
                    #expect(names.contains("\(app.label).json"), "expected JSON tree dump; got \(names)")
                    #expect(names.contains("\(app.label).ansi"), "expected ANSI capture; got \(names)")
                    #expect(names.contains("\(app.label).png"), "expected PNG screenshot; got \(names)")
                }
            } else {
                Issue.record("expected .waitTimeout, got \(error)")
            }
        }

        app.terminate()
    }

    @Test("snapshot record + diff cycle works")
    func snapshotRoundTrip() async throws {
        let app = NCUIApplication(label: "wd-snap-r", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let tempSnaps = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ncuitest-snaps-\(UUID().uuidString.prefix(8))")
        setenv("NCUITEST_SNAPSHOT_DIR", tempSnaps, 1)
        setenv("RECORD_SNAPSHOTS", "1", 1)
        defer {
            unsetenv("NCUITEST_SNAPSHOT_DIR")
            unsetenv("RECORD_SNAPSHOTS")
            try? FileManager.default.removeItem(atPath: tempSnaps)
        }

        // Record.
        try await app.assertSnapshot(named: "widgets_initial")
        let jsonPath = (tempSnaps as NSString).appendingPathComponent("widgets_initial.json")
        let ansiPath = (tempSnaps as NSString).appendingPathComponent("widgets_initial.ansi")
        #expect(FileManager.default.fileExists(atPath: jsonPath))
        #expect(FileManager.default.fileExists(atPath: ansiPath))

        // Diff (no recording mode now).
        unsetenv("RECORD_SNAPSHOTS")
        try await app.assertSnapshot(named: "widgets_initial")  // should pass — same state

        app.terminate()
    }
}
