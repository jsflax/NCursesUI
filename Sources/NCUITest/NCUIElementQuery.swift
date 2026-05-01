import Foundation
import NCUITestProtocol

/// Lazy query that filters elements by type/predicate. Mirrors XCUIElementQuery.
public struct NCUIElementQuery: Sendable {
    let app: NCUIApplication
    let baseSpec: NCUIQuerySpec

    init(app: NCUIApplication, spec: NCUIQuerySpec) {
        self.app = app
        self.baseSpec = spec
    }

    /// Resolve all matching nodes via a fresh probe round-trip.
    public func allElements() async throws -> [NCUINodeSnapshot] {
        let response = try await app.sendRaw(.query(baseSpec))
        if case .nodes(let matches) = response.result {
            return matches
        }
        return []
    }

    public var count: Int {
        get async throws {
            try await allElements().count
        }
    }

    public var firstMatch: NCUIElement {
        NCUIElement(app: app, spec: baseSpec, firstMatch: true)
    }

    /// Look up by testID first, falling back to label-equals match. Mirrors
    /// XCUIElementQuery's `subscript("identifier")` semantics.
    public subscript(_ identifier: String) -> NCUIElement {
        var spec = baseSpec
        spec.testID = identifier
        return NCUIElement(app: app, spec: spec, firstMatch: true)
    }

    /// Refine by predicate. Returns a query whose results are the AND of the
    /// base spec and the new predicate.
    public func matching(_ predicate: NCUIPredicate) -> NCUIElementQuery {
        var merged = baseSpec
        if let v = predicate.spec.typeName { merged.typeName = v }
        if let v = predicate.spec.testID { merged.testID = v }
        if let v = predicate.spec.labelEquals { merged.labelEquals = v }
        if let v = predicate.spec.labelContains { merged.labelContains = v }
        if let v = predicate.spec.labelMatches { merged.labelMatches = v }
        return NCUIElementQuery(app: app, spec: merged)
    }
}

extension NCUIApplication {
    /// All Text views in the tree (or scoped by additional `matching` calls).
    public var staticTexts: NCUIElementQuery {
        NCUIElementQuery(app: self, spec: NCUIQuerySpec(typeName: "Text"))
    }

    /// All TextField views.
    public var textFields: NCUIElementQuery {
        NCUIElementQuery(app: self, spec: NCUIQuerySpec(typeName: "TextField"))
    }

    /// Any view, used as a catch-all root for further refinement.
    public var otherElements: NCUIElementQuery {
        NCUIElementQuery(app: self, spec: NCUIQuerySpec())
    }

    /// XCUITest-style subscript by `.testID`. Resolves to the first match.
    public subscript(_ testID: String) -> NCUIElement {
        NCUIElement(
            app: self,
            spec: NCUIQuerySpec(testID: testID),
            firstMatch: true
        )
    }

    /// Resize the tmux pane the app runs in. For layout regression tests.
    public func resize(cols: Int, rows: Int) throws {
        guard let driver = tmuxDriver else { throw NCUIError.notLaunched }
        try driver.resize(cols: cols, rows: rows)
    }
}
