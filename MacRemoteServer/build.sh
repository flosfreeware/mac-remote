#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
cd "$root"
build_args=(-c release)
if [[ "${RELEASE_BUILD:-0}" == "1" ]]; then
  build_args+=(-Xswiftc -debug-prefix-map -Xswiftc "$root=."
               -Xswiftc -file-prefix-map -Xswiftc "$root=.")
fi
swift build "${build_args[@]}"
app="$root/build/Mac Remote.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/MacRemoteServer" "$app/Contents/MacOS/MacRemoteServer"
if [[ "${RELEASE_BUILD:-0}" == "1" ]]; then
  # Remove debugger/object-file paths before signing the distributable binary.
  /usr/bin/strip -S "$app/Contents/MacOS/MacRemoteServer"
  if LC_ALL=C /usr/bin/grep -aEq '/Users/[^/[:space:]]+/|/private/(var/folders|tmp)/|/var/folders/' "$app/Contents/MacOS/MacRemoteServer"; then
    echo "Release binary contains local machine paths; refusing to sign it." >&2
    exit 1
  fi
fi
cp "$root/Info.plist" "$app/Contents/Info.plist"
find "$root/.build" -path '*/Products/Release/*.bundle' -type d -exec cp -R {} "$app/Contents/Resources/" \;
# Keep Mac branding independent of the iPhone app icon. This PNG is rendered
# from the Mac menu-bar SVG and is used by the Dock, windows, and alerts.
cp "$root/Sources/MacRemoteServer/Resources/AppIcon.png" "$app/Contents/Resources/AppIcon.png"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  signing_args=(--force --deep --sign "$CODESIGN_IDENTITY")
  if [[ "${RELEASE_BUILD:-0}" == "1" ]]; then
    # Notarization requires hardened runtime and a trusted timestamp.
    signing_args+=(--options runtime --timestamp)
  fi
  codesign "${signing_args[@]}" "$app"
else
  echo "Warning: CODESIGN_IDENTITY is unset; using an ad-hoc signature. Set it to a stable Apple Development or Developer ID identity to preserve Accessibility authorization."
  codesign --force --deep --sign - "$app"
fi
echo "Built $app"
