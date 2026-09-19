#!/usr/bin/env bash
# Create a ready-to-build worktree from this checkout instead of a fresh clone.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/new-worktree.sh <branch> [base]

Creates a git worktree for <branch> (new from [base], default origin/main, or
the existing local branch) and runs ./scripts/setup.sh in it, so submodules,
GhosttyKit, and git hooks are in place and ./scripts/reload.sh works at once.

A worktree shares this checkout's git objects: about 0.5 GB and half a minute,
versus several GB and a full clone. It lands in a sibling directory,
<checkout>-wt/<branch>; set CMUX_WORKTREE_ROOT to put it elsewhere.

Remove it with: git worktree remove <path>
EOF
}

case "${1:-}" in
  ""|-h|--help) usage; [[ -n "${1:-}" ]] && exit 0 || exit 1 ;;
esac

branch="$1"
base="${2:-origin/main}"

main_checkout="$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
root="${CMUX_WORKTREE_ROOT:-${main_checkout}-wt}"
dest="$root/${branch//\//-}"

if [[ -e "$dest" ]]; then
  echo "error: $dest already exists" >&2
  exit 1
fi

# Fork branches can pin submodule commits the upstream submodule remotes do not
# have, which makes a recursive fetch fail; setup.sh fetches what is needed.
remote="${base%%/*}"
if git -C "$main_checkout" remote get-url "$remote" >/dev/null 2>&1; then
  git -C "$main_checkout" fetch --quiet --no-recurse-submodules "$remote"
fi

mkdir -p "$root"
if git -C "$main_checkout" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$main_checkout" worktree add "$dest" "$branch"
else
  git -C "$main_checkout" worktree add --no-track -b "$branch" "$dest" "$base"
fi

(cd "$dest" && ./scripts/setup.sh)

echo
echo "ready: $dest"
