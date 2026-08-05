#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )); then
  printf 'usage: %s [package-root]\n' "${0##*/}" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
default_root=$(cd -- "$script_dir/.." && pwd -P)
root_arg=${1:-$default_root}
if ! root=$(cd -- "$root_arg" 2>/dev/null && pwd -P); then
  printf 'error: package root is not accessible: %s\n' "$root_arg" >&2
  exit 2
fi
if [[ ! -f "$root/Package.swift" ]]; then
  printf 'error: Package.swift is missing: %s\n' "$root" >&2
  exit 2
fi

swift package --package-path "$root" clean

if [[ -L "$root/.build" ]]; then
  printf 'error: refusing to remove symlinked SwiftPM build path: %s\n' "$root/.build" >&2
  exit 1
fi
if [[ -e "$root/.build" ]]; then
  rm -rf -- "$root/.build"
fi

while IFS= read -r -d '' metadata; do
  rm -f -- "$metadata"
done < <(
  find "$root" \
    -path "$root/.git" -prune -o \
    -path "$root/.build" -prune -o \
    -type f -name '.DS_Store' -print0
)

if [[ -e "$root/.build" ]]; then
  printf 'error: SwiftPM build output remains after clean: %s\n' "$root/.build" >&2
  exit 1
fi
remaining_metadata=$(find "$root" \
  -path "$root/.git" -prune -o \
  -type f -name '.DS_Store' -print -quit)
if [[ -n "$remaining_metadata" ]]; then
  printf 'error: Finder metadata remains after clean: %s\n' "$remaining_metadata" >&2
  exit 1
fi

printf 'restore: swift build --package-path "%s"\n' "$root"
