import CoreGraphics
import Foundation

// Short, finite interpolation—not prediction or a queued history of positions.
// A resumed stream gets a slightly longer blend; normal input stays very light.
struct CursorSmoother {
    enum Mode: String { case off, normal, high }
    private var start = CGPoint.zero
    private var target: CGPoint?
    private var startedAt = 0.0
    private var duration = 0.012
    private var lastReceived: Double?

    mutating func cancel() { target = nil; lastReceived = nil }

    mutating func retarget(to next: CGPoint, current: CGPoint, now: Double, mode: Mode = .normal) -> CGPoint? {
        guard next.x.isFinite, next.y.isFinite, now.isFinite else { return nil }
        if mode == .off {
            cancel()
            return next
        }
        let gap = lastReceived.map { now - $0 } ?? 0
        lastReceived = now
        if target == next { return nil } // Repeated still frames must not prolong a tail.
        start = position(at: now) ?? current
        target = next; startedAt = now
        switch mode {
        case .normal: duration = gap > 0.035 ? 0.024 : 0.012
        case .high: duration = gap > 0.035 ? 0.060 : 0.030
        case .off: break
        }
        return nil
    }

    mutating func step(now: Double) -> CGPoint? {
        guard let point = position(at: now) else { return nil }
        if now - startedAt >= duration { target = nil }
        return point
    }

    private func position(at now: Double) -> CGPoint? {
        guard let target else { return nil }
        let fraction = min(1, max(0, (now - startedAt) / duration))
        return CGPoint(x: start.x + (target.x - start.x) * fraction,
                       y: start.y + (target.y - start.y) * fraction)
    }
}
