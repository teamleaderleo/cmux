#!/usr/bin/env python3
"""Source-pinned scaling model for chatmux journal forwarding.

This is deliberately a model, not runtime evidence. It reads the current
journal_forwarder.rs constants from the checkout so a stale experiment cannot
silently report numbers for a different implementation.

The model starts at the first threshold flush: one MAX_BATCH_RECORDS batch is
already owned by post_with_retry, while all later producer records accumulate
behind the single in-flight POST during an outage.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
from dataclasses import asdict, dataclass

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "cmux-tui/crates/chatmux-relay/src/journal_forwarder.rs"


def integer_constant(source: str, name: str) -> int:
    pattern = rf"(?:pub\s+)?const\s+{re.escape(name)}:\s+usize\s*=\s*([^;]+);"
    match = re.search(pattern, source)
    if not match:
        raise SystemExit(f"could not find usize constant {name} in {SOURCE}")
    expression = match.group(1).strip()
    if not re.fullmatch(r"[0-9\s*+()]+", expression):
        raise SystemExit(f"refusing to evaluate unexpected expression for {name}: {expression}")
    return int(eval(expression, {"__builtins__": {}}, {}))


def duration_seconds(source: str, name: str) -> float:
    pattern = rf"const\s+{re.escape(name)}:\s+Duration\s*=\s+Duration::from_(secs|millis)\((\d+)\);"
    match = re.search(pattern, source)
    if not match:
        raise SystemExit(f"could not find Duration constant {name} in {SOURCE}")
    unit, raw = match.groups()
    value = int(raw)
    return float(value if unit == "secs" else value / 1000)


@dataclass(frozen=True)
class Constants:
    max_batch_records: int
    max_batch_body_bytes: int
    max_discovered_sessions: int
    request_timeout_seconds: float
    max_retry_backoff_seconds: float


@dataclass(frozen=True)
class Row:
    requested_sessions: int
    active_sessions: int
    records_per_second_per_session: float
    aggregate_records_per_second: float
    outage_seconds: float
    in_flight_batch_records: int
    pending_records_after_outage: int
    pending_encoded_bytes_after_outage: int
    pending_mib_after_outage: float
    recovery_service_records_per_second: float | None
    recovery_net_drain_records_per_second: float | None
    settle_seconds_after_recovery: float | None


def load_constants() -> Constants:
    source = SOURCE.read_text(encoding="utf-8")
    return Constants(
        max_batch_records=integer_constant(source, "MAX_BATCH_RECORDS"),
        max_batch_body_bytes=integer_constant(source, "MAX_BATCH_BODY_BYTES"),
        max_discovered_sessions=integer_constant(source, "MAX_DISCOVERED_SESSIONS"),
        request_timeout_seconds=duration_seconds(source, "DEFAULT_REQUEST_TIMEOUT"),
        max_retry_backoff_seconds=duration_seconds(source, "DEFAULT_MAX_BACKOFF"),
    )


def model_row(
    constants: Constants,
    requested_sessions: int,
    records_per_second: float,
    encoded_record_bytes: int,
    outage_seconds: float,
    recovery_service_records_per_second: float | None,
) -> Row:
    active_sessions = min(requested_sessions, constants.max_discovered_sessions)
    arrival_rate = active_sessions * records_per_second
    produced = int(arrival_rate * outage_seconds)
    pending = max(0, produced - constants.max_batch_records)
    pending_bytes = pending * encoded_record_bytes

    net_drain: float | None = None
    settle: float | None = None
    if recovery_service_records_per_second is not None:
        net_drain = recovery_service_records_per_second - arrival_rate
        if net_drain > 0:
            settle = pending / net_drain
        elif pending == 0:
            settle = 0.0

    return Row(
        requested_sessions=requested_sessions,
        active_sessions=active_sessions,
        records_per_second_per_session=records_per_second,
        aggregate_records_per_second=arrival_rate,
        outage_seconds=outage_seconds,
        in_flight_batch_records=constants.max_batch_records,
        pending_records_after_outage=pending,
        pending_encoded_bytes_after_outage=pending_bytes,
        pending_mib_after_outage=pending_bytes / (1024 * 1024),
        recovery_service_records_per_second=recovery_service_records_per_second,
        recovery_net_drain_records_per_second=net_drain,
        settle_seconds_after_recovery=settle,
    )


def parse_sessions(raw: str) -> list[int]:
    values = [int(part.strip()) for part in raw.split(",") if part.strip()]
    if not values or any(value <= 0 for value in values):
        raise argparse.ArgumentTypeError("sessions must contain positive integers")
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sessions", type=parse_sessions, default=parse_sessions("1,10,50,128,200"))
    parser.add_argument("--records-per-second", type=float, default=10.0)
    parser.add_argument("--encoded-record-bytes", type=int, default=2048)
    parser.add_argument("--outage-seconds", type=float, default=60.0)
    parser.add_argument(
        "--recovery-service-records-per-second",
        type=float,
        default=None,
        help="optional single-consumer service rate used to calculate settle time",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    constants = load_constants()
    rows = [
        model_row(
            constants,
            requested_sessions=count,
            records_per_second=args.records_per_second,
            encoded_record_bytes=args.encoded_record_bytes,
            outage_seconds=args.outage_seconds,
            recovery_service_records_per_second=args.recovery_service_records_per_second,
        )
        for count in args.sessions
    ]

    # Pin the discovery-cap plateau in the default 128/200 sequence.
    by_requested = {row.requested_sessions: row for row in rows}
    if 128 in by_requested and 200 in by_requested and constants.max_discovered_sessions == 128:
        assert by_requested[128].active_sessions == by_requested[200].active_sessions == 128
        assert (
            by_requested[128].pending_records_after_outage
            == by_requested[200].pending_records_after_outage
        )

    if args.json:
        print(json.dumps({"constants": asdict(constants), "rows": [asdict(row) for row in rows]}, indent=2))
        return

    print(f"source={SOURCE.relative_to(ROOT)}")
    print(
        "constants="
        f"batch_records:{constants.max_batch_records} "
        f"batch_body_bytes:{constants.max_batch_body_bytes} "
        f"discovered_sessions:{constants.max_discovered_sessions} "
        f"request_timeout_s:{constants.request_timeout_seconds:g} "
        f"max_retry_backoff_s:{constants.max_retry_backoff_seconds:g}"
    )
    print(
        "requested active aggregate_rps pending_records pending_MiB "
        "net_drain_rps settle_s"
    )
    for row in rows:
        net_drain = "-" if row.recovery_net_drain_records_per_second is None else f"{row.recovery_net_drain_records_per_second:.2f}"
        if row.settle_seconds_after_recovery is None:
            settle = "infinite/unknown" if row.recovery_net_drain_records_per_second is not None else "-"
        else:
            settle = f"{row.settle_seconds_after_recovery:.2f}"
        print(
            f"{row.requested_sessions:9d} {row.active_sessions:6d} "
            f"{row.aggregate_records_per_second:13.2f} "
            f"{row.pending_records_after_outage:15d} "
            f"{row.pending_mib_after_outage:11.2f} "
            f"{net_drain:>13} {settle:>16}"
        )


if __name__ == "__main__":
    main()
