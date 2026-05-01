import Foundation

/// Stub for now — wired up properly when WindowServer.setFocus and the
/// in-tree focus chain are implemented (task 7). Returns nil so the tree
/// walker reports nothing as focused; tests that don't assert on focus
/// state are unaffected.
final class NCUIFocusTracker: @unchecked Sendable {
    static let shared = NCUIFocusTracker()
    private init() {}

    func focusedID(for server: WindowServer) -> ObjectIdentifier? {
        // TODO: wire to WindowServer's actual focus chain (task 7).
        return nil
    }
}
