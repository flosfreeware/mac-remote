import Foundation

// One classifier owns each touch; a failed hold can never swallow a quick tap.
struct TouchSurfaceState {
    enum Action: Equatable {
        case tap, hold(Bool), scroll(Double), scrollEnd, cancelScroll
        case swipeLeft, swipeRight
    }
    private enum Mode { case idle, pending, holding, scrolling, swiping }
    private var mode = Mode.idle
    private var origin = CGPoint.zero
    private var last = CGPoint.zero
    private var started = 0.0
    private var holdEligible = true
    static let holdDuration = 0.2

    mutating func begin(at point: CGPoint, now: TimeInterval) -> [Action] {
        let cleanup = cancel()
        origin = point; last = point; started = now
        holdEligible = true; mode = .pending
        return cleanup + [.cancelScroll]
    }

    mutating func advance(now: TimeInterval) -> [Action] {
        guard mode == .pending, holdEligible, now - started >= Self.holdDuration else { return [] }
        mode = .holding
        return [.hold(true)]
    }

    mutating func move(to point: CGPoint, now: TimeInterval) -> [Action] {
        var actions = advance(now: now)
        let dx = point.x - origin.x, dy = point.y - origin.y
        if mode == .pending {
            if hypot(dx, dy) > 10 { holdEligible = false }
            if hypot(dx, dy) >= 12 {
                mode = abs(dy) > abs(dx) ? .scrolling : .swiping
                if mode == .scrolling {
                    // Consume the first 12 points used to recognise the
                    // gesture, but send any movement beyond it right away.
                    // This avoids the old large threshold jump without making
                    // a short, ordinary scroll feel unresponsive.
                    let threshold: CGFloat = dy >= 0 ? 12 : -12
                    let excess = dy - threshold
                    if excess != 0 { actions.append(.scroll(Double(excess))) }
                }
                last = point
                return actions
            }
        }
        if mode == .scrolling, point.y != last.y { actions.append(.scroll(Double(point.y - last.y))) }
        last = point
        return actions
    }

    mutating func end(at point: CGPoint, now: TimeInterval) -> [Action] {
        guard mode != .idle else { return [] }
        var actions = move(to: point, now: now)
        switch mode {
        case .pending: if holdEligible { actions.append(.tap) }
        case .holding: actions.append(.hold(false))
        case .scrolling: actions.append(.scrollEnd)
        case .swiping:
            let dx = point.x - origin.x, dy = point.y - origin.y
            if abs(dx) > 40, abs(dx) > abs(dy) { actions.append(dx > 0 ? .swipeRight : .swipeLeft) }
        case .idle: break
        }
        mode = .idle
        return actions
    }

    mutating func cancel() -> [Action] {
        let actions: [Action] = mode == .holding ? [.hold(false)] : (mode == .scrolling ? [.cancelScroll] : [])
        mode = .idle
        return actions
    }
}
