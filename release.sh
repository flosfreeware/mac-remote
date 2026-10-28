#!/bin/zsh
# Friendly interactive entry point for the production release pipeline.
set -euo pipefail

root="${0:A:h}"
cd "$root"

# Keep non-interactive automation available when both values are supplied.
if [[ $# -eq 2 ]]; then
  exec "$root/prepare-release.sh" "$1" "$2"
fi
if [[ $# -ne 0 ]]; then
  echo "Usage: pnpm release [version build]" >&2
  exit 2
fi

current_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MacRemoteServer/Info.plist)"
current_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' MacRemoteServer/Info.plist)"
suggested_build=$((current_build + 1))

echo "Recent release history:"
release_history="$(git for-each-ref --sort=-version:refname --format='  %(refname:short)  %(subject)' refs/tags | head -10)"
if [[ -n "$release_history" ]]; then
  echo "$release_history"
else
  echo "  No release tags yet."
fi
echo
echo "Current app version: ${current_version} (${current_build})"
echo

print -n "Next version: "
read -r next_version
if [[ -z "$next_version" ]]; then
  echo "A version is required. Nothing was changed." >&2
  exit 2
fi
print -n "Next build [${suggested_build}]: "
read -r next_build
next_build="${next_build:-$suggested_build}"

echo
echo "Preparing Mac Remote ${next_version} (${next_build})…"
exec "$root/prepare-release.sh" "$next_version" "$next_build"
