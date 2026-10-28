#!/usr/bin/env python3
"""Summarize Mac Remote timing-only JSONL traces using the Python standard library."""
import argparse
import bisect
import collections
import json
import math


def percentiles(values):
    values = sorted(x for x in values if math.isfinite(x))
    if not values:
        return {"count": 0}
    def p(fraction):
        at = (len(values) - 1) * fraction
        lo = int(at)
        return values[lo] + (values[min(lo + 1, len(values) - 1)] - values[lo]) * (at - lo)
    return {"count": len(values), "p50": round(p(.5), 3), "p95": round(p(.95), 3),
            "p99": round(p(.99), 3), "max": round(values[-1], 3)}


def summarize(rows):
    events = collections.Counter(row.get("event") for row in rows)
    summary = {"events": dict(events), "units": "milliseconds unless named otherwise"}
    summary["server_transport_config"] = [
        {k: r[k] for k in ("tcp_nodelay", "tcp_no_ack_stretching", "udp_service_class") if k in r}
        for r in rows if r.get("event") == "transport_config"]
    motions = [r for r in rows if r.get("event") == "motion"]
    queues = [r for r in rows if r.get("event") == "server_queue"]
    polls = [r for r in rows if r.get("event") == "focus_poll"]
    summary["mac_dispatch_queue_wait_ms"] = percentiles(r["wait_ms"] for r in queues)
    summary["focus_poll_off_network_queue"] = sorted({r.get("off_network_queue", False) for r in polls})
    summary["focus_poll_delivery_wait_ms"] = percentiles(r["delivery_wait_ms"] for r in polls if "delivery_wait_ms" in r)
    for field in ("input_ms", "audio_ms", "fullscreen_ms", "total_ms"):
        summary["focus_poll_" + field] = percentiles(r[field] for r in polls)
    summary["mac_parse_ms"] = percentiles((r["parsed_s"] - r["receive_s"]) * 1000 for r in motions)
    summary["mac_injection_call_ms"] = percentiles((r["injection_end_s"] - r["injection_start_s"]) * 1000 for r in motions)
    observed = {r["event_timestamp_ns"]: r["observed_s"] for r in rows
                if r.get("event") == "pointer_observed"}
    observed_keys = sorted(observed)
    observation_lag = []
    for row in motions:
        timestamp = row.get("event_timestamp_ns", 0)
        if timestamp == 0:
            continue
        i = bisect.bisect_left(observed_keys, timestamp)
        candidates = observed_keys[max(i - 1, 0):i + 1]
        if candidates:
            nearest = min(candidates, key=lambda k: abs(k - timestamp))
            # NSEvent bridges a Double timestamp; tolerate nanosecond rounding only.
            if abs(nearest - timestamp) <= 2000:
                observation_lag.append((observed[nearest] - row["injection_end_s"]) * 1000)
    summary["post_to_macos_observer_ms"] = percentiles(
        observation_lag)
    # contentProcessed means accepted by the sending stack, not acknowledged by the Mac.
    completions = [r for r in rows if r.get("event") == "client_send_complete"]
    summary["client_stack_acceptance_ms_NOT_network_RTT"] = percentiles(
        (r["completed_s"] - r["started_s"]) * 1000 for r in completions)
    summary["client_serialization_ms"] = percentiles(r["serialization_ms"] for r in completions)
    probes = []
    for r in rows:
        if r.get("event") != "clock_probe":
            continue
        try:
            t0, t1, t2, t3 = [r[k] for k in ("client_send_s", "mac_receive_s", "mac_reply_s", "client_receive_s")]
        except KeyError:
            continue
        rtt = (t3 - t0) - (t2 - t1)
        if rtt >= 0:
            probes.append((rtt, (t1 + t2 - t0 - t3) / 2, t2 - t3, t1 - t0))
    summary["probe_round_trip_ms"] = percentiles(p[0] * 1000 for p in probes)
    if probes:
        best = min(probes)
        summary["clock_alignment"] = {"method": "midpoint of minimum-RTT four-timestamp probe",
            "offset_mac_minus_client_s": best[1], "uncertainty_ms": best[0] * 500,
            "note": "One-way estimates include Mac dispatch delay; asymmetric paths limit accuracy."}

    streams = collections.defaultdict(list)
    for row in motions:
        streams[(row.get("connection"), row.get("diag_stream"), row.get("transport", "websocket"))].append(row)
    summary["streams"] = []
    for (connection, stream_id, transport), frames in streams.items():
        frames.sort(key=lambda r: r["receive_s"])
        stream = {"connection": connection, "client_stream": stream_id, "frames": len(frames),
                  "transport": transport,
                  "transports": dict(collections.Counter(r.get("transport", "websocket") for r in frames)),
                  "moving_frames": sum(r["moving"] for r in frames),
                  "mac_receive_gap_ms": percentiles((b["receive_s"] - a["receive_s"]) * 1000
                      for a, b in zip(frames, frames[1:]))}
        timed = [r for r in frames if all(k in r for k in ("diag_sensor_s", "diag_callback_s",
                  "diag_computed_s", "diag_enqueued_s", "diag_tx_s"))]
        stream["instrumented_frames"] = len(timed)
        if timed:
            stream["client_transport_config"] = {
                "udp_priority": sorted({r["diag_udp_priority"] for r in timed if "diag_udp_priority" in r}),
                "tcp_nodelay": sorted({r["diag_tcp_nodelay"] for r in timed if "diag_tcp_nodelay" in r}),
                "tcp_no_ack_stretching": sorted({r["diag_tcp_no_ack_stretching"] for r in timed if "diag_tcp_no_ack_stretching" in r}),
                "peer_discovery": sorted({r["diag_peer_discovery"] for r in timed if "diag_peer_discovery" in r})}
            for label, field in (("gyro_sample_gap_ms", "diag_sensor_s"), ("gyro_callback_gap_ms", "diag_callback_s"),
                                 ("client_send_gap_ms", "diag_tx_s")):
                stream[label] = percentiles((b[field] - a[field]) * 1000 for a, b in zip(timed, timed[1:]))
            stream["sensor_to_callback_age_ms"] = percentiles((r["diag_callback_s"] - r["diag_sensor_s"]) * 1000 for r in timed)
            stream["motion_lock_wait_ms"] = percentiles(r.get("diag_lock_ms", 0) for r in timed)
            stream["motion_compute_ms_including_lock_wait"] = percentiles((r["diag_computed_s"] - r["diag_callback_s"]) * 1000 for r in timed)
            stream["client_network_queue_wait_ms"] = percentiles((r["diag_tx_s"] - r["diag_enqueued_s"]) * 1000 for r in timed)
            transit = [r["receive_s"] - r["diag_tx_s"] for r in timed]
            baseline = min(transit)
            stream["send_to_receive_extra_delay_ms_including_mac_dispatch"] = percentiles((v - baseline) * 1000 for v in transit)
            stream["client_sends_in_flight"] = percentiles(r.get("diag_inflight", 0) for r in timed)
            if probes:
                stream["estimated_send_to_receive_ms"] = percentiles((v - best[1]) * 1000 for v in transit)
            stalls = []
            queue_times = [r["enqueued_s"] for r in queues]
            for previous, frame in zip(timed, timed[1:]):
                gap = (frame["receive_s"] - previous["receive_s"]) * 1000
                if gap < 25:
                    continue
                lo = bisect.bisect_left(queue_times, previous["receive_s"] - .02)
                hi = bisect.bisect_right(queue_times, frame["receive_s"] + .02)
                stalls.append({"seq": frame.get("diag_seq"), "mac_receive_s": frame["receive_s"],
                    "receive_gap_ms": round(gap, 3),
                    "sensor_gap_ms": round((frame["diag_sensor_s"] - previous["diag_sensor_s"]) * 1000, 3),
                    "client_send_gap_ms": round((frame["diag_tx_s"] - previous["diag_tx_s"]) * 1000, 3),
                    "mac_queue_wait_near_stall_ms": round(max((r["wait_ms"] for r in queues[lo:hi]), default=0), 3)})
            stream["receive_stalls_over_25ms"] = len(stalls)
            stream["largest_stalls"] = sorted(stalls, key=lambda s: s["receive_gap_ms"], reverse=True)[:12]
        summary["streams"].append(stream)
    summary["limits"] = ["Mac receive timestamps are callback delivery times, not packet capture times.",
        "macOS observer time is not a physical display presentation timestamp.",
        "Frame metadata increases packet size during this opt-in session."]
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace")
    args = parser.parse_args()
    rows = []
    with open(args.trace) as source:
        for line in source:
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass  # A live trace may end with an unfinished write.
    print(json.dumps(summarize(rows), indent=2))


if __name__ == "__main__":
    main()
