#if canImport(Lattice)
import Lattice
import Combine
import Foundation
import typealias Lattice.Predicate
import struct Foundation.SortDescriptor
import enum Foundation.SortOrder

// MARK: - Shared actor for Snapshot materialisation
//
// All `@Snapshot` materialiser work (ref.resolve, query, observe) runs on this
// single global actor. Why: `LatticeCache.get_or_create` keys its cache on
// (configuration, isolation/scheduler). With one materialiser actor per
// wrapper, each had its own isolation → its own cache key → every bind paid
// full `swift_lattice` construction cost while serialising on
// `LatticeCache.mutex_`. Sharing one actor means shared isolation, one cache
// entry, one `swift_lattice` instance reused across all wrappers.
@globalActor
public actor LatticeUIActor {
    public static let shared = LatticeUIActor()
}

@inline(__always)
private func latLog(_ msg: @autoclosure () -> String) {
    TUILog.query(msg())
}

// MARK: - Lattice Environment Key

public struct LatticeKey: EnvironmentKey {
    // Stored `let` (not computed `var`) — the fallback Lattice is opened once per
    // process, not every time someone reads the env. `applyEnvironment` writes
    // the env via WritableKeyPath, which lowers to read-then-write through the
    // subscript getter; if this were computed, every read (and therefore every
    // env-modifier apply in every frame) would open a fresh SQLite DB —
    // previously ~87% of main-thread wall time during draw.
    // `nonisolated(unsafe)` because `Lattice` isn't Sendable; this singleton is
    // opened once and only used as a placeholder the environment never actually
    // reads for data (real Lattice is installed by App at startup).
    nonisolated(unsafe) public static var defaultValue: Lattice = try! Lattice(configuration: .init(isStoredInMemoryOnly: true))
}

extension EnvironmentValues {
    public var lattice: Lattice {
        get { self[LatticeKey.self] }
        set { self[LatticeKey.self] = newValue }
    }
}

// MARK: - @Query property wrapper
//
// Mirrors `@LatticeQuery` from Lattice/SwiftUI.swift: takes a predicate + optional
// sort, reads its Lattice from the environment, binds once in `update()`, and
// observes changes via `lattice.objects(T.self).where(predicate).observe`.
//
// Usage:
//   struct AssetCard: View {
//       @Query(predicate: { $0.symbol == "AAPL" },
//              sort: \.date, order: .reverse) var candles: TableResults<LatticeCandle>
//   }
//   WatchlistView().environment(\.lattice, lattice)

@propertyWrapper
public struct LiveQuery<T: Model>: DynamicProperty {
    /// Nested @Observable wrapper — persists across view struct replacement (framework
    /// carries the class ref forward). Reads of `value` register with
    /// `withObservationTracking`; Lattice's observer fires a fetch which writes
    /// `value` and propagates dirtiness through observation.
    @Observable
    public final class Wrapper: @unchecked Sendable {
        /// Initialized to an empty result set from Lattice's default (in-memory) instance,
        /// so `wrappedValue` is always safe to read — `bind(_:)` will replace it with
        /// real data once the environment provides a Lattice. Matches `@LatticeQuery`.
        public var value: TableResults<T>
        public let predicate: Predicate<T>
        public let sort: SortDescriptor<T>?
        public var lattice: Lattice?
        public var token: AnyCancellable?

        public init(predicate: @escaping Predicate<T>, sort: SortDescriptor<T>?) {
            self.predicate = predicate
            self.sort = sort
            self.value = LatticeEnvironmentKey.defaultValue.objects(T.self)
        }

        public func bind(_ lattice: Lattice) {
            // Config-compare guard: same lattice = no-op (common per-draw
            // case); different lattice config = rebind to follow an env swap.
            guard self.lattice?.configuration != lattice.configuration else {
                return
            }
            let tag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
            latLog("[LiveQuery<\(T.self)>#\(tag)] bind start lattice=\(ObjectIdentifier(lattice as AnyObject).hashValue & 0xFFFF)")
            self.lattice = lattice
            fetch()
            let live = lattice.objects(T.self).where(predicate)
            self.token = live.observe { [weak self] (_: Any) in
                latLog("[LiveQuery<\(T.self)>#\(tag)] observe fired -> fetch")
                self?.fetch()
            }
            latLog("[LiveQuery<\(T.self)>#\(tag)] bind done (observe armed)")
        }

        public func fetch() {
            guard let lattice else {
                latLog("[LiveQuery<\(T.self)>] fetch skipped (no lattice)")
                return
            }
            let t0 = Date()
            var results = lattice.objects(T.self).where(predicate)
            if let sort { results = results.sortedBy(sort) }
            self.value = results
            let dt = Date().timeIntervalSince(t0) * 1000
            latLog("[LiveQuery<\(T.self)>] fetch -> set value (\(String(format: "%.1f", dt))ms; lazy — no SQL until iterated)")
        }
    }

    public let _wrapper: Wrapper

    @Environment(\.lattice) private var lattice: Lattice

    public init<V: Comparable>(
        predicate: @escaping Predicate<T> = { _ in true },
        sort: (any KeyPath<T, V> & Sendable)? = nil,
        order: SortOrder? = nil
    ) {
        let sd = sort.map { SortDescriptor($0, order: order ?? .forward) }
        self._wrapper = Wrapper(predicate: predicate, sort: sd)
    }

    public init(predicate: @escaping Predicate<T> = { _ in true }) {
        self._wrapper = Wrapper(predicate: predicate, sort: nil)
    }

    public var wrappedValue: TableResults<T> { _wrapper.value }

    public func update() {
        _wrapper.bind(lattice)
    }
}

@MainActor
@propertyWrapper
public struct LiveSnapshot<T: Model>: @preconcurrency DynamicProperty {
    /// Nested @Observable wrapper — persists across view struct replacement (framework
    /// carries the class ref forward). Reads of `value` register with
    /// `withObservationTracking`; Lattice's observer fires a fetch which writes
    /// `value` and propagates dirtiness through observation.
    @Observable
    @MainActor
    public class Wrapper: @unchecked Sendable {
        // Isolated to `LatticeUIActor` (not its own actor) so all materialisers
        // across all wrappers share one isolation → one `LatticeCache` entry →
        // one `swift_lattice` instance instead of N cache-miss + mutex-wait
        // instantiations.
        @LatticeUIActor
        final class SnapshotMaterializer {
            let predicate: Lattice.Predicate<T>
            let sort: SortDescriptor<T>?
            let limit: Int64?
            let offset: Int64?
            var lattice: Lattice?
            var token: AnyCancellable?
            weak var wrapper: Wrapper?
            // Observe-fire counter for instrumentation. User pushed back on the
            // "observe storm" hypothesis for ESC→watchlist slowness; logging raw
            // counts per materializer lets us verify before changing anything.
            var observeFireCount: Int = 0
            var fetchCount: Int = 0

            nonisolated init(predicate: @escaping Lattice.Predicate<T>,
                             sort: SortDescriptor<T>?,
                             limit: Int64?,
                             offset: Int64?) {
                self.predicate = predicate
                self.sort = sort
                self.limit = limit
                self.offset = offset
            }

            func bind(_ lattice: LatticeThreadSafeReference, parent: Wrapper) {
                let tag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
                latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] bind entered (on LatticeUIActor), calling ref.resolve()")
                let tR0 = Date()
                guard let resolved = lattice.resolve() else {
                    latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] bind FAILED — ref.resolve() returned nil")
                    return
                }
                let tRdt = Date().timeIntervalSince(tR0) * 1000
                latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] ref.resolve() took \(String(format: "%.1f", tRdt))ms")
                guard self.lattice?.configuration != resolved.configuration else {
                    latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] bind skipped (same config)")
                    return
                }
                latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] bind start limit=\(limit?.description ?? "nil")")
                self.token?.cancel()
                self.lattice = resolved
                self.wrapper = parent
                fetch()
                let live = resolved.objects(T.self).where(predicate)
                self.token = live.observe { [weak self] (_: Any) in
                    Task { @LatticeUIActor [weak self] in
                        guard let self else { return }
                        self.observeFireCount += 1
                        latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] observe fired #\(self.observeFireCount) -> fetch")
                        self.fetch()
                    }
                }
                latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] bind done (observe armed)")
            }

            func fetch() {
                let tag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
                guard let lattice else {
                    latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] fetch skipped (no lattice)")
                    return
                }
                fetchCount += 1
                let t0 = Date()
                var results = lattice.objects(T.self).where(predicate)
                if let sort { results = results.sortedBy(sort) }
                let snapshot = results.snapshot(limit: limit, offset: offset)
                let refs = snapshot.map(\.sendableReference)
                let dt = Date().timeIntervalSince(t0) * 1000
                latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] fetch #\(fetchCount) -> \(refs.count) refs (\(String(format: "%.1f", dt))ms, observes=\(observeFireCount))")
                let w = self.wrapper
                Task { @MainActor in
                    latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] set-task entered on main, refs=\(refs.count), wrapper=\(w == nil ? "nil" : "alive")")
                    w?.set(value: refs)
                    latLog("[LiveSnapshot<\(T.self)>.materializer#\(tag)] set-task finished")
                }
            }
        }
        /// Initialized to an empty result set from Lattice's default instance,
        /// so `wrappedValue` is always safe to read — `bind(_:)` will replace it with
        /// real data once the environment provides a Lattice. Matches `@LatticeQuery`.
        @MainActor public var value: [T]
        public var lattice: Lattice?
        private let materializer: SnapshotMaterializer

        public init(predicate: @escaping Lattice.Predicate<T>,
                    sort: SortDescriptor<T>?,
                    limit: Int64?,
                    offset: Int64?) {
            self.materializer = SnapshotMaterializer(predicate: predicate,
                                                     sort: sort,
                                                     limit: limit,
                                                     offset: offset)
            self.value = []
        }

        public func bind(_ lattice: Lattice) {
            let tag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
            // Config-compare guard: same lattice = no-op, env swap = rebind.
            guard self.lattice?.configuration != lattice.configuration else { return }
            latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] bind called -> scheduling on LatticeUIActor")
            self.lattice = lattice
            let ref = lattice.sendableReference
            let materializer = self.materializer
            // Hop to the shared LatticeUIActor. All materialisers share this
            // isolation → shared `LatticeCache` entry → one swift_lattice
            // instance reused across all wrappers.
            Task { @LatticeUIActor [weak self] in
                guard let self else { return }
                materializer.bind(ref, parent: self)
            }
        }

        public func fetch() {
            let materializer = self.materializer
            Task { @LatticeUIActor in
                materializer.fetch()
            }
        }

        fileprivate func set(value: [ModelThreadSafeReference<T>]) {
            let tag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF, radix: 16)
            let tEnter = Date()
            latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] set ENTER on main (refs=\(value.count))")
            guard let lattice else {
                latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] set SKIPPED (no lattice on wrapper)")
                return
            }
            // Decompose `value.resolve(on: lattice)` into its internal steps so
            // we can see which sub-operation blocks when main stalls for
            // seconds. The Collection.resolve extension expands to:
            //   1. compactMap keys
            //   2. build objects query with `.in(optKeys)`
            //   3. .snapshot() — this is the SQL round-trip
            //   4. build byKey dict
            //   5. compactMap back into ordered [T]
            let tStep1 = Date()
            let sampleKeys = value.prefix(5).compactMap { ref -> Int64? in
                // Use Mirror to introspect the private `key` field without
                // modifying Lattice. ModelThreadSafeReference has a single
                // stored prop `key: Int64?`.
                Mirror(reflecting: ref).children.first?.value as? Int64
            }
            let dtStep1 = Date().timeIntervalSince(tStep1) * 1000
            latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] set: sample keys \(sampleKeys) (mirror \(String(format: "%.1f", dtStep1))ms)")

            let tBuild = Date()
            let results = lattice.objects(T.self)
            let dtBuild = Date().timeIntervalSince(tBuild) * 1000
            latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] set: lattice.objects() \(String(format: "%.1f", dtBuild))ms")

            let tResolve = Date()
            let resolved: [T] = value.resolve(on: lattice)
            let dtResolve = Date().timeIntervalSince(tResolve) * 1000
            latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] set: value.resolve() \(String(format: "%.1f", dtResolve))ms -> \(resolved.count)/\(value.count)")

            let tAssign = Date()
            self.value = resolved
            let dtAssign = Date().timeIntervalSince(tAssign) * 1000
            let dtTotal = Date().timeIntervalSince(tEnter) * 1000
            latLog("[LiveSnapshot<\(T.self)>.wrapper#\(tag)] set EXIT: self.value= \(String(format: "%.1f", dtAssign))ms | total \(String(format: "%.1f", dtTotal))ms")
            _ = results
        }
    }

    public let _wrapper: Wrapper

    @Environment(\.lattice) private var lattice: Lattice

    public init<V: Comparable>(
        predicate: @escaping Lattice.Predicate<T> = { _ in true },
        sort: (any KeyPath<T, V> & Sendable)? = nil,
        order: SortOrder? = nil,
        limit: Int64? = nil,
        offset: Int64? = nil
    ) {
        let sd = sort.map { SortDescriptor($0, order: order ?? .forward) }
        self._wrapper = Wrapper(predicate: predicate, sort: sd, limit: limit, offset: offset)
    }

    public init(predicate: @escaping Lattice.Predicate<T> = { _ in true },
                limit: Int64? = nil,
                offset: Int64? = nil) {
        self._wrapper = Wrapper(predicate: predicate, sort: nil, limit: limit, offset: offset)
    }

    public var wrappedValue: [T] { _wrapper.value }

    public func update() {
        _wrapper.bind(lattice)
    }
}
#endif
