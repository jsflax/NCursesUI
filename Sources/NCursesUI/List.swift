import Foundation
import Cncurses

/// Vertical list of items with keyboard-driven single selection.
///
/// Mirrors SwiftUI's `List(_, selection:)` shape, with one deliberate
/// departure: the row closure receives an `isSelected` Bool so the caller
/// styles the selected row explicitly (terminals can't paint a highlight
/// bar behind content the way AppKit does). Typical usage:
///
///     List(items, selection: $selected) { item, isSelected in
///         Text("\(isSelected ? "▸" : " ") \(item.name)").reverse(isSelected)
///     }
///     .onSubmit { … act on `selected` … }
///
/// Keys: ↑/↓ step, Home/End jump. ESC, Tab, and Enter bubble up — wrap
/// with `.onSubmit { ... }` to react to Enter; the overlay / focus
/// coordinator can claim the others.
public struct List<Item: Identifiable, Row: View>: View, KeyHandling {
    public let items: [Item]
    @Binding public var selection: Item.ID?
    @Binding public var isFocused: Bool
    public let rowContent: (Item, Bool) -> Row

    public init(_ items: [Item],
                selection: Binding<Item.ID?>,
                isFocused: Binding<Bool> = .constant(true),
                @ViewBuilder rowContent: @escaping (Item, Bool) -> Row) {
        self.items = items
        self._selection = selection
        self._isFocused = isFocused
        self.rowContent = rowContent
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                rowContent(item, item.id == selection)
            }
        }
    }

    // MARK: KeyHandling

    public func handles(_ ch: Int32) -> Bool {
        guard isFocused else { return false }
        switch ch {
        case Int32(KEY_UP), Int32(KEY_DOWN),
             Int32(KEY_HOME), Int32(KEY_END):
            return true
        default:
            return false
        }
    }

    public func handleKey(_ ch: Int32) -> Bool {
        guard isFocused else { return false }
        guard !items.isEmpty else { return true }

        let currentIndex = selection.flatMap { id in
            items.firstIndex { $0.id == id }
        }

        switch ch {
        case Int32(KEY_UP):
            // Clamp at top — wrapping surprises users mid-scroll.
            if let i = currentIndex {
                if i > 0 { selection = items[i - 1].id }
            } else {
                // From "no selection", up enters from the bottom.
                selection = items.last?.id
            }
            return true

        case Int32(KEY_DOWN):
            if let i = currentIndex {
                if i < items.count - 1 { selection = items[i + 1].id }
            } else {
                selection = items.first?.id
            }
            return true

        case Int32(KEY_HOME):
            selection = items.first?.id
            return true

        case Int32(KEY_END):
            selection = items.last?.id
            return true

        default:
            return false
        }
    }
}
