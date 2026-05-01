import Foundation
import NCUITestProtocol

/// Server-side predicate evaluation. Re-runs the query against the live tree
/// after every frame and resolves the wait the first frame the predicate is
/// satisfied — guaranteeing the test never observes intermediate state.
enum NCUIPredicateMatcher {
    static func evaluateOnce(spec: NCUIQuerySpec, tree: NCUINodeSnapshot) -> [NCUINodeSnapshot] {
        return NCUIQuery.run(spec: spec, in: tree)
    }
}
