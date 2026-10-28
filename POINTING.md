# Pointing and reset

The selected drift improvements are 1, 2, 3, 5 and 7. No angle-dependent gain or
general Mac cursor-position feedback was added.

- A reset captures the phone's neutral attitude, sends a fresh UUID, and waits for
  the Mac to confirm successful centering before sending pointer targets. The Mac
  accepts only the current connection and generation. Retries do not center twice.
- The top-left center button captures a fresh neutral pose and centers the Mac.
  Holding the touch surface for 200 ms instead presses the left mouse button;
  gyro motion sends real left-drag events until finger-up/cancellation. Scrolling
  and horizontal shortcuts are exclusive with holding; release never adds a tap.
  A native touch surface classifies each touch directly: quick release sends one
  click immediately, without nested gesture recognizers swallowing short taps.
  Holds release on disconnect, background, reset, sleep and physical mouse input,
  with a 1.5-second heartbeat lease as a network-failure safeguard.
  Reset clears all prior tap/filter state. Opening the app and
  reconnecting resume the saved reference instead; they never center the cursor.
  The phone saves neutral, visible offset, sensitivity and reference generation
  every second and on backgrounding. A new Mac server binds that saved offset to
  its current cursor location without warping; a retained server keeps its anchor.
- Relative attitude rotates a pointing ray. Orthogonal yaw/pitch axes at neutral
  keep a sideways grip from shearing movement. Roll around the pointing ray is
  ignored. Gain is constant: sensitivity 27 gives 1,944 screen points per radian,
  matching the old speed curve's medium-speed gain. Speed acceleration is removed.
- Light time-based filtering affects the displayed target, never the neutral pose.
  There is no velocity deadzone. Taps briefly hold the visible target, then smoothly
  catch up to the current attitude, preserving intentional rotation during a tap.
- Screen clipping leaves the underlying target unchanged. Returning to neutral
  returns to the reset center, even after travel beyond a screen edge. Physical
  mouse movement/clicks/scrolling and physical Mac typing take priority, including
  throughout held mouse buttons, keys or modifiers. Mouse input keeps a 300 ms
  quiet period; keyboard activity keeps a one-second quiet period afterward.
  Caps Lock's latched state does not count as a held modifier. iPhone-generated
  key events are tagged and excluded. No typed characters are retained or logged.
  Keyboard takeover also cancels pending cursor interpolation and remote holds.
  Secure Input can hide normal key events even with Accessibility/Input Monitoring
  granted. A fallback samples only public hardware key-down/up activity counters
  without reading key identities or text. This fallback pauses for one second after
  detected activity, never indefinitely based on an inferred held-key state.
  iPhone keyboard events
  use a private Core Graphics source state rather than the hardware state table.
  Phone targets during takeover are absorbed, and its
  screen anchor follows the real mouse; returning to phone control does not snap
  back or replay suppressed motion. Explicit reset establishes a new screen center.
- Core Motion uses xMagneticNorthZVertical when supported, giving saved attitudes
  a compass-fixed reference that survives app/sensor restarts. Otherwise it uses
  xArbitraryCorrectedZVertical or xArbitraryZVertical and aligns the first new pose
  to the last saved pose (heading changes while inactive cannot be recovered on
  hardware without a compass). The frame stays fixed for the session. Correction
  depends on calibration and local magnetic conditions; it is not a guarantee of
  zero drift. Diagnostics include frame selection and magnetic accuracy.

Run deterministic math/reset/edge tests with `bash tests/run-pointing-tests.sh`.
On-device checks: use the center button; hold and aim to drag, then release;
background while holding and verify the Mac button releases; turn out and back at different
speeds; repeat after touching a screen edge; tap while turning; background/reopen;
quit/relaunch and check there is no automatic reset or cursor centering.
Return to the same phone orientation, not just the same physical location.
