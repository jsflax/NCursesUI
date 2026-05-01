import Foundation
import NCUITestProtocol

/// Golden-file snapshot recording + diffing. Writes ANSI for human review
/// and JSON tree for assertions; the JSON form is the actual diff target.
///
/// Recording: set `RECORD_SNAPSHOTS=1` in the environment to overwrite
/// goldens with the current output. Otherwise the helper compares and fails
/// on mismatch.
public enum NCUISnapshot {
    public enum Failure: Error, CustomStringConvertible {
        case missingGolden(jsonPath: String)
        case mismatch(name: String, jsonPath: String, current: String)

        public var description: String {
            switch self {
            case .missingGolden(let path):
                return "no golden snapshot at \(path) — run with RECORD_SNAPSHOTS=1 to record"
            case .mismatch(let name, let path, _):
                return "snapshot '\(name)' diverged from \(path) — re-run with RECORD_SNAPSHOTS=1 to update"
            }
        }
    }

    public static var directory: String {
        if let dir = ProcessInfo.processInfo.environment["NCUITEST_SNAPSHOT_DIR"] {
            return dir
        }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent("Tests/Snapshots")
    }

    public static var isRecordingMode: Bool {
        return ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
    }

    /// Compare the app's current tree against `<directory>/<name>.json`.
    /// Also writes the corresponding ANSI capture for human review.
    public static func compare(
        of app: NCUIApplication,
        named name: String,
        maskingTestIDs: Set<String> = []
    ) async throws {
        let response = try await app.sendRaw(.tree)
        guard case .tree(let root) = response.result else {
            throw NCUIError.probeError("snapshot: expected tree response, got \(response.result)")
        }

        let masked = mask(node: root, maskedIDs: maskingTestIDs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(masked)

        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let jsonPath = (directory as NSString).appendingPathComponent("\(name).json")
        let ansiPath = (directory as NSString).appendingPathComponent("\(name).ansi")

        // Always write ANSI as a side-channel reviewable artifact.
        if let raw = try? app.captureANSI() {
            try? raw.data(using: .utf8)?.write(to: URL(fileURLWithPath: ansiPath))
        }

        if isRecordingMode {
            try json.write(to: URL(fileURLWithPath: jsonPath))
            return
        }

        guard FileManager.default.fileExists(atPath: jsonPath) else {
            throw Failure.missingGolden(jsonPath: jsonPath)
        }

        let golden = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        if golden != json {
            // Write current alongside golden for diffing.
            let currentPath = (directory as NSString).appendingPathComponent("\(name).current.json")
            try? json.write(to: URL(fileURLWithPath: currentPath))
            throw Failure.mismatch(
                name: name,
                jsonPath: jsonPath,
                current: currentPath
            )
        }
    }

    /// Walk the tree, replacing fields under masked testIDs with placeholders
    /// so volatile content (timestamps, breathing-cursor frames) doesn't
    /// cause false diffs.
    private static func mask(node: NCUINodeSnapshot, maskedIDs: Set<String>) -> NCUINodeSnapshot {
        var copy = node
        if let id = copy.testID, maskedIDs.contains(id) {
            copy.content = "<<masked>>"
            copy.runs = nil
        }
        copy.children = copy.children.map { mask(node: $0, maskedIDs: maskedIDs) }
        // Strip nodeId — it's based on object identity and isn't stable across runs.
        copy.nodeId = 0
        return copy
    }
}

extension NCUIApplication {
    /// Convenience wrapper. Throws on diff or missing golden.
    public func assertSnapshot(named name: String, maskingTestIDs: Set<String> = []) async throws {
        try await NCUISnapshot.compare(of: self, named: name, maskingTestIDs: maskingTestIDs)
    }
}
