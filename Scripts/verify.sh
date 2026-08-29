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
if [[ -e "$root/.github/workflows" ]]; then
  printf 'error: GitHub Actions workflows are forbidden: %s\n' "$root/.github/workflows" >&2
  exit 1
fi

for legacy_path in \
  Docs/COMPLETION_REPORT.md \
  Docs/RELEASE_READINESS.md \
  Scripts/cleanup_inventory.sh; do
  if [[ -e "$root/$legacy_path" ]]; then
    printf 'error: legacy path remains: %s\n' "$legacy_path" >&2
    exit 1
  fi
done

swift build --package-path "$root" -Xswiftc -warnings-as-errors
swift build --package-path "$root" -c release -Xswiftc -warnings-as-errors
swift test --package-path "$root" --parallel -Xswiftc -warnings-as-errors
swift test --package-path "$root" --sanitize=thread -Xswiftc -warnings-as-errors
swift test --package-path "$root" --sanitize=address -Xswiftc -warnings-as-errors
swift format lint --recursive "$root/Sources" "$root/Tests"
python3 "$script_dir/verify-providerkit-boundaries.py" "$root"

ios_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
ios_scratch=$(mktemp -d "${TMPDIR:-/tmp}/semi-providerkit-ios.XXXXXX")
trap 'rm -rf "$ios_scratch"' EXIT
swift build \
  --package-path "$root" \
  --scratch-path "$ios_scratch" \
  --triple arm64-apple-ios18.0-simulator \
  --sdk "$ios_sdk" \
  -Xswiftc -warnings-as-errors

printf 'PASS: macOS build/test/sanitizer/format/boundaries and iOS build verification\n'
