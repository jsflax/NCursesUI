import Foundation
import Observation
@_exported import Cncurses
import Combine
import os

let logFileURL = URL(fileURLWithPath: "~/.config/trader/ncurses.log")

/// File logger for NCursesUI. Uses a persistent file handle so logging
/// at 7000+ lines per draw pass costs ~1µs per line instead of the
/// ~50µs/line of the original open+seek+write+close-per-call impl.
struct FileLogHandler {
    let label: String

    private let fileURL: URL
    private let logger = Logger.init(subsystem: "", category: "")
    nonisolated(unsafe) private static var handles: [String: FileHandle] = [:]
    nonisolated(unsafe) private static var writeLock = NSLock()

    init(label: String, fileURL: URL) {
        self.label = label
        self.fileURL = fileURL
    }

    private func handle() -> FileHandle? {
        FileLogHandler.writeLock.lock()
        defer { FileLogHandler.writeLock.unlock() }
        if let existing = FileLogHandler.handles[fileURL.path] {
            return existing
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return nil }
        h.seekToEndOfFile()
        FileLogHandler.handles[fileURL.path] = h
        return h
    }

    func log(level: OSLogType, message: String,
             file: String = #file,
             function: String = #function,
             line: UInt = #line) {
        let entry = "[\(Date())] [\(level)] [\(label)] \(message)\n"
        logger.log(level: level, "\(entry, privacy: .public)")
        guard let data = entry.data(using: .utf8), let h = handle() else { return }
        FileLogHandler.writeLock.lock()
        h.write(data)
        FileLogHandler.writeLock.unlock()
    }

    func debug(_ message: String,
               file: String = #file,
               function: String = #function,
               line: UInt = #line) {
        log(level: .debug, message: message, file: file, function: function, line: line)
    }
}

let logger = FileLogHandler(label: "ncursesUI", fileURL: logFileURL)

// MARK: - Instrumentation tag legend (grep `~/.config/trader/ncurses.log`)
//
//   [tick N] ...                    — WindowServer run-loop iteration N
//   [WindowServer.init] ...         — startup before the loop runs
//   [WindowServer.run] ...          — entering / exiting the loop
//   [WindowServer.setNeedsWork] ... — pending flag flip (no-op repeats suppressed)
//
//   [mount] view=Foo#abcd parent=… initial_children=N done dirty=…
//   [expand] view=… kind=primitive|transparent|composite children=N
//   [reconcile] view=… dirty_before=… done children=N
//                                   — re-evaluated body, matched children, cleared dirty
//   [match] parent=… pos=i type=T REUSE_CLEAN | REUSE+DIRTY | REPLACE | MOUNT
//                                   — per-position decision in matchChildren
//   [markDirty] view=… -> true | skip (already dirty)
//   [onChange] tracker_fired view=…
//                                   — Observation registrar fired during a mutation
//
//   [draw] view=… rect=… children=N | dirty=true -> reconcile before draw
//   [key] view=… ch=N HANDLED | consumed_by_child
//   [onKeyPress] firing handler for key=K on Content=…
//
//   [@State.set] type=V old=… new=…            — direct .wrappedValue write
//   [@State.set via Binding] type=V old=… new=… — write via projectedValue/$prop
//
// Trace template for "press right arrow → expected re-render":
//   1. [tick N] KEY received ch=261 (arrow)
//   2. [onKeyPress] firing handler for key=261 on Content=…
//   3. [@State.set] type=Int old=0 new=1
//   4. [onChange] tracker_fired view=WatchlistGridView#…
//   5. [reconcile] view=WatchlistGridView dirty_before=false  (stale read in willSet)
//   6. [markDirty] view=WatchlistGridView -> true
//   7. [tick N+1] BEGIN draw_pass
//   8. [draw] view=WatchlistGridView dirty=true -> reconcile before draw
//   9. [reconcile] reads NEW value, [match] flags 2 cards REUSE+DIRTY
//  10. [draw] those cards re-render with new isSelected


// MARK: - Swift runtime reflection (SPI access via @_silgen_name)
//
// The Swift stdlib exposes `_forEachField` (a reflection hook that visits each
// stored property of a type with its byte offset, type metadata, and kind).
// It's not re-exported by the macOS stdlib's public .swiftinterface, so we
// link to it directly by its mangled ABI symbol. We use the offset-based form
// rather than the keypath form because keypath-based SPI crashes with SIGSEGV
// in our environment.

/// Mirror of Swift stdlib's `_EachFieldOptions`. Single `UInt32` rawValue —
/// ABI-compatible with the stdlib's layout.
private struct _EachFieldOptions: OptionSet {
    var rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }
    static let classType     = _EachFieldOptions(rawValue: 1 << 0)
    static let ignoreUnknown = _EachFieldOptions(rawValue: 1 << 1)
}

/// Mirror of Swift stdlib's `_MetadataKind`. `UInt` rawValue — ABI-compatible.
private enum _MetadataKind: UInt {
    case `class`                 = 0
    case `struct`                = 0x200
    case `enum`                  = 0x201
    case optional                = 0x202
    case foreignClass            = 0x203
    case opaque                  = 0x300
    case tuple                   = 0x301
    case function                = 0x302
    case existential             = 0x303
    case metatype                = 0x304
    case objCClassWrapper        = 0x305
    case existentialMetatype     = 0x306
    case heapLocalVariable       = 0x400
    case heapGenericLocalVariable = 0x500
    case errorObject             = 0x501
    case unknown                 = 0xffff
}

@_silgen_name("swift_reflectionMirror_recursiveCount")
private func _getRecursiveChildCount(_: Any.Type) -> Int

@_silgen_name("swift_reflectionMirror_recursiveChildOffset")
private func _getChildOffset(_: Any.Type, index: Int) -> Int

private typealias NameFreeFunc = @convention(c) (UnsafePointer<CChar>?) -> Void

@_silgen_name("swift_reflectionMirror_subscript")
private func _getChild<T>(
    of: T,
    type: Any.Type,
    index: Int,
    outName: UnsafeMutablePointer<UnsafePointer<CChar>?>,
    outFreeFunc: UnsafeMutablePointer<NameFreeFunc?>
) -> Any

/// Calls the given closure on every field of the specified value.
///
/// - Parameters:
///   - value: The value to inspect.
///   - body: A closure to call with information about each field in `value`.
///     The parameters to `body` are the name of the field, the offset of the
///     field, and the value of the field.
func _forEachField<Value>(of value: Value, body: (String?, Int, Any) -> Void) {
    let childCount = _getRecursiveChildCount(Value.self)
    for index in 0..<childCount {
        let offset = _getChildOffset(Value.self, index: index)

        var nameC: UnsafePointer<CChar>? = nil
        var freeFunc: NameFreeFunc? = nil
        defer { freeFunc?(nameC) }

        let childValue = _getChild(
            of: value,
            type: Value.self,
            index: index,
            outName: &nameC,
            outFreeFunc: &freeFunc
        )
        let childName = nameC.flatMap(String.init(validatingCString:))

        body(childName, offset, childValue)
    }
}

// MARK: - Geometry

public struct Size: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public static let zero = Size(width: 0, height: 0)
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public struct Rect: Equatable, Sendable, CustomStringConvertible {
    public var x, y, width, height: Int
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public func inset(dx: Int = 0, dy: Int = 0) -> Rect {
        Rect(x: x + dx, y: y + dy, width: max(0, width - 2 * dx), height: max(0, height - 2 * dy))
    }
    
    public var description: String {
        "(\(x), \(y), \(width), \(height))"
    }
}

public struct Style {
    public var color: Color = .dim
    public var bold: Bool = false
    public var inverted: Bool = false
    /// Palette-role pair ID override. When non-nil, wins over `color`
    /// — the run renders with the active palette's concrete RGB for
    /// that semantic slot instead of the legacy 9-slot `Color` enum.
    /// Set by `Text.foregroundColor(_ role: Palette.Role)`.
    public var palettePair: Int32? = nil
    public init(color: Color = .dim, bold: Bool = false, inverted: Bool = false) {
        self.color = color; self.bold = bold; self.inverted = inverted
    }
}

// MARK: - View Protocol
//
// Framework model:
//   • The app's view tree is represented by a persistent tree of `Node` objects.
//   • Each `Node` holds the current view struct (`node.view`) for that position.
//   • View structs are transient; they get replaced on every reconcile of a dirty node.
//   • State boxes (class refs inside @State wrappers) are preserved across replacements.
//   • Composite views expose children via `body`. Leaves draw via `draw(in:)`.

@MainActor @preconcurrency public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Body { get }

    /// Leaves override this to draw themselves into `rect`.
    /// Composites do nothing here; their children are drawn by the framework.
    func draw(in rect: Rect)

    /// Each view reports its desired size given a proposed width and its live children.
    func measure(children: [ViewNode], proposedWidth: Int) -> Size

    /// Containers override this to lay children out. Default is vertical stack.
    func childRects(children: [ViewNode], in rect: Rect) -> [Rect]
}

public extension View {
    func draw(in rect: Rect) {
        logger.debug("EMPTY DRAW")
    }

    func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        // Default: vertical stack of children.
        var h = 0, w = 0
        for child in children {
            let s = child.measure(proposedWidth: proposedWidth)
            h += s.height
            w = max(w, s.width)
        }
        return Size(width: w, height: h)
    }

    func childRects(children: [ViewNode], in rect: Rect) -> [Rect] {
        // Default: vertical stacking at rect.
        var rects: [Rect] = []
        var y = rect.y
        for child in children {
            let s = child.measure(proposedWidth: rect.width)
            let h = max(0, min(s.height, rect.maxY - y))
            rects.append(Rect(x: rect.x, y: y, width: rect.width, height: h))
            y += s.height
        }
        return rects
    }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never has no body") }
}

// MARK: - Framework-internal merge hook (not exposed to consumers)
//
// Copies property-wrapper backing storage ("_foo" fields) from `old` into a
// copy of `self` and returns the merged view. Called by Node during reconcile
// so @State / @Query class refs survive view-struct replacement. Internal
// access — not part of NCursesUI's public API.
//
// Implementation: `_forEachField` hands us each field's byte offset and
// concrete type. For fields whose name begins with "_" (property-wrapper
// backing storage), we do a Swift-typed pointer assignment: opening the type
// to a concrete `T`, taking `UnsafeMutablePointer<T>` at the offset, and
// assigning `.pointee = .pointee`. Swift's typed assignment handles ARC for
// class references inside T, so no manual retain/release is needed.
extension View {
    mutating func _mergeWrappers(from old: any View) {
        guard let oldSelf = old as? Self else { return }
        var merged = self
        withUnsafePointer(to: oldSelf) { srcPtr in
            withUnsafeMutablePointer(to: &merged) { dstPtr in
                let srcBase = UnsafeRawPointer(srcPtr)
                let dstBase = UnsafeMutableRawPointer(dstPtr)
                _forEachField(of: oldSelf) { name, offset, childValue in
                    guard let name, name.hasPrefix("_") else { return }
                    _copyField(value: childValue, offset: offset,
                               from: srcBase, to: dstBase)
                }
            }
        }
        self = merged
    }
}

/// Copy one field from `src` to `dst` at `offset`. We open `value`'s concrete
/// type to get a static `T`, then take `UnsafeMutablePointer<T>` at `offset`
/// and assign `.pointee = .pointee`. Swift's typed assignment handles ARC for
/// class references inside T.
private func _copyField(
    value: Any,
    offset: Int,
    from src: UnsafeRawPointer,
    to dst: UnsafeMutableRawPointer
) {
    func impl<T>(_ v: T) {
        let s = src.advanced(by: offset).assumingMemoryBound(to: T.self)
        let d = dst.advanced(by: offset).assumingMemoryBound(to: T.self)
        d.pointee = s.pointee
    }
    _openExistential(value, do: impl)
}

// MARK: - DynamicProperty
//
// Property wrappers (@State, @Query, @Binding, @Environment) conform to this.
// The framework calls `update()` on each wrapper in a view's Mirror-reflected fields
// before evaluating that view's body, giving the wrapper a chance to sync with the
// current environment (read @Environment values, bind lattices, etc.). Non-mutating
// because all wrappers hold their mutable state in class refs.

public protocol DynamicProperty {
    func update()
}

public extension DynamicProperty {
    func update() {}
}

// MARK: - Marker Protocols

/// Views that draw themselves and have no children.
/// Their `body` is `Never` and must not be evaluated.
public protocol PrimitiveView {}

/// Views that transparently unpack into one or more child views.
/// The framework flattens these; they do not create their own `Node`.
@MainActor @preconcurrency public protocol TransparentView {
    var unpacked: [any View] { get }
}

/// Views that handle key events. Framework walks the tree bottom-up asking each node.
@MainActor @preconcurrency public protocol KeyHandling {
    func handles(_ ch: Int32) -> Bool
    func handleKey(_ ch: Int32) -> Bool
}

/// Views that contribute an environment override for their subtree.
@MainActor @preconcurrency public protocol EnvironmentApplying {
    func applyEnvironment()
}

/// Views that want to inject work around the default child-iteration path
/// in `Node.draw`. `beforeChildren` runs after the view's own `draw(in:)`
/// but before `childRects` + child recursion; `afterChildren` runs after
/// all children have drawn. `ScrollView` uses this to push a pad target
/// before the child renders and to pop + queue a viewport blit after.
/// Existing views don't opt in — the default implementations are no-ops.
@MainActor @preconcurrency public protocol ContainerRendering {
    func beforeChildren(children: [any ViewNode], in rect: Rect)
    func afterChildren(children: [any ViewNode], in rect: Rect)
}
public extension ContainerRendering {
    func beforeChildren(children: [any ViewNode], in rect: Rect) {}
    func afterChildren(children: [any ViewNode], in rect: Rect) {}
}

/// Views that consume mouse events. Dispatched by `Node.dispatchMouse`
/// depth-first via frame hit-testing — innermost view at the event's
/// (y, x) gets first refusal, then the event bubbles up.
@MainActor @preconcurrency public protocol MouseHandling {
    func handles(_ event: MouseEvent) -> Bool
    func handleMouse(_ event: MouseEvent) -> Bool
}

// MARK: - ViewBuilder

@MainActor
@resultBuilder
public struct ViewBuilder {
    public static func buildBlock<V: View>(_ view: V) -> V { view }
    public static func buildBlock<each V: View>(_ views: repeat each V) -> TupleView<repeat each V> {
        TupleView(repeat each views)
    }
    public static func buildOptional<V: View>(_ view: V?) -> OptionalView<V> {
        OptionalView(view)
    }
    public static func buildEither<T: View, F: View>(first: T) -> EitherView<T, F> {
        .trueView(first)
    }
    public static func buildEither<T: View, F: View>(second: F) -> EitherView<T, F> {
        .falseView(second)
    }
    public static func buildExpression<V: View>(_ expression: V) -> V { expression }
}

// MARK: - TupleView (transparent)

public struct TupleView<each V: View>: View, TransparentView {
    public typealias Body = Never
    public let children: (repeat each V)
    public init(_ c: repeat each V) { self.children = (repeat each c) }
    public var body: Never { fatalError("TupleView has no body") }

    public var unpacked: [any View] {
        var result: [any View] = []
        for view in repeat each children {
            result.append(view)
        }
        return result
    }
}

// MARK: - OptionalView, EitherView (transparent)

public struct OptionalView<Wrapped: View>: View, TransparentView {
    public typealias Body = Never
    public let wrapped: Wrapped?
    public init(_ w: Wrapped?) { self.wrapped = w }
    public var body: Never { fatalError("OptionalView has no body") }
    public var unpacked: [any View] { wrapped.map { [$0 as any View] } ?? [] }
}

public enum EitherView<T: View, F: View>: View, TransparentView {
    case trueView(T), falseView(F)
    public typealias Body = Never
    public var body: Never { fatalError("EitherView has no body") }
    public var unpacked: [any View] {
        switch self {
        case .trueView(let v): return [v as any View]
        case .falseView(let v): return [v as any View]
        }
    }
}

// MARK: - Primitive leaves

public struct Text: View, PrimitiveView {
    public typealias Body = Never

    /// Styled segment of a Text. A plain `Text("hi")` has a single run;
    /// concatenating with `+` produces a Text with multiple runs, each
    /// retaining its own style. Internal — callers compose via `Text + Text`
    /// and the public modifiers, they don't build Runs directly.
    struct Run {
        var content: String
        var style: Style
    }

    let runs: [Run]

    public init(_ content: String) {
        self.runs = [Run(content: content, style: Style())]
    }

    init(runs: [Run]) {
        self.runs = runs
    }

    public var body: Never { fatalError("Text has no body") }

    /// Back-compat accessor for the concatenated string (used by measuring /
    /// diagnostics). Prefer the Text view itself; reading `.content` loses
    /// any per-run style information.
    public var content: String { runs.map(\.content).joined() }

    /// Concatenate two Texts, preserving each side's run styles — analogous
    /// to SwiftUI's `Text + Text`.
    public static func + (lhs: Text, rhs: Text) -> Text {
        Text(runs: lhs.runs + rhs.runs)
    }

    public func foregroundColor(_ c: Color) -> Text {
        Text(runs: runs.map {
            var r = $0
            r.style.color = c
            // Legacy color explicit — clear any palette override so
            // the call-site intent wins.
            r.style.palettePair = nil
            return r
        })
    }

    /// Paint this Text in the active palette's concrete RGB for the
    /// given semantic role. Separate method from `foregroundColor(_:)`
    /// because `Color.dim` and `Palette.Role.dim` share names — one
    /// call-site dot-syntax would be ambiguous otherwise.
    /// Callers pinned to the legacy 9-slot enum keep using
    /// `foregroundColor(_:)`; palette-driven views use this.
    public func paletteColor(_ role: Palette.Role) -> Text {
        let pair = PaletteRegistrar.pairId(for: role)
        return Text(runs: runs.map { var r = $0; r.style.palettePair = pair; return r })
    }

    public func bold(_ b: Bool = true) -> Text {
        Text(runs: runs.map { var r = $0; r.style.bold = b; return r })
    }

    public func reverse(_ r: Bool = true) -> Text {
        Text(runs: runs.map { var run = $0; run.style.inverted = r; return run })
    }

    public func draw(in rect: Rect) {
        guard rect.width > 0, rect.height > 0 else { return }
        if runs.count <= 1 {
            // Single-run fast path: preserve existing word-wrapped rendering.
            let style = runs.first?.style ?? Style()
            let text = runs.first?.content ?? ""
            let lines = Text.wrap(text, width: rect.width)
            for (i, line) in lines.prefix(rect.height).enumerated() {
                Self.drawStyled(line, y: rect.y + i, x: rect.x, style: style)
            }
            return
        }
        // Multi-run: inline on a single line, truncated at rect.width. Word
        // wrapping across styled run boundaries is intentionally out of scope
        // — the common case (per-nick colored chat rows) is one line each,
        // and the owning ScrollView handles the break between messages.
        var x = rect.x
        let maxX = rect.x + rect.width
        for run in runs {
            guard x < maxX else { break }
            let available = maxX - x
            let fit = run.content.prefix(available)
            Self.drawStyled(String(fit), y: rect.y, x: x, style: run.style)
            x += fit.count
        }
    }

    /// Resolve a styled run to concrete ncurses attrs and emit. When
    /// `style.palettePair` is set, it wins over the legacy `style.color`
    /// pair; otherwise this matches `Term.put(..., color:)`.
    private static func drawStyled(_ s: String, y: Int, x: Int, style: Style) {
        let pairId = style.palettePair ?? style.color.rawValue
        var attrs = tui_color_pair(pairId)
        if style.bold { attrs |= tui_a_bold() }
        if style.inverted { attrs |= tui_a_reverse() }
        Term.screen.attron(attrs)
        Term.screen.move(Int32(y), Int32(x))
        Term.screen.addstr(s)
        Term.screen.attroff(attrs)
    }

    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        guard proposedWidth > 0 else { return Size(width: 0, height: 0) }
        if runs.count <= 1 {
            let text = runs.first?.content ?? ""
            guard !text.isEmpty else { return Size(width: 0, height: 0) }
            let lines = Text.wrap(text, width: proposedWidth)
            let w = lines.map(\.count).max() ?? 0
            return Size(width: min(w, proposedWidth), height: lines.count)
        }
        let totalChars = runs.reduce(0) { $0 + $1.content.count }
        return Size(width: min(totalChars, proposedWidth), height: totalChars > 0 ? 1 : 0)
    }

    /// Word-wrap `text` to lines of at most `width` columns. Breaks at spaces
    /// when possible; hard-breaks words longer than `width`. Preserves
    /// embedded newlines as paragraph separators (blank input lines stay
    /// blank in the output so paragraphs visually separate).
    static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var out: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if paragraph.isEmpty { out.append(""); continue }
            var line = ""
            for word in paragraph.split(separator: " ") {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= width {
                    line += " " + word
                } else {
                    out.append(line)
                    line = String(word)
                }
                while line.count > width {
                    out.append(String(line.prefix(width)))
                    line = String(line.dropFirst(width))
                }
            }
            if !line.isEmpty { out.append(line) }
        }
        return out
    }
}

public struct HLineView: View, PrimitiveView {
    public typealias Body = Never
    public init() {}
    public var body: Never { fatalError("HLineView has no body") }
    public func draw(in rect: Rect) { Term.hline(rect.y, rect.x, rect.width) }
    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        Size(width: proposedWidth, height: 1)
    }
}

public struct SpacerView: View, PrimitiveView {
    public typealias Body = Never
    public let height: Int
    public init(_ h: Int = 1) { self.height = h }
    public var body: Never { fatalError("SpacerView has no body") }
    public func draw(in rect: Rect) {}
    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        Size(width: 0, height: height)
    }
}

public struct SparklineView: View, PrimitiveView {
    public typealias Body = Never
    public let values: [Float]
    public var style: Style
    public init(_ values: [Float], color: Color = .green) {
        self.values = values
        self.style = Style(color: color)
    }
    public var body: Never { fatalError("SparklineView has no body") }
    public func draw(in rect: Rect) {
        guard rect.width > 0 else { return }
        let s = sparkline(values, width: rect.width)
        Term.put(rect.y, rect.x, s, color: style.color)
    }
    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        Size(width: proposedWidth, height: 1)
    }
}

public struct EmptyView: View, PrimitiveView {
    public typealias Body = Never
    public init() {}
    public var body: Never { fatalError("EmptyView has no body") }
    public func draw(in rect: Rect) {}
    public func measure(children: [ViewNode], proposedWidth: Int) -> Size { .zero }
}

public struct Row: View, PrimitiveView {
    public typealias Body = Never
    public let columns: [(text: String, width: Int, style: Style)]
    public init(columns: [(text: String, width: Int, style: Style)]) { self.columns = columns }
    public var body: Never { fatalError("Row has no body") }
    public func draw(in rect: Rect) {
        var x = rect.x
        for (text, width, style) in columns {
            guard x + width <= rect.maxX else { break }
            let t = pad(text, width)
            Term.put(rect.y, x, t, color: style.color, bold: style.bold, inverted: style.inverted)
            x += width
        }
    }
    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        Size(width: columns.reduce(0) { $0 + $1.width }, height: 1)
    }
}

// MARK: - Layout containers

public struct VStack<Content: View>: View {
    public let spacing: Int
    public let content: Content
    public init(spacing: Int = 0, @ViewBuilder content: () -> Content) {
        self.spacing = spacing; self.content = content()
    }
    public var body: some View { content }

    public func childRects(children: [ViewNode], in rect: Rect) -> [Rect] {
        var rects: [Rect] = []
        var y = rect.y
        for (i, child) in children.enumerated() {
            let s = child.measure(proposedWidth: rect.width)
            let h = max(0, min(s.height, rect.maxY - y))
            rects.append(Rect(x: rect.x, y: y, width: rect.width, height: h))
            y += s.height
            if i < children.count - 1 { y += spacing }
        }
        return rects
    }

    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        var h = 0, w = 0
        for child in children {
            let s = child.measure(proposedWidth: proposedWidth)
            h += s.height; w = max(w, s.width)
        }
        h += spacing * max(0, children.count - 1)
        return Size(width: w, height: h)
    }
}

public struct HStack<Content: View>: View {
    public let spacing: Int
    public let content: Content
    public init(spacing: Int = 1, @ViewBuilder content: () -> Content) {
        self.spacing = spacing; self.content = content()
    }
    public var body: some View { content }

    public func childRects(children: [ViewNode], in rect: Rect) -> [Rect] {
        var rects: [Rect] = []
        var x = rect.x
        for (i, child) in children.enumerated() {
            let remainingWidth = max(0, rect.maxX - x)
            let s = child.measure(proposedWidth: remainingWidth)
            let w = max(0, min(s.width, remainingWidth))
            rects.append(Rect(x: x, y: rect.y, width: w, height: rect.height))
            x += s.width
            if i < children.count - 1 { x += spacing }
        }
        return rects
    }

    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        var w = 0, h = 0
        for child in children {
            let s = child.measure(proposedWidth: max(0, proposedWidth - w))
            w += s.width; h = max(h, s.height)
        }
        w += spacing * max(0, children.count - 1)
        return Size(width: w, height: h)
    }
}

// MARK: - Pad + ScrollView
//
// A `Pad` is an ncurses off-screen buffer we allocate once per ScrollView and
// resize when the content's width/height changes. Child draws land in the
// pad via `Term.pushTarget(pad.handle)`; the visible viewport is blitted to
// stdscr by `Term.queuePadRefresh`, which is drained in `Term.flush` at the
// end of each frame. Owning the pad via `@State` + ARC means the handle is
// freed by `Pad.deinit` when the ScrollView node is dropped (e.g. replaced
// in `matchChildren`), so there's no manual teardown hook.

final class Pad: @unchecked Sendable {
    let handle: OpaquePointer
    private(set) var rows: Int
    private(set) var cols: Int
    init(rows: Int, cols: Int) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.handle = tui_newpad(Int32(self.rows), Int32(self.cols))!
    }
    deinit { _ = tui_delwin(handle) }
}

/// Internal state for a `ScrollView`. Held in an `@State` box on the view
/// struct so it survives reconciles and is freed (along with the pad) when
/// the ScrollView node is dropped. Not part of NCursesUI's public surface
/// — consumers interact with `ScrollView` only.
///
/// `@Observable` so that when `ScrollView` has no external offset binding,
/// reading `box.offset` during body evaluation registers an observer and
/// subsequent writes from the wheel/key handlers dirty the node → redraw.
/// Without this, internal-offset ScrollViews appeared frozen: the wheel
/// event was handled, `box.offset` mutated, but nothing fired markDirty
/// because the @State Box only observes reassignments of its `value`
/// (the class reference), not mutations of the held class's properties.
@Observable
final class ScrollViewState: @unchecked Sendable {
    var offset: Int = 0
    /// Pad + cache fields are mutated DURING `beforeChildren`/`afterChildren`
    /// (i.e. mid-draw). If the observation macro tracked them, those mid-draw
    /// writes would fire observers from inside a `withObservationTracking`
    /// block that's still evaluating body — re-entrant access into
    /// `generateAccessList` trips a runtime assertion in libswiftObservation
    /// (SIGTRAP). Only `offset` needs to be observed (wheel/key handlers
    /// write it between frames, not during draw).
    @ObservationIgnored var pad: Pad?
    /// Cached content height — used to clamp `offset` on key input between
    /// frames (the pad is resized during `beforeChildren`, but users press
    /// keys in between frames too).
    @ObservationIgnored var lastContentHeight: Int = 0
    @ObservationIgnored var lastPadWidth: Int = 0
    init() {}

    /// Ensure the pad is sized (width × height). Recreate on size change.
    /// ncurses has no in-place pad resize; we `delwin` + `newpad`. Triggered
    /// lazily in `beforeChildren` so a ScrollView that's never drawn (e.g.
    /// inside a hidden tab) never allocates.
    func sizedPad(width: Int, height: Int) -> Pad {
        let w = max(1, width), h = max(1, height)
        if let p = pad, p.cols == w && p.rows == h { return p }
        let p = Pad(rows: h, cols: w)
        self.pad = p
        self.lastPadWidth = w
        self.lastContentHeight = h
        return p
    }
}

public struct ScrollView<Content: View>: View, ContainerRendering, KeyHandling, MouseHandling {
    public let visibleHeight: Int
    public let content: Content
    /// External offset — caller-owned; if nil, `box.offset` is used. Exposed
    /// so selection-coupled scroll (e.g. "keep selected row visible") can
    /// read and write without owning the ScrollView's internal state.
    public let externalOffset: Binding<Int>?
    @State var box: ScrollViewState = ScrollViewState()

    public init(height: Int,
                offset: Binding<Int>? = nil,
                @ViewBuilder content: () -> Content) {
        self.visibleHeight = max(1, height)
        self.content = content()
        self.externalOffset = offset
    }

    public var body: some View {
        // When no external binding is provided, read `box.offset` so the
        // observation tracker wrapping this body registers on it. Wheel /
        // key writes to `box.offset` then fire the tracker → markDirty →
        // redraw. Without this read, internal-offset ScrollViews never
        // redraw after scroll input.
        if externalOffset == nil { _ = box.offset }
        return content
    }

    /// Offset is either caller-bound or internal. We don't replicate writes
    /// — the one that's "live" is the source of truth. When external is
    /// bound, internal `box.offset` is unused.
    private var currentOffset: Int {
        externalOffset?.wrappedValue ?? box.offset
    }
    private func setOffset(_ v: Int) {
        // Skip the write when the offset didn't actually change — e.g.
        // when the user keeps wheeling past the top/bottom of the
        // content. Without this guard, each wheel event at the boundary
        // writes the same value into the `@Observable` box, which still
        // fires `markDirty` and triggers a full redraw — 50 wheel events
        // past the edge caused a visible pile-up of useless redraws.
        guard v != currentOffset else { return }
        if let ext = externalOffset {
            ext.wrappedValue = v
        } else {
            box.offset = v
        }
    }

    /// Width reserved for the scrollbar column. Scrollbar is drawn only when
    /// content exceeds viewport, but we always reserve the column so layout
    /// is stable and `childRects` doesn't jitter between "bar"/"no-bar" on
    /// content-size changes. Swift forbids stored static properties on
    /// generic types, so this is a computed `var`.
    private static var scrollbarCols: Int { 1 }

    // MARK: View layout

    public func measure(children: [any ViewNode], proposedWidth: Int) -> Size {
        Size(width: proposedWidth, height: visibleHeight)
    }

    public func childRects(children: [any ViewNode], in rect: Rect) -> [Rect] {
        guard children.first != nil else { return [] }
        let w = max(0, rect.width - Self.scrollbarCols)
        // Children render in PAD-LOCAL coords: (0, 0) is the pad's top-left.
        // Height is whatever `beforeChildren` sized the pad to (measured
        // from the child directly), so it matches the pad exactly.
        return [Rect(x: 0, y: 0, width: w, height: box.lastContentHeight)]
    }

    // MARK: ContainerRendering — switch target before children render

    public func beforeChildren(children: [any ViewNode], in rect: Rect) {
        guard rect.width > Self.scrollbarCols, rect.height > 0,
              let child = children.first else { return }
        let padWidth = rect.width - Self.scrollbarCols
        // Measure the child up front so we know its real content height for
        // this frame. Pad must be AT LEAST the viewport height, even if the
        // content is smaller — `pnoutrefresh` requires the source pad region
        // (sy2-sy1 rows) to fit inside the pad's real size. If the pad is
        // shorter than the requested blit region, ncurses truncates silently
        // and the target region doesn't get redrawn → existing stdscr cells
        // from the previous frame (or garbage after an overlay dismissed)
        // remain on screen.
        let contentH = max(1, child.measure(proposedWidth: padWidth).height)
        let padHeight = max(contentH, rect.height)
        box.lastContentHeight = contentH
        box.lastPadWidth = padWidth
        let pad = box.sizedPad(width: padWidth, height: padHeight)
        _ = tui_werase(pad.handle)
        Term.pushTarget(pad.handle)
    }

    public func afterChildren(children: [any ViewNode], in rect: Rect) {
        Term.popTarget()
        guard rect.width > Self.scrollbarCols, rect.height > 0,
              let pad = box.pad else { return }

        let viewportH = min(visibleHeight, rect.height)
        // `childRects` wrote the real content height into the box this
        // frame; use it for scroll-range + scrollbar math.
        let contentH = max(1, box.lastContentHeight)
        // If the pad is smaller than content (first frame of a growing
        // child), we'd have truncated the draw. Accept one frame of clip
        // — next frame will see the new lastContentHeight and resize.
        let maxOffset = max(0, contentH - viewportH)
        let clamped = min(max(0, currentOffset), maxOffset)
        if clamped != currentOffset { setOffset(clamped) }

        let blitRect = Rect(x: rect.x, y: rect.y,
                            width: rect.width - Self.scrollbarCols,
                            height: viewportH)
        Term.queuePadRefresh(pad.handle, padY: clamped, padX: 0, on: blitRect)

        if contentH > viewportH {
            drawScrollbar(in: rect, offset: clamped,
                          contentH: contentH, viewportH: viewportH)
        }
    }

    /// Draws a thumb directly to stdscr (target has been popped). The bar
    /// lives in the rightmost column of our rect; consumes 1 col already
    /// reserved by `childRects`.
    private func drawScrollbar(in rect: Rect, offset: Int,
                               contentH: Int, viewportH: Int) {
        let x = rect.x + rect.width - 1
        // Track
        for row in rect.y ..< (rect.y + viewportH) {
            Term.put(row, x, "┊", color: .dim)
        }
        let thumbH = max(1, viewportH * viewportH / contentH)
        let thumbRange = max(1, contentH - viewportH)
        let thumbY = rect.y + (offset * (viewportH - thumbH)) / thumbRange
        for row in thumbY ..< min(thumbY + thumbH, rect.y + viewportH) {
            Term.put(row, x, "█", color: .selected)
        }
    }

    // MARK: KeyHandling — ↑ ↓ PgUp PgDn Home End
    //
    // When an external offset binding is provided, the caller owns scroll
    // semantics (e.g. "keep selected row visible" in a list view where ↑/↓
    // moves a cursor). In that mode we don't intercept keys at all — they
    // bubble up to the caller's own `onKeyPress` handlers. When the binding
    // is nil we handle arrows + paging ourselves (typical for an article
    // reader or any purely-scrollable region).

    public func handles(_ ch: Int32) -> Bool {
        guard externalOffset == nil else { return false }
        return ch == Int32(KEY_UP) || ch == Int32(KEY_DOWN)
            || ch == Int32(KEY_PPAGE) || ch == Int32(KEY_NPAGE)
            || ch == Int32(KEY_HOME) || ch == Int32(KEY_END)
    }

    public func handleKey(_ ch: Int32) -> Bool {
        guard externalOffset == nil else { return false }
        let cur = currentOffset
        let page = max(1, visibleHeight - 1)
        let maxOff = max(0, box.lastContentHeight - visibleHeight)
        switch ch {
        case Int32(KEY_UP):    setOffset(max(0, cur - 1))
        case Int32(KEY_DOWN):  setOffset(min(maxOff, cur + 1))
        case Int32(KEY_PPAGE): setOffset(max(0, cur - page))
        case Int32(KEY_NPAGE): setOffset(min(maxOff, cur + page))
        case Int32(KEY_HOME):  setOffset(0)
        case Int32(KEY_END):   setOffset(maxOff)
        default: return false
        }
        return true
    }

    // MARK: MouseHandling — wheel scrolls by a small step regardless of
    // whether an external offset binding is attached. Mouse events are
    // dispatched by frame hit-test, so the scrollable region under the
    // cursor owns the wheel; siblings don't argue.

    private static var wheelStep: Int { 3 }

    public func handles(_ event: MouseEvent) -> Bool {
        event.kind == .wheelUp || event.kind == .wheelDown
    }

    public func handleMouse(_ event: MouseEvent) -> Bool {
        let cur = currentOffset
        let maxOff = max(0, box.lastContentHeight - visibleHeight)
        switch event.kind {
        case .wheelUp:   setOffset(max(0, cur - Self.wheelStep))
        case .wheelDown: setOffset(min(maxOff, cur + Self.wheelStep))
        default: return false
        }
        return true
    }
}

public struct BoxView<Content: View>: View {
    public let title: String
    public var style: Style
    public var background: Color?
    public let content: Content
    public init(_ title: String, color: Color = .cyan, bold: Bool = false, inverted: Bool = false,
                background: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.style = Style(color: color, bold: bold, inverted: inverted)
        self.background = background
        self.content = content()
    }
    public var body: some View { content }

    public func draw(in rect: Rect) {
        guard rect.width >= 4, rect.height >= 3 else { return }
        if let bg = background {
            for row in 0..<rect.height {
                Term.fill(rect.y + row, rect.x, rect.width, color: bg)
            }
        }
        let label = " \(title) "
        let fill = max(0, rect.width - 4 - label.count)
        Term.put(rect.y, rect.x, "┌─" + label + String(repeating: "─", count: fill) + "─┐",
                 color: style.color, bold: style.bold, inverted: style.inverted)
        for row in 1..<(rect.height - 1) {
            Term.put(rect.y + row, rect.x, "│",
                     color: style.color, bold: style.bold, inverted: style.inverted)
            Term.put(rect.y + row, rect.x + rect.width - 1, "│",
                     color: style.color, bold: style.bold, inverted: style.inverted)
        }
        Term.put(rect.y + rect.height - 1, rect.x,
                 "└" + String(repeating: "─", count: rect.width - 2) + "┘",
                 color: style.color, bold: style.bold, inverted: style.inverted)
    }

    public func childRects(children: [ViewNode], in rect: Rect) -> [Rect] {
        // BoxView's @ViewBuilder content is often a TupleView (e.g.
        // `BoxView { Row; Sparkline; Row }`), and TupleView is TransparentView —
        // its elements are flattened to become BoxView's direct children. So
        // `children` may be 1 (single primitive content) or N (tuple content).
        // Stack them vertically inside the inset content rect; if we returned a
        // single rect, `zip(children, rects)` would silently drop everything
        // past index 0.
        guard !children.isEmpty else { return [] }
        let inner = rect.inset(dx: 2, dy: 1)
        var rects: [Rect] = []
        var y = inner.y
        for child in children {
            let s = child.measure(proposedWidth: inner.width)
            let h = max(0, min(s.height, inner.maxY - y))
            rects.append(Rect(x: inner.x, y: y, width: inner.width, height: h))
            y += s.height
        }
        return rects
    }

    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        // Same multi-child logic as childRects: sum heights, max widths.
        let innerW = max(0, proposedWidth - 4)
        var h = 0, w = 0
        for child in children {
            let s = child.measure(proposedWidth: innerW)
            h += s.height
            w = max(w, s.width)
        }
        return Size(width: w + 4, height: h + 2)
    }
}

// MARK: - ForEach (transparent)

public struct ForEach<Data: RandomAccessCollection, Content: View>: View, TransparentView {
    public typealias Body = Never
    public let data: Data
    public let content: (Data.Element) -> Content
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.content = content
    }
    public var body: Never { fatalError("ForEach has no body") }
    public var unpacked: [any View] {
        data.map { content($0) as any View }
    }
}

// MARK: - GridView

public struct GridView<Data: RandomAccessCollection, Cell: View>: View where Data.Index == Int {
    public let columns: Int
    public let cellWidth: Int
    public let cellHeight: Int
    public let gap: Int
    public let data: Data
    public let cell: (Data.Element) -> Cell
    public init(columns: Int, cellWidth: Int, cellHeight: Int, gap: Int = 2,
                data: Data, @ViewBuilder cell: @escaping (Data.Element) -> Cell) {
        self.columns = columns
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.gap = gap
        self.data = data
        self.cell = cell
    }
    // body produces a ForEach, which the framework flattens into individual cells.
    public var body: some View {
        ForEach(data, content: cell)
    }

    public func childRects(children: [any ViewNode], in rect: Rect) -> [Rect] {
        var rects: [Rect] = []
        for i in 0..<children.count {
            let col = i % columns
            let row = i / columns
            let x = rect.x + col * (cellWidth + gap)
            let y = rect.y + row * cellHeight
            if y + cellHeight > rect.maxY {
                rects.append(Rect(x: x, y: y, width: 0, height: 0))
            } else {
                rects.append(Rect(x: x, y: y, width: cellWidth, height: cellHeight))
            }
        }
        return rects
    }

    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        let rows = (children.count + columns - 1) / columns
        return Size(width: columns * cellWidth + max(0, (columns - 1) * gap),
                    height: rows * cellHeight)
    }
}

// MARK: - Environment

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues {
    public nonisolated(unsafe) static var _current = EnvironmentValues()
    private var storage: [ObjectIdentifier: Any] = [:]

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(key)] = newValue }
    }
}

@propertyWrapper
public struct Environment<Value> {
    public let keyPath: KeyPath<EnvironmentValues, Value>
    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }
    public var wrappedValue: Value { EnvironmentValues._current[keyPath: keyPath] }
}

public struct EnvironmentModifier<Content: View, V>: View, EnvironmentApplying {
    public let content: Content
    public let keyPath: WritableKeyPath<EnvironmentValues, V>
    public let value: V
    public var body: some View { content }
    public func applyEnvironment() {
        EnvironmentValues._current[keyPath: keyPath] = value
    }
}

public extension View {
    func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V)
        -> EnvironmentModifier<Self, V>
    {
        EnvironmentModifier(content: self, keyPath: keyPath, value: value)
    }

    func id(_ id: some CustomStringConvertible) -> IdModifier<Self> {
        IdModifier(content: self, id: id.description)
    }
}

public struct IdModifier<Content: View>: View {
    public let content: Content
    public let id: String
    public var body: some View { content }
}

// MARK: - @State (ephemeral wrapper, persistent @Observable Box)

@propertyWrapper
public struct State<V> {
    /// Nested @Observable class. Reads register with `withObservationTracking`,
    /// writes fire onChange — framework needs no wiring.
    @Observable
    public final class Box: @unchecked Sendable {
        public var value: V
        public init(_ v: V) {
            self.value = v
        }
    }

    public let _box: Box

    public init(wrappedValue: V) { self._box = Box(wrappedValue) }

    public var wrappedValue: V {
        get {
            _box.value
        }
        nonmutating set {
            // Log the WRITE (reads are too noisy — they happen every reconcile).
            // The before/after diff makes it easy to spot which @State changed
            // and correlate with the onChange callbacks that should follow.
            logger.debug("[@State.set] type=\(V.self) old=\(self._box.value) new=\(newValue)")
            _box.value = newValue
        }
    }

    public var projectedValue: Binding<V> {
        // Read `box.value` here so the access is visible to the
        // `withObservationTracking` block that's wrapping the current
        // body evaluation. Without this read, using `$foo` (which only
        // touches `projectedValue`, never `wrappedValue`) means the
        // observation tracker never registers on `foo` — so later writes
        // via the Binding.set closure mutate the @Observable box but no
        // observer fires, `markDirty` never runs, and the view never
        // redraws. This bit a real bug: wheel-scroll went through
        // `ScrollView(offset: $scrollOffset)` and updated the box but the
        // list stayed frozen.
        _ = _box.value
        let box = _box
        return Binding(
            get: {
                box.value
            },
            set: {
                logger.debug("[@State.set via Binding] type=\(V.self) old=\(box.value) new=\($0)")
                box.value = $0
            }
        )
    }
}

// MARK: - @Binding

@propertyWrapper
public struct Binding<V> {
    public let get: () -> V
    public let set: (V) -> Void

    public init(get: @escaping () -> V, set: @escaping (V) -> Void) {
        self.get = get
        self.set = set
    }

    public var wrappedValue: V {
        get { get() }
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<V> { self }

    /// Read-only binding with a fixed value. Mirrors SwiftUI's
    /// `Binding.constant`; useful as a default argument when a widget
    /// doesn't need a settable binding (e.g. "always focused" TextField).
    public static func constant(_ value: V) -> Binding<V> {
        Binding(get: { value }, set: { _ in })
    }
}

// MARK: - .onKeyPress modifier

public struct OnKeyPressModifier<Content: View>: View, KeyHandling {
    public let content: Content
    public let key: Int32
    public let handler: () -> Bool
    public var body: some View { content }
    public func handles(_ ch: Int32) -> Bool { ch == key }
    public func handleKey(_ ch: Int32) -> Bool {
        logger.debug("[onKeyPress] firing handler for key=\(self.key) on Content=\(Content.self)")
        return handler()
    }
}

public extension View {
    func onKeyPress(_ key: Int32, _ handler: @escaping () -> Void)
        -> OnKeyPressModifier<Self>
    {
        OnKeyPressModifier(content: self, key: key, handler: { handler(); return true })
    }
}

// MARK: - .background modifier

/// Fills the rect occupied by `content` with a solid color pair BEFORE the
/// content draws. Mirrors the shape of SwiftUI's `.background(_:)` for the
/// limited palette we have. Passing `nil` is a no-op, which lets callers
/// write `content.background(isSelected ? .selected : nil)` without a
/// conditional branch on the view type.
public struct BackgroundModifier<Content: View>: View, ContainerRendering {
    public let color: Color?
    public let content: Content
    public var body: some View { content }

    public func beforeChildren(children: [any ViewNode], in rect: Rect) {
        guard let color, rect.width > 0, rect.height > 0 else { return }
        for y in rect.y..<(rect.y + rect.height) {
            Term.fill(y, rect.x, rect.width, color: color)
        }
    }
}

public extension View {
    func background(_ color: Color?) -> BackgroundModifier<Self> {
        BackgroundModifier(color: color, content: self)
    }
}

// MARK: - .frame modifier
//
// Pins a view's measured width (and optionally height) to a fixed
// value, regardless of the child's natural size. Used to build
// flex-less layouts where the caller knows the exact widths each
// region should occupy — e.g. an IRC-style three-column layout where
// sidebars get fixed widths and the center pane gets the residual.
//
// The child is passed that pinned rect verbatim; inner content
// word-wraps / clips to it. Passing a width larger than the child's
// natural size leaves empty space at the right (same visual you'd
// get from a SwiftUI `.frame(width:, alignment: .leading)`).

public struct FrameModifier<Content: View>: View {
    public let content: Content
    public let width: Int?
    public let height: Int?
    public var body: some View { content }

    public func measure(children: [ViewNode], proposedWidth: Int) -> Size {
        // Child is our single mounted child. Ask it to measure at
        // our pinned width so it can word-wrap properly.
        let childProposed = width ?? proposedWidth
        let childSize = children.first?.measure(proposedWidth: childProposed)
            ?? Size(width: 0, height: 0)
        return Size(
            width: width ?? childSize.width,
            height: height ?? childSize.height)
    }

    public func childRects(children: [ViewNode], in rect: Rect) -> [Rect] {
        // Lay the child inside the pinned rect — its draw sees the
        // exact rect we advertise via measure.
        children.map { _ in rect }
    }
}

public extension View {
    /// Pin this view's measured width (and/or height) to a fixed value.
    /// Callers in flex-less contexts (NCursesUI's HStack / VStack) use
    /// this to reserve exact space — e.g. `sidebar.frame(width: 24)`
    /// in a 3-column layout.
    func frame(width: Int? = nil, height: Int? = nil) -> FrameModifier<Self> {
        FrameModifier(content: self, width: width, height: height)
    }
}

// MARK: - .onSubmit modifier

/// Fires `handler` when Enter (Return) is pressed and no inner view has
/// consumed it. Shaped to match SwiftUI's `.onSubmit { ... }` so the caller
/// reads the current selection / text from its own bindings rather than
/// receiving an item argument. Attach to a `List` or `TextField` subtree:
///
///     List(items, selection: $selected) { item, sel in ... }
///         .onSubmit {
///             if let id = selected, let item = items.first(where: { $0.id == id }) {
///                 // ...
///             }
///         }
public struct OnSubmitModifier<Content: View>: View, KeyHandling {
    public let content: Content
    public let handler: () -> Void
    /// When non-nil, the modifier only claims Enter while the binding
    /// reads `true`. Lets callers with Tab-cycled focus gate Enter to
    /// one region so keys bubble to sibling handlers otherwise. `nil`
    /// preserves the original always-claim behavior.
    public let isFocused: Binding<Bool>?

    public var body: some View { content }
    public func handles(_ ch: Int32) -> Bool {
        guard ch == 10 || ch == 13 else { return false }
        if let isFocused { return isFocused.wrappedValue }
        return true
    }
    public func handleKey(_ ch: Int32) -> Bool {
        handler()
        return true
    }
}

public extension View {
    func onSubmit(_ handler: @escaping () -> Void) -> OnSubmitModifier<Self> {
        OnSubmitModifier(content: self, handler: handler, isFocused: nil)
    }

    /// Focus-gated variant: `handles(Enter)` returns `true` only while
    /// `isFocused.wrappedValue` is `true`. Use when the parent view
    /// Tab-cycles between regions and each region owns its own Enter.
    func onSubmit(
        isFocused: Binding<Bool>,
        _ handler: @escaping () -> Void
    ) -> OnSubmitModifier<Self> {
        OnSubmitModifier(content: self, handler: handler, isFocused: isFocused)
    }
}

// MARK: - .task modifier

/// Persistent lifecycle handle for a `.task(id:)` modifier. Stored in an
/// `@State` box so it survives reconciles and is freed (along with the
/// running task) when the modifier's node is dropped by `matchChildren`.
final class TaskHost: @unchecked Sendable {
    @ObservationIgnored var currentId: AnyHashable? = nil
    @ObservationIgnored var task: Task<Void, Never>? = nil
    init() {}
    deinit { task?.cancel() }
}

public struct TaskModifier<Content: View>: View, ContainerRendering {
    public let content: Content
    public let id: AnyHashable
    public let priority: TaskPriority
    public let operation: @MainActor @Sendable () async -> Void
    @State var host: TaskHost = TaskHost()

    public var body: some View { content }

    public func beforeChildren(children: [any ViewNode], in rect: Rect) {
        guard host.currentId != id else { return }
        host.task?.cancel()
        host.currentId = id
        host.task = Task(priority: priority) { await operation() }
    }
}

public extension View {
    func task(
        id: some Hashable = 0,
        priority: TaskPriority = .userInitiated,
        _ operation: @MainActor @Sendable @escaping () async -> Void
    ) -> TaskModifier<Self> {
        TaskModifier(content: self, id: AnyHashable(id), priority: priority,
                     operation: operation)
    }
}

// MARK: - Screen environment key

private struct ScreenKey: EnvironmentKey {
    public static var defaultValue: WindowServer? { nil }
}

public extension EnvironmentValues {
    var screen: WindowServer? {
        get { self[ScreenKey.self] }
        set { self[ScreenKey.self] = newValue }
    }
}

// MARK: - App protocol

@MainActor public protocol App {
    associatedtype Body: Scene
    @MainActor @preconcurrency var body: Body { get }
    init()
}

public protocol Scene {
    @MainActor @preconcurrency func run()
}

public extension App {
    // Synchronous main — we own the main-thread loop and pump CFRunLoop
    // ourselves (via RunLoop.main.run in WindowServer.run) so MainActor tasks
    // and ncurses getch can both make progress. Using `async throws` here
    // would install Swift's `DispatchMainExecutor` on the main actor, and
    // that executor blocks in `mach_msg` waiting for Dispatch events — it
    // doesn't know to poll stdin, so our `getch` starves and keys get
    // queued in the kernel buffer until a Dispatch event happens to wake it.
    @MainActor
    static func main() {
        let app = Self.init()
        app.body.run()
    }
}

public protocol ViewNode: AnyObject {
    associatedtype V: View
    func draw(in rect: Rect)
    func measure(proposedWidth: Int) -> Size
    func dispatchKey(_ ch: Int32) -> Bool
    func dispatchMouse(_ event: MouseEvent) -> Bool
    func observeChildren()

    var view: V { get set }
    var frame: Rect { get }
    var dirty: Bool { get set }
    /// Walk-up access to the parent node, used by tests and key-routing helpers.
    /// Weak in concrete `Node`; existential here so any conformer fits.
    var parent: (any ViewNode)? { get }
}

extension ViewNode {
    func set(view: any View) {
        if let view = view as? V {
            self.view = view
        }
    }
}
// MARK: - Node (persistent, tree-structured)

// MARK: - Node (owns all tree operations)
//
// A Node represents one position in the live view tree. It holds the current
// view struct and its child nodes, and knows how to mount new subtrees,
// reconcile against fresh body output, draw itself, and dispatch keys.
// WindowServer only orchestrates the run loop — it does not touch the tree
// internals beyond holding the root and invoking Node's methods.

/// Shared (non-generic) state for the measure cache. Static fields on a
/// generic `Node<V>` would be per-specialisation, which defeats the
/// purpose of a global frame counter.
enum NodeLayout {
    nonisolated(unsafe) static var measureGeneration: Int = 0
}

public final class Node<V: View>: ViewNode, @unchecked Sendable {
    public weak var parent: (any ViewNode)?
    public weak var screen: WindowServer?
    package var children: [any ViewNode] = []
    public var view: V
    public var dirty: Bool = true
    public var frame: Rect = .zero
    /// Per-frame measure cache. Layout cascades call `child.measure(…)`
    /// from both `VStack.measure` and `VStack.childRects`, which each
    /// recurse through the whole subtree — for a 500-row list that
    /// blows up to 5k+ measure calls. The generation counter (see
    /// `NodeLayout._measureGeneration`) bumps once per draw pass so
    /// cached sizes remain valid within a frame and invalidate
    /// naturally at the next frame.
    private var _cachedSize: (generation: Int, width: Int, size: Size)?

    /// Stable, short identifier for this node — useful in logs to tell instances
    /// of the same view type apart. Hex of the ObjectIdentifier's hash.
    private var _id: String {
        let h = UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xFFFF
        return String(h, radix: 16)
    }
    private var _typeName: String { "\(type(of: view))" }
    private var _tag: String { "\(_typeName)#\(_id)" }

    /// Mount a view at this position — store it and leave children empty.
    /// We can't expand children here because `body` eval reads
    /// `@Query`/`@Snapshot` `.wrappedValue`, which are still bound to the
    /// fallback default Lattice (env modifiers above us install their real
    /// values during *draw*, not during mount). An early `.prefix(n)` or
    /// `.first` on a TableResults against the empty fallback traps with
    /// "no such table".
    ///
    /// The first `draw()` pass applies env → runs `updateDynamicProperties`
    /// (so wrappers re-bind to the real env) → runs `observeChildren`, which
    /// evaluates body with the correct data and mounts children via
    /// `matchChildren`. Each child repeats the same sequence on its own first
    /// draw — mount stays lazy all the way down.
    public init(view: V, parent: (any ViewNode)?, screen: WindowServer?) {
        self.view = view
        self.parent = parent
        self.screen = screen
        let parentTag = (parent as? Node)?._tag ?? "<root>"
        logger.debug("[mount] view=\(self._tag) parent=\(parentTag) (lazy — children built on first draw)")
        // `children` = []; `dirty` = true (property default). First draw fills in.
    }

    private func openViewToNode<C: View>(_ view: C) -> any ViewNode {
        Node<C>(view: view, parent: self, screen: screen)
    }
    /// Expand a view into the list of children the framework should treat as its
    /// subtree:
    ///   • Primitive: no children.
    ///   • Transparent: unpacked list, recursively flattened.
    ///   • Composite: body, flattened for transparent wrappers.
    private func expandChildren() -> [any View] {
        if view is any PrimitiveView {
            logger.debug("[expand] view=\(self._tag) kind=primitive children=0")
            return []
        }
        if let transparent = view as? any TransparentView {
            let result = transparent.unpacked.flatMap { flatten($0) }
            logger.debug("[expand] view=\(self._tag) kind=transparent children=\(result.count)")
            return result
        }
        let result = flatten(openBody(view))
        logger.debug("[expand] view=\(self._tag) kind=composite children=\(result.count)")
        return result
    }

    public func observeChildren() {
        logger.debug("[reconcile] view=\(self._tag) dirty_before=\(self.dirty)")
        let fresh = withObservationTracking {
            expandChildren()
        } onChange: { [weak self] in
            guard let self else { return }
            logger.debug("[onChange] tracker_fired view=\(self._tag)")
            // Observation's onChange fires synchronously during the @Observable's
            // willSet — the mutation hasn't landed yet. Calling observeChildren()
            // here would re-evaluate body against the STALE value, waste the work,
            // and clear the dirty bit before anything real happens. Only signal;
            // the next tick's draw() calls observeChildren() via its dirty gate,
            // by which point willSet has completed and the value is current.
            self.markDirty()
        }
        children = matchChildren(old: children, fresh: fresh)   // may mark children dirty
        dirty = false
        logger.debug("[reconcile] view=\(self._tag) done children=\(self.children.count)")
//        draw(in: frame)
    }

    public func markDirty() {
        guard !dirty else {
            logger.debug("[markDirty] view=\(self._tag) skip (already dirty)")
            return
        }
        logger.debug("[markDirty] view=\(self._tag) -> true (signaling pending work)")
        dirty = true
        // A dirtied subtree may render at a different size; invalidate
        // the measure cache so stale heights from prior frames don't
        // feed into layout.
        _cachedSize = nil
        screen?.setNeedsWork()
    }

    public func measure(proposedWidth: Int) -> Size {
        // Cache the result per frame. VStack.measure and VStack.childRects
        // both call `child.measure(proposedWidth:)`, and each call walks
        // the full descendant tree — for a 500-row news list this balloons
        // to 5000+ measure calls per draw. Caching by
        // (frame generation, proposedWidth) collapses the redundant
        // cascades back to one measure per node per frame. Invalidation
        // happens automatically: `markDirty` bumps the generation so a
        // dirtied subtree re-measures.
        if let cached = _cachedSize,
           cached.generation == NodeLayout.measureGeneration,
           cached.width == proposedWidth {
            logger.debug("[measure] view=\(self._tag) dirty=\(self.dirty) children=\(self.children.count) -> \(cached.size.width)x\(cached.size.height) (cached)")
            return cached.size
        }
        let savedEnv = EnvironmentValues._current
        defer { EnvironmentValues._current = savedEnv }
        if let applier = view as? any EnvironmentApplying {
            applier.applyEnvironment()
        }
        if dirty {
            updateDynamicProperties(of: view)
            observeChildren()
        }
        let size = view.measure(children: children, proposedWidth: proposedWidth)
        _cachedSize = (generation: NodeLayout.measureGeneration, width: proposedWidth, size: size)
        logger.debug("[measure] view=\(self._tag) dirty=\(self.dirty) children=\(self.children.count) -> \(size.width)x\(size.height)")
        return size
    }

    /// Invalidate this node's cached measure. Called by `markDirty` so a
    /// subtree that changes since last measure isn't served stale sizes.
    private func _invalidateMeasure() {
        _cachedSize = nil
    }

    /// Draw this node and recurse into children using the view's `childRects`.
    /// Apply env, update dynamic-property wrappers, and reconcile children.
    /// Lazy Node.init defers this; `mount` is the single realization step.
    /// Caller is responsible for saving/restoring `EnvironmentValues._current`
    /// — `draw(in:)` does that before calling mount, so child env overrides
    /// don't leak out of this subtree. Tests call mount directly inside a
    /// save/restore if they need env; with no env it's just a reconcile.
    public func mount() {
        if let applier = view as? any EnvironmentApplying {
            applier.applyEnvironment()
        }
        guard dirty else { return }
        logger.debug("[mount] view=\(self._tag) dirty=true -> reconcile")
        updateDynamicProperties(of: view)
        observeChildren()   // sets dirty = false
    }

    public func draw(in rect: Rect) {
        let savedEnv = EnvironmentValues._current
        defer { EnvironmentValues._current = savedEnv }
        mount()

        logger.debug("[draw] view=\(self._tag) rect=\(rect) children=\(self.children.count)")
        frame = rect

        view.draw(in: rect)
        // ContainerRendering lets a view wrap the child-iteration loop with
        // work that isn't expressible as "paint your own rect" — notably
        // ScrollView pushing a pad target, pulling it afterward, and
        // queuing a viewport blit. Default implementations are no-ops, so
        // views that don't opt in pay nothing.
        let container = view as? any ContainerRendering
        container?.beforeChildren(children: children, in: rect)
        let rects = view.childRects(children: children, in: rect)
        for (child, childRect) in zip(children, rects) {
            child.draw(in: childRect)
        }
        container?.afterChildren(children: children, in: rect)
    }

    /// Dispatch a key event depth-first, last-child-first. Returns true if
    /// consumed.
    public func dispatchKey(_ ch: Int32) -> Bool {
        for child in children.reversed() {
            if child.dispatchKey(ch) {
                logger.debug("[key] view=\(self._tag) ch=\(ch) consumed_by_child")
                return true
            }
        }
        if let handler = view as? any KeyHandling, handler.handles(ch) {
            logger.debug("[key] view=\(self._tag) ch=\(ch) HANDLED")
            return handler.handleKey(ch)
        }
        return false
    }

    /// Dispatch a mouse event via frame hit-test: recurse into children
    /// whose frame contains (y, x), innermost first, letting the event
    /// bubble back up. Two sibling ScrollViews scroll independently based
    /// on where the wheel event landed.
    public func dispatchMouse(_ event: MouseEvent) -> Bool {
        for child in children.reversed() {
            if child.frame.contains(y: event.y, x: event.x),
               child.dispatchMouse(event) {
                logger.debug("[mouse] view=\(self._tag) at=(\(event.y),\(event.x)) consumed_by_child")
                return true
            }
        }
        if let handler = view as? any MouseHandling, handler.handles(event) {
            logger.debug("[mouse] view=\(self._tag) at=(\(event.y),\(event.x)) kind=\(event.kind) HANDLED")
            return handler.handleMouse(event)
        }
        return false
    }

    /// Reconcile fresh child view structs against existing child nodes:
    ///   • same position + same type → reuse node, merge wrappers,
    ///     mark dirty if non-wrapper fields differ.
    ///   • otherwise → mount a fresh subtree.
    /// Extra old nodes beyond `fresh.count` are dropped (freed by ARC).
    private func matchChildren(old: [any ViewNode], fresh: [any View]) -> [any ViewNode] {
        if old.count != fresh.count {
            logger.debug("[match] parent=\(self._tag) old=\(old.count) fresh=\(fresh.count) (size differs)")
        }
        var result: [any ViewNode] = []
        for var (i, freshView) in fresh.enumerated() {
            if i < old.count, type(of: old[i].view) == type(of: freshView) {
                var oldNode = old[i]
                let differs = !viewsEqualIgnoringState(oldNode.view, freshView)
                freshView._mergeWrappers(from: oldNode.view)
                oldNode.set(view: freshView)
                if differs {
                    logger.debug("[match] parent=\(self._tag) pos=\(i) type=\(type(of: freshView)) REUSE+DIRTY")
                    oldNode.dirty = true
                    // Don't recurse into the child's observeChildren() here —
                    // draw()'s dirty gate will do it once, lazily, right before
                    // this child is drawn. Running it eagerly here duplicates
                    // the work and happens *outside* the upcoming draw recursion,
                    // where the child's env/context may not yet be correct.
                } else {
                    logger.debug("[match] parent=\(self._tag) pos=\(i) type=\(type(of: freshView)) REUSE_CLEAN")
                }
                result.append(oldNode)
            } else {
                let kind = i < old.count ? "REPLACE(type_changed)" : "MOUNT(new)"
                logger.debug("[match] parent=\(self._tag) pos=\(i) type=\(type(of: freshView)) \(kind)")
                result.append(openViewToNode(freshView))
            }
        }
        return result
    }
}

extension Rect {
    public func contains(y: Int, x: Int) -> Bool {
        y >= self.y && y < self.y + self.height
            && x >= self.x && x < self.x + self.width
    }
}

// MARK: - File-scope tree helpers
//
// These are free functions, not methods on WindowServer or Node, because they
// operate on views rather than tree state. They are `private` to the
// framework — not part of NCursesUI's public surface.

/// Call `update()` on every DynamicProperty wrapper inside a view struct.
private func updateDynamicProperties(of view: any View) {
    for child in Mirror(reflecting: view).children {
        if let dp = child.value as? any DynamicProperty { dp.update() }
    }
}

private func flatten(_ view: any View) -> [any View] {
    if let transparent = view as? any TransparentView {
        return transparent.unpacked.flatMap { flatten($0) }
    }
    return [view]
}

/// Opens an `any View` existential so we can call `.body` generically.
private func openBody<V: View>(_ view: V) -> any View { view.body }

/// Compare two view structs by value, skipping @State/@Query/@Binding fields
/// (names starting with "_"). Closures are considered unequal because they may
/// capture mutable state invisible to reflection.
private func viewsEqualIgnoringState(_ a: any View, _ b: any View) -> Bool {
    let ma = Mirror(reflecting: a)
    let mb = Mirror(reflecting: b)
    let aChildren = Array(ma.children)
    let bChildren = Array(mb.children)
    guard aChildren.count == bChildren.count else { return false }
    for (ac, bc) in zip(aChildren, bChildren) {
        if ac.label != bc.label { return false }
        if ac.label?.hasPrefix("_") == true { continue }
        if !valuesEqual(ac.value, bc.value) { return false }
    }
    return true
}

private func valuesEqual(_ a: Any, _ b: Any) -> Bool {
    let typeA = type(of: a)
    if "\(typeA)".contains("->") { return false }

    // Identifiable first — the canonical "same logical entity" check. Lattice
    // materialises a fresh Swift wrapper per query iteration for the same row,
    // so reference identity is unreliable and non-Identifiable Equatable would
    // also fail for class rows. Comparing by .id handles both classes and structs
    // uniformly (many value types are Identifiable too).
    if let ia = a as? any Identifiable {
        return anyIdentifiableEqual(ia, b)
    }
    // Class identity fast path for non-Identifiable class values.
    if type(of: a) is AnyClass {
        if let aObj = a as AnyObject?, let bObj = b as AnyObject? {
            return aObj === bObj
        }
    }
    if let eq = (a as? any Equatable) {
        return anyEquatableEqual(eq, b)
    }
    let ma = Mirror(reflecting: a)
    let mb = Mirror(reflecting: b)
    if ma.children.count == 0 && mb.children.count == 0 {
        return type(of: a) == type(of: b)
    }
    let aChildren = Array(ma.children)
    let bChildren = Array(mb.children)
    guard aChildren.count == bChildren.count else { return false }
    for (ac, bc) in zip(aChildren, bChildren) {
        if !valuesEqual(ac.value, bc.value) { return false }
    }
    return true
}

private func anyEquatableEqual<T: Equatable>(_ a: T, _ b: Any) -> Bool {
    guard let bT = b as? T else { return false }
    return a == bT
}

/// Open the `any Identifiable` existential to compare by `id`. Both sides must
/// have the same concrete Identifiable type; otherwise they can't be equal.
private func anyIdentifiableEqual<T: Identifiable>(_ a: T, _ b: Any) -> Bool {
    guard let bT = b as? T else { return false }
    return a.id == bT.id
}

// MARK: - WindowServer (run loop + root container)

public final class WindowServer: @unchecked Sendable, Scene {
    private var rootNode: ViewNode?
//    private let makeRootView: () -> any View
    private var hasPendingWork = true
    public var shouldExit = false
    /// Monotonic counter to tag each tick in logs — useful for correlating
    /// "key press at tick N → reconcile at tick N+1 → draw at tick N+1".
    private var _tick: UInt64 = 0

    public init(@ViewBuilder _ rootView: @escaping () -> some View) {
        Term.setup()
        logger.debug("[WindowServer.init] Term.setup done cols=\(Term.cols) rows=\(Term.rows)")
        rootNode = Node(view: rootView(), parent: nil, screen: self)
        logger.debug("[WindowServer.init] root mounted, performing initial draw")
        rootNode?.draw(in: Rect(x: 0, y: 0, width: Term.cols, height: Term.rows))
    }

    public func setNeedsWork() {
        if !hasPendingWork {
            logger.debug("[WindowServer.setNeedsWork] hasPendingWork: false -> true")
        }
        hasPendingWork = true
    }

    /// Back-compat name; any caller can signal "something changed, please re-render".
    public func setNeedsDraw(file: String = #file, function: String = #function, line: Int = #line) {
        if !hasPendingWork {
            logger.debug("[WindowServer.setNeedsDraw] called from \((file as NSString).lastPathComponent):\(line)")
        }
        hasPendingWork = true
    }

    public func run() {
        defer { Term.teardown() }
        signal(SIGINT,  { _ in endwin(); exit(0) })
        signal(SIGTERM, { _ in endwin(); exit(0) })

        EnvironmentValues._current.screen = self
        logger.debug("[WindowServer.run] entering main loop")

        while !shouldExit {
            // Drain MainActor / Dispatch.main work queued since the last tick.
            // Our loop is synchronous and blocks in `getch`; without this pump,
            // MainActor-isolated tasks (e.g. `Task { @MainActor in … }` from
            // @Snapshot's write-back or Lattice observe callbacks) sit in the
            // queue forever. `before:` in the past means RunLoop returns as
            // soon as the queue is empty — no extra blocking.
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0))
            _tick &+= 1
            if hasPendingWork, let root = rootNode {
                NodeLayout.measureGeneration &+= 1
                let tStart = DispatchTime.now()
                logger.debug("[tick \(self._tick)] BEGIN draw_pass cols=\(Term.cols) rows=\(Term.rows)")
                let saved = EnvironmentValues._current
                EnvironmentValues._current.screen = self
                Term.clear()
                let tAfterClear = DispatchTime.now()
                root.draw(in: Rect(x: 0, y: 0, width: Term.cols, height: Term.rows))
                let tAfterDraw = DispatchTime.now()
                root.observeChildren()
                let tAfterReconcile = DispatchTime.now()
                EnvironmentValues._current = saved
                Term.refresh()
                let tAfterRefresh = DispatchTime.now()
                hasPendingWork = false
                // Sub-ms frame timing — each step separately so we can see
                // which phase is eating the seconds of lag reported during
                // scroll. logger.debug's Date() serialization only gives
                // second-level precision, so the ms breakdown goes in this
                // single extra log line per frame.
                let msDraw = Double(tAfterDraw.uptimeNanoseconds - tAfterClear.uptimeNanoseconds) / 1_000_000
                let msRecon = Double(tAfterReconcile.uptimeNanoseconds - tAfterDraw.uptimeNanoseconds) / 1_000_000
                let msRefresh = Double(tAfterRefresh.uptimeNanoseconds - tAfterReconcile.uptimeNanoseconds) / 1_000_000
                let msTotal = Double(tAfterRefresh.uptimeNanoseconds - tStart.uptimeNanoseconds) / 1_000_000
                logger.debug("[tick \(self._tick)] END draw_pass total=\(String(format: "%.1f", msTotal))ms draw=\(String(format: "%.1f", msDraw)) reconcile=\(String(format: "%.1f", msRecon)) refresh=\(String(format: "%.1f", msRefresh))")
            }
            // Drain ALL pending input before looping back to draw. Without
            // this, the loop does draw → read-1-event → draw → read → …,
            // so every wheel tick triggers its own full redraw. Draining
            // coalesces a burst (e.g. 30 wheel events/sec) into a single
            // redraw per frame.
            //
            // First read uses the normal 16ms timeout so we idle-pace;
            // subsequent reads use a zero-ms timeout to return `.none`
            // immediately when the kernel buffer is empty.
            if let root = rootNode {
                let first = Term.nextEvent()          // 16ms idle pacing
                if case .none = first {} else {
                    dispatchEvent(first, to: root)
                    var drained = 0
                    while drained < 32 {
                        let more = Term.nextEvent(timeoutMs: 0)
                        if case .none = more { break }
                        dispatchEvent(more, to: root)
                        drained += 1
                    }
                }
            }
        }
        logger.debug("[WindowServer.run] exiting main loop (shouldExit=true)")
    }

    private func dispatchEvent(_ event: TermEvent, to root: any ViewNode) {
        switch event {
        case .none:
            break
        case .key(let ch):
            logger.debug("[tick \(self._tick)] KEY received ch=\(ch)")
            // ncurses delivers KEY_RESIZE via getch when SIGWINCH fires
            // and keypad is enabled. View bodies read Term.cols/rows
            // outside any withObservationTracking, so nothing else marks
            // the tree dirty — handle it at the framework level.
            if ch == KEY_RESIZE {
                logger.debug("[tick \(self._tick)] KEY_RESIZE -> markDirty(root) cols=\(Term.cols) rows=\(Term.rows)")
                root.dirty = true
                self.hasPendingWork = true
            }
            let handled = root.dispatchKey(ch)
            logger.debug("[tick \(self._tick)] KEY dispatch done handled=\(handled) pending_after=\(self.hasPendingWork)")
        case .mouse(let mev):
            logger.debug("[tick \(self._tick)] MOUSE received at=(\(mev.y),\(mev.x)) kind=\(mev.kind)")
            let handled = root.dispatchMouse(mev)
            logger.debug("[tick \(self._tick)] MOUSE dispatch done handled=\(handled) pending_after=\(self.hasPendingWork)")
        }
    }
}

