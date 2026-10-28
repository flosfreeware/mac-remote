// Own exactly one hide-count increment. Repeated lifecycle notifications must
// never accumulate hides, and showing must not undo another app's hide count.
struct CursorVisibilityState {
    private(set) var hidden = false

    @discardableResult
    mutating func setHidden(_ hidden: Bool, apply: (Bool) -> Bool) -> Bool {
        guard self.hidden != hidden else { return true }
        guard apply(hidden) else { return false }
        self.hidden = hidden
        return true
    }
}
