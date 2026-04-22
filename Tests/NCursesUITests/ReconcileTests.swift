import Testing
import Foundation
@testable import NCursesUI

// Views used in reconcile scenarios.
private struct StaticText: View, PrimitiveView {
    let s: String
    typealias Body = Never
    var body: Never { fatalError() }
}

/// Parent whose body depends on @State.
private struct SwitchableParent: View {
    @State var mode: Int = 0
    var body: some View {
        if mode == 0 {
            StaticText(s: "A")
        } else {
            StaticText(s: "B")
        }
    }
}

/// Parent with @State that passes a derived value down as a prop.
private struct PropsDownParent: View {
    @State var n: Int = 0
    var body: some View {
        StaticText(s: "n=\(n)")
    }
}

@MainActor
@Suite("Reconcile re-evaluates dirty nodes", .serialized)
struct ReconcileTests {
    init() { Term.screen = TestScreen() }

    @Test("Initial mount produces correct children")
    func initialChildren() {
        let node = Node(view: PropsDownParent(), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.count == 1)
        if let txt = node.children[0].view as? StaticText {
            #expect(txt.s == "n=0")
        } else {
            Issue.record("expected StaticText child")
        }
    }

    @Test("Marking dirty then reconciling re-evaluates body with new state")
    func reconcileRunsBody() {
        let node = Node(view: PropsDownParent(), parent: nil, screen: nil)
        node.view.n = 9                  // Node<V> exposes view as concrete V — no cast needed.
        node.markDirty()
        node.observeChildren()
        guard let txt = node.children[0].view as? StaticText else {
            Issue.record("expected StaticText")
            return
        }
        #expect(txt.s == "n=9", "body should have observed the new @State value")
    }

    @Test("Switching branches (EitherView) replaces the child type")
    func switchingBranchesReplaces() {
        let node = Node(view: SwitchableParent(), parent: nil, screen: nil)
        node.view.mode = 1
        node.markDirty()
        node.observeChildren()
        // SwitchableParent's body uses if/else — wrapped in EitherView (transparent),
        // so the StaticText is direct-children, not nested under an Either node.
        guard let txt = node.children[0].view as? StaticText else {
            Issue.record("expected StaticText child after switching")
            return
        }
        #expect(txt.s == "B", "branch should have switched from A to B")
    }
}
