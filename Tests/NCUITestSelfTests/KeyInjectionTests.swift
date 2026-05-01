import Testing
import Foundation
@testable import NCUITest
import NCUITestProtocol

@Suite("NCUITest key injection", .serialized)
struct KeyInjectionTests {
    @Test("Tab key toggles focus state visible in tree")
    func tabTogglesFocus() async throws {
        let app = NCUIApplication(label: "wd-key", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        // Initial state: input is focused, hint reads "(focused)".
        let before = try await app.sendRaw(.query(NCUIQuerySpec(labelContains: "(focused)")))
        guard case .nodes(let beforeMatches) = before.result else {
            Issue.record("expected nodes response")
            app.terminate()
            return
        }
        #expect(beforeMatches.count >= 1, "initial frame should have '(focused)' hint visible")

        // Send Tab → focus flips to list.
        let _ = try await app.sendRaw(.sendKey(.code(.tab, modifiers: [])))
        try await Task.sleep(nanoseconds: 100_000_000)

        let after = try await app.sendRaw(.query(NCUIQuerySpec(labelContains: "(press Tab)")))
        guard case .nodes(let afterMatches) = after.result else {
            Issue.record("expected nodes response")
            app.terminate()
            return
        }
        #expect(afterMatches.count >= 1, "after Tab, expected '(press Tab)' hint to appear; tree didn't reflect focus flip")

        app.terminate()
    }

    @Test("sendKeys types characters into the focused TextField")
    func typeIntoTextField() async throws {
        let app = NCUIApplication(label: "wd-type", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        // TextField is focused by default. Send "hi" and observe.
        _ = try await app.sendRaw(.sendKeys("hi"))
        try await Task.sleep(nanoseconds: 200_000_000)

        let response = try await app.sendRaw(.query(NCUIQuerySpec(labelContains: "hi")))
        guard case .nodes(let matches) = response.result else {
            Issue.record("expected nodes response")
            app.terminate()
            return
        }
        // The TextField's rendered Text should now contain "hi" somewhere.
        let texts = matches.compactMap { $0.content }
        #expect(texts.contains(where: { $0.contains("hi") }), "typed 'hi' but no Text content reflected it; got: \(texts)")

        app.terminate()
    }
}
