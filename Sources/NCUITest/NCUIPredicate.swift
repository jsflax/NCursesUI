import Foundation
import NCUITestProtocol

/// Type-safe predicate DSL that compiles to an `NCUIQuerySpec`. Tests use
/// `.label(contains:)`, `.label(equals:)`, `.type(_:)`, `.testID(_:)`.
public struct NCUIPredicate: Sendable {
    let spec: NCUIQuerySpec

    init(_ spec: NCUIQuerySpec) { self.spec = spec }

    public static func type(_ name: String) -> NCUIPredicate {
        NCUIPredicate(NCUIQuerySpec(typeName: name))
    }

    public static func testID(_ id: String) -> NCUIPredicate {
        NCUIPredicate(NCUIQuerySpec(testID: id))
    }

    public static func label(equals value: String) -> NCUIPredicate {
        NCUIPredicate(NCUIQuerySpec(labelEquals: value))
    }

    public static func label(contains substring: String) -> NCUIPredicate {
        NCUIPredicate(NCUIQuerySpec(labelContains: substring))
    }

    public static func label(matches pattern: String) -> NCUIPredicate {
        NCUIPredicate(NCUIQuerySpec(labelMatches: pattern))
    }

    /// Compose two predicates with AND semantics. Implementation note: the wire
    /// spec is currently a flat AND of fields; combining two specs merges
    /// non-conflicting fields, with fields from `rhs` winning on conflict.
    /// For OR / NOT, see future versions.
    public static func && (lhs: NCUIPredicate, rhs: NCUIPredicate) -> NCUIPredicate {
        var merged = lhs.spec
        if let v = rhs.spec.typeName { merged.typeName = v }
        if let v = rhs.spec.testID { merged.testID = v }
        if let v = rhs.spec.labelEquals { merged.labelEquals = v }
        if let v = rhs.spec.labelContains { merged.labelContains = v }
        if let v = rhs.spec.labelMatches { merged.labelMatches = v }
        return NCUIPredicate(merged)
    }
}
