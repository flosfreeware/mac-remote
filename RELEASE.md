# Mac Remote release workflow

This repository deliberately does **not** publish, push, create GitHub releases,
or modify GitHub Pages automatically.

## Daily development

- Use `./rebuild-install.sh` for the development build on the connected iPhone.
- The production app can stay installed in `/Applications/Mac Remote.app` while
  development builds run from the repository's build folder.
- To remove only the production app, run `./uninstall-production.sh`.
- Run `./uninstall-production.sh --erase-data` only when testing a brand-new
  Mac install. It removes Mac Remote's pairing Keychain entries, preferences,
  and local diagnostics after confirmation.

## Create a local production release

Keep machine-specific signing identity names and the notary profile name in
the ignored `.release-config.sh` file. Start from the example once and edit it
for this Mac; the notary password remains in Keychain.

The preferred command stages every non-ignored source-repository change,
updates both app version numbers, creates a local commit and annotated tag, and
creates the signed/notarized Mac artifacts. It also updates and commits the
local sibling checkout at `../mac-remote-site` with the installer, update ZIP,
updater manifest, and website download link. It never pushes or publishes:

```zsh
cp .release-config.example.sh .release-config.sh
# Edit .release-config.sh once for this Mac, then run:
./prepare-release.sh 1.1 2
```

The arguments are the public version and build number. This command stages all
non-ignored changes because a release must exactly match its local tag. Git
ignore still excludes signing material, diagnostics, and build products.
If notarization is interrupted after upload, rerunning the same command polls
the saved Apple submission and staples the saved artifact rather than uploading
another copy.

The public website checkout must be clean before running. Set
`PUBLIC_SITE_REPOSITORY` only if it lives somewhere other than the default
`../mac-remote-site`.

If you need to produce artifacts for an already committed/tagged release, use
the lower-level script instead:

```zsh
cd MacRemoteServer
./release-mac.sh 'https://covyy.github.io/mac-remote-site/downloads/Mac-Remote-1.1.zip'
```

The script creates `MacRemoteServer/dist/` with a notarized PKG, an updater ZIP
containing the stapled, notarized app, `update.json`, and a manual-release
checklist. It no longer creates a DMG and does not contact GitHub.

## Manual publication

1. Push the release commit/tag to `covyy/mac-remote`, which remains your
   private source repository.
2. Push the prepared commit in the public `covyy/mac-remote-site` repository.
   GitHub Pages then serves the installer, ZIP, and `update.json` directly.
3. Download the public PKG on a clean Mac account and test installation,
   first-run Accessibility setup, Login Item registration, QR pairing, and an
   in-app update before submitting the matching iPhone build.

The installer launches Mac Remote after installing it. Mac Remote then shows
its first-run setup: Accessibility permission first, followed by the pairing
QR code. macOS requires the user to approve Accessibility directly.
