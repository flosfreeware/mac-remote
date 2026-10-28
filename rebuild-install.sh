#!/bin/bash
# Rebuild, sign, install, and restart both apps. Run from any directory.
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Usage: ./rebuild-install.sh"
  echo "Unlock and connect your iPhone before running. Existing pairing data is preserved."
  echo "Optional environment overrides: CODESIGN_IDENTITY, IOS_DEVICE_ID, IOS_DERIVED_DATA"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "Unknown argument. Use --help for usage." >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_config="$repo_dir/.release-config.sh"
if [[ -f "$local_config" ]]; then
  # Keep machine-specific signing and device identifiers out of the repository.
  source "$local_config"
fi
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
device_id="${IOS_DEVICE_ID:-}"
if [[ -z "$device_id" ]]; then
  echo "Set IOS_DEVICE_ID in .release-config.sh or in the environment." >&2
  exit 2
fi
derived_data="${IOS_DERIVED_DATA:-/private/tmp/macremote-build}"
mac_app="$repo_dir/MacRemoteServer/build/Mac Remote.app"
ios_app="$derived_data/Build/Products/Debug-iphoneos/MacRemoteClient.app"

echo "Building and signing the Mac app…"
(cd "$repo_dir/MacRemoteServer" && ./build.sh)
codesign --verify --deep --strict "$mac_app"

echo "Building and signing the iPhone app…"
xcodebuild -quiet \
  -project "$repo_dir/iOS/MacRemoteClient.xcodeproj" \
  -scheme MacRemoteClient \
  -destination "id=$device_id" \
  -configuration Debug \
  -derivedDataPath "$derived_data" build

echo "Installing the iPhone app…"
xcrun devicectl device install app --device "$device_id" "$ios_app"

echo "Restarting the Mac backend…"
if pgrep -x MacRemoteServer >/dev/null; then
  killall MacRemoteServer
  # The listener uses a fixed pairing port. Wait for the old process to fully
  # release it before launching the freshly built replacement.
  for _ in {1..50}; do
    if ! pgrep -x MacRemoteServer >/dev/null; then
      break
    fi
    sleep 0.1
  done
  if pgrep -x MacRemoteServer >/dev/null; then
    echo "Mac Remote did not quit in time; not starting a second copy." >&2
    exit 1
  fi
fi
open -n "$mac_app"

echo "Restarting the iPhone app…"
if ! xcrun devicectl device process launch --terminate-existing \
  --device "$device_id" local.macremote.client; then
  echo "Both apps were built and installed, and the Mac backend restarted." >&2
  echo "The iPhone app could not launch. Unlock the iPhone and open Mac Remote manually." >&2
  exit 1
fi

echo "Done: both apps rebuilt, installed, and restarted."
