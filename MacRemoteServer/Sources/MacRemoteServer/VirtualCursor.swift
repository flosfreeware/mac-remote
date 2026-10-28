import Foundation
import CoreGraphics

// Content-free hardware activity fallback. Secure Input can hide key events,
// but the public HID counters still expose activity, not key identities/text.
struct HardwareKeyboardActivity {
    private var previous: (down: UInt32, up: UInt32)?
    mutating func sample(down: UInt32, up: UInt32) -> Bool {
        defer { previous = (down, up) }
        guard let previous else { return false }
        guard down != previous.down || up != previous.up else { return false }
        return true
    }
}

// Each touch owns a unique hold. Heartbeats renew a short lease; disconnects,
// sleep and physical takeover can release it without stale packets re-pressing it.
struct RemoteMouseHoldState {
    private(set) var id: String?
    private var blockedID: String?
    private var expiresAt = -Double.infinity
    var isDown: Bool { id != nil }

    mutating func update(id: String, down: Bool, now: TimeInterval) -> [Bool] {
        guard UUID(uuidString: id) != nil else { return [] }
        if !down {
            if blockedID == id { blockedID = nil }
            guard self.id == id else { return [] }
            self.id = nil
            return [false]
        }
        guard blockedID != id else { return [] }
        let previous = self.id
        self.id = id; expiresAt = now + 1.5
        if previous == id { return [] }
        return previous == nil ? [true] : [false, true]
    }

    mutating func release() -> [Bool] {
        guard let id else { return [] }
        blockedID = id; self.id = nil
        return [false]
    }

    mutating func expire(now: TimeInterval) -> [Bool] {
        now >= expiresAt ? release() : []
    }
}

// Physical pointer/keyboard input wins temporarily, but it must never rewrite the
// iPhone's centering reference. When the quiet period ends, the phone returns to
// the position implied by its original centered pose.
struct PhonePointerAnchor {
    private(set) var anchor: CGPoint?
    private var offset = CGPoint.zero
    private var physicalPosition = CGPoint.zero
    private var physicalTime = -Double.infinity
    private var keyboardTime = -Double.infinity
    private var buttons: Set<Int64> = []
    private var keys: Set<UInt16> = []
    private var modifiersHeld = false
    private var needsPhoneBaseline = false
    private let quietPeriod = 0.3
    private let keyboardQuietPeriod = 1.0
    var physicalLeftDown: Bool { buttons.contains(0) }

    mutating func reset(to center: CGPoint) {
        anchor = center; offset = .zero
        physicalPosition = center
        needsPhoneBaseline = false
    }

    mutating func resume(at current: CGPoint, offset: CGPoint, sameReference: Bool) {
        if !sameReference || anchor == nil {
            // A new server/reference binds the saved phone offset to the existing
            // cursor, without warping it or assuming the display center.
            anchor = CGPoint(x: current.x - offset.x, y: current.y - offset.y)
            physicalPosition = current
        }
        self.offset = offset
    }

    func allowsRemote(now: TimeInterval) -> Bool {
        buttons.isEmpty && keys.isEmpty && !modifiersHeld && now - physicalTime >= quietPeriod
            && now - keyboardTime >= keyboardQuietPeriod
    }

    mutating func hardwareKeyboard(at point: CGPoint, now: Double, clearObservedKeys: Bool = false) {
        keyboardTime = now
        // Counters indicate activity, NOT a reliable held-key state. This pause
        // must always expire even if Secure Input hides the final key-up.
        // Aggregate hardware state supersedes an incomplete monitor key set
        // when Secure Input hid a corresponding key-up.
        if clearObservedKeys { keys.removeAll() }
        physical(to: point, now: now)
    }

    mutating func keyboard(at point: CGPoint, now: TimeInterval, key: UInt16?, pressed: Bool, modifiersHeld: Bool? = nil) {
        keyboardTime = now
        if let key {
            if pressed { keys.insert(key) } else { keys.remove(key) }
        }
        if let modifiersHeld { self.modifiersHeld = modifiersHeld }
        physical(to: point, now: now)
    }

    mutating func physical(to point: CGPoint, now: TimeInterval, button: Int64? = nil, pressed: Bool? = nil) {
        guard point.x.isFinite, point.y.isFinite else { return }
        if let button, let pressed {
            if pressed { buttons.insert(button) } else { buttons.remove(button) }
        }
        physicalPosition = point; physicalTime = now
        needsPhoneBaseline = true
    }

    mutating func target(offset next: CGPoint, now: TimeInterval) -> CGPoint? {
        guard let anchor, next.x.isFinite, next.y.isFinite else { return nil }
        offset = next
        guard allowsRemote(now: now), !needsPhoneBaseline else {
            needsPhoneBaseline = false
            return nil
        }
        return CGPoint(x: anchor.x + next.x, y: anchor.y + next.y)
    }
}

// Preserve off-screen travel; clamp only the visible pointer, never its reference.
struct VirtualCursor {
    private(set) var position: CGPoint?

    mutating func rebase(to point: CGPoint) { position = point }

    mutating func place(at point: CGPoint, current: CGPoint, displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty, point.x.isFinite, point.y.isFinite else { return current }
        position = point
        return Self.project(point, displays: displays)
    }

    mutating func move(dx: Double, dy: Double, current: CGPoint, displays: [CGRect]) -> CGPoint {
        guard !displays.isEmpty else { return current }
        let previous = position ?? current
        let next = CGPoint(x: previous.x + dx, y: previous.y + dy)
        guard next.x.isFinite, next.y.isFinite else { return current }
        return place(at: next, current: current, displays: displays)
    }

    static func project(_ next: CGPoint, displays: [CGRect]) -> CGPoint {
        // Project onto the nearest real display, including negative origins and gaps.
        // A single bounding rectangle would incorrectly allow positions between monitors.
        return displays.map { bounds in
            CGPoint(x: min(max(next.x, bounds.minX), bounds.maxX - 1),
                    y: min(max(next.y, bounds.minY), bounds.maxY - 1))
        }.min { a, b in
            hypot(a.x - next.x, a.y - next.y) < hypot(b.x - next.x, b.y - next.y)
        } ?? next
    }
}
