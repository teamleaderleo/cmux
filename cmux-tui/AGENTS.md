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

Hosted verification remains the final cross-platform gate, not the development loop:

```bash
./scripts/verify-cmux-tui-hosted.sh --filter <rust-test-name>
./scripts/verify-cmux-tui-hosted.sh --full
```

Use hosted `--filter` when a platform-specific check is needed or when explicitly requested. Use hosted `--full` before merge when the complete Linux/macOS/Windows gate is required. Do not sit in the main conversation polling hosted CI after a local first pass; return to the user and address concrete CI failures when they arrive.
