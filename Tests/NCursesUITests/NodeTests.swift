import Testing
import Foundation
@testable import NCursesUI

// Helpers
private struct Leaf: View, PrimitiveView {
    typealias Body = Never
    var body: Never { fatalError() }
}

private struct Host<C: View>: View {
    let content: C
    var body: some View { content }
}

@MainActor
@Suite("Node tree construction", .serialized)
struct NodeConstructionTests {
    init() { Term.screen = TestScreen() }

    @Test("Mount a primitive creates a node with no children")
    func primitiveHasNoChildren() {
        let node = Node(view: Leaf(), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.isEmpty)
        #expect(!node.dirty)
    }

    @Test("Mount a composite expands body into children")
    func compositeExpandsBody() {
        let node = Node(view: Host(content: Leaf()), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.count == 1)
        #expect(node.children[0].view is Leaf)
    }

    @Test("Mount a TupleView flattens its children into siblings")
    func tupleFlattens() {
        let tuple = TupleView(Leaf(), Leaf(), Leaf())
        let node = Node(view: Host(content: tuple), parent: nil, screen: nil)
        node.mount()
        #expect(node.children.count == 3)
        for child in node.children {
            #expect(child.view is Leaf)
        }
    }

    @Test("Child nodes have correct parent pointer")
    func parentLinking() {
        let node = Node(view: Host(content: Leaf()), parent: nil, screen: nil)
        node.mount()
        #expect(node.children[0].parent === node)
    }
}

@MainActor
@Suite("Node.markDirty", .serialized)
struct MarkDirtyTests {
    init() { Term.screen = TestScreen() }

    @Test("markDirty sets dirty = true")
    func setsDirty() {
        let node = Node(view: Leaf(), parent: nil, screen: nil)
        node.mount()
        #expect(!node.dirty)
        node.markDirty()
        #expect(node.dirty)
    }

    @Test("markDirty on a node with a screen does not crash")
    func markDirtyWithScreen() {
        let screen = WindowServer { Leaf() }
        let node = Node(view: Leaf(), parent: nil, screen: screen)
        node.mount()
        node.markDirty()
        node.markDirty()   // idempotent
        #expect(node.dirty)
    }

    @Test("markDirty on already-dirty node is idempotent")
    func idempotent() {
        let node = Node(view: Leaf(), parent: nil, screen: nil)
        node.mount()
        node.markDirty()
        node.markDirty()
        #expect(node.dirty)
    }
}
