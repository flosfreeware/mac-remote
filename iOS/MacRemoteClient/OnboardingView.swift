import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var remote: RemoteConnection
    let requiresFullOnboarding: Bool
    let centerPointer: () -> Void
    let finish: () -> Void
    let tutorialPreview: AnyView
    @Binding var allowsCursorMovement: Bool

    private enum Page: Equatable { case pair, center, tutorial }
    @State private var page: Page = .pair
    @State private var showScanner = false
    @State private var showCodeField = false
    @State private var pairingCode = ""
    @State private var pairingInProgress = false
    @State private var showPairingFailureAlert = false
    @State private var pairingPresentationTimeout: DispatchWorkItem?
    @State private var hasCentered = false
    @State private var finishing = false

    init(requiresFullOnboarding: Bool, centerPointer: @escaping () -> Void, finish: @escaping () -> Void,
         tutorialPreview: AnyView, allowsCursorMovement: Binding<Bool>) {
        self.requiresFullOnboarding = requiresFullOnboarding
        self.centerPointer = centerPointer
        self.finish = finish
        self.tutorialPreview = tutorialPreview
        _allowsCursorMovement = allowsCursorMovement
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if requiresFullOnboarding {
                    progress
                        .padding(.top, 18)
                }
                pageContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 24)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .scaleEffect(finishing ? 1.16 : 1)
        .opacity(finishing ? 0 : 1)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: finishing)
        .onChange(of: remote.hasSecret) { _, paired in
            if paired {
                pairingPresentationTimeout?.cancel()
                pairingInProgress = false
                advanceAfterPairingIfNeeded(true)
            } else {
                // Reset All Settings clears the pairing on the networking queue.
                // The onboarding view may have appeared before that main-actor
                // publication, so always return to the pairing page explicitly.
                withAnimation {
                    page = .pair
                    hasCentered = false
                    showCodeField = false
                    pairingCode = ""
                }
            }
        }
        .onChange(of: remote.compatibilityIssue) { _, issue in
            if issue != nil { pairingInProgress = false }
        }
        .onChange(of: remote.pairingFailure) { _, failure in
            if failure != nil {
                pairingPresentationTimeout?.cancel()
                pairingInProgress = false
                showPairingFailureAlert = true
            }
        }
        // Pairing replaces the unpaired root content with the live remote in
        // the same render pass. That can recreate this view after hasSecret is
        // already true, in which case onChange has no transition to observe.
        .onAppear {
            advanceAfterPairingIfNeeded(remote.hasSecret)
            publishCursorMovementAllowance()
        }
        .onChange(of: page) { _, _ in publishCursorMovementAllowance() }
        .onChange(of: showScanner) { _, _ in publishCursorMovementAllowance() }
        .onChange(of: hasCentered) { _, _ in publishCursorMovementAllowance() }
        .onDisappear {
            pairingPresentationTimeout?.cancel()
            allowsCursorMovement = false
        }
        .sheet(isPresented: $showScanner) {
            QRCodeScanner { value in
                showScanner = false
                beginPairing(with: value)
            }
            .ignoresSafeArea()
        }
        .alert("Couldn’t pair with your Mac", isPresented: $showPairingFailureAlert) {
            Button("Try Again", role: .cancel) {}
        } message: {
            Text(remote.pairingFailure ?? "Please scan the QR code again.")
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            progressDot(.pair)
            progressDot(.center)
            progressDot(.tutorial)
        }
    }

    private func publishCursorMovementAllowance() {
        allowsCursorMovement = page == .center && hasCentered && !showScanner
    }

    private func advanceAfterPairingIfNeeded(_ paired: Bool) {
        guard paired, page == .pair else { return }
        if requiresFullOnboarding {
            withAnimation { page = .center }
        } else {
            finish()
        }
    }

    private func beginPairing(with code: String) {
        pairingInProgress = true
        showCodeField = false
        pairingPresentationTimeout?.cancel()
        let timeout = DispatchWorkItem {
            guard pairingInProgress, !remote.hasSecret else { return }
            remote.expirePendingPairingAttempt()
        }
        pairingPresentationTimeout = timeout
        // This is deliberately separate from the networking timeout: the user
        // must never be left on a spinner if Network.framework stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        remote.pair(code)
    }

    private func progressDot(_ item: Page) -> some View {
        Capsule()
            .fill(item == page ? Color.white : Color.white.opacity(0.25))
            .frame(width: item == page ? 24 : 7, height: 7)
            .animation(.easeInOut(duration: 0.2), value: page)
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .pair: pairingPage
        case .center: centeringPage
        case .tutorial: tutorialPage
        }
    }

    private var pairingPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "desktopcomputer.and.iphone")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
            Text("Pair your Mac")
                .font(.largeTitle.weight(.bold))
            if pairingInProgress {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Connecting to your Mac…")
                    .font(.headline)
                Text("Keep Mac Remote open. This can take a moment on a weak connection.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Download Mac Remote on your Mac first, then open its menu-bar app and scan the QR code it shows.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Download Mac Remote", destination: URL(string: "https://flosfreeware.github.io/mac-remote/")!)
                    .font(.headline)
                if remote.hasSecret {
                    Text("Your Mac is already paired.")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            VStack(spacing: 12) {
                if pairingInProgress {
                    Button("Cancel") {
                        pairingPresentationTimeout?.cancel()
                        pairingInProgress = false
                        remote.cancelPairingAttempt()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        // The capture session, and therefore camera permission, is
                        // created only after this explicit user action.
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if remote.hasSecret {
                    Button("Continue") { withAnimation { page = .center } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button(showCodeField ? "Hide code entry" : "or enter code") {
                            withAnimation { showCodeField.toggle() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        if showCodeField {
                            HStack(spacing: 8) {
                                TextField("Pairing code", text: $pairingCode)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .textFieldStyle(.roundedBorder)
                                Button("Pair") { beginPairing(with: pairingCode) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            Spacer().frame(height: 18)
        }
    }

    private var centeringPage: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 38)
            Text("Center your pointer")
                .font(.largeTitle.weight(.bold))
            Text("Point your iPhone at the Mac display, then press the centering control. You can use it again whenever you want to readjust.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CenteringInstructionAnimation()
                .frame(height: 380)
                .padding(.vertical, 14)
            Spacer()
            HStack(alignment: .bottom) {
                Button {
                    centerPointer()
                    hasCentered = true
                } label: {
                    Image(systemName: "scope")
                        .font(.body)
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Center pointer")
                Spacer()
                Button("Next") { withAnimation { page = .tutorial } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(hasCentered ? .accentColor : .gray.opacity(0.45))
                    .opacity(hasCentered ? 1 : 0.48)
                    .disabled(!hasCentered)
            }
            .padding(.bottom, 22)
        }
    }

    private var tutorialPage: some View {
        VStack(spacing: 15) {
            Spacer().frame(height: 26)
            Text("Use your remote")
                .font(.largeTitle.weight(.bold))
            Text("Swipe up or down anywhere to scroll. Swipe left or right to navigate in supported apps.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            tutorialPreview
                .frame(width: 390, height: 844)
                // Keep the side-to-side fit, while leaving breathing room above
                // and below the live UI inside the drawn iPhone border.
                .scaleEffect(x: 0.51, y: 0.48)
                .frame(width: 207, height: 447)
                .clipShape(RoundedRectangle(cornerRadius: 43, style: .continuous))
                .overlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: 43, style: .continuous)
                            .stroke(.white, lineWidth: 3)
                        SwipeTutorialOverlay()
                    }
                }
                .padding(.vertical, 4)
                .allowsHitTesting(false)
            Spacer()
            Button("Start using remote") {
                finishing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { finish() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.bottom, 22)
        }
    }
}

private struct CenteringInstructionAnimation: View {
    var body: some View {
        TimelineView(.animation) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8.0)
            let tilt = tiltProgress(at: cycle)
            let hand = handProgress(at: cycle)
            let handOpacity = handVisibility(at: cycle)
            let tap = (3.25..<3.8).contains(cycle) ? (cycle - 3.25) / 0.55 : nil
            let nextEnabled = cycle >= 3.25
            VStack(spacing: 8) {
                laptopOutline
                    .frame(height: 126)
                phoneScene(handProgress: hand, handOpacity: handOpacity, tapProgress: tap, nextEnabled: nextEnabled)
                    // The top edge recedes while the bottom remains nearest the user,
                    // like a remote being pointed forward at a display.
                    .rotation3DEffect(.degrees(28 * tilt), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.78)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func phoneScene(handProgress: Double, handOpacity: Double, tapProgress: Double?, nextEnabled: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white, lineWidth: 2)
            Text("Point at your\ndisplay")
                .font(.system(size: 11, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.9))
            centeringControl
            nextControl(enabled: nextEnabled)
            if let tapProgress {
                Circle()
                    .stroke(.white.opacity(0.7 * (1 - tapProgress)), lineWidth: 1.7)
                    .frame(width: 15, height: 15)
                    .scaleEffect(0.65 + tapProgress)
                    .position(x: 28, y: 216)
            }
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .opacity(handOpacity)
                .position(x: 76 - 38 * handProgress, y: 270 - 39 * handProgress)
        }
        .frame(width: 112, height: 242)
    }

    private var centeringControl: some View {
        Button {} label: {
            Image(systemName: "scope")
                .font(.body)
                .frame(width: 38, height: 38)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .scaleEffect(0.58)
        .allowsHitTesting(false)
        .position(x: 28, y: 216)
    }

    private func nextControl(enabled: Bool) -> some View {
        Button("Next") {}
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(enabled ? .accentColor : .gray.opacity(0.45))
            .opacity(enabled ? 1 : 0.48)
            .disabled(!enabled)
            .scaleEffect(0.45)
            .allowsHitTesting(false)
            .position(x: 84, y: 216)
    }

    private func tiltProgress(at time: Double) -> Double {
        if time < 1.8 { return eased(time / 1.8) }
        if time < 4.65 { return 1 }
        if time < 6.45 { return 1 - eased((time - 4.65) / 1.8) }
        return 0
    }

    private func handProgress(at time: Double) -> Double {
        if (2.45..<3.25).contains(time) { return eased((time - 2.45) / 0.8) }
        if (3.25..<3.85).contains(time) { return 1 }
        if (3.85..<4.65).contains(time) { return 1 - eased((time - 3.85) / 0.8) }
        return 0
    }

    private func handVisibility(at time: Double) -> Double {
        if (2.35..<2.55).contains(time) { return (time - 2.35) / 0.2 }
        if (2.55..<4.65).contains(time) { return 1 }
        if (4.65..<4.85).contains(time) { return 1 - (time - 4.65) / 0.2 }
        return 0
    }

    private func eased(_ value: Double) -> Double {
        let value = min(1, max(0, value))
        return value * value * (3 - 2 * value)
    }

    private var laptopOutline: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.46), lineWidth: 2)
                .frame(width: 202, height: 92)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.46), lineWidth: 2)
                .frame(width: 220, height: 14)
        }
    }
}

private struct SwipeTutorialOverlay: View {
    var body: some View {
        TimelineView(.animation) { context in
            let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8.4)
            let gesture = Int(cycle / 2.8)
            let vertical = gesture == 0
            let horizontal = gesture == 1
            let phase = (cycle - Double(gesture) * 2.8) / 2.8
            let progress = easedProgress(phase)

            ZStack {
                if vertical {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: 2, height: 112)
                        .position(x: 104, y: 260)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .position(x: 104, y: 189)
                    hand
                        .position(x: 104, y: 310 - 104 * progress)
                } else if horizontal {
                    Capsule()
                        .fill(.white.opacity(0.22))
                        .frame(width: 94, height: 2)
                        .position(x: 104, y: 274)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .position(x: 166, y: 274)
                    hand
                        .position(x: 52 + 92 * progress, y: 274)
                } else {
                    let tapProgress = min(1, max(0, (phase - 0.18) / 0.46))
                    Circle()
                        .stroke(.white.opacity(0.62 * (1 - tapProgress)), lineWidth: 2)
                        .frame(width: 22, height: 22)
                        .scaleEffect(0.7 + tapProgress)
                        .position(x: 112, y: 250)
                    hand
                        .position(x: 122, y: 265)
                }
                Text(vertical ? "Scroll" : (horizontal ? "Back" : "Tap"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.65), in: Capsule())
                    .opacity(labelOpacity(phase))
                    .position(x: 104, y: 128)
            }
            .opacity(gestureOpacity(phase))
        }
    }

    private var hand: some View {
        Image(systemName: "hand.point.up.left.fill")
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 2)
    }

    private func easedProgress(_ phase: Double) -> Double {
        let travel = min(1, max(0, (phase - 0.15) / 0.58))
        return travel * travel * (3 - 2 * travel)
    }

    private func gestureOpacity(_ phase: Double) -> Double {
        if phase < 0.12 { return phase / 0.12 }
        if phase > 0.82 { return (1 - phase) / 0.18 }
        return 1
    }

    private func labelOpacity(_ phase: Double) -> Double {
        let visible = min(1, max(0, phase / 0.12))
        return visible * max(0, 1 - (phase - 0.46) / 0.22)
    }
}
