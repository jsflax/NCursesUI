import Testing
import Foundation
@testable import NCUITest
import NCUITestProtocol

@Suite("NCUITest tree walker", .serialized)
struct TreeWalkerTests {
    @Test("tree request returns a non-empty hierarchy with expected types")
    func treeRequestRoundTrip() async throws {
        let app = NCUIApplication(label: "wd-tree", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        // Wait one frame to ensure the initial draw has finished and
        // the probe's frame counter is past zero.
        try await Task.sleep(nanoseconds: 200_000_000)

        let response = try await app.sendRaw(.tree)
        guard case .tree(let root) = response.result else {
            Issue.record("expected tree response, got \(response.result)")
            app.terminate()
            return
        }

        #expect(root.children.count > 0, "root should have children after first draw")

        let typeNames = collectTypeNames(root)
        // WidgetsDemo's root is DemoRoot; somewhere below it should be Text views.
        #expect(typeNames.contains("Text"), "expected at least one Text view; got \(typeNames.sorted())")

        app.terminate()
    }

    @Test("query by content substring finds matching Text")
    func queryByContent() async throws {
        let app = NCUIApplication(label: "wd-query", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let spec = NCUIQuerySpec(labelContains: "widgets demo")
        let response = try await app.sendRaw(.query(spec))
        guard case .nodes(let matches) = response.result else {
            Issue.record("expected nodes response, got \(response.result)")
            app.terminate()
            return
        }

        #expect(matches.count >= 1, "expected at least one match for 'widgets demo'")
        if let first = matches.first {
            #expect(first.typeName == "Text")
            #expect(first.content?.contains("widgets demo") == true)
        }

        app.terminate()
    }

    @Test("query by type name returns only matching nodes")
    func queryByTypeName() async throws {
        let app = NCUIApplication(label: "wd-type", productName: "WidgetsDemo")
        try await app.launch()
        defer { app.terminate() }

        try await Task.sleep(nanoseconds: 200_000_000)

        let response = try await app.sendRaw(.query(NCUIQuerySpec(typeName: "Text")))
        guard case .nodes(let matches) = response.result else {
            Issue.record("expected nodes response")
            app.terminate()
            return
        }
        #expect(matches.count > 0)
        #expect(matches.allSatisfy { $0.typeName == "Text" })

        app.terminate()
    }

    private func collectTypeNames(_ node: NCUINodeSnapshot) -> Set<String> {
        var names: Set<String> = [node.typeName]
        for c in node.children {
            names.formUnion(collectTypeNames(c))
        }
        return names
    }
}
