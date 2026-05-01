import Foundation
import NCUITestProtocol

/// Always-on diagnostic bundling. When a probe operation fails (most
/// commonly `waitForExistence` timing out), NCUITest writes the live tree,
/// raw ANSI, and a PNG screenshot for every running app to a per-test
/// artifact directory. The thrown error includes the path so failures are
/// debuggable from CI artifacts alone.
public enum NCUIDiagnostics {
    /// Where artifact bundles live. Defaults to `<cwd>/Tests/Artifacts`;
    /// override with `NCUITEST_ARTIFACTS_DIR` env var.
    public static var rootDirectory: String {
        if let dir = ProcessInfo.processInfo.environment["NCUITEST_ARTIFACTS_DIR"] {
            return dir
        }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent("Tests/Artifacts")
    }

    /// Capture an artifact bundle for a single app. Returns the directory
    /// path on success, nil if capture itself failed (we never throw —
    /// diagnostics must not mask the original failure).
    public static func captureBundle(for app: NCUIApplication, scope: String) async -> String? {
        let timestamp = Self.timestamp()
        let scoped = (rootDirectory as NSString).appendingPathComponent(scope)
        let dir = (scoped as NSString).appendingPathComponent(timestamp)
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return nil
        }

        // Tree dump.
        if let tree = try? await app.sendRaw(.tree) {
            if case .tree(let root) = tree.result {
                if let json = try? JSONEncoder().encode(root) {
                    let path = (dir as NSString).appendingPathComponent("\(app.label).json")
                    try? json.write(to: URL(fileURLWithPath: path))
                }
            }
        }

        // Raw ANSI.
        if let ansi = try? app.captureANSI() {
            let path = (dir as NSString).appendingPathComponent("\(app.label).ansi")
            try? ansi.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }

        // PNG screenshot (best-effort; macOS only).
        if let png = try? await app.screenshot() {
            let path = (dir as NSString).appendingPathComponent("\(app.label).png")
            try? png.write(to: URL(fileURLWithPath: path))
        }

        return dir
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: Date())
    }
}

extension NCUIElement {
    /// Wait for existence with diagnostic bundling on failure. Replaces the
    /// underlying `waitForExistence` for tests that want auto-capture.
    @discardableResult
    public func waitForExistenceWithDiagnostics(
        timeout: TimeInterval = 5,
        scope: String = "wait"
    ) async throws -> Bool {
        do {
            return try await waitForExistence(timeout: timeout)
        } catch let error as NCUIError {
            if case .waitTimeout(let spec, let t, _) = error {
                let dir = await NCUIDiagnostics.captureBundle(for: app, scope: scope)
                throw NCUIError.waitTimeout(spec: spec, timeout: t, artifactsDir: dir)
            }
            throw error
        }
    }
}
