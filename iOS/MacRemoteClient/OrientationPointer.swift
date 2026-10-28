import Foundation
import simd

// Pose maps to position, never an increment. Speed, sampling, tap suppression
// and screen clipping therefore cannot accumulate integration error.
struct OrientationPointer {
    struct Snapshot: Codable {
        var reference: [Double]
        var gravity: [Double]
        var visible: [Double]
    }
    private var reference: simd_quatd?
    private var vertical = SIMD3<Double>(0, -1, 0)
    private var horizontal = SIMD3<Double>(1, 0, 0)
    private var forward = SIMD3<Double>(0, 0, -1)
    private(set) var visible = SIMD2<Double>.zero
    private var suppressUntil = -Double.infinity
    private var recoverUntil = -Double.infinity

    var snapshot: Snapshot? {
        guard let reference else { return nil }
        let q = reference.vector
        return Snapshot(reference: [q.x, q.y, q.z, q.w],
                        gravity: [vertical.x, vertical.y, vertical.z], visible: [visible.x, visible.y])
    }

    @discardableResult
    mutating func restore(_ saved: Snapshot) -> Bool {
        guard saved.reference.count == 4, saved.gravity.count == 3, saved.visible.count == 2,
              (saved.reference + saved.gravity + saved.visible).allSatisfy({ $0.isFinite }),
              saved.visible.allSatisfy({ abs($0) <= 1_000_000 }) else { return false }
        let q = saved.reference, g = saved.gravity
        guard center(attitude: simd_quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3]),
                     gravity: SIMD3(g[0], g[1], g[2])) else { return false }
        visible = SIMD2(saved.visible[0], saved.visible[1])
        return true
    }

    mutating func clearTransientEffects() {
        suppressUntil = -.infinity; recoverUntil = -.infinity
    }

    @discardableResult
    mutating func center(attitude: simd_quatd, gravity: SIMD3<Double>) -> Bool {
        guard gravity.x.isFinite, gravity.y.isFinite, gravity.z.isFinite,
              simd_length(gravity) > 0.5, attitude.vector.allFinite,
              simd_length(attitude.vector) > 0.5 else { return false }
        vertical = simd_normalize(gravity)
        let deviceX = SIMD3<Double>(1, 0, 0)
        var pitchAxis = deviceX - vertical * simd_dot(deviceX, vertical)
        // At this singular grip device X is vertical; use device Z instead.
        if simd_length(pitchAxis) < 0.05 {
            let deviceZ = SIMD3<Double>(0, 0, 1)
            pitchAxis = deviceZ - vertical * simd_dot(deviceZ, vertical)
        }
        horizontal = simd_normalize(pitchAxis)
        forward = simd_normalize(simd_cross(horizontal, vertical))
        reference = attitude.normalized
        visible = .zero; suppressUntil = -.infinity; recoverUntil = -.infinity
        return true
    }

    mutating func suppress(until deadline: TimeInterval) {
        suppressUntil = max(suppressUntil, deadline)
        recoverUntil = suppressUntil + 0.24
    }

    mutating func target(attitude: simd_quatd, sensitivity: Double, speed: Double,
                         interval: TimeInterval, now: TimeInterval) -> SIMD2<Double>? {
        guard let reference, attitude.vector.allFinite, simd_length(attitude.vector) > 0.5 else { return nil }
        let relative = reference.inverse * attitude.normalized
        let ray = relative.act(forward)
        let x = simd_dot(ray, horizontal), y = simd_dot(ray, vertical), z = simd_dot(ray, forward)
        // Constant gain matching the old curve's medium-speed response.
        // No velocity deadzone, speed acceleration or angle-dependent gain.
        let scale = sensitivity * 120 * 0.6
        let desired = SIMD2(atan2(x, z), atan2(y, hypot(x, z))) * scale
        guard desired.x.isFinite, desired.y.isFinite else { return nil }
        if now < suppressUntil { return visible }
        // Smooth the visible position, not the reference: tiny turns eventually
        // reach their correct position instead of being permanently discarded.
        let tau = now < recoverUntil ? 0.08 : (0.025 - 0.017 * min(max(speed / 0.8, 0), 1))
        visible += (desired - visible) * (1 - exp(-max(interval, 0) / tau))
        return visible
    }
}

struct SavedPointingState: Codable {
    var version = 1
    var generation: String
    var frame: UInt
    var sensitivity: Double
    var pointer: OrientationPointer.Snapshot
    var lastAttitude: [Double]
}

// A resting phone can report tiny gyro/attitude fluctuations indefinitely.
// This deliberately has hysteresis: it requires a brief quiet period to enter
// rest, but exits on the first clearly intentional lift or turn.
struct FlatRestGate {
    private var quietSince: TimeInterval?
    private var wakeSince: TimeInterval?
    private var restGravity: SIMD3<Double>?
    private(set) var isResting = false

    mutating func reset() {
        quietSince = nil
        wakeSince = nil
        restGravity = nil
        isResting = false
    }

    mutating func update(gravity: SIMD3<Double>, rotationRate: SIMD3<Double>,
                         userAcceleration: SIMD3<Double>, now: TimeInterval) -> Bool {
        let gravityLength = simd_length(gravity)
        guard gravityLength.isFinite, gravityLength > 0.5 else {
            reset()
            return false
        }
        // The device Z axis is perpendicular to its screen: a table-resting
        // phone has gravity almost entirely on that axis, either face up or down.
        let normalizedGravity = gravity / gravityLength
        let isFlat = abs(normalizedGravity.z) >= 0.82
        let turn = simd_length(rotationRate)
        let acceleration = simd_length(userAcceleration)
        guard turn.isFinite, acceleration.isFinite else {
            reset()
            return false
        }

        // A real pickup changes this vector persistently; table-level sensor
        // spikes do not. Require the signal for 50 ms so a stone table cannot
        // repeatedly flash the UI awake, without a perceptible pickup delay.
        let gravityShift = restGravity.map { simd_length(normalizedGravity - $0) } ?? 0
        let moved = !isFlat || gravityShift >= 0.02 || turn >= 0.05 || acceleration >= 0.03
        if isResting {
            if moved {
                if let wakeSince, now - wakeSince >= 0.05 {
                    reset()
                } else if wakeSince == nil {
                    self.wakeSince = now
                }
            } else {
                wakeSince = nil
            }
            return isResting
        }

        // Table-level accelerometer noise can be noticeably higher than the
        // gyro's noise floor. Accept a realistically quiet flat pose, then
        // use the much more sensitive gravity baseline above to wake it.
        guard isFlat, turn < 0.04, acceleration < 0.025 else {
            quietSince = nil
            return false
        }
        if let quietSince {
            if now - quietSince >= 0.35 {
                isResting = true
                restGravity = normalizedGravity
                wakeSince = nil
            }
        } else {
            quietSince = now
        }
        return isResting
    }
}

private extension SIMD4 where Scalar == Double {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
}
