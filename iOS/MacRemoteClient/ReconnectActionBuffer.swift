import Foundation

// A fresh ready token is required on every foreground resume, even if SwiftUI
// coalesces the intermediate searching/connected status changes into one frame.
struct RemoteControlReadiness {
    private(set) var foreground = false
    private(set) var ready = false

    mutating func resume() { foreground = true; ready = false }
    mutating func suspend() { foreground = false; ready = false }
    mutating func disconnect() { ready = false }
    mutating func confirm() -> UUID? {
        guard foreground, !ready else { return nil }
        ready = true
        return UUID()
    }
}

// Keep the background/app-switcher presentation optimistic. Network callbacks
// while suspended must not leave an error frame waiting for the next launch.
struct ReconnectPresentationState {
    private(set) var graceActive = true
    private(set) var showHelp = false
    private(set) var generation = UUID()
    private var foreground = false

    mutating func resume() -> UUID {
        generation = UUID()
        foreground = true
        graceActive = true
        showHelp = false
        return generation
    }

    mutating func suspend() {
        generation = UUID()
        foreground = false
        graceActive = true
        showHelp = false
    }

    mutating func connectionChanged(connected: Bool) {
        guard foreground else { return }
        if connected { graceActive = false; showHelp = false }
        else if !graceActive { showHelp = true }
    }

    mutating func expire(generation: UUID, connected: Bool) {
        guard foreground, self.generation == generation, !connected else { return }
        graceActive = false
        showHelp = true
    }
}

// One short foreground-only window. Never replay stale actions after a failed
// reconnect, on another foreground session, or more than once.
struct ReconnectActionBuffer<Action> {
    static var graceDuration: Double { 1.0 }
    private(set) var deadline: Double?
    private var actions: [Action] = []
    private let capacity = 128

    static func accepts(messageType: String) -> Bool {
        ["click", "scroll", "media", "shortcut", "fullscreen", "open_safari", "open_spotify", "sleep",
         "input_insert", "input_backspace", "input_delete", "input_return"].contains(messageType)
    }

    mutating func begin(now: Double) {
        actions.removeAll(); deadline = now + Self.graceDuration
    }
    @discardableResult
    mutating func enqueue(_ action: Action, now: Double) -> Bool {
        guard let deadline, now < deadline, actions.count < capacity else { return false }
        actions.append(action); return true
    }
    mutating func drain(now: Double) -> [Action] {
        let result = deadline.map { now < $0 ? actions : [] } ?? []
        cancel()
        return result
    }
    mutating func cancel() { actions.removeAll(); deadline = nil }
}
