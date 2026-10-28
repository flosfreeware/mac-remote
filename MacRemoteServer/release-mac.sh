#!/bin/zsh
# Create local, production-ready Mac artifacts. This script never uploads,
# pushes, creates GitHub releases, or modifies the GitHub Pages repository.
set -euo pipefail

root="${0:A:h}"
cd "$root"
release_config="${root:h}/.release-config.sh"
if [[ -f "$release_config" ]]; then
  source "$release_config"
fi
download_url="${1:-}"
if [[ -z "$download_url" ]]; then
  echo "Usage: $0 <future-public-zip-url>" >&2
  echo "Example: $0 https://covyy.github.io/mac-remote-site/downloads/Mac-Remote-1.1.zip" >&2
  exit 2
fi
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to a Developer ID Application certificate.}"
: "${INSTALLER_IDENTITY:?Set INSTALLER_IDENTITY to a Developer ID Installer certificate.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an xcrun notarytool keychain profile.}"
if [[ "${ALLOW_DIRTY_RELEASE:-0}" != "1" ]] && [[ -n "$(/usr/bin/git -C "$root/.." status --porcelain)" ]]; then
  echo "Refusing to create a production release from a dirty working tree." >&2
  echo "Commit or stash changes first. Set ALLOW_DIRTY_RELEASE=1 only for an intentional local rehearsal." >&2
  exit 2
fi

dist="$root/dist"
notary_state_directory="$root/.release-state"
rm -rf "$dist"
mkdir -p "$dist" "$notary_state_directory"
RELEASE_BUILD=1 "$root/build.sh"
app="$root/build/Mac Remote.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
zip="$dist/Mac-Remote-${version}.zip"
pkg="$dist/Mac-Remote-${version}.pkg"
stable_pkg="$dist/Mac-Remote.pkg"
app_upload="$notary_state_directory/${version}-${build}-app-upload.zip"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

restore_pending_artifact() {
  local artifact="$1"
  local kind="$2"
  local state_file="$notary_state_directory/${version}-${build}-${kind}.submission"
  local cached_artifact="$notary_state_directory/${version}-${build}-${kind}.artifact"
  if [[ -f "$state_file" && -f "$cached_artifact" ]]; then
    echo "Resuming the existing ${kind} notarization submission."
    /bin/cp "$cached_artifact" "$artifact"
  fi
}

notarize_artifact() {
  local artifact="$1"
  local kind="$2"
  local staple_target="${3:-$artifact}"
  local state_file="$notary_state_directory/${version}-${build}-${kind}.submission"
  local cached_artifact="$notary_state_directory/${version}-${build}-${kind}.artifact"
  local submission_id
  local response
  local notarization_status

  if [[ -f "$state_file" && -f "$cached_artifact" ]]; then
    submission_id="$(<"$state_file")"
    echo "Waiting for existing ${kind} notarization submission ${submission_id}…"
  else
    # Preserve the exact submitted bytes so an interrupted run can be resumed
    # without creating another Apple notarization submission.
    /bin/cp "$artifact" "$cached_artifact"
    response="$(/usr/bin/xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --output-format json)"
    submission_id="$(/usr/bin/plutil -extract id raw -o - - <<< "$response")"
    if [[ -z "$submission_id" ]]; then
      echo "Could not read the notarization submission ID." >&2
      exit 1
    fi
    print -r -- "$submission_id" > "$state_file"
    echo "Submitted ${kind} for notarization: ${submission_id}"
  fi

  while true; do
    response="$(/usr/bin/xcrun notarytool info "$submission_id" --keychain-profile "$NOTARY_PROFILE" --output-format json)"
    notarization_status="$(/usr/bin/plutil -extract status raw -o - - <<< "$response")"
    case "$notarization_status" in
      Accepted)
        /usr/bin/xcrun stapler staple "$staple_target"
        if [[ "$staple_target" == "$artifact" ]]; then
          /bin/cp "$artifact" "$cached_artifact"
        fi
        return
        ;;
      "In Progress")
        echo "${kind} notarization is still processing; checking again in 15 seconds…"
        sleep 15
        ;;
      Invalid)
        echo "${kind} notarization was rejected. Fetching Apple's log:" >&2
        /usr/bin/xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
        ;;
      *)
        echo "Unexpected notarization status: ${notarization_status}" >&2
        exit 1
        ;;
    esac
  done
}

# Notarize the app inside a ZIP first, staple the ticket to the app bundle, and
# then create the updater ZIP from that stapled bundle. ZIP files cannot have a
# ticket stapled to them directly.
if [[ -f "$notary_state_directory/${version}-${build}-app.submission" && \
      -f "$notary_state_directory/${version}-${build}-app.artifact" ]]; then
  restore_pending_artifact "$app_upload" app
else
  # App bundles do not need AppleDouble/resource-fork sidecar entries in the
  # distributable ZIP. Keep the bundle's ordinary files and symlinks only.
  /usr/bin/ditto -c -k --norsrc --keepParent "$app" "$app_upload"
fi
app_stage="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$app_stage"' EXIT
/usr/bin/ditto -x -k "$app_upload" "$app_stage"
notarized_app="$app_stage/Mac Remote.app"
if [[ ! -d "$notarized_app" ]]; then
  echo "Could not extract the app archive for notarization." >&2
  exit 1
fi
notarize_artifact "$app_upload" app "$notarized_app"
/usr/bin/xcrun stapler validate "$notarized_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$notarized_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$notarized_app"
/usr/bin/ditto -c -k --norsrc --keepParent "$notarized_app" "$zip"

# Catch accidental AppleDouble, Finder, or archive-wrapper metadata before the
# artifact is published. These entries are not part of the signed app bundle.
if /usr/bin/unzip -Z1 "$zip" | /usr/bin/grep -E '(^|/)(__MACOSX/|\.DS_Store$|\._|\.AppleDouble/)' >/dev/null; then
  echo "Release ZIP contains macOS metadata entries; refusing to continue." >&2
  exit 1
fi

/usr/bin/pkgbuild --component "$notarized_app" --install-location /Applications \
  --scripts "$root/installer-scripts" --identifier local.macremote.server.installer \
  --version "$version" --sign "$INSTALLER_IDENTITY" "$pkg"

restore_pending_artifact "$pkg" pkg
notarize_artifact "$pkg" pkg
/usr/sbin/spctl --assess --type install "$pkg"
# The website uses this stable name through GitHub's /releases/latest URL.
# The versioned package remains in dist for archival and diagnostics.
/bin/cp "$pkg" "$stable_pkg"

digest="$(/usr/bin/shasum -a 256 "$zip" | /usr/bin/awk '{print $1}')"
cat > "$dist/update.json" <<EOF
{
  "version": "${version}",
  "build": ${build},
  "protocol_version": 1,
  "accepted_protocol_minimum": 1,
  "accepted_protocol_maximum": 1,
  "download_url": "${download_url}",
  "sha256": "${digest}"
}
EOF
cat > "$dist/README.txt" <<EOF
Created locally. Nothing was uploaded or pushed.

Manual release steps:
1. prepare-release.sh copies Mac-Remote.pkg, Mac-Remote-${version}.zip, update.json, and the website download link into the local public site checkout.
2. Commit and push that public site checkout yourself. Your private source repository stays private.
EOF
rm -f "$notary_state_directory/${version}-${build}-app.submission" \
      "$notary_state_directory/${version}-${build}-app.artifact" \
      "$app_upload" \
      "$notary_state_directory/${version}-${build}-pkg.submission" \
      "$notary_state_directory/${version}-${build}-pkg.artifact"
echo "Created local artifacts in $dist"
