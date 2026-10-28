1. On the Mac, run `cd MacRemoteServer && ./build.sh`, then open `build/Mac Remote.app` and grant Accessibility when prompted.
2. Click the menu-bar icon and scan the displayed one-time pairing QR code (or copy its pairing code). Closing the pairing window invalidates it; use **Decouple iPhone** in the same menu before pairing a different phone.
3. Open `iOS/MacRemoteClient.xcodeproj` in Xcode, select an iOS 17+ device, choose a signing team, and run it.
4. Scan the Mac QR code (or paste its secret); the client discovers the service and reconnects automatically.
5. For a WebSocket check, use `websocat --tls-domain localhost --tls-psk $(security find-generic-password -s MacRemotePSK -w | xxd -p -c 256) wss://MAC_IP:PORT` (websocat builds must support PSK).
