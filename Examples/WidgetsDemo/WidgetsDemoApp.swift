import NCursesUI

/// Minimal demo exercising the NCursesUI widgets added in P1:
///   • Text + Text concatenation with per-run styling
///   • Expanded 9-color palette
///   • TextField (input line editor)
///   • List<Item> (arrow-nav selection)
///   • Overlay (libpanel modal with optional dim-background)
///
/// Controls: Tab cycles focus between the input field and the list; typing
/// fills the input; ↑/↓ moves list selection; Enter on the list prints
/// "activated: <id>" into the input field (visible evidence the callback
/// fired); `o` toggles the overlay; ESC dismisses the overlay; `q` quits.
struct Fruit: Identifiable {
    let id: String
    let name: String
}

struct DemoRoot: View {
    @Environment(\.screen) var screen

    @State var inputText: String = ""
    @State var selected: String? = "banana"
    @State var overlayOpen: Bool = false
    @State var overlayPick: String? = "apple"
    @State var focus: Focus = .input

    enum Focus { case input, list }

    let fruits: [Fruit] = [
        Fruit(id: "apple",  name: "apple"),
        Fruit(id: "banana", name: "banana"),
        Fruit(id: "cherry", name: "cherry"),
        Fruit(id: "durian", name: "durian"),
    ]

    var body: some View {
        VStack(spacing: 1) {
            // Title
            Text("NCursesUI widgets demo").foregroundColor(.cyan).bold()

            // Palette row — 9 colors, bold variant.
            (Text("palette: ").foregroundColor(.dim)
             + Text("red ").foregroundColor(.red)
             + Text("green ").foregroundColor(.green)
             + Text("yellow ").foregroundColor(.yellow)
             + Text("blue ").foregroundColor(.blue)
             + Text("magenta ").foregroundColor(.magenta)
             + Text("cyan ").foregroundColor(.cyan)
             + Text("white ").foregroundColor(.white)
             + Text("dim ").foregroundColor(.dim)
             + Text("[bold]").foregroundColor(.green).bold())

            // Multi-run Text — dim timestamp + colored nick + default body.
            (Text("14:03 ").foregroundColor(.dim)
             + Text("<alice> ").foregroundColor(.green).bold()
             + Text("hello world"))

            // Input — TextField, always focused when focus == .input.
            (Text("> ").foregroundColor(.dim)
             + Text(focus == .input ? "(focused)" : "(press Tab)").foregroundColor(.dim))
            TextField(
                "type here…",
                text: $inputText,
                isFocused: Binding(
                    get: { focus == .input },
                    set: { if $0 { focus = .input } }
                ),
                onSubmit: { inputText = "" }
            )

            // List — focused when focus == .list.
            Text("list (↑/↓ to move, Enter activates):").foregroundColor(.dim)
            List(
                fruits,
                selection: $selected,
                isFocused: Binding(
                    get: { focus == .list },
                    set: { if $0 { focus = .list } }
                )
            ) { item, isSelected in
                Text((isSelected ? "▸ " : "  ") + item.name)
                    .foregroundColor(isSelected ? .selected : .dim)
                    .background(isSelected ? .selected : nil)
            }
            .onSubmit {
                if let id = selected,
                   let item = fruits.first(where: { $0.id == id }) {
                    inputText = "activated: \(item.id)"
                }
            }

            // Hints
            Text("tab: switch focus  •  o: overlay  •  q: quit").foregroundColor(.dim)
        }
        .onKeyPress(Int32(UInt8(ascii: "\t"))) {
            focus = (focus == .input) ? .list : .input
        }
        .onKeyPress(Int32(UInt8(ascii: "o"))) {
            overlayOpen = true
        }
        .onKeyPress(Int32(UInt8(ascii: "q"))) {
            screen?.shouldExit = true
        }
        .overlay(isPresented: $overlayOpen, dimsBackground: true) {
            BoxView("pick a fruit", color: .cyan) {
                VStack(spacing: 0) {
                    // List-inside-Overlay demonstrates that keyboard routing
                    // works through libpanel: arrow keys land on this List
                    // (deepest child of the overlay panel, first in the
                    // reversed dispatch traversal) rather than the base
                    // List under the dimmed background.
                    List(fruits, selection: $overlayPick) { item, isSelected in
                        Text((isSelected ? "▸ " : "  ") + item.name)
                            .foregroundColor(isSelected ? .selected : .dim)
                            .background(isSelected ? .selected : nil)
                    }
                    .onSubmit {
                        if let id = overlayPick,
                           let item = fruits.first(where: { $0.id == id }) {
                            inputText = "picked: \(item.id)"
                            overlayOpen = false
                        }
                    }
                    Text("")
                    Text("↵ pick  •  ⎋ cancel").foregroundColor(.dim)
                }
            }
            .onKeyPress(27) {
                overlayOpen = false
            }
        }
    }
}

@main
struct WidgetsDemoApp: App {
    var body: some Scene {
        WindowServer {
            DemoRoot()
        }
    }
}
