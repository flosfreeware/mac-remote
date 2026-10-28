import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var remote: RemoteConnection
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showConnectionWarning = false
    @State private var onboardingAllowsCursorMovement = false
    @State private var keyboardText = ""
    @State private var lastKeyboardText = ""
    @AppStorage("cursorSensitivityStep") private var cursorSensitivityStep = 3.0
    @AppStorage("autoOpenKeyboardOnInputFocus") private var autoOpenKeyboardOnInputFocus = true
    @AppStorage("cursorSmoothing") private var cursorSmoothing = "normal"
    @AppStorage("scrollSpeed") private var scrollSpeed = "normal"
    @AppStorage("liveActivityEnabled") private var liveActivityEnabled = false
    @AppStorage("showSafariShortcut") private var showSafariShortcut = false
    @AppStorage("showSpotifyShortcut") private var showSpotifyShortcut = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @FocusState private var keyboardFocused: Bool
    @StateObject private var motion = MotionController()
    @StateObject private var inertia = ScrollInertia()
    private let controlRailWidth: CGFloat = 66
    var body: some View {
        ZStack {
            if remote.hasSecret {
                remoteChrome
                if remote.showConnectionHelp {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 32))
                        Text("This iPhone needs to be on the same network as your computer. Some guest and university Wi-Fi networks prevent devices from reaching each other. Make sure \"Mac Remote\" is running on your computer.")
                            .font(.footnote)
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
                    .padding(24)
                    .environment(\.colorScheme, .dark)
                }
                if remote.connectionUnstable && !remote.diagnosticsEnabled && remote.controlsEnabled {
                    connectionWarning
                }
                if let compatibilityIssue = remote.compatibilityIssue {
                    updateOverlay(compatibilityIssue)
                    // Version incompatibility blocks remote controls, but must
                    // never block the reset path in Settings.
                    settingsControlPositioned
                }
                // Keep the keyboard's responder alive across remote focus updates.
                Group {
                    TextField("", text: $keyboardText)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textContentType(.none)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .focused($keyboardFocused)
                        .disabled(!remote.controlsEnabled)
                        .submitLabel(.return)
                        .opacity(0)
                        .frame(width: 1, height: 1)
                        .onAppear { setKeyboardVisible(remote.inputActive, automatically: true) }
                        .onSubmit { remote.send(["type": "input_return"]); keyboardFocused = true }
                        .onChange(of: keyboardText) { _, value in
                            guard keyboardFocused, value != lastKeyboardText else { return }
                            sendKeyboardDelta(from: lastKeyboardText, to: value)
                            lastKeyboardText = value
                        }
                }
                if remote.diagnosticsEnabled {
                    diagnosticsMeasurementOverlay
                }
            } else {
                Color.black.ignoresSafeArea()
            }
            if !hasCompletedOnboarding || !remote.hasSecret {
                OnboardingView(requiresFullOnboarding: !hasCompletedOnboarding,
                               centerPointer: centerDuringOnboarding,
                               finish: finishOnboarding,
                               tutorialPreview: AnyView(remoteChrome),
                               allowsCursorMovement: $onboardingAllowsCursorMovement)
                    .environmentObject(remote)
                    .transition(.opacity)
            }
            if remote.hasSecret && remote.status == .connected && remote.macAccessibilityGranted == false {
                accessibilityRequiredOverlay
                settingsControlPositioned
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: remote.diagnosticsEnabled)
        .statusBarHidden(true)
        .onAppear { applyCursorSensitivity(); if scenePhase == .active { resumeControl() } }.onChange(of: scenePhase) { _, phase in if phase == .active { resumeControl() } else { motion.stop(); remote.suspendControls() } }.onChange(of: remote.inputActive) { _, active in
            setKeyboardVisible(active, automatically: true)
        }.onChange(of: remote.status) { _, status in
            setKeyboardVisible(status == .connected && remote.inputActive, automatically: true)
            if status != .connected { motion.pauseConnection() }
            else { updateCursorMovement() }
            Task { await RemotePresentationPreview.sync(connected: status == .connected, enabled: liveActivityEnabled) }
        }.onChange(of: remote.controlSession) { _, session in
            guard session != nil else { return }
            updateCursorMovement()
            applyCursorSmoothing()
        }.onChange(of: remote.diagnosticsEnabled) { _, enabled in
            motion.setDiagnosticsEnabled(enabled)
            setKeyboardVisible(enabled ? false : remote.inputActive)
            updateCursorMovement()
        }.onChange(of: remote.remoteEnabled) { _, enabled in
            if !enabled {
                setKeyboardVisible(false)
                motion.stop()
                inertia.stop()
            } else { updateCursorMovement() }
        }.onChange(of: remote.macAccessibilityGranted) { _, granted in
            if granted == false {
                setKeyboardVisible(false)
                motion.stop()
                inertia.stop()
            } else { updateCursorMovement() }
        }.onChange(of: remote.macSleeping) { _, sleeping in
            if sleeping { setKeyboardVisible(false); motion.stop(); inertia.stop() }
            else { updateCursorMovement() }
        }.onChange(of: cursorSensitivityStep) { _, _ in
            applyCursorSensitivity()
        }.onChange(of: cursorSmoothing) { _, level in
            applyCursorSmoothing()
        }.onChange(of: liveActivityEnabled) { _, enabled in
            Task { await RemotePresentationPreview.sync(connected: remote.status == .connected, enabled: enabled) }
        }.onChange(of: showSettings) { _, presented in
            if presented { setKeyboardVisible(false) }
            updateCursorMovement()
        }.onChange(of: showConnectionWarning) { _, presented in
            if presented { setKeyboardVisible(false) }
            updateCursorMovement()
        }.onChange(of: remote.compatibilityIssue) { _, presented in
            if presented != nil { setKeyboardVisible(false) }
            updateCursorMovement()
        }.onChange(of: remote.showConnectionHelp) { _, _ in
            updateCursorMovement()
        }.onChange(of: onboardingAllowsCursorMovement) { _, _ in
            updateCursorMovement()
        }.onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed { setKeyboardVisible(false) }
            updateCursorMovement()
        }.onDisappear { motion.stop(); remote.suspendControls() }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                Form {
                    Section("Controls") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Cursor sensitivity")
                                Spacer()
                                Text(cursorSensitivityName)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $cursorSensitivityStep, in: 1...5, step: 1)
                        }
                        Toggle("Auto open keyboard when focusing an input", isOn: $autoOpenKeyboardOnInputFocus)
                        Picker("Cursor smoothing", selection: $cursorSmoothing) {
                            Text("Off").tag("off")
                            Text("Normal").tag("normal")
                            Text("High").tag("high")
                        }
                        Picker("Scroll speed", selection: $scrollSpeed) {
                            Text("Slow").tag("slow")
                            Text("Normal").tag("normal")
                            Text("Fast").tag("fast")
                        }
                    }
                    Section("Live Activity") {
                        Toggle("Show Live Activity", isOn: $liveActivityEnabled)
                    }
                    Section("App shortcuts") {
                        Toggle("Safari", isOn: $showSafariShortcut)
                        Toggle("Spotify", isOn: $showSpotifyShortcut)
                    }
                    Section {
                        Button("Unpair \(remote.pairedMacName)", role: .destructive) {
                            motion.stop()
                            remote.unpair()
                            showSettings = false
                        }
                    } footer: {
                        Text("This removes your computer's pairing code from your iPhone.")
                    }
                    Section {
                        Button("Reset All Settings", role: .destructive) {
                            resetAllSettings()
                        }
                    } footer: {
                        Text("Unpairs this iPhone and restores defaults.")
                    }
                    Section {
                        Link("pails.splits_60@icloud.com", destination: URL(string: "mailto:pails.splits_60@icloud.com")!)
                    } header: {
                        Text("Contact")
                    }
                    Section("Version") {
                        LabeledContent("App", value: RemoteAppVersion.display)
                        LabeledContent("Protocol", value: "\(RemoteProtocol.version) (accepts \(RemoteProtocol.acceptedRangeDescription))")
                    }
                }
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showConnectionWarning) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 52, weight: .medium))
                            .foregroundStyle(.yellow)
                        Text("Connection is unstable")
                            .font(.title2.weight(.semibold))
                        Group {
                            Text("Mac Remote is seeing repeated delays in cursor updates. Try moving closer to your Wi-Fi access point or reducing other network activity.")
                            Text("If possible, try disabling AirDrop on your Mac. AirDrop discovery can sometimes cause lag.")
                        }
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(28)
                }
                .navigationTitle("Connection")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showConnectionWarning = false }
                    }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .presentationDetents([.medium])
        }
    }
    // The same composition powers the live remote and the scaled, read-only
    // tutorial phone. Keeping it in one place prevents their designs drifting.
    private var remoteChrome: some View {
        ZStack {
            ZStack {
                touchSurface
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .environment(\.colorScheme, .dark)
                    .disabled(!remote.controlsEnabled)
                    .allowsHitTesting(remote.controlsEnabled)
                sideControls
                    .padding(10)
                    .environment(\.colorScheme, .dark)
                    .disabled(!remote.controlsEnabled)
                cursorResetControl
                    .environment(\.colorScheme, .dark)
                    .disabled(!remote.controlsEnabled)
            }
            .opacity(remote.showConnectionHelp ? 0.35 : 1)
            if !remote.remoteEnabled {
                remoteDisabledOverlay
            }
            settingsControlPositioned
            if motion.isRestingFlat {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: motion.isRestingFlat)
    }
    private var touchSurface: some View {
        ZStack {
            RemoteTouchSurface(onAction: handleTouchAction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container)
            VStack { HStack(alignment: .top) {
                VStack(spacing: 8) {
                    control(remote.macFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", remote.macFullscreen ? "Exit fullscreen" : "Enter fullscreen") { remote.send(["type": "shortcut", "key": "f", "command": false]) }
                    control("moon.zzz.fill", "Sleep Mac") { remote.send(["type": "sleep"]) }
                }
                .frame(width: controlRailWidth)
                Spacer()
                if remote.inSafari {
                    HStack(spacing: 8) {
                        control("plus", "New tab") { remote.send(["type": "shortcut", "key": "t"]) }
                        control("xmark", "Close", tint: .red) { remote.send(["type": "shortcut", "key": "w"]) }
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    control("gearshape", "Settings") { }
                        .hidden()
                        .allowsHitTesting(false)
                    if showSafariShortcut {
                        safariControl { remote.send(["type": "open_safari"]) }
                    }
                    if showSpotifyShortcut {
                        spotifyControl { remote.send(["type": "open_spotify"]) }
                    }
                }
                .frame(width: controlRailWidth)
            }; Spacer() }.padding(10)
            VStack { Spacer(); HStack(spacing: 2) {
                mediaSegment("backward.end.fill", "previous", "Previous", position: .left)
                mediaSegment("playpause.fill", "play_pause", "Play or pause", position: .middle)
                mediaSegment("forward.end.fill", "next", "Next", position: .right)
            }; }.padding(.bottom, 12)
        }
    }

    private var cursorResetControl: some View {
        VStack {
            Spacer()
            HStack {
                control("scope", "Reset cursor center") { resetPointer() }
                    .frame(width: controlRailWidth)
                Spacer()
            }
        }
        .padding(10)
    }

    private var diagnosticsMeasurementOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Measuring connection")
                    .font(.title3.weight(.semibold))
                Text("Don't close or background the app")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 300)
            }
            .foregroundStyle(.white)
            .padding(32)
        }
        .transition(.opacity)
    }

    private var remoteDisabledOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "power")
                    .font(.system(size: 32, weight: .medium))
                Text("Remote turned off")
                    .font(.title3.weight(.semibold))
                Text("Mac Remote is turned off on your Mac")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(32)
        }
        .transition(.opacity)
    }

    private var accessibilityRequiredOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 32, weight: .medium))
                Text("Accessibility required")
                    .font(.title3.weight(.semibold))
                Text("Allow Mac Remote in Accessibility settings on your Mac to control it.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(32)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func updateOverlay(_ overlay: RemoteCompatibilityIssue) -> some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.blue)
                Text(overlay.title)
                    .font(.title2.weight(.semibold))
                Text(overlay.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
                if case .iphoneNeedsUpdate = overlay {
                    Button("Open App Store") {
                        if let url = URL(string: "itms-apps://apps.apple.com") {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(32)
            .foregroundStyle(.white)
        }
        .transition(.opacity)
    }

    private var settingsControlPositioned: some View {
        VStack {
            HStack {
                Spacer()
                control("gearshape", "Settings") {
                    setKeyboardVisible(false)
                    showSettings = true
                }
                .frame(width: controlRailWidth)
            }
            Spacer()
        }
        .padding(10)
    }

    private var connectionWarning: some View {
        Button {
            setKeyboardVisible(false)
            showConnectionWarning = true
        } label: {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                // A time-derived curve does not restart when SwiftUI refreshes
                // surrounding connection state, unlike a repeating state animation.
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                let opacity = 0.48 + 0.52 * (0.5 + 0.5 * cos(phase * .pi * 2))
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
                    .opacity(opacity)
                    .padding(22)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection unstable")
    }
    private func handleTouchAction(_ action: TouchSurfaceState.Action) {
        switch action {
        case .tap:
            motion.suppress(); Haptics.tap(); remote.send(["type": "click", "button": "left"])
        case .hold(let held):
            remote.setMouseHeld(held); motion.suppress()
            if held { inertia.stop(); Haptics.longPress() }
        case .scroll(let dy):
            // Renew this while the gesture is active so incidental phone motion
            // cannot nudge the Mac pointer during a scroll.
            motion.suppress(for: 0.18)
            inertia.update(delta: CGFloat(dy) * 2.2 * scrollSpeedMultiplier) { remote.send(["type": "scroll", "dy": $0]) }
        case .scrollEnd:
            // Also hide motion while the brief inertial scroll tail runs.
            motion.suppress(for: 0.18)
            inertia.end { remote.send(["type": "scroll", "dy": $0]) }
        case .cancelScroll:
            motion.suppress()
            inertia.stop()
        case .swipeLeft: remote.send(["type": "shortcut", "key": "ä"])
        case .swipeRight: remote.send(["type": "shortcut", "key": "ö"])
        }
    }
    private var sideControls: some View {
        VStack(spacing: 8) {
            HStack {
                GeometryReader { geometry in
                    ScrollView(.vertical) {
                        leftControlButtons
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geometry.size.height)
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.never)
                }
                .frame(width: controlRailWidth)
                // Leave both the fullscreen and Sleep buttons' top-left hit areas unobstructed.
                .padding(.top, 104)
                Spacer()
            }
            HStack {
                Spacer()
                control(keyboardFocused ? "keyboard.chevron.compact.down" : "keyboard", keyboardFocused ? "Hide keyboard" : "Show keyboard") {
                    setKeyboardVisible(!keyboardFocused)
                }
            }
        }
    }
    private var leftControlButtons: some View {
        VStack(spacing: 8) {
            VStack(spacing: 2) {
                mediaSegment("sun.max.fill", "brightness_up", "Increase brightness", position: .top)
                    .buttonRepeatBehavior(.enabled)
                mediaSegment("sun.min.fill", "brightness_down", "Decrease brightness", position: .bottom)
                    .buttonRepeatBehavior(.enabled)
            }
            VStack(spacing: 2) {
                mediaSegment("plus", "volume_up", "Volume up", position: .top)
                    .buttonRepeatBehavior(.enabled)
                mediaSegment(remote.macMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", "mute", remote.macMuted ? "Unmute" : "Mute", position: .middle, tint: remote.macMuted ? .red : .primary)
                mediaSegment("minus", "volume_down", "Volume down", position: .bottom)
                    .buttonRepeatBehavior(.enabled)
            }
        }
    }
    private func control(_ symbol: String, _ label: String, tint: Color = .primary, size: CGFloat = 38, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: { Image(systemName: symbol).font(.body).frame(width: size, height: size) }.buttonStyle(.bordered).controlSize(.small).tint(tint).accessibilityLabel(label)
    }
    private func safariControl(action: @escaping () -> Void) -> some View {
        appIconControl("SafariDockIcon", label: "Open Safari", action: action)
    }
    private func spotifyControl(action: @escaping () -> Void) -> some View {
        appIconControl("SpotifyIcon", label: "Open Spotify", action: action)
    }
    private func appIconControl(_ image: String, label: String, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(image)
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel(label)
    }
    private func mediaSegment(_ symbol: String, _ action: String, _ label: String, position: MediaSegmentStyle.Position, tint: Color = .primary, height: CGFloat = 46) -> some View {
        Button { Haptics.tap(); remote.send(["type": "media", "action": action]) } label: {
            Image(systemName: symbol).font(.body).frame(width: 50, height: height)
        }
        .buttonStyle(MediaSegmentStyle(position: position, tint: tint))
        .accessibilityLabel(label)
    }
    private func resumeControl() {
        motion.pauseConnection()
        remote.resumeControls()
        updateCursorMovement()
    }
    private func resetPointer() {
        motion.reset { id in
            remote.resetPointer(generation: id) { motion.acknowledge($0) }
        }
    }
    private func restorePointer() {
        motion.resume { id, x, y in
            remote.resumePointer(generation: id, x: x, y: y) { motion.acknowledge($0) }
        }
    }
    private func startMotion() {
        guard cursorMovementAllowed else { return }
        motion.setDiagnosticsEnabled(remote.diagnosticsEnabled)
        motion.start { id, x, y, raw in
            var message: [String: Any] = ["type": "pointer_target", "generation": id, "x": x, "y": y]
            raw.forEach { message[$0.key] = $0.value }
            remote.send(message)
        }
    }
    private func centerDuringOnboarding() {
        guard remote.controlsEnabled else { return }
        // Start sampling before reset captures the phone's current pointing pose.
        motion.setDiagnosticsEnabled(false)
        motion.start { id, x, y, raw in
            var message: [String: Any] = ["type": "pointer_target", "generation": id, "x": x, "y": y]
            raw.forEach { message[$0.key] = $0.value }
            remote.send(message)
        }
        resetPointer()
    }
    private func finishOnboarding() {
        hasCompletedOnboarding = true
        startMotion()
        restorePointer()
        applyCursorSmoothing()
    }
    private var cursorMovementAllowed: Bool {
        guard remote.hasSecret, !remote.macSleeping, remote.remoteEnabled, remote.macAccessibilityGranted != false,
              !showConnectionWarning, !remote.diagnosticsEnabled,
              !remote.showConnectionHelp, remote.compatibilityIssue == nil else { return false }
        return hasCompletedOnboarding || onboardingAllowsCursorMovement
    }
    private func updateCursorMovement() {
        guard scenePhase == .active, remote.status == .connected, cursorMovementAllowed else {
            motion.stop()
            inertia.stop()
            return
        }
        startMotion()
        restorePointer()
    }
    private func resetAllSettings() {
        setKeyboardVisible(false)
        inertia.stop()
        motion.stop()
        motion.clearSavedReference()
        cursorSensitivityStep = 3
        autoOpenKeyboardOnInputFocus = true
        cursorSmoothing = "normal"
        scrollSpeed = "normal"
        liveActivityEnabled = false
        showSafariShortcut = false
        showSpotifyShortcut = false
        hasCompletedOnboarding = false
        Task { await RemotePresentationPreview.end() }
        remote.unpair()
        showSettings = false
    }
    private var cursorSensitivityName: String {
        ["Very low", "Low", "Normal", "High", "Very high"][Int(cursorSensitivityStep.rounded()) - 1]
    }

    private func applyCursorSensitivity() {
        let values = [15.0, 21.0, 27.0, 33.0, 39.0]
        let index = min(max(Int(cursorSensitivityStep.rounded()) - 1, 0), values.count - 1)
        motion.setSensitivity(values[index])
    }

    private func applyCursorSmoothing() {
        remote.send(["type": "cursor_smoothing", "level": cursorSmoothing])
    }

    private var scrollSpeedMultiplier: CGFloat {
        switch scrollSpeed {
        case "slow": 0.72
        case "fast": 1.35
        default: 1
        }
    }

    private func setKeyboardVisible(_ visible: Bool, automatically: Bool = false) {
        let mainUIVisible = remote.hasSecret && hasCompletedOnboarding && !showSettings && !showConnectionWarning
        let visible = visible && mainUIVisible && remote.controlsEnabled && !remote.diagnosticsEnabled && (!automatically || autoOpenKeyboardOnInputFocus)
        if visible && !keyboardFocused {
            // This is a keystroke buffer, not a copy of the Mac's input contents.
            lastKeyboardText = ""
            keyboardText = ""
        }
        keyboardFocused = visible
    }
    private func sendKeyboardDelta(from old: String, to new: String) {
        let oldUnits = Array(old.utf16); let newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < oldUnits.count && prefix < newUnits.count && oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < oldUnits.count - prefix && suffix < newUnits.count - prefix && oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        for _ in 0..<(oldUnits.count - prefix - suffix) { remote.send(["type": "input_backspace"]) }
        let inserted = String(decoding: newUnits[prefix..<(newUnits.count - suffix)], as: UTF16.self)
        if !inserted.isEmpty { remote.send(["type": "input_insert", "text": inserted]) }
    }
}

private struct MediaSegmentStyle: ButtonStyle {
    enum Position: Equatable { case top, middle, bottom, left, right }
    let position: Position
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: position == .top || position == .left ? 14 : 4,
            bottomLeadingRadius: position == .bottom || position == .left ? 14 : 4,
            bottomTrailingRadius: position == .bottom || position == .right ? 14 : 4,
            topTrailingRadius: position == .top || position == .right ? 14 : 4,
            style: .continuous
        )
        configuration.label
            .foregroundStyle(tint)
            .background(shape.fill(tint.opacity(configuration.isPressed ? 0.28 : 0.12)))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.35)
    }
}

private enum Haptics {
    static func tap() { fire(.light, intensity: 1.0) }
    static func longPress() { fire(.medium, intensity: 1.0) }
    private static func fire(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: style)
            generator.prepare()
            generator.impactOccurred(intensity: intensity)
        }
    }
}

private final class ScrollInertia: ObservableObject {
    private var timer: Timer?
    private var velocity: CGFloat = 0
    private var lastDirectDelta: CGFloat = 0
    func stop() { timer?.invalidate(); timer = nil; velocity = 0; lastDirectDelta = 0 }
    func update(delta: CGFloat, send: (CGFloat) -> Void) {
        timer?.invalidate(); timer = nil
        // A touch move is only one display frame, so retaining just its last
        // delta makes a released scroll lose almost all of its momentum. Keep
        // a small weighted history instead; this produces the same continuous
        // hand-off into deceleration that native scrolling has.
        // Finger movement commonly slows for a frame or two just before the
        // lift. Give that last-frame slowdown only a light influence so the
        // inertial tail starts at the swipe's perceived speed, not at the
        // nearly-stationary release sample.
        velocity = velocity == 0 ? delta : (velocity * 0.78) + (delta * 0.22)
        lastDirectDelta = delta
        send(delta)
    }
    func end(send: @escaping (CGFloat) -> Void) {
        timer?.invalidate()
        // Do not turn an intentional slow stop into a small extra scroll.
        // The retained velocity above is for a real fling; it is only used
        // when the finger was still moving with a meaningful final speed.
        guard abs(lastDirectDelta) > 3.0, abs(velocity) > 0.5 else {
            velocity = 0
            lastDirectDelta = 0
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            // 0.88 stopped after only a handful of frames. This deliberately
            // has a longer native-feeling glide, while still reaching rest in
            // roughly a second rather than continuing indefinitely.
            self.velocity *= 0.94
            if abs(self.velocity) <= 0.5 {
                timer.invalidate()
                self.timer = nil
                self.velocity = 0
                self.lastDirectDelta = 0
            } else {
                send(self.velocity)
            }
        }
    }
    deinit { timer?.invalidate() }
}
