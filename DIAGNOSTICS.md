# Cursor latency tracing

## iPhone lifecycle cursor visibility

The iPhone sends `client_active: false` immediately when it becomes inactive
(Home/app switching/lock). A one-second iOS background task gives the existing
encrypted WebSocket a short opportunity to transmit; it does not keep gyro or
controls running in the background. Returning to the app sends `client_active:
true` before queued actions/pose restoration. The Mac cancels pending cursor
interpolation/releases remote holds on inactivity and rejects late phone input
until the client reports active again. Physical mouse/keyboard activity restores
the cursor, as does returning to the iPhone app or quitting the backend.

Cursor hiding uses public `CGDisplayHideCursor`/`CGDisplayShowCursor` and balances
only the backend's own hide count. Duplicate lifecycle messages are idempotent.
The Mac app is never activated to steal focus from a movie. Apple documents that
background callers may not affect the cursor, so a `cursor_visibility` trace row
with `api_success: true` confirms the call, not physical visibility; verify this
visually on the target system. A broken network or abrupt termination before
the inactive signal can be transmitted cannot guarantee instantaneous hiding.

## Keyboard takeover diagnostics

`keyboard_environment` records Accessibility/Input Monitoring permission booleans
and the app's actual Secure Input state. `keyboard_detection` records only event
type classifications and whether an event has our remote tag/source PID—never
characters, key codes or text. `hardware_keyboard_activity` records `detected: true`
when public HID keyboard activity counters change. Those counters
provide the typing-pause fallback when Secure Input hides ordinary key events;
Secure Input is not disabled or bypassed to capture keys. Remote keyboard events
use a private source state so they do not pollute the hardware activity table.
Keyboard activity extends a one-second inactivity pause; it never infers a held key
from event ages. A missing key-up must not permanently latch the cursor pause.
Motion records include `cursor_target_accepted` to distinguish suppressed targets
from targets accepted for rendering. This is not a physical-display timestamp.

## Reconnect interaction window

Opening/foregrounding the iPhone app enables existing controls optimistically for
one second while the retained socket is validated or Bonjour reconnects. Remote button
actions are bounded to 128 queued entries and replay in order, once, only if the
connection is ready before the deadline. Gyro/absolute/relative cursor updates and
automatic pose restoration are never queued. Explicit centering and mouse hold/up
actions retain their own acknowledgment/lease safety. Backgrounding or expiration
discards the queue so a stale sleep/close-tab action cannot run on a later reconnect.
After the grace period, the normal disabled styling applies and an additional
centered Wi-Fi-off explanation/download link appears. Existing controls/layout
are otherwise unchanged; a successful reconnect clears the message automatically.

Choose **Start / Stop Latency Diagnostics (2 min)** in the Mac menu-bar app.
The iPhone receives the diagnostic configuration over its existing encrypted connection.
Both apps must use the instrumented build. Move the phone while keeping the iOS app active.
Tracing stops automatically after two minutes; the same menu item can stop it earlier.

Traces are timing-only JSONL files in `~/Library/Application Support/MacRemote/Diagnostics/`.
They do not include typed text, Accessibility text values, or the pairing secret.
Analyze a completed trace with:

```sh
python3 scripts/analyze_latency.py "/absolute/path/to/latency-SESSION.jsonl"
```

The trace separates sensor timestamps, callback scheduling, motion computation, the
iPhone network queue, JSON serialization, sending-stack acceptance, Mac receive
callbacks, Mac processing-queue delay, state polling, cursor-event posting, and
observation of posted events through macOS. It includes periodic four-timestamp
round-trip probes. Client and Mac clocks are independent; one-way delay estimates
use the lowest-RTT probe and report alignment uncertainty. Relative changes in
send-to-receive delay do not require synchronized clocks.

Status reads now run on a separate, single-in-flight worker. New traces mark
`focus_poll` with `off_network_queue: true` and report result-delivery wait
separately. A long status read no longer means the movement queue was blocked;
use the independent `server_queue` timings to check input-queue responsiveness.

Cursor targets now use a light Mac-side 120 Hz render timer: 12 ms interpolation
normally, 24 ms for the first target after a delivery gap over 35 ms. No movement
is predicted during a gap. Targets supersede earlier pending targets; interpolation
settles exactly and stops. Reset, resume, physical mouse input, disconnect and
sleep cancel pending interpolation. Screen-edge reference math remains unchanged.
For this path `mac_injection_call_ms` measures scheduling a target, not rendering
the entire move. A traced event timestamp identifies the first rendered step for
the latest target; superseded targets may have no observed event. Observer delay
includes render scheduling and is not time to the final position or presentation.

Sending-stack acceptance is **not** a TCP acknowledgment or proof of transmission.
Mac receive callback time is **not** a packet-capture timestamp. Event observation
is **not** physical display presentation time. Frame metadata increases traffic
during tracing. These limits matter when interpreting the results.

For an automatic trace after launch, start the Mac app with `--diagnostics`.
Transport settings, cursor acceleration, and smoothing are not changed by tracing.

## Encrypted UDP cursor experiment

Absolute `pointer_target` updates now prefer DTLS 1.2 over UDP, using the existing
32-byte pairing secret and `TLS_PSK_WITH_AES_256_GCM_SHA384`. The TLS WebSocket
negotiates a UDP port and per-connection session token. Only cursor targets are
accepted on that channel; clicks, mouse-button leases/releases, scrolling,
typing, reset acknowledgments and other controls stay on the reliable channel.
The first authenticated UDP hello is acknowledged over the WebSocket before
cursor traffic switches. Failed handshakes/path checks fall back to secure
WebSocket; there is no plaintext fallback. Acknowledgments while moving detect
a subsequently blocked UDP path. Returning from background renegotiates UDP.

Sequence numbers span both transports, so missing packets do not block newer
targets and reordered/duplicate targets are ignored. Reset generations still
reject pre-reset motion. The sender retains at most one in-flight cursor send
and the newest pending target. Datagrams are capped at 1,200 bytes.

Motion trace rows now include `transport` (`dtls-udp` or `websocket`); the analyzer
reports per-stream transport counts. Verify this field before comparing latency
with AirDrop on/off, since firewalls may force fallback. This experiment does not
claim to prevent radio-level stalls.

Following the UDP-only comparison, the UDP listener and iPhone cursor connection
now request `serviceClass = .interactiveVideo` (constant-rate, low-latency traffic).
The WebSocket, discovery and TCP options remain unchanged. This is only a request
to prioritize traffic; it does not guarantee radio airtime or router support.
New traces report server `udp_service_class: interactiveVideo` and client
`diag_udp_priority: 1`; the analyzer exposes both alongside actual transport counts.

Standalone DTLS smoke test (does not inject input):

```sh
swiftc -parse-as-library tests/DTLSIntegrationTests.swift -o /private/tmp/macremote-dtls-test
/private/tmp/macremote-dtls-test
```

## Controlled comparisons

Diagnostic builds accept launch-only flags; ordinary launches use LAN-only discovery and default TCP options:

- `--test-tcp-nodelay`: set TCP `noDelay` (Mac and iPhone).
- `--test-tcp-no-ack-stretching`: disable TCP acknowledgment stretching (not needed in the completed investigation).
- `--test-peer-discovery`: temporarily enable peer-to-peer interfaces in the iPhone Bonjour browser to reproduce the original stutter.
- `--diagnostics-short`: use a 40-second Mac trace instead of two minutes.

The 2026-10-18 comparison is saved in `diagnostics/2026-10-18-peer-discovery-comparison.json`.
An on/off/on test of peer discovery, using the same binaries and original TCP options,
reproduced the frequent stutter with discovery enabled and largely removed it when disabled.
This isolates the principal recurring delay to peer-to-peer discovery. It does not prove
the exact radio scheduling mechanism, and a few isolated latency spikes remained.

The confirmed fix is now applied: normal launches disable peer-to-peer discovery.
