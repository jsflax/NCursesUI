import Testing
import Foundation
import Observation
@testable import NCursesUI

// Test views that expose @State for inspection.
private struct Counter: View {
    @State var value: Int = 0
    typealias Body = Never
    var body: Never { fatalError() }
}

extension Counter: PrimitiveView {}

@MainActor
@Suite("@State basics", .serialized)
struct StateBasicsTests {
    init() { Term.screen = TestScreen() }

    @Test("wrappedValue returns the initial value")
    func initialValue() {
        let c = Counter(value: 7)
        #expect(c.value == 7)
    }

    @Test("Setting wrappedValue mutates the box")
    func setMutatesBox() {
        let c = Counter()
        #expect(c.value == 0)
        c.value = 42
        #expect(c.value == 42)
    }

    @Test("Box is @Observable — reads register with withObservationTracking")
    func observationFiresOnChange() async {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        let c = Counter()
        withObservationTracking {
            _ = c.value
        } onChange: {
            flag.fired = true
        }
        c.value = 1
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(flag.fired == true)
    }

    @Test("projectedValue Binding round-trips through the same box")
    func bindingRoundTrip() {
        let c = Counter()
        c.value = 5
        let binding = c.$value
        #expect(binding.wrappedValue == 5)
        binding.wrappedValue = 99
        #expect(c.value == 99)
    }

    /// Regression: touching `$value` (projectedValue) inside a
    /// `withObservationTracking` block must register an observer on the
    /// underlying `@State` value, so that subsequent writes through the
    /// Binding's setter fire onChange. Before the fix, `projectedValue`
    /// only returned a wrapper without reading `box.value`, so no observer
    /// registered — `$scrollOffset` was a dead wire: Binding.set wrote into
    /// an observable that nobody was listening to, and the owning view
    /// never re-rendered when ScrollView updated the offset.
    @Test("Binding write through $value fires the observation tracker")
    func bindingWriteFiresObserver() async {
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        let c = Counter()

        withObservationTracking {
            // The only access is the projectedValue (`$value`). If
            // projectedValue doesn't internally read `box.value`, the
            // tracker registers nothing here and the later write below
            // never fires onChange — which is the bug we're guarding
            // against.
            let _ = c.$value
        } onChange: {
            flag.fired = true
        }

        // Write via the Binding the same way ScrollView.setOffset does.
        c.$value.wrappedValue = 42
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(flag.fired,
                "Binding.set must fire observers registered via projectedValue")
    }
}

@MainActor
@Suite("@State survives reconcile (preserveWrappers)", .serialized)
struct StatePreservationTests {
    init() { Term.screen = TestScreen() }

    /// Composite view that holds a Counter child and exposes a reloadable input.
    private struct Host: View {
        let tag: Int
        @State var count: Int = 0
        var body: some View { Text("tag \(tag) count \(count)") }
    }

    @Test("Setting @State after mount, then re-mounting same-type view preserves the value")
    func statePreservedAcrossRematch() {
        // Mount once. Node<V>.view is the concrete struct — no cast needed.
        let node = Node(view: Host(tag: 1), parent: nil, screen: nil)
        node.view.count = 123

        // Simulate matchChildren merging a fresh Host (same type, different tag).
        // _mergeWrappers is `mutating` — it copies the OLD view's underscore-prefixed
        // (property-wrapper backing) fields into the fresh struct, preserving boxes.
        var fresh: any View = Host(tag: 2)
        fresh._mergeWrappers(from: node.view)

        // After merge, `fresh` should have tag=2 from the new struct and count=123
        // from the old @State Box (preserved by ARC through the wrapper copy).
        guard let mergedHost = fresh as? Host else {
            Issue.record("merged view has wrong type")
            return
        }
        #expect(mergedHost.tag == 2, "non-wrapper field `tag` should take fresh's value")
        #expect(mergedHost.count == 123, "@State value should survive the merge")
    }
}
