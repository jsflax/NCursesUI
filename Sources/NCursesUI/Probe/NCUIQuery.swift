import Foundation
import NCUITestProtocol

enum NCUIQuery {
    /// Walk the snapshot tree depth-first, collecting nodes that match the spec.
    /// `firstMatch` short-circuits.
    static func run(spec: NCUIQuerySpec, in tree: NCUINodeSnapshot) -> [NCUINodeSnapshot] {
        var out: [NCUINodeSnapshot] = []
        walk(tree, spec: spec, into: &out)
        if spec.firstMatch, let first = out.first {
            return [first]
        }
        return out
    }

    private static func walk(_ node: NCUINodeSnapshot, spec: NCUIQuerySpec, into out: inout [NCUINodeSnapshot]) {
        if matches(node, spec: spec) {
            out.append(node)
            if spec.firstMatch { return }
        }
        for child in node.children {
            walk(child, spec: spec, into: &out)
            if spec.firstMatch, !out.isEmpty { return }
        }
    }

    private static func matches(_ node: NCUINodeSnapshot, spec: NCUIQuerySpec) -> Bool {
        if let t = spec.typeName, t != node.typeName { return false }
        if let id = spec.testID, id != node.testID { return false }
        if let eq = spec.labelEquals {
            guard node.content == eq else { return false }
        }
        if let sub = spec.labelContains {
            guard let c = node.content, c.contains(sub) else { return false }
        }
        if let pattern = spec.labelMatches {
            guard let c = node.content,
                  let r = try? Regex(pattern),
                  c.firstMatch(of: r) != nil else { return false }
        }
        return true
    }
}
