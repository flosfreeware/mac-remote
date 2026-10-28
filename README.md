# Mac Remote

Use your iPhone as a remote for your Mac over a local network.

## Build the Mac app

On a Mac with Swift installed:

```sh
cd MacRemoteServer
./build.sh
```

Open `MacRemoteServer/build/Mac Remote.app`. Allow Accessibility access when prompted.

## Build the iPhone app

1. Open `iOS/MacRemoteClient.xcodeproj` in Xcode.
2. Select the `MacRemoteClient` scheme, an iPhone, and your signing team.
3. Build and run the app.

## Pair

Open **Show Pairing QR Code** from the Mac menu-bar menu, then scan the QR code from the iPhone app. Both devices must be able to reach each other on the local network.

## Website

The GitHub Pages source is in `docs/` (home, privacy, security, and app icon).
