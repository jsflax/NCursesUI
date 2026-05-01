import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("NCUIElement / NCUIElementQuery API", .serialized)
struct ElementApiTests {
    @Test("staticTexts returns all Text nodes; firstMatch resolves")
    func staticTextsBasic() async throws {
        let app = NCUIApplication(label: "wd-elem-1", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let count = try await app.staticTexts.count
        #expect(count > 0)

        let title = app.staticTexts.matching(.label(contains: "widgets demo")).firstMatch
        #expect(try await title.exists)
        let label = try await title.label
        #expect(label?.contains("widgets demo") == true)

        app.terminate()
    }

    @Test("waitForExistence returns true when the predicate is already satisfied")
    func waitForExistenceImmediate() async throws {
        let app = NCUIApplication(label: "wd-elem-2", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let title = app.staticTexts.matching(.label(contains: "widgets demo")).firstMatch
        let found = try await title.waitForExistence(timeout: 1.0)
        #expect(found)

        app.terminate()
    }

    @Test("waitForExistence throws .waitTimeout for a never-satisfied predicate")
    func waitForExistenceTimeout() async throws {
        let app = NCUIApplication(label: "wd-elem-3", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let ghost = app.staticTexts.matching(.label(contains: "this never appears anywhere")).firstMatch
        do {
            _ = try await ghost.waitForExistence(timeout: 0.3)
            Issue.record("expected waitTimeout to throw")
        } catch let error as NCUIError {
            if case .waitTimeout(let spec, let t, _) = error {
                #expect(spec.contains("never appears"))
                #expect(t == 0.3)
            } else {
                Issue.record("expected .waitTimeout, got \(error)")
            }
        }

        app.terminate()
    }

    @Test("typeText delivers characters to the focused TextField")
    func typeTextLands() async throws {
        let app = NCUIApplication(label: "wd-elem-4", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // The TextField is focused by default; we don't have a stable .testID
        // on it yet, so we use the generic otherElements.firstMatch — typeText
        // falls through to the currently-focused widget regardless.
        try await app.otherElements.firstMatch.typeText("xy")
        try await Task.sleep(nanoseconds: 200_000_000)

        let typed = app.staticTexts.matching(.label(contains: "xy")).firstMatch
        #expect(try await typed.waitForExistence(timeout: 1.0))

        app.terminate()
    }
}
