import Testing
import Foundation
import Observation
@testable import NCursesUI

// End-to-end coverage of the @State → @Observable willSet → onChange → markDirty
// → next-tick reconcile pipeline. Most other tests fake this chain by calling
// `node.markDirty(); node.observeChildren()` explicitly; these tests assert
// that a plain mutation alone is enough.

private struct Counter: View, PrimitiveView {
    @State var value: Int = 0
    typealias Body = Never
    var body: Never { fatalError() }
}

private struct Parent: View {
    @State var count: Int = 0
    var body: some View { Text("count=\(count)") }
}

/// Two-level composite: `Outer` body reads nothing mutable — it only forwards
/// to `Inner`. `Inner` owns the @State that changes. This mimics AppView →
/// WatchlistGridView where only the inner view's tracker should fire.
private struct Outer: View {
    let tag: Int
    var body: some View { Inner() }
}
private struct Inner: View {
    @State var n: Int = 0
    var body: some View { Text("n=\(n)") }
}

@MainActor
@Suite("@State mutation propagates through the observation pipeline", .serialized)
struct ObservationPipelineTests {
    init() { Term.screen = TestScreen() }

    @Test("Mutating @State on the root view marks the node dirty with no explicit markDirty call")
    func mutationSetsDirtyViaObservation() {
        let node = Node(view: Parent(), parent: nil, screen: nil)
        node.mount()
        #expect(node.dirty == false, "fresh mount should be clean")

        node.view.count = 7   // @State.set → Box.value setter → willSet → onChange

        #expect(node.dirty == true,
                "onChange fires synchronously during willSet; markDirty should set dirty before the setter returns")
    }

    @Test("Drawing a dirty node re-evaluates body with the new @State value")
    func drawReconcilesWithFreshValue() {
        let node = Node(view: Parent(), parent: nil, screen: nil)
        node.mount()
        node.view.count = 42

        node.draw(in: Rect(x: 0, y: 0, width: 20, height: 1))

        #expect(node.dirty == false, "draw should have cleared dirty")
        guard let txt = node.children[0].view as? Text else {
            Issue.record("expected Text child after reconcile")
            return
        }
        #expect(txt.content == "count=42",
                "body should have observed the new @State value during draw's dirty gate")
    }

    @Test("Mutation on a grandchild's @State does NOT mark the grandparent dirty")
    func parentStaysClean() {
        // Outer.body returns Inner. Only Inner reads n, so only Inner's tracker fires.
        let outerNode = Node(view: Outer(tag: 1), parent: nil, screen: nil)
        outerNode.mount()
        let innerNode = outerNode.children[0] as! Node<Inner>
        innerNode.mount()
        #expect(outerNode.dirty == false)
        #expect(innerNode.dirty == false)

        innerNode.view.n = 5

        #expect(innerNode.dirty == true, "inner should be dirty (its body reads n)")
        #expect(outerNode.dirty == false,
                "outer body doesn't read n — outer's tracker must not fire")
    }

    @Test("Binding writes propagate through the same Box as direct writes")
    func bindingMutationAlsoSetsDirty() {
        let node = Node(view: Parent(), parent: nil, screen: nil)
        node.mount()
        let binding = node.view.$count
        #expect(node.dirty == false)

        binding.wrappedValue = 9

        #expect(node.dirty == true)
        #expect(node.view.count == 9)
    }

    @Test("onChange re-arms after firing — two mutations both mark dirty")
    func observationRearmsAfterFire() {
        let node = Node(view: Parent(), parent: nil, screen: nil)
        node.mount()
        node.view.count = 1
        #expect(node.dirty == true)

        // Clear dirty (simulating a draw pass) so we can see the NEXT mutation.
        // draw(in:) does observeChildren which clears dirty AND re-arms the tracker.
        node.draw(in: Rect(x: 0, y: 0, width: 20, height: 1))
        #expect(node.dirty == false)

        node.view.count = 2
        #expect(node.dirty == true,
                "second mutation must also fire onChange; withObservationTracking is one-shot — draw must re-arm it")
    }
}
