import Foundation
import NCUITestProtocol

/// A lazy reference to one or more views in the live tree. Property accesses
/// re-resolve against the latest tree state via the probe — no stale handles.
public struct NCUIElement: Sendable {
    /// The application this element belongs to.
    public let app: NCUIApplication

    /// The query spec that selects this element. Resolved fresh per access.
    let spec: NCUIQuerySpec

    /// True if exactly one resolution is the only intended match. `firstMatch:
    /// true` causes the resolver to short-circuit on the first hit — useful
    /// for "any match will do" patterns.
    let firstMatch: Bool

    init(app: NCUIApplication, spec: NCUIQuerySpec, firstMatch: Bool = true) {
        self.app = app
        var s = spec
        s.firstMatch = firstMatch
        self.spec = s
        self.firstMatch = firstMatch
    }

    /// Re-resolve the element via a fresh tree query. Returns `nil` if not
    /// currently present.
    public func snapshot() async throws -> NCUINodeSnapshot? {
        let response = try await app.sendRaw(.query(spec))
        if case .nodes(let matches) = response.result {
            return matches.first
        }
        return nil
    }

    public var exists: Bool {
        get async throws {
            return (try await snapshot()) != nil
        }
    }

    /// Concatenated text content if the resolved node is a `Text`, or `nil`.
    public var label: String? {
        get async throws {
            return try await snapshot()?.content
        }
    }

    public var frame: NCURect? {
        get async throws {
            return try await snapshot()?.frame
        }
    }

    public var attributes: NCUIAttributes? {
        get async throws {
            return try await snapshot()?.attributes
        }
    }

    public var runs: [NCUIRunSnapshot]? {
        get async throws {
            return try await snapshot()?.runs
        }
    }

    public var isFocused: Bool {
        get async throws {
            return try await snapshot()?.isFocused ?? false
        }
    }

    /// Wait until the element exists. Returns true on success, throws on
    /// timeout (NCUIError.waitTimeout). On timeout, automatically captures
    /// a diagnostic bundle (`Tests/Artifacts/<scope>/<timestamp>/<label>.{json,ansi,png,log}`)
    /// for every running app and includes the path in the thrown error.
    /// Pass `captureScope: nil` to opt out of auto-capture (rare).
    @discardableResult
    public func waitForExistence(
        timeout: TimeInterval = 5,
        captureScope: String? = "wait"
    ) async throws -> Bool {
        let timeoutMs = Int(timeout * 1000)
        let response = try await app.sendRaw(.awaitPredicate(spec, timeoutMs: timeoutMs))
        switch response.result {
        case .nodes(let matches):
            return !matches.isEmpty
        case .error(let msg) where msg.contains("timeout"):
            let dir = captureScope.flatMap { scope in
                // Synchronously bridge to the async capture; on a timeout the
                // user is already paying multiple seconds, the extra tree dump
                // and PNG render is negligible.
                NCUIDiagnostics.captureBundleSync(for: app, scope: scope)
            }
            throw NCUIError.waitTimeout(spec: describe(spec), timeout: timeout, artifactsDir: dir)
        case .error(let msg):
            throw NCUIError.probeError(msg)
        default:
            throw NCUIError.probeError("unexpected awaitPredicate response: \(response.result)")
        }
    }

    /// Activates the element: scroll-to-visible, set focus, send Enter.
    /// Currently the focus + scroll steps return `not implemented` from the
    /// probe (task 7); the Enter is delivered regardless, so simple-input
    /// flows already work. Once task 7 lands, focus and scroll will run
    /// transparently.
    public func tap() async throws {
        // Try scroll-to-visible (best-effort — ignore "not implemented").
        _ = try? await app.sendRaw(.scrollToMakeVisible(.query(spec)))
        // Try setFocus (best-effort).
        _ = try? await app.sendRaw(.setFocus(.query(spec)))
        // Send Enter.
        let response = try await app.sendRaw(.sendKey(.code(.enter, modifiers: [])))
        if case .error(let msg) = response.result {
            throw NCUIError.probeError(msg)
        }
    }

    /// Type characters into the element. Currently sends to whatever is
    /// focused; once setFocus is implemented (task 7), tap-then-type semantics
    /// will be guaranteed.
    public func typeText(_ text: String) async throws {
        _ = try? await app.sendRaw(.scrollToMakeVisible(.query(spec)))
        _ = try? await app.sendRaw(.setFocus(.query(spec)))
        let response = try await app.sendRaw(.sendKeys(text))
        if case .error(let msg) = response.result {
            throw NCUIError.probeError(msg)
        }
    }

    /// Explicit form for tests that want to assert scrolling happens at a
    /// specific point. Once ScrollView.scrollToMakeVisible lands (task 7) this
    /// will reliably scroll.
    public func scrollIntoView() async throws {
        let response = try await app.sendRaw(.scrollToMakeVisible(.query(spec)))
        if case .error(let msg) = response.result, !msg.contains("not implemented") {
            throw NCUIError.probeError(msg)
        }
    }

    private func describe(_ spec: NCUIQuerySpec) -> String {
        var parts: [String] = []
        if let t = spec.typeName { parts.append("type=\(t)") }
        if let id = spec.testID { parts.append("testID=\(id)") }
        if let s = spec.labelEquals { parts.append("label==\(s)") }
        if let s = spec.labelContains { parts.append("label~\(s)") }
        if let s = spec.labelMatches { parts.append("label=~/\(s)/") }
        return parts.isEmpty ? "<empty>" : parts.joined(separator: " ")
    }
}
