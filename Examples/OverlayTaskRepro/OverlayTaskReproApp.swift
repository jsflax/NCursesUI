import NCursesUI

/// Minimal repro of a bug seen in ClaudeCodeIRC's RoomView: attaching
/// `.overlay(isPresented:)` to a VStack that contains a ScrollView +
/// ForEach + TextField never renders the overlay, even with a plain
/// `@State` binding initialized to `true` — same pattern that works in
/// the simpler `WidgetsDemo` DemoRoot.
///
/// Press `q` to quit. On mount, overlay should appear red. If it
/// doesn't, this reproduces the bug.
struct ReproRoot: View {
    @Environment(\.screen) var screen

    /// Initialized to `true` — overlay should appear immediately on
    /// mount with no user interaction. If it does, the rest of the
    /// structure is innocent and we need a different scenario.
    @State var flag: Bool = true
    @State var draft: String = ""

    let rows: [String] = (1...30).map { "row \($0)" }

    var body: some View {
        VStack {
            Text("overlay repro — flag=\(flag ? "true" : "false")")
                .foregroundColor(.cyan).bold()
            HLineView()
            ScrollView(height: 10) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack {
                            Text("•").foregroundColor(.dim)
                            Text(" \(row)")
                        }
                    }
                }
            }
            HLineView()
            HStack {
                Text("input> ").foregroundColor(.cyan)
                TextField("type…", text: $draft)
            }
        }
        .onKeyPress(Int32(UInt8(ascii: "q"))) {
            screen?.shouldExit = true
        }
        .onKeyPress(Int32(UInt8(ascii: "t"))) {
            flag.toggle()
        }
        .overlay(isPresented: $flag, dimsBackground: true) {
            BoxView("DEBUG overlay", color: .red) {
                Text("hello from the overlay").foregroundColor(.white)
            }
            .onKeyPress(27) { flag = false }
        }
    }
}

@main
struct OverlayTaskReproApp: App {
    var body: some Scene {
        WindowServer {
            ReproRoot()
        }
    }
}
