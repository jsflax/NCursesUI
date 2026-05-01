import Foundation

/// Marker protocol for views that can take focus from the NCUITest probe.
/// Conforming views expose a write path to their `isFocused` binding (or
/// equivalent state) that doesn't require key navigation.
///
/// Built-in conformances: `TextField`, `List`. Apps can conform their own
/// focusable views to make them probe-focusable too.
@MainActor
public protocol ProbeFocusable {
    /// Set the focus state. Returns `true` if the view took focus, `false`
    /// if the view is in a state that prohibits it (e.g. disabled).
    /// Implementations typically write through their `isFocused` binding.
    func _probeSetFocused(_ value: Bool) -> Bool
}

extension TextField: ProbeFocusable {
    public func _probeSetFocused(_ value: Bool) -> Bool {
        // `@Binding` exposes a wrappedValue with `nonmutating set`, so the
        // assignment writes through to the parent's @State without needing
        // a mutable receiver.
        var copy = self
        copy.isFocused = value
        return true
    }
}

extension List: ProbeFocusable {
    public func _probeSetFocused(_ value: Bool) -> Bool {
        var copy = self
        copy.isFocused = value
        return true
    }
}
