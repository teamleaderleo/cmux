#!/usr/bin/env python3
"""A workflow must not fall back to a Blacksmith runner outside manaflow-ai.

Blacksmith runners exist only in the manaflow-ai organization. On a fork with
no repository variables, a `vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'`
job sits queued forever, and because it holds its concurrency group, every
later run on the same ref queues behind it.

Every Blacksmith literal is therefore written owner-gated, in one of the
canonical shapes in scripts/ci/runner_fallback.py, and gates to the
GitHub-hosted image with the same OS. A Blacksmith label may still appear
ungated only where it cannot be selected by a zero-configuration run:

- as a `workflow_dispatch` choice option, which a person picks explicitly;
- as a dispatch input `default:` whose every read of that input is translated
  by the owner-gated input shape;
- inside a job whose own `if:` is exactly the owner gate, so it never starts
  outside manaflow-ai;
- in the prose allow-listed below, with a reason.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import runner_fallback as rf  # noqa: E402

sys.path.pop(0)

LABEL = re.compile(rf.BLACKSMITH_LABEL)
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$")
INPUT_HEADER = re.compile(r"^      ([A-Za-z0-9_-]+):\s*$")

# (workflow, stripped line) -> why an ungated label there selects nothing.
PROSE = {
    (
        "reload-build.yml",
        "macOS runner label to build on. Blacksmith (blacksmith-6vcpu-macos-26),",
    ): "description text of the runner input, not a value",
}


def _check_tokens(name: str, number: int, line: str, errors: list[str]) -> str:
    """Validate every canonical token on a line and return the line without them."""
    for pattern in (rf.WHOLE_VALUE, rf.INLINE_TOKEN):
        for match in pattern.finditer(line):
            expected = rf.hosted_equivalent(match.group("label"))
            if match.group("hosted") != expected:
                errors.append(
                    f"{name}:{number}: {match.group('label')} gates to "
                    f"{match.group('hosted')!r}; its GitHub-hosted equivalent is {expected!r}"
                )
        line = pattern.sub("<gated>", line)
    for match in rf.INPUT_TRANSLATION.finditer(line):
        for arm in rf.INPUT_ARM.finditer(match.group("arms")):
            expected = rf.hosted_equivalent(arm.group("label"))
            if arm.group("hosted") != expected:
                errors.append(
                    f"{name}:{number}: {match.group('input')} == {arm.group('label')} "
                    f"translates to {arm.group('hosted')!r}; expected {expected!r}"
                )
    return rf.INPUT_TRANSLATION.sub("<gated-input>", line)


def _translated_inputs(text: str) -> dict[str, set[str]]:
    """inputs.X -> the Blacksmith labels its owner-gated translation maps."""
    mapped: dict[str, set[str]] = {}
    for match in rf.INPUT_TRANSLATION.finditer(text):
        labels = {arm.group("label") for arm in rf.INPUT_ARM.finditer(match.group("arms"))}
        mapped.setdefault(match.group("input"), set()).update(labels)
    return mapped


def _raw_input_reads(text: str, input_name: str) -> int:
    """`runs-on:` reads of inputs.X that the translation does not own.

    Other reads (a concurrency group, a timing record) name the input without
    selecting a runner, so they may stay raw. So may a read that only tests the
    value (`startsWith(inputs.X, ...)`, `inputs.X == ...`, `!inputs.X`), because
    it cannot become the selected label.
    """
    read = rf"inputs\.{re.escape(input_name)}\b"
    predicate = re.compile(rf"\w+\(\s*{read}|{read}\s*[!=]=|!\s*{read}")
    count = 0
    for line in text.splitlines():
        if re.match(r"^\s*runs-on:", line):
            stripped = predicate.sub("", rf.INPUT_TRANSLATION.sub("", line))
            count += len(re.findall(read, stripped))
    return count


def violations(name: str, text: str) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()
    translated = _translated_inputs(text)
    owner_gated_job = False
    in_options = False
    current_input = None
    for number, raw in enumerate(lines, start=1):
        if JOB_HEADER.match(raw):
            owner_gated_job = False
        stripped_job_if = raw.strip()
        if raw.startswith("    if:") and stripped_job_if == f"if: {rf.OWNER_GATE}":
            owner_gated_job = True
        header = INPUT_HEADER.match(raw)
        if header:
            current_input = header.group(1)
        if raw.strip().startswith("options:"):
            in_options = True
            continue
        if in_options and not raw.strip().startswith("- "):
            in_options = False
        if raw.lstrip().startswith("#"):
            continue

        line = _check_tokens(name, number, raw, errors)
        for match in LABEL.finditer(line):
            label = match.group(0)
            if in_options and raw.strip() == f"- {label}":
                continue
            if raw.strip() == f"default: {label}" and current_input:
                reads = f"inputs.{current_input}"
                if label in translated.get(reads, set()) and _raw_input_reads(text, current_input) == 0:
                    continue
                errors.append(
                    f"{name}:{number}: dispatch input {current_input!r} defaults to {label} "
                    f"but not every read of {reads} translates it for a fork; wrap each "
                    f"read as ({rf.OWNER_GATE} && {reads} || {reads} == '{label}' && "
                    f"'{rf.hosted_equivalent(label)}' || {reads})"
                )
                continue
            if owner_gated_job:
                continue
            if (name, raw.strip()) in PROSE:
                continue
            errors.append(
                f"{name}:{number}: {label} is selectable outside manaflow-ai, where no "
                f"Blacksmith runner exists; write {rf.gated(label)}"
            )
    return errors


class ForkRunnerFallbackTests(unittest.TestCase):
    def test_no_workflow_can_fall_back_to_blacksmith_outside_manaflow_ai(self) -> None:
        files = sorted(WORKFLOWS.glob("*.y*ml"))
        self.assertTrue(files, f"no workflows under {WORKFLOWS}")
        errors: list[str] = []
        for path in files:
            errors.extend(violations(path.name, path.read_text(encoding="utf-8")))
        self.assertEqual(errors, [], "\n" + "\n".join(errors))

    def test_an_ungated_fallback_is_rejected(self) -> None:
        text = (
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}\n"
            "  b:\n"
            "    runs-on: blacksmith-6vcpu-macos-15\n"
            "  c:\n"
            "    strategy:\n"
            "      matrix:\n"
            "        include:\n"
            "          - runner: blacksmith-6vcpu-macos-26\n"
        )
        self.assertEqual(len(violations("x.yml", text)), 3)

    def test_the_canonical_shapes_pass(self) -> None:
        linux = rf.gated("blacksmith-4vcpu-ubuntu-2404")
        text = (
            "jobs:\n"
            "  a:\n"
            f"    runs-on: ${{{{ vars.LINUX_RUNNER || {linux} }}}}\n"
            "  b:\n"
            "    runs-on: ${{ github.repository_owner == 'manaflow-ai' && "
            "'blacksmith-6vcpu-macos-15' || 'macos-15' }}\n"
            "  c:\n"
            "    if: github.repository_owner == 'manaflow-ai'\n"
            "    runs-on: blacksmith-32vcpu-ubuntu-2404\n"
        )
        self.assertEqual(violations("x.yml", text), [])

    def test_a_gate_to_the_wrong_hosted_image_is_rejected(self) -> None:
        text = (
            "jobs:\n"
            "  a:\n"
            "    runs-on: ${{ vars.MACOS_RUNNER_26 || (github.repository_owner == "
            "'manaflow-ai' && 'blacksmith-6vcpu-macos-26' || 'macos-15') }}\n"
        )
        errors = violations("x.yml", text)
        self.assertEqual(len(errors), 1)
        self.assertIn("'macos-26'", errors[0])

    def test_a_dispatch_default_needs_every_read_translated(self) -> None:
        translated = (
            "(github.repository_owner == 'manaflow-ai' && inputs.runner || "
            "inputs.runner == 'blacksmith-6vcpu-macos-15' && 'macos-15' || inputs.runner)"
        )
        base = (
            "on:\n"
            "  workflow_dispatch:\n"
            "    inputs:\n"
            "      runner:\n"
            "        default: blacksmith-6vcpu-macos-15\n"
            "        type: choice\n"
            "        options:\n"
            "          - blacksmith-6vcpu-macos-15\n"
            "jobs:\n"
            "  a:\n"
            f"    runs-on: ${{{{ {translated} || 'ubuntu-24.04' }}}}\n"
        )
        self.assertEqual(violations("x.yml", base), [])
        raw_read = base + "  b:\n    runs-on: ${{ inputs.runner }}\n"
        self.assertEqual(len(violations("x.yml", raw_read)), 1)

    def test_upstream_collapse_restores_the_blacksmith_literal(self) -> None:
        linux = rf.gated("blacksmith-4vcpu-ubuntu-2404")
        self.assertEqual(
            rf.collapse(f"runs-on: ${{{{ vars.LINUX_RUNNER || {linux} }}}}"),
            "runs-on: ${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}",
        )
        self.assertEqual(
            rf.collapse(
                "runs-on: ${{ github.repository_owner == 'manaflow-ai' && "
                "'blacksmith-6vcpu-macos-15' || 'macos-15' }}"
            ),
            "runs-on: blacksmith-6vcpu-macos-15",
        )


if __name__ == "__main__":
    unittest.main()
