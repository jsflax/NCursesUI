import Testing
import Foundation
@testable import NCUITest
import NCUITestProtocol

@Suite("NCUITest awaitPredicate", .serialized)
struct AwaitTests {
    @Test("awaitPredicate returns immediately when already satisfied")
    func awaitImmediate() async throws {
        let app = NCUIApplication(label: "wd-await-1", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let response = try await app.sendRaw(
            .awaitPredicate(NCUIQuerySpec(labelContains: "widgets demo"), timeoutMs: 1000)
        )
        guard case .nodes(let matches) = response.result else {
            Issue.record("expected nodes response, got \(response.result)")
            app.terminate()
            return
        }
        #expect(matches.count >= 1)

        app.terminate()
    }

    @Test("awaitPredicate resolves after a state-changing keystroke")
    func awaitAfterKey() async throws {
        let app = NCUIApplication(label: "wd-await-2", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        // Kick off the wait BEFORE sending the key; resolves on the post-key frame.
        async let waitTask: NCUIResponse = app.sendRaw(
            .awaitPredicate(NCUIQuerySpec(labelContains: "(press Tab)"), timeoutMs: 3000)
        )

        // Small gap so the await is registered before we tab.
        try await Task.sleep(nanoseconds: 50_000_000)
        _ = try await app.sendRaw(.sendKey(.code(.tab, modifiers: [])))

        let result = try await waitTask
        guard case .nodes(let matches) = result.result else {
            Issue.record("expected nodes response, got \(result.result)")
            app.terminate()
            return
        }
        #expect(matches.count >= 1, "Tab should produce '(press Tab)' hint within 3s")

        app.terminate()
    }

    @Test("awaitPredicate times out with a clear error when state never changes")
    func awaitTimeout() async throws {
        let app = NCUIApplication(label: "wd-await-3", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let response = try await app.sendRaw(
            .awaitPredicate(NCUIQuerySpec(labelContains: "this string does not exist anywhere"),
                            timeoutMs: 300)
        )
        if case .error(let msg) = response.result {
            #expect(msg.contains("timeout"))
        } else {
            Issue.record("expected timeout error, got \(response.result)")
        }

        app.terminate()
    }
}
