import Testing
import Foundation
@testable import NCursesUI

// Perf-regression tests. Each keystroke in TraderTUI currently produces ~270
// reconcile calls across ~60 nodes (~4.5× redundant work per node). These
// tests lock in a budget so that number can't quietly grow, and document the
// specific sources of excess work (closures forcing REUSE+DIRTY, onChange
// running a stale reconcile during willSet, run-loop calling observeChildren
// again after draw).

/// Shared counter that body evaluation increments. Using a class so all views
/// share the same instance through normal value-type captures.
private final class BodyCounter: @unchecked Sendable {
    var count = 0
    func bump() { count += 1 }
}

private struct Tracked: View {
    let counter: BodyCounter
    @State var value: Int = 0
    var body: some View {
        counter.bump()
        return Text("value=\(value)")
    }
}

/// Host with a closure field. `viewsEqualIgnoringState` treats closures as
/// always-different, so this view always reports REUSE+DIRTY in matchChildren.
private struct ClosureHost<Child: View>: View {
    let child: Child
    let handler: () -> Void
    var body: some View { child }
}

@MainActor
@Suite("Reconcile body evaluations stay within budget", .serialized)
struct ReconcileEfficiencyTests {
    init() { Term.screen = TestScreen() }

    @Test("Single @State mutation triggers exactly one body re-evaluation")
    func oneMutationOneBodyCall() {
        let counter = BodyCounter()
        let node = Node(view: Tracked(counter: counter), parent: nil, screen: nil)
        node.mount()
        let mountCount = counter.count
        #expect(mountCount >= 1, "mount evaluates body at least once")

        node.view.value = 1
        node.draw(in: Rect(x: 0, y: 0, width: 20, height: 1))

        let afterMutation = counter.count - mountCount
        // #expect's comment slot takes a single Comment literal, not a concatenation.
        // If this fails with `afterMutation > 1`, it means onChange is running a stale
        // observeChildren during willSet AND draw is running another one at the dirty
        // gate — the onChange variant is wasted work.
        #expect(afterMutation == 1, "expected 1 body eval after one mutation")
    }

    @Test("Drawing a clean node does NOT re-evaluate body")
    func cleanDrawSkipsBody() {
        let counter = BodyCounter()
        let node = Node(view: Tracked(counter: counter), parent: nil, screen: nil)
        node.mount()
        node.draw(in: Rect(x: 0, y: 0, width: 20, height: 1))
        let mountCount = counter.count

        node.draw(in: Rect(x: 0, y: 0, width: 20, height: 1))

        #expect(counter.count == mountCount,
                "draw with dirty=false must not call body — only the leaf's draw(in:) should fire")
    }

    @Test("Mutating one sibling does not re-evaluate the other's body")
    func siblingsDoNotCrossContaminate() {
        // Two counters, two Tracked views, both children of a host. Mutate one —
        // only that one's body should re-run.
        let a = BodyCounter(), b = BodyCounter()
        struct Host: View {
            let a: BodyCounter
            let b: BodyCounter
            var body: some View {
                TupleView(Tracked(counter: a), Tracked(counter: b))
            }
        }
        let node = Node(view: Host(a: a, b: b), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.count == 2)

        let aBefore = a.count, bBefore = b.count
        let aNode = node.children[0] as! Node<Tracked>
        aNode.view.value = 1
        aNode.draw(in: Rect(x: 0, y: 0, width: 20, height: 1))

        #expect(a.count - aBefore == 1, "mutated sibling evaluated once")
        #expect(b.count - bBefore == 0, "untouched sibling must not re-evaluate body")
    }
}

@MainActor
@Suite("Known perf cliffs — documentation tests", .serialized)
struct ReconcilePerfCliffTests {
    init() { Term.screen = TestScreen() }

    @Test("A view with a closure field is considered unequal on every reconcile")
    func closuresAlwaysDiffer() {
        // viewsEqualIgnoringState walks children via Mirror and refuses to equate
        // closure-typed values. Any view type with a closure (OnKeyPressModifier,
        // GridView.cell, ForEach.content, any custom `handler: () -> Void` field)
        // therefore always propagates REUSE+DIRTY through matchChildren.
        let leaf = Text("x")
        let a = ClosureHost(child: leaf, handler: {})

        // Inspect both via the framework's comparator. NCursesUI keeps this
        // helper file-private, so reach it through the public reconcile path:
        // host two nodes of the same type and check matchChildren's decision.
        let parent = Node(view: TupleView(a), parent: nil, screen: nil)
        parent.mount()
        // Re-driving with a freshly-constructed equivalent view should still
        // mark the child dirty because the closure differs by identity.
        let before = parent.children.first.map(ObjectIdentifier.init(_:))
        parent.observeChildren()
        let after = parent.children.first.map(ObjectIdentifier.init(_:))
        #expect(before == after,
                "same-type child should be REUSED (not replaced) — identity preserved")
        // The actual perf cost shows up in body re-evaluation counts; see the
        // budget test above. This test only locks in the reuse-not-replace half.
    }
}
