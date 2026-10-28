#!/bin/zsh
# Prepare source, website downloads, and a release tag in this checkout.
# It intentionally stages every non-ignored source-repository change.
set -euo pipefail

root="${0:A:h}"
cd "$root"

version="${1:-}"
build="${2:-}"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || [[ ! "$build" =~ '^[1-9][0-9]*$' ]]; then
  echo "Usage: $0 <version> <build>" >&2
  echo "Example: $0 1.1 2" >&2
  exit 2
fi

tag="v${version}"
release_url="https://flosfreeware.github.io/mac-remote/downloads/Mac-Remote-${version}.zip"

if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
  echo "Resolve merge conflicts before preparing a release." >&2
  exit 2
fi
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "The local tag ${tag} already exists. Choose a new version or remove that tag deliberately." >&2
  exit 2
fi
public_remote="$(git remote get-url origin)"
if [[ "$public_remote" != "https://github.com/flosfreeware/mac-remote.git" && \
      "$public_remote" != "git@github.com:flosfreeware/mac-remote.git" ]]; then
  echo "Refusing to publish to unexpected public repository remote: ${public_remote}" >&2
  exit 2
fi

# Load optional per-machine signing identity names and Keychain profile. The
# local file is gitignored so personal release configuration stays off Git.
release_config="$root/.release-config.sh"
if [[ -f "$release_config" ]]; then
  source "$release_config"
fi

# Keep environment overrides usable when the local config file is absent.
export CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
export INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
export NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Fail before editing version files or creating the release commit if any
# required signing/notarization setting is still empty.
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to a Developer ID Application certificate.}"
: "${INSTALLER_IDENTITY:?Set INSTALLER_IDENTITY to a Developer ID Installer certificate.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an xcrun notarytool keychain profile.}"

# Keep the Mac app, iPhone app, and widgets on the same public version.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" MacRemoteServer/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build}" MacRemoteServer/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version}" iOS/MacRemoteClient/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${build}" iOS/MacRemoteClient/Info.plist
/usr/bin/perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${version};/g; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = ${build};/g" iOS/MacRemoteClient.xcodeproj/project.pbxproj

# The caller explicitly asked to include all work. gitignore still protects
# signing keys, diagnostics, build products, and other private machine files.
git add -A
if git diff --cached --quiet; then
  # A previous invocation may have created the release commit before failing
  # during signing or notarization. Reuse that clean commit on a retry.
  echo "No new changes to commit; preparing the release from the current commit."
else
  git commit -m "Release ${version} (${build})"
fi

# This signs and notarizes the Mac artifacts locally. It does not push anything.
(
  cd MacRemoteServer
  ./release-mac.sh "$release_url"
)

# Prepare the public GitHub Pages content. The stable installer path is used by
# the download button, while versioned ZIPs remain available for app updates.
site_downloads="$root/docs/downloads"
mkdir -p "$site_downloads"
/bin/cp "$root/MacRemoteServer/dist/Mac-Remote.pkg" "$site_downloads/Mac-Remote.pkg"
/bin/cp "$root/MacRemoteServer/dist/Mac-Remote-${version}.zip" "$site_downloads/Mac-Remote-${version}.zip"
/bin/cp "$root/MacRemoteServer/dist/update.json" "$root/docs/update.json"

git add docs/downloads/Mac-Remote.pkg "docs/downloads/Mac-Remote-${version}.zip" docs/update.json
if ! git diff --cached --quiet; then
  git commit -m "Publish Mac Remote ${version} (${build})"
fi
# Tag the finished release, including the exact files served by GitHub Pages.
git tag -a "$tag" -m "Mac Remote ${version} (${build})"

cat <<EOF

Release prepared successfully in this repository.

The release is still local and unpublished. To push the commit and tag, type
exactly: push

  git push origin HEAD
  git push origin ${tag}

GitHub Pages serves the new installer and updater after its deployment finishes.
Creating a GitHub Release is optional; these downloads are hosted under docs/.
EOF

if [[ -t 0 ]]; then
  read -r "push_confirmation?Type 'push' to publish the commit and tag (anything else keeps them local): "
  if [[ "$push_confirmation" == "push" ]]; then
    git push origin HEAD
    git push origin "$tag"
    echo "Release commit and tag pushed."
  else
    echo "Nothing was pushed. The prepared release remains local."
  fi
else
  echo "Non-interactive run: nothing was pushed."
fi
