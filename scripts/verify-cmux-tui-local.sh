#!/usr/bin/env bash
# Fast local cmux-tui verification for macOS development.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/verify-cmux-tui-local.sh --filter <rust-test-name>
  ./scripts/verify-cmux-tui-local.sh --full

--filter runs matching cmux-tui-core library tests locally on this Mac.
--full runs formatting, clippy, and the local workspace test suite.
Hosted verification remains the final cross-platform merge gate.
EOF
}

mode=""
test_filter=""
case "${1:-}" in
  --filter)
    if [[ $# -ne 2 ]]; then
      usage >&2
      exit 2
    fi
    mode="focused"
    test_filter="$2"
    ;;
  --full)
    if [[ $# -ne 1 ]]; then
      usage >&2
      exit 2
    fi
    mode="full"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ "$mode" == "focused" && ! "$test_filter" =~ ^[A-Za-z0-9_][A-Za-z0-9_:.-]{0,199}$ ]]; then
  echo "error: --filter must be one Rust test-name substring without shell syntax" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this helper is for local macOS development; use the hosted verifier for cross-platform checks" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"

for command_name in git python3 rustup curl tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "error: required command not found: $command_name" >&2
    exit 1
  fi
done

# The TUI build links Ghostty's VT library from the repository submodule.
git -C "$repo_root" submodule update --init --depth 1 ghostty

# Keep local Rust exactly aligned with cmux-tui/rust-toolchain.toml.
rust_info="$(python3 - "$repo_root/cmux-tui/rust-toolchain.toml" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def value(name):
    match = re.search(rf'^\s*{name}\s*=\s*"([^"]+)"', text, re.MULTILINE)
    if match is None:
        raise SystemExit(f"missing {name} in rust-toolchain.toml")
    return match.group(1)

components_match = re.search(r'^\s*components\s*=\s*\[([^]]*)\]', text, re.MULTILINE)
if components_match is None:
    raise SystemExit("missing components in rust-toolchain.toml")
components = " ".join(re.findall(r'"([^"]+)"', components_match.group(1)))
print(f"{value('channel')}|{value('profile')}|{components}")
PY
)"
IFS='|' read -r rust_channel rust_profile rust_components <<< "$rust_info"
rustup_args=(toolchain install "$rust_channel" --profile "$rust_profile")
for component in $rust_components; do
  rustup_args+=(--component "$component")
done
rustup "${rustup_args[@]}" >/dev/null

# Use the exact Zig version Ghostty requires. Prefer an existing matching Zig;
# otherwise install it privately under the user's cache without sudo.
# shellcheck source=ghostty-zig-version.sh
source "$repo_root/scripts/ghostty-zig-version.sh"
zig_version="$(ghostty_minimum_zig_version "$repo_root")"
case "$(uname -m)" in
  arm64) zig_arch="aarch64" ;;
  x86_64) zig_arch="x86_64" ;;
  *)
    echo "error: unsupported macOS architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

zig_cache="${CMUX_TUI_LOCAL_ZIG_ROOT:-$HOME/.cache/cmux/zig}"
zig_name="zig-${zig_arch}-macos-${zig_version}"
cached_zig="$zig_cache/$zig_name/zig"
zig_path=""

system_zig="$(command -v zig 2>/dev/null || true)"
if [[ -n "$system_zig" && "$("$system_zig" version 2>/dev/null || true)" == "$zig_version" ]]; then
  zig_path="$system_zig"
elif [[ -x "$cached_zig" && "$("$cached_zig" version 2>/dev/null || true)" == "$zig_version" ]]; then
  zig_path="$cached_zig"
else
  mkdir -p "$zig_cache"
  ZIG_FORCE_LOCAL_INSTALL=1 \
    ZIG_INSTALL_ROOT="$zig_cache" \
    "$repo_root/scripts/install-zig-ci.sh"
  zig_path="$cached_zig"
fi

if [[ ! -x "$zig_path" ]]; then
  echo "error: Zig $zig_version was not installed at $zig_path" >&2
  exit 1
fi
export ZIG="$zig_path"

echo "Local cmux-tui toolchain: rust $rust_channel, zig $zig_version"
cd "$repo_root/cmux-tui"

if [[ "$mode" == "focused" ]]; then
  cargo test -p cmux-tui-core --lib --locked "$test_filter" -- --nocapture
else
  cargo fmt --all -- --check
  cargo clippy --workspace --all-targets --locked -- -D warnings
  cargo test --workspace --locked
fi
