#!/bin/zsh
# Removes only the released Mac app. It never touches development builds.
set -euo pipefail

app="/Applications/Mac Remote.app"
bundle_id="local.macremote.server"
erase_data=false
[[ "${1:-}" == "--erase-data" ]] && erase_data=true

if [[ ! -d "$app" ]]; then
  echo "No production Mac Remote app is installed at $app."
  exit 0
fi
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$actual_id" != "$bundle_id" ]]; then
  echo "Refusing to remove an unexpected app bundle: $actual_id" >&2
  exit 1
fi
echo "This removes only $app."
if [[ "$erase_data" == true ]]; then
  echo "It will also erase Mac Remote pairing data and diagnostics."
else
  echo "Pairing data is preserved. Pass --erase-data to remove it too."
fi
read -r "reply?Continue? [y/N] "
[[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || exit 0

/usr/bin/pkill -x MacRemoteServer 2>/dev/null || true
/bin/rm -rf "$app"
if [[ "$erase_data" == true ]]; then
  /usr/bin/security delete-generic-password -s MacRemotePSK 2>/dev/null || true
  /usr/bin/security delete-generic-password -s MacRemotePairedDeviceCredential 2>/dev/null || true
  /usr/bin/security delete-generic-password -s MacRemotePairedDeviceName 2>/dev/null || true
  /usr/bin/defaults delete "$bundle_id" 2>/dev/null || true
  current_user="$(/usr/bin/id -un)"
  current_home="$(/usr/bin/dscl . -read "/Users/$current_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
  data_directory="$current_home/Library/Application Support/MacRemote"
  [[ -d "$data_directory" ]] && /bin/rm -rf "$data_directory"
fi
echo "Production Mac Remote removed."
