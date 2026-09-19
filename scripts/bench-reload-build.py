#!/usr/bin/env python3
"""Measure repeated tagged cmux reloads without hiding failed builds."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import selectors
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
        completion_marker = ""
        reload_log_path: pathlib.Path | None = None
        process = subprocess.Popen(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            start_new_session=True,
            bufsize=1,
        )

        # reload.sh can finish the build and print its completion summary while
        # a descendant keeps the inherited stdout/stderr pipes open. Waiting on
        # communicate() in that case turns a successful build into a timeout.
        # The summary is emitted only after the build and post-build cleanup are
        # complete, so terminate the isolated process group at that marker and
        # measure the build instead of waiting for unrelated descendants.
        output_parts: list[str] = []
        selector = selectors.DefaultSelector()
        assert process.stdout is not None
        assert process.stderr is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        selector.register(process.stderr, selectors.EVENT_READ)
        deadline = started + args.timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            events = selector.select(remaining)
            if not events:
                timed_out = True
                break
            for key, _ in events:
                line = key.fileobj.readline()
                if line == "":
                    selector.unregister(key.fileobj)
                    continue
                output_parts.append(line)
                if "log:" in line:
                    candidate = line.split("log:", 1)[1].strip().rstrip(")")
                    if candidate.startswith("/"):
                        reload_log_path = pathlib.Path(candidate)
                if "Build complete." in line:
                    completion_marker = "build_complete"
                elif "==> reload succeeded" in line and not completion_marker:
                    completion_marker = "reload_succeeded"
            if completion_marker:
                break

        selector.close()
        if timed_out or completion_marker:
            if process.poll() is None:
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
            # A descendant can retain the pipe after the isolated reload
            # process exits. Close our descriptors instead of waiting for EOF
            # from an unrelated child; the selector already captured the
            # output needed for this receipt.
            process.stdout.close()
            process.stderr.close()
        else:
            process.wait()
            process.stdout.close()
            process.stderr.close()

        output = "".join(output_parts)
        if (timed_out or (process.returncode not in (None, 0))) and reload_log_path:
            try:
                log_tail = reload_log_path.read_text(errors="replace").splitlines()[-20:]
            except OSError:
                log_tail = []
            if log_tail:
                output += "\n==> reload log tail:\n" + "\n".join(log_tail) + "\n"
        exit_code = process.returncode
        if completion_marker and not timed_out:
            # The process group is deliberately terminated after the build
            # summary. Preserve a successful benchmark result even when a
            # descendant kept the pipes open and forced that cleanup.
            exit_code = 0
        elapsed = time.monotonic() - started
        combined = output.splitlines()
        samples.append(
            {
                "iteration": index + 1,
                "elapsed_seconds": round(elapsed, 3),
                "exit_code": exit_code,
                "timed_out": timed_out,
                "completion_marker": completion_marker or None,
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
            sample["elapsed_seconds"]
            for sample in samples
            if sample["exit_code"] == 0 and not sample["timed_out"]
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    return 0 if all(sample["exit_code"] == 0 for sample in samples) else 1


if __name__ == "__main__":
    raise SystemExit(main())
