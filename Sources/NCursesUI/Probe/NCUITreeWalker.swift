import Foundation
import NCUITestProtocol

enum NCUITreeWalker {
    /// Walk the tree from `root`, producing the snapshot the wire format expects.
    /// Caller must invoke this on @MainActor (NCursesUI views are MainActor).
    @MainActor
    static func snapshot(from root: any ViewNode, focused: ObjectIdentifier?) -> NCUINodeSnapshot {
        return walk(node: root, inheritedTestID: nil, focused: focused)
    }

    @MainActor
    private static func walk(
        node: any ViewNode,
        inheritedTestID: String?,
        focused: ObjectIdentifier?
    ) -> NCUINodeSnapshot {
        let view = node.anyView

        // TestIDView wraps a single child; promote its `id` onto the child
        // snapshot rather than emitting a TestIDView node ourselves.
        if let tagged = view as? any TaggedViewProtocol {
            let id = tagged.taggedID
            // Walk children with the inherited testID applied to first non-transparent.
            // Since TestIDView's body is its content, the framework reconciles it as
            // a regular composite node — its single child holds the actual content.
            let childSnapshots = node.anyChildren.map { child in
                walk(node: child, inheritedTestID: id, focused: focused)
            }
            // If we have exactly one child, hoist it (collapsing the wrapper node away).
            if childSnapshots.count == 1 {
                return childSnapshots[0]
            }
            return baseSnapshot(
                node: node,
                view: view,
                testID: inheritedTestID ?? id,
                focused: focused,
                children: childSnapshots
            )
        }

        let childSnapshots = node.anyChildren.map { child in
            walk(node: child, inheritedTestID: nil, focused: focused)
        }
        return baseSnapshot(
            node: node,
            view: view,
            testID: inheritedTestID,
            focused: focused,
            children: childSnapshots
        )
    }

    @MainActor
    private static func baseSnapshot(
        node: any ViewNode,
        view: any View,
        testID: String?,
        focused: ObjectIdentifier?,
        children: [NCUINodeSnapshot]
    ) -> NCUINodeSnapshot {
        let typeName = "\(type(of: view))"
        let oid = ObjectIdentifier(node)
        let nodeId = UInt64(UInt(bitPattern: oid.hashValue))

        var content: String?
        var runs: [NCUIRunSnapshot]?
        var topAttrs = NCUIAttributes()

        if let text = view as? Text {
            let textRuns = TextIntrospection.runs(of: text)
            content = textRuns.map { $0.content }.joined()
            runs = textRuns.map { run in
                NCUIRunSnapshot(
                    content: run.content,
                    color: TextIntrospection.colorSlot(run.style.color),
                    palettePair: run.style.palettePair,
                    attributes: NCUIAttributes(
                        bold: run.style.bold,
                        dim: run.style.dim,
                        italic: run.style.italic,
                        inverted: run.style.inverted
                    )
                )
            }
            // Top-level attrs: union of all runs (useful for queries like
            // "is this Text bold overall"). For queries on a specific span,
            // use the runs array.
            for r in textRuns {
                if r.style.bold { topAttrs.bold = true }
                if r.style.dim { topAttrs.dim = true }
                if r.style.italic { topAttrs.italic = true }
                if r.style.inverted { topAttrs.inverted = true }
            }
        }

        let isFocused = (oid == focused)

        return NCUINodeSnapshot(
            nodeId: nodeId,
            typeName: typeName,
            testID: testID,
            frame: NCURect(
                x: node.frame.x,
                y: node.frame.y,
                width: node.frame.width,
                height: node.frame.height
            ),
            content: content,
            runs: runs,
            attributes: topAttrs,
            isFocused: isFocused,
            isFocusable: view is any KeyHandling,
            children: children
        )
    }
}

/// Existential bridge so the walker doesn't need to know `TestIDView`'s generic
/// content type — only that it can hand us its `id`.
@MainActor
protocol TaggedViewProtocol {
    var taggedID: String { get }
}

extension TestIDView: TaggedViewProtocol {
    var taggedID: String { id }
}

/// Helper to read the `package` runs/colors out of `Text` from the same module.
enum TextIntrospection {
    static func runs(of text: Text) -> [Text.Run] { text.runs }

    static func colorSlot(_ c: Color) -> NCUIColorSlot {
        switch c {
        case .normal: return .normal
        case .green: return .green
        case .red: return .red
        case .yellow: return .yellow
        case .cyan: return .cyan
        case .selected: return .selected
        case .dim: return .dim
        case .magenta: return .magenta
        case .blue: return .blue
        case .white: return .white
        case .purple: return .purple
        case .gold: return .gold
        case .teal: return .teal
        }
    }
}
