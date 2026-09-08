# cmux-tui agent instructions

Local development on this fork is allowed on the developer's Mac. Do not require a hosted GitHub Actions round trip for ordinary Rust iteration.

For focused work, prefer the local helper from the repository root:

```bash
./scripts/verify-cmux-tui-local.sh --filter <rust-test-name>
```

For a broader local macOS pass:

```bash
./scripts/verify-cmux-tui-local.sh --full
```

Direct `cargo`, `rustc`, and Zig commands are also allowed locally when using the repository-pinned toolchain and Ghostty submodule. `rust-toolchain.toml` is the Rust toolchain source of truth. The local helper initializes `ghostty`, installs the pinned Rust components through `rustup`, and installs the Ghostty-required Zig version under the user's cache when a matching Zig is not already available.

Local verification does not require a clean tree, a commit, or a push. Use it during implementation and review-fix iteration.

## Fork self-hosted Mac runner

When an agent is operating through GitHub rather than a shell attached to the Mac, use the fork-only self-hosted workflow in `.github/workflows/cmux-tui-local-mac.yml`. The physical Mac runner must be registered only to `teamleaderleo/cmux` and carry the custom label `cmux-local-mac`.

The workflow is intentionally owner-only: it schedules the self-hosted job only when `github.actor == 'teamleaderleo'`, and it accepts only exact commit SHAs contained in a branch of this fork. Do not weaken that actor gate and do not add `pull_request` or `pull_request_target` triggers to the self-hosted workflow.

From the GitHub connector, trigger a focused or full local-Mac run by posting one of these top-level comments on a PR or issue:

```text
/cmux-tui-local <40-character-fork-commit> focused <rust-test-name>
/cmux-tui-local <40-character-fork-commit> full
```

A manual `workflow_dispatch` form is also available in the fork Actions UI with the same commit/mode/filter fields. The comment form exists so a connected agent can request the run without needing shell access to the Mac.

Hosted verification remains the final cross-platform gate, not the development loop:

```bash
./scripts/verify-cmux-tui-hosted.sh --filter <rust-test-name>
./scripts/verify-cmux-tui-hosted.sh --full
```

Use hosted `--filter` when a platform-specific check is needed or when explicitly requested. Use hosted `--full` before merge when the complete Linux/macOS/Windows gate is required. Do not sit in the main conversation polling hosted CI after a local first pass; return to the user and address concrete CI failures when they arrive.
