#!/usr/bin/env python3
"""Measure repeated tagged cmux reloads without hiding failed builds."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import signal
import subprocess
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="isolated reload tag")
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--profile", default="unspecified")
    parser.add_argument("--derived-data", type=pathlib.Path)
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument(
        "--prod-auth",
        action="store_true",
        help="use reload.sh production-auth build settings without the private dev backend",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=900,
        help="maximum seconds per reload; timed-out samples are recorded as failures",
    )
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    command = ["./scripts/reload.sh", "--tag", args.tag]
    if args.prod_auth:
        command.append("--prod-auth")
    if args.derived_data:
        command += ["--derived-data", str(args.derived_data)]
    environment = os.environ.copy()
    if args.keep_running:
        environment["CMUX_RELOAD_KEEP_RUNNING"] = "1"

    samples: list[dict[str, object]] = []
    for index in range(args.iterations):
        started = time.monotonic()
        timed_out = False
        process = subprocess.Popen(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            start_new_session=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=args.timeout)
            output = stdout + stderr
            exit_code = process.returncode
        except subprocess.TimeoutExpired as timeout:
            timed_out = True
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            stdout, stderr = process.communicate()
            if isinstance(stdout, bytes):
                stdout = stdout.decode(errors="replace")
            if isinstance(stderr, bytes):
                stderr = stderr.decode(errors="replace")
            output = stdout + stderr
            exit_code = None
        elapsed = time.monotonic() - started
        combined = output.splitlines()
        samples.append(
            {
                "iteration": index + 1,
                "elapsed_seconds": round(elapsed, 3),
                "exit_code": exit_code,
                "timed_out": timed_out,
                "tail": combined[-20:],
            }
        )

    result = {
        "schema_version": 1,
        "profile": args.profile,
        "tag": args.tag,
        "iterations": args.iterations,
        "command": command,
        "keep_running": args.keep_running,
        "prod_auth": args.prod_auth,
        "timeout_seconds": args.timeout,
        "samples": samples,
        "successful_samples": [
            sample["elapsed_seconds"] for sample in samples if sample["exit_code"] == 0
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if all(sample["exit_code"] == 0 for sample in samples) else 1


if __name__ == "__main__":
    raise SystemExit(main())
