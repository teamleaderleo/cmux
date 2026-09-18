#!/usr/bin/env python3
"""Measure repeated tagged cmux reloads without hiding failed builds."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import time


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="isolated reload tag")
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--profile", default="unspecified")
    parser.add_argument("--derived-data", type=pathlib.Path)
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("--iterations must be positive")

    command = ["./scripts/reload.sh", "--tag", args.tag]
    if args.derived_data:
        command += ["--derived-data", str(args.derived_data)]
    environment = os.environ.copy()
    if args.keep_running:
        environment["CMUX_RELOAD_KEEP_RUNNING"] = "1"

    samples: list[dict[str, object]] = []
    for index in range(args.iterations):
        started = time.monotonic()
        completed = subprocess.run(
            command, text=True, capture_output=True, check=False, env=environment
        )
        elapsed = time.monotonic() - started
        combined = (completed.stdout + completed.stderr).splitlines()
        samples.append(
            {
                "iteration": index + 1,
                "elapsed_seconds": round(elapsed, 3),
                "exit_code": completed.returncode,
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
