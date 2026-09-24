#!/usr/bin/env python3
"""The owner-gated Blacksmith fallback every workflow runner literal uses.

Blacksmith runners exist only in the manaflow-ai organization. A workflow
running anywhere else (a fork's own push, dispatch or schedule) that falls back
to a `blacksmith-*` label queues forever, and a wedged run holds its
concurrency group, so later runs on the same ref queue behind it too.

Every Blacksmith literal a workflow can fall back to is therefore written as

    (github.repository_owner == 'manaflow-ai' && 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04')

inside an expression, or, where the whole value is the label,

    ${{ github.repository_owner == 'manaflow-ai' && 'blacksmith-4vcpu-ubuntu-2404' || 'ubuntu-24.04' }}

Both labels are non-empty strings, so under manaflow-ai the token evaluates to
exactly the Blacksmith literal it replaced and every `vars.*` / `inputs.*`
override around it keeps its precedence. Pull requests from forks to
manaflow-ai/cmux run in the upstream repository, so they are unaffected too.

A dispatch input whose default is a Blacksmith label is translated where it is
read, in the same shape:

    (github.repository_owner == 'manaflow-ai' && inputs.runner || inputs.runner == 'blacksmith-6vcpu-macos-26' && 'macos-26' || inputs.runner)

`collapse()` rewrites each canonical form back to the literal it gates, which is
the text an upstream run effectively evaluates. Guards that pin upstream runner
routing read collapsed text; `tests/test_ci_fork_runner_fallbacks.py` pins the
gate itself.
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

OWNER_GATE = "github.repository_owner == 'manaflow-ai'"

BLACKSMITH_LABEL = r"blacksmith-\d+vcpu-(?:ubuntu-2404|macos-15|macos-26|macos-latest)"
HOSTED_LABEL = r"ubuntu-24\.04|macos-15|macos-26|macos-latest"

# Blacksmith image suffix -> the GitHub-hosted image with the same OS.
HOSTED_EQUIVALENT = {
    "ubuntu-2404": "ubuntu-24.04",
    "macos-15": "macos-15",
    "macos-26": "macos-26",
    "macos-latest": "macos-latest",
}

_GATE = re.escape(OWNER_GATE)

# `(gate && 'blacksmith-…' || 'hosted')` inside a larger expression.
INLINE_TOKEN = re.compile(
    rf"\({_GATE} && '(?P<label>{BLACKSMITH_LABEL})' \|\| '(?P<hosted>{HOSTED_LABEL})'\)"
)
# `${{ gate && 'blacksmith-…' || 'hosted' }}` as a whole YAML value.
WHOLE_VALUE = re.compile(
    rf"\$\{{\{{ {_GATE} && '(?P<label>{BLACKSMITH_LABEL})' \|\| '(?P<hosted>{HOSTED_LABEL})' \}}\}}"
)
# `(gate && inputs.X || inputs.X == 'blacksmith-…' && 'hosted' … || inputs.X)`.
INPUT_TRANSLATION = re.compile(
    rf"\({_GATE} && (?P<input>inputs\.[A-Za-z0-9_]+)"
    rf"(?P<arms>(?: \|\| (?P=input) == '{BLACKSMITH_LABEL}' && '(?:{HOSTED_LABEL})')+)"
    rf" \|\| (?P=input)\)"
)
INPUT_ARM = re.compile(rf"== '(?P<label>{BLACKSMITH_LABEL})' && '(?P<hosted>{HOSTED_LABEL})'")


def hosted_equivalent(label: str) -> str:
    for suffix, hosted in HOSTED_EQUIVALENT.items():
        if label.endswith("-" + suffix):
            return hosted
    raise ValueError(f"no GitHub-hosted equivalent for {label!r}")


def gated(label: str) -> str:
    return f"({OWNER_GATE} && '{label}' || '{hosted_equivalent(label)}')"


def collapse(text: str) -> str:
    """Rewrite each canonical fork fallback to the upstream literal it gates."""
    text = WHOLE_VALUE.sub(lambda m: m.group("label"), text)
    text = INLINE_TOKEN.sub(lambda m: f"'{m.group('label')}'", text)
    return INPUT_TRANSLATION.sub(lambda m: m.group("input"), text)


def collapse_tree(source: Path, destination: Path) -> None:
    """Copy a workflows directory with every canonical fallback collapsed."""
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True)
    for path in sorted(source.iterdir()):
        if path.is_file():
            (destination / path.name).write_text(
                collapse(path.read_text(encoding="utf-8")), encoding="utf-8"
            )


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "collapse-tree":
        collapse_tree(Path(argv[1]), Path(argv[2]))
        return 0
    print("usage: runner_fallback.py collapse-tree SOURCE_DIR DEST_DIR", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
