#!/usr/bin/env python3
"""Re-derive this personal fork's CI policy over upstream workflow files.

The fork cannot use the upstream organization's paid runner fleet, and must not
fire upstream's release automation. Both rules were originally applied as
one-off commits, which makes every upstream merge conflict on the same files.
Expressing them as an idempotent transform means an upstream merge can take
upstream's workflows wholesale and then re-run this script.

Policy (documented in docs/ci-runners.md):

  1. Ordinary Linux CI defaults to GitHub-hosted runners. Paid Linux provider
     labels queue forever here because the provider is absent. `LINUX_RUNNER`
     stays an override, so only the *fallback* literal is rewritten.
  2. Upstream release automation is manual-only in this fork: Nightly macOS and
     the CMUX INTERNAL TestFlight workflow keep `workflow_dispatch` and lose
     `push` / `schedule` triggers.

macOS runner labels are deliberately untouched: those lanes are opt-in and are
not part of ordinary CI.

Usage:
    python3 scripts/apply-fork-ci-policy.py [--check]

`--check` exits non-zero if the policy is not already applied, and prints what
would change. Safe to run repeatedly; it is a fixpoint.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github/workflows"

# Paid Linux provider fallbacks -> GitHub-hosted equivalents.
# Order matters: the -arm variants must be tried before their non-arm prefixes.
LINUX_FALLBACKS = [
    (re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+-arm\b"), "ubuntu-24.04-arm"),
    (re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+\b"), "ubuntu-24.04"),
    (re.compile(r"warp-ubuntu-[a-z0-9]+-arm64-\d+x\b"), "ubuntu-24.04-arm"),
    (re.compile(r"warp-ubuntu-[a-z0-9]+-x64-\d+x\b"), "ubuntu-24.04"),
    (re.compile(r"depot-ubuntu-[a-z0-9.-]*arm\b"), "ubuntu-24.04-arm"),
    (re.compile(r"depot-ubuntu-[a-z0-9.-]+\b"), "ubuntu-24.04"),
]

# Workflows whose upstream automation must not fire in this fork.
MANUAL_ONLY = ("nightly.yml", "ios-testflight.yml")

TRIGGER_BLOCK = re.compile(
    r"^(?P<indent>  )(?P<key>push|schedule|pull_request|merge_group):[^\n]*\n"
    r"(?:(?:\1\s+[^\n]*|\s*#[^\n]*|)\n)*?"
    r"(?=^  \S|^\S|\Z)",
    re.M,
)


def rewrite_linux_fallbacks(text: str) -> tuple[str, int]:
    changed = 0
    for pattern, replacement in LINUX_FALLBACKS:
        text, n = pattern.subn(replacement, text)
        changed += n
    return text, changed


def make_manual_only(text: str) -> tuple[str, int]:
    """Strip automatic triggers from an `on:` block, keeping workflow_dispatch."""
    match = re.search(r"^on:\s*\n(?P<body>(?:^[ \t]+.*\n|^\s*#.*\n|^\s*\n)*)", text, re.M)
    if not match:
        return text, 0
    body = match.group("body")
    stripped, n = TRIGGER_BLOCK.subn("", body)
    if n == 0:
        return text, 0
    if "workflow_dispatch" not in stripped:
        stripped = "  workflow_dispatch:\n" + stripped
    return text[: match.start("body")] + stripped + text[match.end("body") :], n


def main() -> int:
    check = "--check" in sys.argv
    if not WORKFLOWS.is_dir():
        print(f"no workflows directory at {WORKFLOWS}", file=sys.stderr)
        return 2

    pending: list[str] = []
    runner_hits = trigger_hits = 0

    for path in sorted(WORKFLOWS.glob("*.yml")):
        original = path.read_text(encoding="utf-8")
        text, n = rewrite_linux_fallbacks(original)
        runner_hits += n
        if path.name in MANUAL_ONLY:
            text, m = make_manual_only(text)
            trigger_hits += m
        if text != original:
            pending.append(path.name)
            if not check:
                path.write_text(text, encoding="utf-8")

    verb = "would rewrite" if check else "rewrote"
    print(f"{verb} {runner_hits} paid Linux runner fallback(s) "
          f"and {trigger_hits} automatic trigger block(s)")
    if pending:
        for name in pending:
            print(f"  {name}")
    else:
        print("  fork CI policy already applied")

    if check and pending:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
