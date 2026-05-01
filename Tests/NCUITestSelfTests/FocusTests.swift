import Testing
import Foundation
import NCUITest
import NCUITestProtocol

@Suite("NCUITest setFocus", .serialized)
struct FocusTests {
    @Test("setFocus on a TextField succeeds and is reflected in the tree")
    func setFocusOnTextField() async throws {
        let app = NCUIApplication(label: "wd-focus-1", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // After Tab, focus moves to List. Verify by hint text.
        _ = try await app.sendRaw(.sendKey(.code(.tab, modifiers: [])))
        try await Task.sleep(nanoseconds: 100_000_000)
        let pressTab = app.staticTexts.matching(.label(contains: "(press Tab)")).firstMatch
        #expect(try await pressTab.waitForExistence(timeout: 1))

        // Now use setFocus to refocus the TextField — the hint should swap
        // back to "(focused)".
        let response = try await app.sendRaw(.setFocus(.query(NCUIQuerySpec(typeName: "TextField"))))
        if case .error(let msg) = response.result {
            Issue.record("setFocus returned error: \(msg)")
            app.terminate()
            return
        }
        let focusedHint = app.staticTexts.matching(.label(contains: "(focused)")).firstMatch
        #expect(try await focusedHint.waitForExistence(timeout: 2),
                "after setFocus(TextField), hint should swap back to '(focused)'")

        app.terminate()
    }

    @Test("setFocus on a non-focusable returns clear error")
    func setFocusUnfocusable() async throws {
        let app = NCUIApplication(label: "wd-focus-2", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }
        try await Task.sleep(nanoseconds: 200_000_000)

        // Targeting a Text view (not ProbeFocusable) should error.
        let response = try await app.sendRaw(.setFocus(.query(NCUIQuerySpec(typeName: "Text"))))
        if case .error(let msg) = response.result {
            #expect(msg.contains("not ProbeFocusable") || msg.contains("not implemented"))
        } else {
            Issue.record("expected error response, got \(response.result)")
        }

        app.terminate()
    }
}
