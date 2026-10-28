# Mac Remote release workflow

Run development and releases from this checkout: `mac-remote-public`.
The source, website, and downloadable Mac artifacts now live in the same
`flosfreeware/mac-remote` repository. The old checkouts are not needed.

## Development

- `pnpm dev` rebuilds, installs, and restarts the Mac and connected iPhone apps.
- `pnpm dev:setup` also resets the Mac setup-completed preference.
- Machine-specific signing settings and the iPhone ID belong in the ignored
  `.release-config.sh`. Notarization credentials remain in Keychain.

## Prepare and publish a release

Run:

```sh
pnpm release
```

The command shows local release history and current version numbers, then asks
for the next version and build. Use a version that has no existing release tag;
the build number must increase.

It stages all non-ignored changes, updates the Mac/iPhone/widget versions, and
creates a local source commit. It builds and signs the Mac app and installer,
notarizes them, verifies the installer signature, and prepares:

- `docs/downloads/Mac-Remote.pkg`: the website's installer.
- `docs/downloads/Mac-Remote-VERSION.zip`: the Mac updater's download.
- `docs/update.json`: the update manifest.

It commits those website files and tags the completed release. If signing or
notarization fails before the tag is created, rerun with the same version/build
to resume the saved notarization submission.

At the final prompt, type exactly `push` to publish. Any other answer keeps the
release local. You can publish later yourself:

```sh
git push origin HEAD
git push origin vVERSION
```

GitHub Pages deploys the contents of `docs/`. Once deployment finishes, the
download button serves the new PKG and the Mac updater reads the new manifest.
A GitHub Release is optional; the website hosts these downloads directly.

Test the downloaded installer, Accessibility setup, pairing, and an in-app
update before submitting the matching iPhone build. The iPhone App Store
submission is a separate Xcode/App Store Connect step.

## Rebuild artifacts without a new release commit

For an already committed release:

```sh
cd MacRemoteServer
./release-mac.sh 'https://flosfreeware.github.io/mac-remote/downloads/Mac-Remote-VERSION.zip'
```

This only prepares local artifacts under `MacRemoteServer/dist/`; it does not
publish them or change the website's downloads.
