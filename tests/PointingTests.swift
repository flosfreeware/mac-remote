import Foundation
import CoreGraphics
import simd

@main
struct PointingTests {
    static let neutral = simd_quatd(angle: 0, axis: SIMD3<Double>(1, 0, 0))
    static let gravity = SIMD3<Double>(0, -1, 0)
    static let scale = 27.0 * 120 * 0.6

    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        print("PASS: \(name)")
    }

    static func settle(_ pointer: inout OrientationPointer, _ attitude: simd_quatd,
                       speed: Double = 0, start: Double = 10) -> SIMD2<Double> {
        var result = SIMD2<Double>.zero
        for i in 0..<240 {
            result = pointer.target(attitude: attitude, sensitivity: 27, speed: speed,
                                    interval: 1.0 / 120, now: start + Double(i) / 120)!
        }
        return result
    }

    static func testFlatRestGate() {
        var gate = FlatRestGate()
        let flat = SIMD3<Double>(0, 0, -1)
        let zero = SIMD3<Double>.zero
        check(!gate.update(gravity: flat, rotationRate: zero, userAcceleration: zero, now: 0),
              "flat rest gate waits before suppressing a newly flat phone")
        check(gate.update(gravity: flat, rotationRate: zero, userAcceleration: zero, now: 0.41),
              "flat rest gate suppresses table noise after a quiet settle")
        check(gate.update(gravity: flat, rotationRate: SIMD3(0.06, 0, 0), userAcceleration: zero, now: 0.42),
              "flat rest gate ignores a one-sample table sensor spike")
        check(!gate.update(gravity: flat, rotationRate: SIMD3(0.06, 0, 0), userAcceleration: zero, now: 0.48),
              "flat rest gate resumes promptly on a sustained intentional turn")
        check(!gate.update(gravity: SIMD3(0, 0.5, -0.5), rotationRate: zero, userAcceleration: zero, now: 0.43),
              "flat rest gate never suppresses a phone that is pointed up")
    }

    static func main() {
        var visibility = CursorVisibilityState()
        var visibilityCalls: [Bool] = []
        check(visibility.setHidden(false, apply: { visibilityCalls.append($0); return true }) && visibilityCalls.isEmpty,
              "cursor visibility never shows a cursor hidden by another app")
        check(visibility.setHidden(true, apply: { visibilityCalls.append($0); return true }) && visibility.hidden,
              "iPhone inactivity owns one cursor hide")
        visibility.setHidden(true) { visibilityCalls.append($0); return true }
        check(visibilityCalls == [true], "duplicate inactive/lock notifications cannot accumulate hide counts")
        visibility.setHidden(false) { visibilityCalls.append($0); return true }
        check(!visibility.hidden && visibilityCalls == [true, false], "app resume or real Mac input balances our hide exactly once")
        visibility.setHidden(false) { visibilityCalls.append($0); return true }
        check(visibilityCalls == [true, false], "repeated physical input cannot over-show the cursor")
        check(!visibility.setHidden(true, apply: { _ in false }) && !visibility.hidden,
              "failed hide API does not claim a hide count or require an unmatched show")
        visibility.setHidden(true) { _ in true }
        check(!visibility.setHidden(false, apply: { _ in false }) && visibility.hidden,
              "failed cursor restore retains ownership for a safe retry")
        check(visibility.setHidden(false, apply: { _ in true }) && !visibility.hidden,
              "cursor visibility restores correctly after retry")
        var hardwareActivity = HardwareKeyboardActivity()
        check(!hardwareActivity.sample(down: 100, up: 100),
              "hardware keyboard counter initializes without inventing a key press")
        check(hardwareActivity.sample(down: 101, up: 100),
              "content-free hardware counters detect typing even without monitor events")
        check(!hardwareActivity.sample(down: 101, up: 100),
              "missing hardware key-up does not invent continuing keyboard activity")
        check(hardwareActivity.sample(down: 101, up: 101),
              "hardware key-up is detected as fresh activity, not a held-state latch")
        check(!hardwareActivity.sample(down: 101, up: 101),
              "unchanged hardware counters do not extend the typing quiet period")
        check(hardwareActivity.sample(down: 102, up: 102),
              "quick complete key press between polls is still detected")
        var protectedAnchor = PhonePointerAnchor()
        protectedAnchor.reset(to: CGPoint(x: 400, y: 300))
        protectedAnchor.hardwareKeyboard(at: CGPoint(x: 400, y: 300), now: 1)
        check(protectedAnchor.target(offset: CGPoint(x: 300, y: 100), now: 1.1) == nil,
              "Secure Input hardware activity pauses incoming cursor targets")
        check(!protectedAnchor.allowsRemote(now: 1.9), "keyboard activity pauses phone input for a full second")
        check(protectedAnchor.allowsRemote(now: 2), "REGRESSION: cursor unblocks after quiet period even if key-up never arrives")
        protectedAnchor.hardwareKeyboard(at: CGPoint(x: 400, y: 300), now: 10)
        check(protectedAnchor.target(offset: CGPoint(x: 350, y: 150), now: 10.1) == nil,
              "Secure Input fallback preserves post-typing quiet period")
        check(protectedAnchor.target(offset: CGPoint(x: 350, y: 150), now: 11) == CGPoint(x: 750, y: 450),
              "Secure Input fallback preserves the iPhone's original centered mapping")
        protectedAnchor.keyboard(at: .zero, now: 12, key: 1, pressed: true)
        protectedAnchor.hardwareKeyboard(at: .zero, now: 13, clearObservedKeys: true)
        check(protectedAnchor.allowsRemote(now: 14), "hidden key-up cannot leave monitor key state stuck during Secure Input")
        var readiness = RemoteControlReadiness()
        check(readiness.confirm() == nil && !readiness.ready, "background socket readiness cannot enable phone control")
        readiness.resume()
        let firstSession = readiness.confirm()
        check(firstSession != nil && readiness.ready, "foreground connection produces explicit control-ready notification")
        check(readiness.confirm() == nil, "duplicate connection replies do not restart pointer restoration")
        readiness.suspend()
        check(!readiness.ready && readiness.confirm() == nil, "late background pong cannot reactivate controls")
        readiness.resume()
        let resumedSession = readiness.confirm()
        check(resumedSession != nil && resumedSession != firstSession,
              "fast retained-socket resume restores control even when visible status remains connected")
        readiness.disconnect()
        check(!readiness.ready && readiness.confirm() != nil, "foreground reconnect produces a new restoration session")

        var presentation = ReconnectPresentationState()
        let firstGrace = presentation.resume()
        presentation.connectionChanged(connected: false)
        check(presentation.graceActive && !presentation.showHelp, "foreground reconnect hides warning during grace")
        presentation.expire(generation: firstGrace, connected: false)
        check(!presentation.graceActive && presentation.showHelp, "failed foreground reconnect shows warning only after expiry")
        presentation.suspend()
        presentation.connectionChanged(connected: false)
        presentation.connectionChanged(connected: true)
        presentation.connectionChanged(connected: false)
        presentation.expire(generation: firstGrace, connected: false)
        check(presentation.graceActive && !presentation.showHelp, "background callbacks and old timeout cannot leave a disabled warning snapshot")
        let secondGrace = presentation.resume()
        presentation.expire(generation: firstGrace, connected: false)
        check(presentation.graceActive && !presentation.showHelp, "return from background gets a fresh grace independent of the previous deadline")
        presentation.connectionChanged(connected: true)
        presentation.expire(generation: secondGrace, connected: true)
        check(!presentation.graceActive && !presentation.showHelp, "successful reconnect never shows connection help")
        presentation.connectionChanged(connected: false)
        check(presentation.showHelp, "real foreground disconnect after connection still shows help")

        var reconnectActions = ReconnectActionBuffer<Int>()
        check(!ReconnectActionBuffer<Int>.accepts(messageType: "pointer_target") &&
              !ReconnectActionBuffer<Int>.accepts(messageType: "mouse_move"),
              "reconnect grace never queues absolute or relative gyro cursor movement")
        check(ReconnectActionBuffer<Int>.accepts(messageType: "media") &&
              ReconnectActionBuffer<Int>.accepts(messageType: "shortcut") &&
              ReconnectActionBuffer<Int>.accepts(messageType: "click"),
              "reconnect grace queues media, shortcuts and touch clicks")
        check(!reconnectActions.enqueue(0, now: 0), "reconnect actions rejected outside a foreground grace window")
        reconnectActions.begin(now: 1)
        check(reconnectActions.enqueue(1, now: 1) && reconnectActions.enqueue(2, now: 1.999),
              "reconnect grace accepts button actions immediately for one second")
        check(!reconnectActions.enqueue(3, now: 2), "reconnect grace rejects actions at the exact deadline")
        check(reconnectActions.drain(now: 1.999) == [1, 2], "successful reconnect replays queued actions in order")
        check(reconnectActions.drain(now: 1.999).isEmpty, "reconnect actions replay only once")
        reconnectActions.begin(now: 2); reconnectActions.enqueue(3, now: 2.1)
        check(reconnectActions.drain(now: 3).isEmpty, "late reconnect discards old actions rather than executing them unexpectedly")
        reconnectActions.begin(now: 3); reconnectActions.enqueue(4, now: 3.1); reconnectActions.cancel()
        check(reconnectActions.drain(now: 3.2).isEmpty, "backgrounding cancels queued actions")
        reconnectActions.begin(now: 4); reconnectActions.enqueue(5, now: 4.1); reconnectActions.begin(now: 4.15)
        check(reconnectActions.drain(now: 4.2).isEmpty, "new foreground session cannot replay actions from the previous one")
        reconnectActions.begin(now: 5)
        for i in 0..<128 { reconnectActions.enqueue(i, now: 5.1) }
        check(!reconnectActions.enqueue(129, now: 5.1) && reconnectActions.drain(now: 5.2).count == 128,
              "reconnect action buffer has a fixed memory bound")
        var smoothing = CursorSmoother()
        smoothing.retarget(to: CGPoint(x: 100, y: 50), current: .zero, now: 0)
        check(smoothing.step(now: 0) == .zero, "smoothing starts at visible cursor, not new remote target")
        let middle = smoothing.step(now: 0.006)!
        check(abs(middle.x - 50) < 0.001 && abs(middle.y - 25) < 0.001,
              "normal cursor update blends both axes equally over 12 ms")
        check(smoothing.step(now: 0.012) == CGPoint(x: 100, y: 50), "smoothing reaches exact target with no overshoot")
        check(smoothing.step(now: 0.03) == nil, "settled smoothing has no idle drift or prediction")
        smoothing.retarget(to: CGPoint(x: 200, y: 50), current: CGPoint(x: 100, y: 50), now: 0.1)
        check(abs(smoothing.step(now: 0.106)!.x - 125) < 0.001,
              "first update after a delivery gap uses a short 24 ms catch-up blend")
        check(smoothing.step(now: 0.125) == CGPoint(x: 200, y: 50), "catch-up finishes without an unbounded tail")
        smoothing = CursorSmoother()
        smoothing.retarget(to: CGPoint(x: 100, y: 0), current: .zero, now: 0)
        smoothing.retarget(to: CGPoint(x: 200, y: 0), current: .zero, now: 0.006)
        check(abs(smoothing.step(now: 0.006)!.x - 50) < 0.001,
              "a newer target continues smoothly rather than restarting from stale position")
        check(smoothing.step(now: 0.03) == CGPoint(x: 200, y: 0), "newest target replaces older queued motion")
        smoothing.retarget(to: .zero, current: CGPoint(x: 200, y: 0), now: 0.031)
        smoothing.cancel()
        check(smoothing.step(now: 0.04) == nil, "physical mouse/reset/disconnect cancellation stops all smoothing")
        smoothing.retarget(to: CGPoint(x: 501, y: 0), current: CGPoint(x: 500, y: 0), now: 1)
        check(smoothing.step(now: 1) == CGPoint(x: 500, y: 0), "after cancellation the new physical cursor is the starting point")
        smoothing = CursorSmoother()
        smoothing.retarget(to: CGPoint(x: 0.1, y: 0), current: .zero, now: 0)
        smoothing.retarget(to: CGPoint(x: 0.1, y: 0), current: .zero, now: 0.006)
        check(smoothing.step(now: 0.013) == CGPoint(x: 0.1, y: 0), "repeated still targets neither suppress tiny movement nor prolong smoothing")
        smoothing.retarget(to: CGPoint(x: Double.nan, y: 0), current: .zero, now: 2)
        check(smoothing.step(now: 2) == nil, "malformed smoothing targets are ignored safely")
        testFlatRestGate()
        var order = MotionPacketOrder()
        check(!order.accept(0) && !order.accept(-1), "UDP rejects invalid sequence numbers")
        check(order.accept(1), "UDP accepts first target")
        check(order.accept(5), "UDP skips lost packets without waiting")
        check(!order.accept(4) && !order.accept(5), "UDP ignores reordered and duplicate targets")
        check(order.accept(6), "WebSocket fallback can continue the same motion sequence")
        check(!order.accept(3), "late UDP target cannot overwrite newer WebSocket fallback")
        order = MotionPacketOrder()
        check(order.accept(1), "new authenticated connection resets the sequence")
        testStatusPolling()
        var touch = TouchSurfaceState()
        _ = touch.begin(at: .zero, now: 0)
        check(touch.end(at: .zero, now: 0.06) == [.tap],
              "REGRESSION: quick single tap emits one click without hold/drag arbitration")
        _ = touch.begin(at: .zero, now: 0.1)
        check(touch.end(at: CGPoint(x: 2, y: 3), now: 0.18) == [.tap],
              "quick tap with small finger movement still clicks immediately")
        check(touch.end(at: .zero, now: 0.19).isEmpty,
              "duplicate touch end cannot click twice")
        _ = touch.begin(at: .zero, now: 1)
        check(touch.advance(now: 1.19).isEmpty, "touch-down is not a confirmed hold")
        check(touch.advance(now: 1.21) == [.hold(true)], "hold starts mouse-down at threshold")
        check(touch.move(to: CGPoint(x: 50, y: 70), now: 1.3).isEmpty,
              "finger movement during hold cannot scroll or swipe")
        check(touch.end(at: CGPoint(x: 50, y: 70), now: 1.4) == [.hold(false)],
              "held touch releases mouse without an extra tap")
        _ = touch.begin(at: .zero, now: 2)
        check(touch.end(at: .zero, now: 2.3) == [.hold(true), .hold(false)],
              "late timer delivery still distinguishes a hold from a tap")
        _ = touch.begin(at: .zero, now: 3)
        _ = touch.advance(now: 3.21)
        check(touch.cancel() == [.hold(false)] && touch.cancel().isEmpty,
              "cancellation/backgrounding releases hold exactly once")
        check(touch.advance(now: 4).isEmpty, "canceled hold timer cannot press mouse later")
        _ = touch.begin(at: .zero, now: 5)
        _ = touch.move(to: CGPoint(x: 0, y: 3), now: 5.01)
        check(touch.move(to: CGPoint(x: 0, y: 20), now: 5.05) == [.scroll(8)],
              "vertical drag scrolls its movement beyond the recognition threshold without an initial jump")
        check(touch.end(at: CGPoint(x: 0, y: 25), now: 5.3) == [.scroll(5), .scrollEnd],
              "scroll ends with inertia but no click or hold")
        _ = touch.begin(at: .zero, now: 6)
        _ = touch.move(to: CGPoint(x: 45, y: 0), now: 6.05)
        check(touch.end(at: CGPoint(x: 45, y: 0), now: 6.1) == [.swipeRight],
              "horizontal swipe still switches tabs without clicking")
        _ = touch.begin(at: .zero, now: 7)
        _ = touch.move(to: CGPoint(x: 11, y: 0), now: 7.05)
        check(touch.advance(now: 7.3).isEmpty && touch.end(at: CGPoint(x: 11, y: 0), now: 7.4).isEmpty,
              "moving outside hold tolerance cannot become a late hold or click")
        _ = touch.begin(at: .zero, now: 8)
        check(touch.cancel().isEmpty && touch.end(at: .zero, now: 8.05).isEmpty,
              "canceled quick touch does not click")
        var heldButton = RemoteMouseHoldState()
        let touchA = UUID().uuidString, touchB = UUID().uuidString
        check(heldButton.update(id: touchA, down: true, now: 0) == [true] && heldButton.isDown,
              "hold sends one real mouse-down")
        check(heldButton.update(id: touchA, down: true, now: 0.25).isEmpty,
              "hold heartbeat renews without repeated mouse-downs")
        check(heldButton.expire(now: 1.6).isEmpty && heldButton.isDown,
              "heartbeat extends hold lease")
        check(heldButton.update(id: touchA, down: false, now: 1.7) == [false] && !heldButton.isDown,
              "finger release sends mouse-up")
        check(heldButton.update(id: touchA, down: false, now: 1.8).isEmpty,
              "duplicate releases do not emit extra clicks")
        _ = heldButton.update(id: touchA, down: true, now: 2)
        check(heldButton.release() == [false] && !heldButton.isDown,
              "cancel/disconnect/sleep releases held button")
        check(heldButton.update(id: touchA, down: true, now: 2.1).isEmpty && !heldButton.isDown,
              "physical takeover blocks old hold heartbeats from re-pressing")
        check(heldButton.update(id: touchB, down: true, now: 3) == [true],
              "a new finger hold can press after takeover")
        check(heldButton.update(id: touchA, down: false, now: 3.1).isEmpty && heldButton.isDown,
              "late release from an old touch cannot release a new hold")
        check(heldButton.expire(now: 4.6) == [false] && !heldButton.isDown,
              "lost connection/heartbeats trigger failsafe mouse-up")
        check(heldButton.update(id: touchB, down: true, now: 4.7).isEmpty,
              "a timed-out hold cannot restart from queued heartbeats")
        check(heldButton.update(id: "bad-id", down: true, now: 5).isEmpty && !heldButton.isDown,
              "malformed mouse hold ignored")
        _ = heldButton.update(id: UUID().uuidString, down: true, now: 6)
        check(heldButton.update(id: UUID().uuidString, down: true, now: 6.1) == [false, true],
              "new touch replaces an unreleased old touch with up then down")
        var pointer = OrientationPointer()
        check(pointer.target(attitude: neutral, sensitivity: 27, speed: 0, interval: 0.01, now: 0) == nil,
              "no movement before reference capture")
        pointer.center(attitude: neutral, gravity: gravity)
        let right = simd_quatd(angle: 0.1, axis: gravity)
        let up = simd_quatd(angle: 0.1, axis: SIMD3<Double>(1, 0, 0))
        let rightPoint = settle(&pointer, right)
        let upPoint = settle(&pointer, up)
        check(abs(rightPoint.x - scale * 0.1) < 0.0001 && abs(rightPoint.y) < 0.0001,
              "right turn moves right")
        check(abs(upPoint.y + scale * 0.1) < 0.0001 && abs(upPoint.x) < 0.0001,
              "pitch up moves up with equal angular scale")
        let slow = settle(&pointer, right, speed: 0.01)
        let fast = settle(&pointer, right, speed: 3)
        check(simd_length(slow - fast) < 0.0001, "same pose has same position at any speed")
        for i in 0..<300 {
            let angle = Double(i) / 299 * 0.8
            _ = pointer.target(attitude: simd_quatd(angle: angle, axis: gravity), sensitivity: 27,
                               speed: 0.8, interval: 1.0 / 60, now: Double(i) / 60)
        }
        check(simd_length(settle(&pointer, neutral)) < 0.0001, "out-and-back returns to center")
        let tiny = settle(&pointer, simd_quatd(angle: 0.00001, axis: gravity))
        check(abs(tiny.x - scale * 0.00001) < 0.000001, "tiny slow movement is not discarded")
        pointer.center(attitude: neutral, gravity: gravity)
        let roll = simd_quatd(angle: 0.7, axis: SIMD3<Double>(0, 0, -1))
        check(simd_length(settle(&pointer, roll)) < 0.0001, "twist around pointing axis does not move cursor")

        // Tilt sideways: yaw and pitch remain orthogonal and equally scaled.
        let reference = simd_quatd(angle: 0.65, axis: SIMD3<Double>(0, 0, 1))
        let tiltedGravity = reference.inverse.act(gravity)
        let xAxis = SIMD3<Double>(1, 0, 0)
        let pitchAxis = simd_normalize(xAxis - tiltedGravity * simd_dot(xAxis, tiltedGravity))
        pointer.center(attitude: reference, gravity: tiltedGravity)
        let tiltedRight = settle(&pointer, reference * simd_quatd(angle: 0.1, axis: tiltedGravity))
        let tiltedUp = settle(&pointer, reference * simd_quatd(angle: 0.1, axis: pitchAxis))
        check(abs(tiltedRight.x - scale * 0.1) < 0.0001 && abs(tiltedRight.y) < 0.0001
              && abs(tiltedUp.y + scale * 0.1) < 0.0001 && abs(tiltedUp.x) < 0.0001,
              "sideways grip does not shear axes or flatten movement")

        pointer.center(attitude: neutral, gravity: gravity)
        pointer.suppress(until: 1)
        let suppressed = pointer.target(attitude: right, sensitivity: 27, speed: 1,
                                        interval: 1.0 / 120, now: 0.5)!
        check(suppressed == .zero, "tap impulse is held without moving reference")
        let recovery = pointer.target(attitude: right, sensitivity: 27, speed: 0,
                                      interval: 1.0 / 120, now: 1.001)!
        check(recovery.x > 0 && recovery.x < rightPoint.x / 4, "tap recovery is smooth, not a teleport")
        check(simd_length(settle(&pointer, right) - rightPoint) < 0.0001,
              "intended rotation during tap is fully recovered")
        pointer.suppress(until: 20)
        pointer.center(attitude: right, gravity: gravity)
        check(simd_length(settle(&pointer, right)) < 0.0001, "reset clears tap recovery and uses fresh neutral")

        // Disk round-trip models a process quit, not merely an in-memory pause.
        pointer.center(attitude: reference, gravity: tiltedGravity)
        let beforeQuit = settle(&pointer, reference * simd_quatd(angle: 0.12, axis: tiltedGravity))
        let state = SavedPointingState(generation: UUID().uuidString, frame: 4, sensitivity: 27,
            pointer: pointer.snapshot!, lastAttitude: [0, 0, 0, 1])
        let bytes = try! JSONEncoder().encode(state)
        let loaded = try! JSONDecoder().decode(SavedPointingState.self, from: bytes)
        var restored = OrientationPointer()
        check(loaded.generation == state.generation && loaded.frame == 4 && restored.restore(loaded.pointer),
              "neutral pose and generation survive disk serialization")
        check(simd_length(restored.visible - beforeQuit) < 0.000001,
              "cursor offset survives process relaunch without resetting to zero")
        check(simd_length(settle(&restored, reference * simd_quatd(angle: 0.12, axis: tiltedGravity)) - beforeQuit) < 0.000001,
              "restored pose retains the same angle-to-position mapping")
        check(simd_length(settle(&restored, reference)) < 0.000001,
              "original neutral is still neutral after restoring")
        check(!restored.restore(.init(reference: [], gravity: [], visible: [])),
              "malformed saved pointing state is rejected safely")

        var cursor = VirtualCursor()
        let display = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let center = CGPoint(x: 500, y: 400)
        let outside = cursor.place(at: CGPoint(x: 1800, y: 400), current: center, displays: [display])
        check(outside.x == 999 && cursor.position?.x == 1800, "screen clipping preserves underlying target")
        let returned = cursor.place(at: center, current: outside, displays: [display])
        check(returned == center, "return to reference after screen edge returns to center")

        var handoff = PhonePointerAnchor()
        handoff.reset(to: center)
        check(handoff.target(offset: CGPoint(x: 100, y: -40), now: 1) == CGPoint(x: 600, y: 360),
              "phone target uses reset anchor before physical takeover")
        let mouse = CGPoint(x: 120, y: 200)
        handoff.physical(to: mouse, now: 2)
        check(handoff.target(offset: CGPoint(x: 300, y: 90), now: 2.1) == nil,
              "physical mouse suppresses even queued phone motion")
        check(handoff.target(offset: CGPoint(x: 300, y: 90), now: 2.5) == CGPoint(x: 800, y: 490),
              "physical mouse movement never changes the iPhone's centered reference")
        check(handoff.target(offset: CGPoint(x: 310, y: 85), now: 2.6) == CGPoint(x: 810, y: 485),
              "phone continues from its original centered coordinate system after takeover")
        handoff.physical(to: mouse, now: 3, button: 0, pressed: true)
        check(handoff.target(offset: CGPoint(x: 900, y: 900), now: 20) == nil,
              "held physical drag retains priority even without movement")
        handoff.physical(to: CGPoint(x: 140, y: 220), now: 21, button: 0, pressed: false)
        check(handoff.target(offset: CGPoint(x: 950, y: 950), now: 21.1) == nil,
              "physical release retains short priority window")
        check(handoff.target(offset: CGPoint(x: 950, y: 950), now: 21.5) == CGPoint(x: 1450, y: 1350),
              "a physical drag cannot re-center the iPhone's cursor mapping")
        handoff.physical(to: CGPoint(x: -200, y: 50), now: 22)
        check(handoff.target(offset: CGPoint(x: 1200, y: 1800), now: 23) == nil,
              "late first phone frame establishes baseline without moving real mouse")
        check(handoff.target(offset: CGPoint(x: 1200, y: 1800), now: 23.1) == CGPoint(x: 1700, y: 2200),
              "late phone frames retain the original centering after physical takeover")

        var resumedAnchor = PhonePointerAnchor()
        var keyboardAnchor = PhonePointerAnchor()
        keyboardAnchor.reset(to: center)
        keyboardAnchor.keyboard(at: mouse, now: 1, key: 0, pressed: true)
        check(keyboardAnchor.target(offset: CGPoint(x: 50, y: 30), now: 1.1) == nil,
              "physical Mac typing suppresses incoming phone cursor targets")
        check(!keyboardAnchor.allowsRemote(now: 10), "held Mac key blocks phone motion even before/without key repeat")
        keyboardAnchor.keyboard(at: mouse, now: 10, key: 0, pressed: false)
        check(keyboardAnchor.target(offset: CGPoint(x: 80, y: 40), now: 10.1) == nil,
              "phone stays paused during quiet period after typing ends")
        check(!keyboardAnchor.allowsRemote(now: 10.9), "normal keyboard monitor also keeps the full one-second typing pause")
        let resumedAfterTyping = keyboardAnchor.target(offset: CGPoint(x: 80, y: 40), now: 11.01)
        check(resumedAfterTyping == CGPoint(x: 580, y: 440),
              "typing cannot re-center the iPhone's cursor mapping")
        check(keyboardAnchor.target(offset: CGPoint(x: 90, y: 45), now: 11.1) == CGPoint(x: 590, y: 445),
              "phone resumes from its original center after typing")
        keyboardAnchor.keyboard(at: mouse, now: 12, key: nil, pressed: false, modifiersHeld: true)
        check(!keyboardAnchor.allowsRemote(now: 20), "held Command/Shift/Option/Control also pauses remote cursor")
        keyboardAnchor.keyboard(at: mouse, now: 20, key: nil, pressed: false, modifiersHeld: false)
        check(keyboardAnchor.allowsRemote(now: 21), "releasing modifiers restores phone control after quiet period")
        keyboardAnchor.keyboard(at: mouse, now: 21, key: 1, pressed: true)
        keyboardAnchor.keyboard(at: mouse, now: 21.1, key: 2, pressed: true)
        keyboardAnchor.keyboard(at: mouse, now: 21.2, key: 1, pressed: false)
        check(!keyboardAnchor.allowsRemote(now: 22), "releasing one Mac key does not clear another held key")
        keyboardAnchor.keyboard(at: mouse, now: 22, key: 2, pressed: false)
        check(keyboardAnchor.allowsRemote(now: 23), "all Mac keys released restores phone control")
        let savedOffset = CGPoint(x: 100, y: -60)
        let existingCursor = CGPoint(x: 710, y: 290)
        resumedAnchor.resume(at: existingCursor, offset: savedOffset, sameReference: false)
        check(resumedAnchor.target(offset: savedOffset, now: 1) == existingCursor,
              "first connection/server restart resumes at existing cursor without centering")
        resumedAnchor.resume(at: existingCursor, offset: savedOffset, sameReference: true)
        check(resumedAnchor.target(offset: CGPoint(x: 110, y: -60), now: 2) == CGPoint(x: 720, y: 290),
              "reconnect retains the established screen anchor")
        resumedAnchor.physical(to: mouse, now: 3)
        resumedAnchor.resume(at: mouse, offset: savedOffset, sameReference: true)
        _ = resumedAnchor.target(offset: savedOffset, now: 3.1)
        check(resumedAnchor.target(offset: savedOffset, now: 4) == existingCursor,
              "physical mouse changes made while phone was inactive do not re-center the phone")

        var reset = PointerResetState()
        let a = UUID().uuidString, b = UUID().uuidString
        var centers = 0
        check(!reset.accepts(a), "motion rejected before reset")
        check(reset.reset(id: a) { centers += 1; return true }, "successful reset establishes generation")
        check(reset.reset(id: a) { centers += 1; return true } && centers == 1,
              "duplicate reset is acknowledged without recentering")
        check(!reset.reset(id: b) { false } && reset.accepts(a) && !reset.accepts(b),
              "failed centering does not acknowledge a new generation")
        check(reset.reset(id: b) { true } && !reset.accepts(a) && reset.accepts(b),
              "old queued motion rejected after reset")
        check(!reset.reset(id: "malformed") { fatalError("must not run") }, "malformed reset ignored")
        var resumeSession = PointerResetState()
        var resumes = 0
        check(resumeSession.resume(id: a) { resumes += 1; return true } && resumeSession.accepts(a),
              "new connection acknowledges a saved generation without reset")
        check(resumeSession.resume(id: a) { resumes += 1; return true } && resumes == 1,
              "resume retries do not re-anchor twice")
    }

    static func testStatusPolling() {
        let network = DispatchQueue(label: "test.input.network")
        let key = DispatchSpecificKey<Int>()
        network.setSpecific(key: key, value: 1)
        let poller = StatusPoller<Int>()
        let entered = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let motion = DispatchSemaphore(value: 0)
        check(poller.request(deliverOn: network, read: {
            precondition(DispatchQueue.getSpecific(key: key) == nil)
            entered.signal(); unblock.wait()
            return 7
        }, deliver: { value in
            if value == 7, DispatchQueue.getSpecific(key: key) == 1 { delivered.signal() }
        }), "status polling starts on a worker, not the input queue")
        check(entered.wait(timeout: .now() + 2) == .success, "slow status query started")
        check(!poller.request(deliverOn: network, read: { 99 }, deliver: { _ in }),
              "slow status reads cannot accumulate overlapping polls")
        network.async { motion.signal() }
        let inputProgress = motion.wait(timeout: .now() + 1)
        unblock.signal()
        check(inputProgress == .success, "input queue remains responsive while status read is blocked")
        check(delivered.wait(timeout: .now() + 2) == .success,
              "status result is delivered back on the input queue")

        let oldEntered = DispatchSemaphore(value: 0)
        let oldUnblock = DispatchSemaphore(value: 0)
        let staleDelivered = DispatchSemaphore(value: 0)
        check(poller.request(deliverOn: network, read: {
            oldEntered.signal(); oldUnblock.wait(); return 8
        }, deliver: { _ in staleDelivered.signal() }), "completed poll releases its in-flight slot")
        check(oldEntered.wait(timeout: .now() + 2) == .success, "old-connection status read started")
        poller.invalidate()
        oldUnblock.signal()
        let deadline = Date().addingTimeInterval(2)
        while poller.isBusy && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        network.sync {}
        check(!poller.isBusy && staleDelivered.wait(timeout: .now()) == .timedOut,
              "disconnect/reconnect discards old in-flight status results")
        let fresh = DispatchSemaphore(value: 0)
        check(poller.request(deliverOn: network, read: { 42 }, deliver: { value in
            if value == 42 { fresh.signal() }
        }), "fresh connection can request status after invalidation")
        check(fresh.wait(timeout: .now() + 2) == .success, "fresh status still publishes after reconnect")
    }
}
