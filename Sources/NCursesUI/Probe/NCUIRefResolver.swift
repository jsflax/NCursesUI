import Foundation
import NCUITestProtocol

enum NCUIRefResolver {
    /// Walk the tree to find a node matching `ref`. Returns the live node
    /// (not a snapshot) so callers can mutate via its view.
    @MainActor
    static func resolve(ref: NCUINodeRef, in root: any ViewNode) -> (any ViewNode)? {
        switch ref {
        case .nodeId(let id):
            return findByNodeId(id, in: root)
        case .testID(let id):
            return findByTestID(id, in: root, inheritedID: nil)
        case .query(let spec):
            return findByQuery(spec, in: root, inheritedID: nil)
        }
    }

    @MainActor
    private static func findByNodeId(_ id: UInt64, in node: any ViewNode) -> (any ViewNode)? {
        let oid = ObjectIdentifier(node)
        if UInt64(UInt(bitPattern: oid.hashValue)) == id { return node }
        for child in node.anyChildren {
            if let m = findByNodeId(id, in: child) { return m }
        }
        return nil
    }

    @MainActor
    private static func findByTestID(_ id: String, in node: any ViewNode, inheritedID: String?) -> (any ViewNode)? {
        // TestIDView inherits its id onto its single child; the walker treats
        // the child as the tagged node. So we descend looking for either:
        //   - a TestIDView whose inner view we should match against
        //   - a non-TaggedView whose inheritedID equals the target
        if let tagged = node.anyView as? any TaggedViewProtocol {
            let next = tagged.taggedID
            for child in node.anyChildren {
                if let m = findByTestID(id, in: child, inheritedID: next) { return m }
            }
            return nil
        }
        if inheritedID == id { return node }
        for child in node.anyChildren {
            if let m = findByTestID(id, in: child, inheritedID: nil) { return m }
        }
        return nil
    }

    @MainActor
    private static func findByQuery(_ spec: NCUIQuerySpec, in node: any ViewNode, inheritedID: String?) -> (any ViewNode)? {
        let effectiveID: String?
        let descendInto: [any ViewNode]
        if let tagged = node.anyView as? any TaggedViewProtocol {
            effectiveID = tagged.taggedID
            descendInto = node.anyChildren
        } else {
            effectiveID = inheritedID
            // Check this node against the spec.
            if matches(node: node, testID: effectiveID, spec: spec) {
                return node
            }
            descendInto = node.anyChildren
        }
        for child in descendInto {
            if let m = findByQuery(spec, in: child, inheritedID: effectiveID) {
                return m
            }
        }
        return nil
    }

    @MainActor
    private static func matches(node: any ViewNode, testID: String?, spec: NCUIQuerySpec) -> Bool {
        let typeName = "\(type(of: node.anyView))"
        if let t = spec.typeName, t != typeName { return false }
        if let id = spec.testID, id != testID { return false }
        if spec.labelEquals != nil || spec.labelContains != nil || spec.labelMatches != nil {
            // Match against Text content if any.
            guard let text = node.anyView as? Text else { return false }
            let content = TextIntrospection.runs(of: text).map { $0.content }.joined()
            if let eq = spec.labelEquals, eq != content { return false }
            if let sub = spec.labelContains, !content.contains(sub) { return false }
            if let pattern = spec.labelMatches {
                guard let r = try? Regex(pattern), content.firstMatch(of: r) != nil else { return false }
            }
        }
        return true
    }
}
