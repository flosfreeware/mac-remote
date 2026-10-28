import CoreMotion
import Combine
import Foundation
import simd

final class MotionController: ObservableObject {
    @Published var sensitivity: Double = 27.0
    @Published private(set) var isRestingFlat = false
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let stateLock = NSLock()
    private var running = false
    private var diagnosticsEnabled = false
    private var lastTimestamp: TimeInterval?
    private var pointer = OrientationPointer()
    private var generation: String?
    private var acknowledged = false
    private var captureAfter: TimeInterval?
    private var referenceReady: ((String) -> Void)?
    private var resumeReady: ((String, Double, Double) -> Void)?
    private var selectedFrame: CMAttitudeReferenceFrame = .xArbitraryZVertical
    private var savedFrame: UInt?
    private var lastAttitude: simd_quatd?
    private var flatRestGate = FlatRestGate()
    private var lastPublishedFlatResting = false
    private var alignment: simd_quatd?
    private var needsAlignment = false
    private var lastSaved = -Double.infinity
    private static let savedKey = "pointing.reference.v1"

    // Sensor callbacks run off the main actor; publish only state transitions
    // back to SwiftUI rather than attempting to update the UI at 120 Hz.
    private func publishFlatRestStateIfNeeded(_ resting: Bool) {
        guard resting != lastPublishedFlatResting else { return }
        lastPublishedFlatResting = resting
        DispatchQueue.main.async { [weak self] in self?.isRestingFlat = resting }
    }

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedKey),
              let saved = try? JSONDecoder().decode(SavedPointingState.self, from: data),
              saved.version == 1, UUID(uuidString: saved.generation) != nil,
              saved.sensitivity.isFinite, saved.sensitivity > 0, saved.sensitivity <= 1000,
              saved.lastAttitude.count == 4, saved.lastAttitude.allSatisfy({ $0.isFinite }),
              pointer.restore(saved.pointer) else { return }
        let q = saved.lastAttitude
        let attitude = simd_quatd(ix: q[0], iy: q[1], iz: q[2], r: q[3])
        guard simd_length(attitude.vector) > 0.5 else { pointer = OrientationPointer(); return }
        generation = saved.generation; sensitivity = saved.sensitivity
        savedFrame = saved.frame; lastAttitude = attitude.normalized
    }

    private func saveState() {
        guard let id = generation, let snapshot = pointer.snapshot, let lastAttitude else { return }
        let q = lastAttitude.vector
        let saved = SavedPointingState(generation: id, frame: selectedFrame.rawValue,
            sensitivity: sensitivity, pointer: snapshot, lastAttitude: [q.x, q.y, q.z, q.w])
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
            lastSaved = ProcessInfo.processInfo.systemUptime
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        diagnosticsEnabled = enabled
    }

    // Disconnecting must not throw away the user's neutral pose or cursor offset.
    func pauseConnection() {
        stateLock.lock(); defer { stateLock.unlock() }
        acknowledged = false
    }

    func resume(ready: @escaping (String, Double, Double) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        // A reconnect must not replace an explicit reset still awaiting its
        // first sensor sample (including one tapped in the one-second grace window).
        if captureAfter != nil, referenceReady != nil { return }
        acknowledged = false
        pointer.clearTransientEffects()
        if let id = generation, pointer.snapshot != nil, captureAfter == nil {
            ready(id, pointer.visible.x, pointer.visible.y)
        } else {
            // First use: establish a phone reference at the existing Mac cursor,
            // without warping it to the center of the screen.
            generation = UUID().uuidString
            captureAfter = ProcessInfo.processInfo.systemUptime
            referenceReady = nil; resumeReady = ready
        }
    }

    func reset(ready: @escaping (String) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        generation = UUID().uuidString; acknowledged = false
        pointer = OrientationPointer()
        resumeReady = nil
        // Capture a fresh sample immediately after the hold is recognized.
        captureAfter = ProcessInfo.processInfo.systemUptime
        referenceReady = ready
    }

    func acknowledge(_ id: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard generation == id, captureAfter == nil else { return }
        acknowledged = true
    }

    func suppress(for seconds: TimeInterval = 0.12) {
        stateLock.lock(); defer { stateLock.unlock() }
        pointer.suppress(until: ProcessInfo.processInfo.systemUptime + seconds)
    }

    func setSensitivity(_ value: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        sensitivity = min(max(value, 1), 1_000)
    }

    func start(send: @escaping (String, Double, Double, [String: Double]) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true; lastTimestamp = nil
        flatRestGate.reset()
        publishFlatRestStateIfNeeded(false)
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 120.0
        let available = CMMotionManager.availableAttitudeReferenceFrames()
        // Unlike an arbitrary frame, magnetic north survives sensor/app restarts.
        selectedFrame = available.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical
            : (available.contains(.xArbitraryCorrectedZVertical) ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical)
        if let savedFrame, savedFrame != selectedFrame.rawValue {
            pointer = OrientationPointer(); generation = nil; lastAttitude = nil
        }
        savedFrame = selectedFrame.rawValue
        alignment = nil
        // Hardware without a compass cannot recover heading changes while off.
        // Align its first sample to the last saved pose instead of jumping/resetting.
        needsAlignment = selectedFrame != .xMagneticNorthZVertical && lastAttitude != nil
        manager.showsDeviceMovementDisplay = false
        manager.startDeviceMotionUpdates(using: selectedFrame, to: queue) { motion, _ in
            guard let motion else { return }
            let callbackTime = ProcessInfo.processInfo.systemUptime
            self.stateLock.lock(); defer { self.stateLock.unlock() }
            guard self.running else { return }
            let lockedTime = ProcessInfo.processInfo.systemUptime
            let interval = self.lastTimestamp.map { min(max(motion.timestamp - $0, 0), 1.0 / 30.0) } ?? 1.0 / 120.0
            self.lastTimestamp = motion.timestamp
            let q = motion.attitude.quaternion
            let rawAttitude = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            if self.needsAlignment, let previous = self.lastAttitude {
                self.alignment = previous * rawAttitude.inverse
                self.needsAlignment = false
            }
            let attitude = self.alignment.map { $0 * rawAttitude } ?? rawAttitude
            self.lastAttitude = attitude
            let g = motion.gravity; let r = motion.rotationRate
            if let deadline = self.captureAfter {
                guard callbackTime >= deadline, motion.timestamp >= deadline,
                      self.pointer.center(attitude: attitude, gravity: SIMD3(g.x, g.y, g.z)),
                      let id = self.generation else { return }
                self.captureAfter = nil
                let ready = self.referenceReady; self.referenceReady = nil
                let resume = self.resumeReady; self.resumeReady = nil
                self.saveState()
                ready?(id)
                resume?(id, self.pointer.visible.x, self.pointer.visible.y)
            }
            // A phone left face-up or face-down on a table still produces
            // microscopic attitude changes. Do not let those compete with a
            // physical mouse. Lifting or even beginning to rotate the phone
            // leaves this gate on the same sensor sample.
            let restingFlat = self.flatRestGate.update(
                gravity: SIMD3(g.x, g.y, g.z),
                rotationRate: SIMD3(r.x, r.y, r.z),
                userAcceleration: SIMD3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z),
                now: callbackTime
            )
            self.publishFlatRestStateIfNeeded(restingFlat)
            if restingFlat { return }
            guard self.acknowledged, let id = self.generation,
                  let target = self.pointer.target(attitude: attitude, sensitivity: self.sensitivity,
                      speed: simd_length(SIMD3(r.x, r.y, r.z)), interval: interval, now: callbackTime) else { return }
            var raw = ["rx": r.x, "ry": r.y, "rz": r.z, "gx": g.x, "gy": g.y, "gz": g.z]
            if self.diagnosticsEnabled {
                raw["diag_sensor_s"] = motion.timestamp
                raw["diag_callback_s"] = callbackTime
                raw["diag_lock_ms"] = (lockedTime - callbackTime) * 1000
                raw["diag_computed_s"] = ProcessInfo.processInfo.systemUptime
                raw["diag_corrected_frame"] = self.selectedFrame == .xArbitraryZVertical ? 0 : 1
                raw["diag_reference_frame"] = Double(self.selectedFrame.rawValue)
                raw["diag_magnetic_accuracy"] = Double(motion.magneticField.accuracy.rawValue)
                raw["diag_rotation_rate"] = simd_length(SIMD3(r.x, r.y, r.z))
                raw["diag_user_acceleration"] = simd_length(SIMD3(motion.userAcceleration.x, motion.userAcceleration.y, motion.userAcceleration.z))
            }
            send(id, target.x, target.y, raw)
            if callbackTime - self.lastSaved >= 1 { self.saveState() }
        }
    }

    func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        saveState()
        running = false; acknowledged = false
        captureAfter = nil; referenceReady = nil; resumeReady = nil
        pointer.clearTransientEffects()
        flatRestGate.reset()
        publishFlatRestStateIfNeeded(false)
        stateLock.unlock()
        manager.stopDeviceMotionUpdates()
    }

    func clearSavedReference() {
        stateLock.lock(); defer { stateLock.unlock() }
        pointer = OrientationPointer()
        generation = nil
        acknowledged = false
        captureAfter = nil
        referenceReady = nil
        resumeReady = nil
        savedFrame = nil
        lastAttitude = nil
        alignment = nil
        needsAlignment = false
        UserDefaults.standard.removeObject(forKey: Self.savedKey)
    }
}
