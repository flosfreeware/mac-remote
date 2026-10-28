import Foundation

// One monotonically increasing sequence spans UDP and WebSocket fallback for
// the lifetime of the reliable connection. Missing datagrams never block input.
struct MotionPacketOrder {
    private(set) var latest = 0
    mutating func accept(_ sequence: Int) -> Bool {
        guard sequence > latest else { return false }
        latest = sequence
        return true
    }
}

// Scoped to one authenticated connection. Duplicate retries are idempotent;
// targets from a previous neutral pose must never affect the current cursor.
struct PointerResetState {
    private(set) var generation: String?

    mutating func reset(id: String, center: () -> Bool) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        if generation == id { return true }
        guard center() else { return false }
        generation = id
        return true
    }

    func accepts(_ id: String) -> Bool { generation == id }

    mutating func resume(id: String, restore: () -> Bool) -> Bool {
        reset(id: id, center: restore)
    }
}
