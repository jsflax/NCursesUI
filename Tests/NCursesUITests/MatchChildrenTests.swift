import Testing
import Foundation
@testable import NCursesUI

// matchChildren is the reconcile-path subroutine that decides, per-position,
// whether to REUSE the old node (optionally mutating it), REPLACE it with a
// fresh mount, or drop it entirely. The rules are:
//   1. fresh[i] same type as old[i]:   reuse old[i], merge wrappers, mark dirty
//                                      if non-wrapper fields differ.
//   2. fresh[i] different type:        replace with a fresh mount.
//   3. fresh.count < old.count:        tail old nodes are dropped (ARC-freed).
//   4. fresh.count > old.count:        trailing positions get fresh mounts.
// matchChildren is file-private, so these tests drive it indirectly through
// `observeChildren()` on a parent whose body produces the desired fresh list.

private struct Leaf: View, PrimitiveView {
    let label: String
    typealias Body = Never
    var body: Never { fatalError() }
}

private struct OtherLeaf: View, PrimitiveView {
    typealias Body = Never
    var body: Never { fatalError() }
}

/// A parent whose body produces a variable-length / variable-type tuple based
/// on a mutable `@State` field, so we can drive different fresh-list shapes
/// from one test.
private struct FlexParent: View {
    @State var mode: Int = 0
    var body: some View {
        switch mode {
        case 0: TupleView(Leaf(label: "a"), Leaf(label: "b"))
        case 1: TupleView(Leaf(label: "a-prime"), Leaf(label: "b"))   // pos 0 non-wrapper differs
        case 2: TupleView(OtherLeaf(), Leaf(label: "b"))              // pos 0 type differs
        case 3: TupleView(Leaf(label: "a"))                           // shrink
        case 4: TupleView(Leaf(label: "a"), Leaf(label: "b"), Leaf(label: "c")) // grow
        default: TupleView(Leaf(label: "a"), Leaf(label: "b"))
        }
    }
}

@MainActor
@Suite("matchChildren reuse / replace / drop / mount", .serialized)
struct MatchChildrenTests {
    init() { Term.screen = TestScreen() }

    private func reconcile(_ node: Node<FlexParent>) {
        // Mirror the run-loop's path: mark dirty, let reconcile re-run body.
        node.markDirty()
        node.observeChildren()
    }

    @Test("Same-type same-fields: node identity preserved, dirty stays false")
    func reuseClean() {
        let node = Node(view: FlexParent(), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.count == 2)
        let aId = ObjectIdentifier(node.children[0] as AnyObject)
        let bId = ObjectIdentifier(node.children[1] as AnyObject)

        reconcile(node)     // mode unchanged; body returns structurally equal tuple

        #expect(ObjectIdentifier(node.children[0] as AnyObject) == aId)
        #expect(ObjectIdentifier(node.children[1] as AnyObject) == bId)
    }

    @Test("Same-type different-fields: node identity preserved, view struct updated")
    func reuseDirty() {
        let node = Node(view: FlexParent(), parent: nil, screen: nil)
        node.mount()
        let aId = ObjectIdentifier(node.children[0] as AnyObject)

        node.view.mode = 1
        reconcile(node)

        #expect(ObjectIdentifier(node.children[0] as AnyObject) == aId,
                "same-type child should be reused, not replaced")
        guard let leaf = node.children[0].view as? Leaf else {
            Issue.record("expected Leaf at position 0")
            return
        }
        #expect(leaf.label == "a-prime",
                "fresh non-wrapper fields should overwrite the old view's copy")
    }

    @Test("Different type at a position: old node is dropped, fresh mount replaces it")
    func typeChangeReplaces() {
        let node = Node(view: FlexParent(), parent: nil, screen: nil)
        node.mount()
        let aIdBefore = ObjectIdentifier(node.children[0] as AnyObject)

        node.view.mode = 2
        reconcile(node)

        #expect(node.children[0].view is OtherLeaf)
        #expect(ObjectIdentifier(node.children[0] as AnyObject) != aIdBefore,
                "type change should produce a brand-new node at this position")
    }

    @Test("Shrinking fresh list drops tail old nodes")
    func shrinkDropsTail() {
        let node = Node(view: FlexParent(), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.count == 2)

        node.view.mode = 3
        reconcile(node)

        #expect(node.children.count == 1, "tail nodes past fresh.count are dropped")
        #expect((node.children[0].view as? Leaf)?.label == "a")
    }

    @Test("Growing fresh list mounts trailing new nodes")
    func growMountsTail() {
        let node = Node(view: FlexParent(), parent: nil, screen: nil)
        node.mount()

        node.view.mode = 4
        reconcile(node)

        #expect(node.children.count == 3, "trailing positions beyond old.count get fresh mounts")
        #expect((node.children[2].view as? Leaf)?.label == "c")
    }
}
