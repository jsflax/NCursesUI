import Foundation
import Cncurses

// MARK: - OverlayWindowState (internal)

/// Owns the ncurses WINDOW + libpanel PANEL backing an active overlay. Lives
/// in an `@State` box on `OverlayWindowLayer` so it survives reconciles and
/// is torn down when the overlay hides or the subtree is dropped.
@Observable
final class OverlayWindowState: @unchecked Sendable {
    // WINDOW is opaque in <curses.h> (forward-declared), so it imports to
    // Swift as OpaquePointer. PANEL is a concrete struct in <panel.h> and
    // imports as UnsafeMutablePointer<PANEL>.
    @ObservationIgnored var window: OpaquePointer?
    @ObservationIgnored var panel: UnsafeMutablePointer<PANEL>?
    @ObservationIgnored var currentRect: Rect = .zero

    init() {}

    deinit {
        if let p = panel { _ = tui_del_panel(p) }
        if let w = window { _ = tui_delwin(w) }
    }

    /// Ensure the window+panel exist and match the requested rect. ncurses
    /// has no "in-place move+resize" primitive, so a size change tears down
    /// and recreates the window (and the panel it backs).
    func ensureWindow(at rect: Rect) -> OpaquePointer? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        if window == nil {
            guard let w = tui_newwin(Int32(rect.height),
                                     Int32(rect.width),
                                     Int32(rect.y),
                                     Int32(rect.x)) else { return nil }
            window = w
            panel = tui_new_panel(w)
            currentRect = rect
            return w
        }
        if rect != currentRect {
            if let p = panel { _ = tui_del_panel(p); panel = nil }
            if let w = window { _ = tui_delwin(w); window = nil }
            guard let w = tui_newwin(Int32(rect.height),
                                     Int32(rect.width),
                                     Int32(rect.y),
                                     Int32(rect.x)) else { return nil }
            window = w
            panel = tui_new_panel(w)
            currentRect = rect
        }
        return window
    }
}

// MARK: - OverlayWindowLayer (internal)

/// The child that wraps a user-supplied overlay content view. Switches the
/// ncurses draw target to a panel-backed window around its content, so the
/// content is drawn into the overlay rather than stdscr. `update_panels()`
/// (called by `Term.flush()`) puts the result on top of the base UI.
///
/// Not exposed publicly — users apply `.overlay(isPresented:…)` instead.
struct OverlayWindowLayer<Content: View>: View, ContainerRendering {
    let content: Content
    let dimsBackground: Bool
    @State var state: OverlayWindowState = OverlayWindowState()

    var body: some View { content }

    func measure(children: [any ViewNode], proposedWidth: Int) -> Size {
        // The layer sizes to its content; the owning OverlayModifier
        // positions that size centered on screen.
        children.first?.measure(proposedWidth: proposedWidth) ?? .zero
    }

    func childRects(children: [any ViewNode], in rect: Rect) -> [Rect] {
        // Children draw in WINDOW-LOCAL coords: (0, 0) is the top-left of
        // the overlay's own window, not stdscr.
        [Rect(x: 0, y: 0, width: rect.width, height: rect.height)]
    }

    func beforeChildren(children: [any ViewNode], in rect: Rect) {
        guard let w = state.ensureWindow(at: rect) else { return }
        _ = tui_werase(w)
        Term.pushTarget(w)
    }

    func afterChildren(children: [any ViewNode], in rect: Rect) {
        guard state.window != nil else { return }
        Term.popTarget()
        // Do NOT call wnoutrefresh(w) — update_panels (in Term.flush) both
        // stages this panel's window and handles z-ordering against stdscr.
        // Manual refreshes here corrupt the touch map.
        if dimsBackground {
            applyDimBackground(overlayRect: rect)
        }
    }

    /// Walk stdscr cells outside the overlay rect and OR `A_DIM` into their
    /// attributes without overwriting the underlying characters. With the
    /// overlay panel on top, this produces a visibly darker background.
    private func applyDimBackground(overlayRect rect: Rect) {
        let rows = Int32(Term.rows), cols = Int32(Term.cols)
        let dimAttr = tui_a_dim()
        let stdscr = tui_stdscr()
        let rx = Int32(rect.x)
        let ry = Int32(rect.y)
        let rw = Int32(rect.width)
        let rh = Int32(rect.height)

        // Rows above.
        if ry > 0 {
            for y in 0..<ry {
                _ = tui_mvwchgat(stdscr, y, 0, cols, dimAttr, 0)
            }
        }
        // Rows below.
        let belowStart = ry + rh
        if belowStart < rows {
            for y in belowStart..<rows {
                _ = tui_mvwchgat(stdscr, y, 0, cols, dimAttr, 0)
            }
        }
        // Left + right sidebars on overlay rows.
        for y in ry..<min(ry + rh, rows) {
            if rx > 0 {
                _ = tui_mvwchgat(stdscr, y, 0, rx, dimAttr, 0)
            }
            let rightStart = rx + rw
            if rightStart < cols {
                _ = tui_mvwchgat(stdscr, y, rightStart, cols - rightStart, dimAttr, 0)
            }
        }
    }
}

// MARK: - OverlayModifier (public)

/// Content wrapper returned by `.overlay(isPresented:…)`. Lays out its base
/// across the full rect and, when presented, overlays a centered content
/// box on top via libpanel. Overlay rect size is measured from the content.
public struct OverlayModifier<Base: View, Content: View>: View, ContainerRendering {
    public let base: Base
    public let overlayContent: () -> Content
    public let isPresented: Binding<Bool>
    public let dimsBackground: Bool

    public init(base: Base,
                isPresented: Binding<Bool>,
                dimsBackground: Bool,
                @ViewBuilder content: @escaping () -> Content) {
        self.base = base
        self.overlayContent = content
        self.isPresented = isPresented
        self.dimsBackground = dimsBackground
    }

    public var body: some View {
        if isPresented.wrappedValue {
            TupleView(base, OverlayWindowLayer(
                content: overlayContent(),
                dimsBackground: dimsBackground))
        } else {
            TupleView(base)
        }
    }

    public func childRects(children: [any ViewNode], in rect: Rect) -> [Rect] {
        // Base fills the rect; overlay is centered at its measured size,
        // clamped inside the rect with a small margin.
        guard children.count > 1 else {
            return [rect]
        }
        let overlaySize = children[1].measure(proposedWidth: max(1, rect.width - 4))
        let w = min(overlaySize.width, max(1, rect.width - 4))
        let h = min(overlaySize.height, max(1, rect.height - 2))
        let x = rect.x + max(0, (rect.width - w) / 2)
        let y = rect.y + max(0, (rect.height - h) / 2)
        return [rect, Rect(x: x, y: y, width: w, height: h)]
    }
}

public extension View {
    /// Present `content` as a modal overlay while `isPresented` is true.
    /// The overlay is a libpanel-backed window stacked on top of the base
    /// UI; when `dimsBackground` is true, cells outside the overlay rect
    /// are drawn with `A_DIM` so focus shifts to the modal.
    ///
    /// Key routing: while the overlay is visible, it sits last in the tree
    /// and therefore gets first-dibs dispatch for key events. Overlay
    /// content is responsible for handling its own dismiss key (ESC, etc.)
    /// and clearing `isPresented`.
    func overlay<Content: View>(
        isPresented: Binding<Bool>,
        dimsBackground: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) -> OverlayModifier<Self, Content> {
        OverlayModifier(
            base: self,
            isPresented: isPresented,
            dimsBackground: dimsBackground,
            content: content
        )
    }
}
