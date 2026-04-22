import Testing
import Foundation
@testable import NCursesUI

// Simple leaf for wrapping in modifiers.
private struct EmptyLeaf: View, PrimitiveView {
    typealias Body = Never
    var body: Never { fatalError() }
}

/// Spy handler that increments a counter when called, for test assertions.
private final class HandlerSpy: @unchecked Sendable {
    var count = 0
    func fire() { count += 1 }
}

@MainActor
@Suite("Key dispatch through the node tree", .serialized)
struct KeyDispatchTests {
    init() { Term.screen = TestScreen() }

    @Test("OnKeyPressModifier handles matching key")
    func modifierHandlesMatching() {
        let spy = HandlerSpy()
        let view = EmptyLeaf().onKeyPress(65) { spy.fire() }  // key 'A'
        let node = Node(view: view, parent: nil, screen: nil)

        let consumed = node.dispatchKey(65)

        #expect(consumed == true)
        #expect(spy.count == 1)
    }

    @Test("OnKeyPressModifier ignores non-matching key")
    func modifierIgnoresNonMatching() {
        let spy = HandlerSpy()
        let view = EmptyLeaf().onKeyPress(65) { spy.fire() }
        let node = Node(view: view, parent: nil, screen: nil)

        let consumed = node.dispatchKey(66)

        #expect(consumed == false)
        #expect(spy.count == 0)
    }

    @Test("Chained onKeyPress: 'a' handler fires for key 'a'")
    func chainedModifiersDispatchCorrectKey() {
        let spyA = HandlerSpy()
        let spyB = HandlerSpy()
        let view = EmptyLeaf()
            .onKeyPress(Int32(Character("a").asciiValue!)) { spyA.fire() }
            .onKeyPress(Int32(Character("b").asciiValue!)) { spyB.fire() }
        let node = Node(view: view, parent: nil, screen: nil)
        node.mount()

        _ = node.dispatchKey(Int32(Character("a").asciiValue!))

        #expect(spyA.count == 1)
        #expect(spyB.count == 0)
    }

    @Test("Chained onKeyPress: 'b' handler fires for key 'b'")
    func chainedModifiersOuterKey() {
        let spyA = HandlerSpy()
        let spyB = HandlerSpy()
        let view = EmptyLeaf()
            .onKeyPress(Int32(Character("a").asciiValue!)) { spyA.fire() }
            .onKeyPress(Int32(Character("b").asciiValue!)) { spyB.fire() }
        let node = Node(view: view, parent: nil, screen: nil)
        node.mount()

        _ = node.dispatchKey(Int32(Character("b").asciiValue!))

        #expect(spyA.count == 0)
        #expect(spyB.count == 1)
    }

    @Test("Handler nested inside a wrapping VStack still fires")
    func handlerInsideVStack() {
        let spy = HandlerSpy()
        struct Host: View {
            let k: Int32
            let fire: () -> Void
            var body: some View {
                VStack {
                    Text("hi")
                }
                .onKeyPress(k) { fire() }
            }
        }
        let node = Node(view: Host(k: 42, fire: { spy.fire() }),
                        parent: nil, screen: nil)
        node.mount()

        let consumed = node.dispatchKey(42)

        #expect(consumed == true)
        #expect(spy.count == 1)
    }

    @Test("dispatchKey returns false when no handler matches anywhere")
    func noHandlerReturnsFalse() {
        struct Host: View {
            var body: some View {
                VStack { Text("no handler") }
            }
        }
        let node = Node(view: Host(), parent: nil, screen: nil)
        #expect(node.dispatchKey(99) == false)
    }
}
