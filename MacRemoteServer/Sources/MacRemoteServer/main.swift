import AppKit
import Carbon
import CoreAudio
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import Network
import Security
import ServiceManagement
import IOKit.pwr_mgt

private final class PairingPanelController: NSWindowController, NSWindowDelegate {
    private var enrollment: String
    private let invalidate: () -> Void
    private let dismissed: () -> Void
    private let refreshEnrollment: (@escaping (String?) -> Void) -> Void
    private var invalidated = false
    private var refreshTimer: Timer?
    private weak var qrImageView: NSImageView?
    private weak var enrollmentField: NSTextField?

    init(enrollment: String, invalidate: @escaping () -> Void,
         refreshEnrollment: @escaping (@escaping (String?) -> Void) -> Void,
         dismissed: @escaping () -> Void) {
        self.enrollment = enrollment
        self.invalidate = invalidate
        self.refreshEnrollment = refreshEnrollment
        self.dismissed = dismissed
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Pair an iPhone"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildInterface(in: panel)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshTimerIfNeeded()
    }

    // Enrollment has already consumed the one-time token, so this must not
    // invalidate it again while dismissing the modal panel.
    func closeAfterSuccessfulPairing() {
        invalidated = true
        refreshTimer?.invalidate(); refreshTimer = nil
        window?.orderOut(nil)
        window?.close()
    }

    @objc private func copySecret() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(enrollment, forType: .string)
    }

    @objc private func done() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate(); refreshTimer = nil
        if !invalidated {
            invalidated = true
            invalidate()
        }
        dismissed()
    }

    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: PairingEnrollment.rotationInterval, repeats: true) { [weak self] _ in
            self?.refreshCode()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshCode() {
        guard !invalidated, window?.isVisible == true else { return }
        refreshEnrollment { [weak self] enrollment in
            DispatchQueue.main.async {
                guard let self, let enrollment, !self.invalidated else { return }
                self.enrollment = enrollment
                self.enrollmentField?.stringValue = enrollment
                self.qrImageView?.image = QRCode.image(for: enrollment)
                self.qrImageView?.needsDisplay = true
            }
        }
    }

    private func buildInterface(in panel: NSPanel) {
        let content = NSView(frame: panel.contentView!.bounds)
        panel.contentView = content

        let title = NSTextField(labelWithString: "Pair an iPhone")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.frame = NSRect(x: 28, y: 438, width: 364, height: 28)
        content.addSubview(title)

        let instructions = NSTextField(wrappingLabelWithString: "Scan this one-time QR code, or copy the pairing code below. A fresh code replaces it every minute, and it can pair one iPhone only.")
        instructions.font = .systemFont(ofSize: 14)
        instructions.textColor = .secondaryLabelColor
        instructions.frame = NSRect(x: 28, y: 370, width: 364, height: 54)
        content.addSubview(instructions)

        let cardSide: CGFloat = 210
        let card = NSView(frame: NSRect(x: (420 - cardSide) / 2, y: 140, width: cardSide, height: cardSide))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 14
        card.layer?.masksToBounds = true
        if let image = QRCode.image(for: enrollment) {
            let imageView = NSImageView(frame: card.bounds.insetBy(dx: 10, dy: 10))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            card.addSubview(imageView)
            qrImageView = imageView
        }
        content.addSubview(card)

        let codeLabel = NSTextField(labelWithString: "Pairing code")
        codeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        codeLabel.textColor = .secondaryLabelColor
        codeLabel.frame = NSRect(x: 28, y: 116, width: 160, height: 18)
        content.addSubview(codeLabel)

        let codeContainer = NSView(frame: NSRect(x: 28, y: 76, width: 364, height: 34))
        codeContainer.wantsLayer = true
        codeContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        codeContainer.layer?.cornerRadius = 8
        codeContainer.layer?.borderWidth = 1
        codeContainer.layer?.borderColor = NSColor.separatorColor.cgColor
        content.addSubview(codeContainer)

        let field = NSTextField(string: enrollment)
        field.isEditable = false
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingMiddle
        field.alignment = .left
        field.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        field.frame = NSRect(x: 10, y: 7, width: 344, height: 20)
        codeContainer.addSubview(field)
        enrollmentField = field

        let copy = NSButton(title: "Copy", target: self, action: #selector(copySecret))
        copy.frame = NSRect(x: 214, y: 28, width: 86, height: 32)
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 306, y: 28, width: 86, height: 32)
        content.addSubview(copy)
        content.addSubview(done)
    }
}

private final class FirstRunSetupController: NSWindowController {
    private let openPairing: () -> Void
    private let complete: (Bool) -> Void
    private var permissionTimer: Timer?
    private var hasRequestedAccessibilityPermission = false
    private let statusLabel = NSTextField(labelWithString: "")
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Open Mac Remote at startup", target: nil, action: nil)

    init(openPairing: @escaping () -> Void, complete: @escaping (Bool) -> Void) {
        self.openPairing = openPairing
        self.complete = complete
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Mac Remote"
        window.level = .floating
        window.isReleasedWhenClosed = false
        super.init(window: window)
        showWelcome()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showWelcome() {
        permissionTimer?.invalidate()
        launchAtLoginCheckbox.state = .on
        setPage(title: "Welcome to Mac Remote",
                message: "Mac Remote runs silently in the background. You can make changes using its menu bar controls.",
                primaryTitle: "Continue", primaryAction: #selector(showAccessibility))
    }

    @objc private func showAccessibility() {
        // Let macOS's Device Control and Data Access prompt remain above the
        // setup window. The setup window returns to floating level after the
        // permission is granted.
        window?.level = .normal
        setPage(title: "Enable Accessibility",
                message: "In System Settings, go to Privacy & Security → Accessibility and allow Mac Remote under Device Control and Data Access. This permission lets Mac Remote control your pointer and simulate key presses.",
                primaryTitle: nil, primaryAction: nil)
        statusLabel.stringValue = AXIsProcessTrusted() ? "Accessibility is enabled." : "Waiting for Accessibility permission…"
        statusLabel.textColor = AXIsProcessTrusted() ? .systemGreen : .secondaryLabelColor
        beginPermissionPolling()
        // Let the Accessibility step draw before macOS presents its own sheet.
        // Without the defer, the system sheet obscures this page as it appears.
        guard !hasRequestedAccessibilityPermission else { return }
        hasRequestedAccessibilityPermission = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            self?.requestAccessibilityPermission()
        }
    }

    private func beginPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.permissionTimer?.invalidate(); self.permissionTimer = nil
            self.statusLabel.stringValue = "Accessibility is enabled."
            self.statusLabel.textColor = .systemGreen
            self.window?.level = .floating
            self.showPairingStep()
        }
        if let permissionTimer { RunLoop.main.add(permissionTimer, forMode: .common) }
    }

    private func showPairingStep() {
        permissionTimer?.invalidate(); permissionTimer = nil
        statusLabel.stringValue = ""
        setPage(title: "Pair your iPhone",
                message: "The pairing code is ready on your Mac. Scan it in the Mac Remote app on your iPhone to finish setup.",
                primaryTitle: "Show Pairing QR Code", primaryAction: #selector(finishSetup))
    }

    @objc private func finishSetup() {
        complete(launchAtLoginCheckbox.state == .on)
        close()
        openPairing()
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func setPage(title: String, message: String, primaryTitle: String?, primaryAction: Selector?) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 300))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.frame = NSRect(x: 30, y: 220, width: 410, height: 30)
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.frame = NSRect(x: 30, y: 142, width: 410, height: 65)
        if title == "Enable Accessibility" {
            messageLabel.frame = NSRect(x: 30, y: 132, width: 410, height: 74)
        }
        let later = NSButton(title: "Set Up Later", target: self, action: #selector(close))
        later.frame = NSRect(x: 30, y: 28, width: 120, height: 32)
        content.addSubview(titleLabel)
        content.addSubview(messageLabel)
        if title == "Enable Accessibility" {
            statusLabel.frame = NSRect(x: 30, y: 110, width: 410, height: 22)
            content.addSubview(statusLabel)
            let securityLink = NSButton(title: "Read our security commitments", target: self, action: #selector(openSecurityCommitments))
            securityLink.isBordered = false
            securityLink.attributedTitle = NSAttributedString(
                string: "Read our security commitments",
                attributes: [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
            )
            securityLink.frame = NSRect(x: 30, y: 76, width: 260, height: 20)
            content.addSubview(securityLink)
        }
        if title == "Welcome to Mac Remote" {
            launchAtLoginCheckbox.frame = NSRect(x: 30, y: 100, width: 280, height: 22)
            content.addSubview(launchAtLoginCheckbox)
        }
        if let primaryTitle, let primaryAction {
            let primary = NSButton(title: primaryTitle, target: self, action: primaryAction)
            primary.bezelStyle = .rounded
            primary.keyEquivalent = "\r"
            primary.frame = NSRect(x: 250, y: 28, width: 190, height: 32)
            content.addSubview(primary)
        }
        content.addSubview(later)
        window?.contentView = content
    }

    @objc private func openSecurityCommitments() {
        guard let url = URL(string: "https://github.com/covyy/mac-remote-site/blob/main/security.md") else { return }
        NSWorkspace.shared.open(url)
    }

    deinit { permissionTimer?.invalidate() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: RemoteServer!
    private var hasPairedIPhone = false
    private var pairedIPhoneName: String?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var remoteToggleMenuItem: NSMenuItem!
    private var automaticUpdatesMenuItem: NSMenuItem!
    private var pairingMenuItem: NSMenuItem!
    private var unpairMenuItem: NSMenuItem!
    private var updateManager: UpdateManager!
    private var pairingPanel: PairingPanelController?
    private var firstRunSetupController: FirstRunSetupController?
    private var diagnosticsWindowController: DiagnosticsWindowController?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pointerEventTap: CFMachPort?
    private var pointerEventTapSource: CFRunLoopSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = RemoteServer(secret: SecretStore.loadOrCreate(), status: { [weak self] state in
            DispatchQueue.main.async { self?.statusMenuItem.title = "Status: \(state)" }
        }, pairingStateChanged: { [weak self] paired, deviceName in
            DispatchQueue.main.async {
                self?.hasPairedIPhone = paired
                self?.pairedIPhoneName = deviceName
                self?.updatePairingMenuItems()
                if paired, let panel = self?.pairingPanel {
                    panel.closeAfterSuccessfulPairing()
                    self?.pairingPanel = nil
                    self?.showPairingSuccess(for: deviceName ?? "iPhone")
                }
            }
        })
        server.start()
        updateManager = UpdateManager(
            installSafetyCheck: { [weak self] completion in self?.server.hasConnectedPhone(completion) ?? completion(true) },
            statusChanged: { status in
                if case .failed(let message) = status { NSLog("Mac Remote update: %@", message) }
            }
        )
        updateManager.start()
        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel,
            .keyDown, .keyUp, .flagsChanged]
        let observePointer: (NSEvent) -> Void = { [weak self] event in
            let keyboard = event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged
            if keyboard { self?.server.observeKeyboardDetection(event) }
            guard let event = event.cgEvent else { return }
            if event.getIntegerValueField(.eventSourceUserData) == Input.pointerEventTag {
                if !keyboard { self?.server.observePointerEvent(timestamp: event.timestamp, observed: LatencyDiagnostics.now()) }
                return
            }
            if keyboard {
                Input.physicalKeyboard(event)
                return
            }
            self?.rebasePhysicalPointer(event)
        }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents, handler: observePointer)
        // Global monitors exclude this app's own menus/windows.
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { event in
            observePointer(event)
            return event
        }
        installPointerEventTap()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let icon = appIconImage() {
            let iconSide = NSStatusBar.system.thickness
            icon.size = NSSize(width: iconSide, height: iconSide)
            icon.isTemplate = false
            statusItem.button?.image = icon
            statusItem.button?.imagePosition = .imageOnly
        }
        statusItem.button?.toolTip = "Mac Remote"
        let menu = NSMenu()
        statusMenuItem = menu.addItem(withTitle: "Status: Starting…", action: nil, keyEquivalent: "")
        remoteToggleMenuItem = menu.addItem(withTitle: "Remote Enabled", action: #selector(toggleRemote), keyEquivalent: "")
        remoteToggleMenuItem.target = self
        remoteToggleMenuItem.state = .on
        automaticUpdatesMenuItem = menu.addItem(withTitle: "Update Automatically", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
        automaticUpdatesMenuItem.target = self
        automaticUpdatesMenuItem.state = updateManager.automaticUpdatesEnabled ? .on : .off
        menu.addItem(NSMenuItem.separator())
        pairingMenuItem = menu.addItem(withTitle: "Show Pairing QR Code", action: #selector(showSecret), keyEquivalent: "s")
        pairingMenuItem.target = self
        unpairMenuItem = menu.addItem(withTitle: "Decouple iPhone", action: #selector(decoupleIPhone), keyEquivalent: "")
        unpairMenuItem.target = self
        updatePairingMenuItems()
        menu.addItem(withTitle: "Check Accessibility Permission", action: #selector(checkAccessibility), keyEquivalent: "a")
        menu.addItem(withTitle: "Open Diagnostics", action: #selector(openDiagnostics), keyEquivalent: "d")
        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "About", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Uninstall", action: #selector(resetAllSettings), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Mac Remote", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
        if UserDefaults.standard.bool(forKey: "completedFirstRunSetup") {
            if UserDefaults.standard.object(forKey: "launchAtLoginEnabled") as? Bool ?? true {
                registerForLaunchAtLogin()
            }
        } else {
            showFirstRunSetup()
        }
    }

    private func showFirstRunSetup() {
        let controller = FirstRunSetupController(openPairing: { [weak self] in self?.showSecret() }, complete: { [weak self] launchAtLogin in
            UserDefaults.standard.set(true, forKey: "completedFirstRunSetup")
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLoginEnabled")
            self?.setLaunchAtLoginEnabled(launchAtLogin)
        })
        firstRunSetupController = controller
        controller.showWindow(nil)
    }

    private func updatePairingMenuItems() {
        pairingMenuItem?.isHidden = hasPairedIPhone
        unpairMenuItem?.isHidden = !hasPairedIPhone
        unpairMenuItem?.title = "Decouple \(pairedIPhoneName ?? "iPhone")"
    }

    private func registerForLaunchAtLogin() {
        let service = SMAppService.mainApp
        guard service.status == .notRegistered else { return }
        do {
            try service.register()
        } catch {
            NSLog("Mac Remote: could not register as a login item: %@", error.localizedDescription)
        }
    }

    private func setLaunchAtLoginEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status == .notRegistered else { return }
                try service.register()
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            NSLog("Mac Remote: could not update login item: %@", error.localizedDescription)
        }
    }

    private func appIconImage() -> NSImage? {
        guard let iconURL = Bundle.module.url(forResource: "icon", withExtension: "svg"),
              let icon = NSImage(contentsOf: iconURL) else { return nil }
        icon.isTemplate = false
        return icon
    }

    private func fullColorAppIconImage() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let icon = NSImage(contentsOf: iconURL) else { return nil }
        icon.isTemplate = false
        return icon
    }

    @objc private func showSecret() {
        if let pairingPanel {
            pairingPanel.show()
            return
        }
        server.beginPairing { [weak self] enrollment in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let enrollment else {
                    NSAlert(error: NSError(domain: "MacRemote", code: 0, userInfo: [NSLocalizedDescriptionKey: "Decouple the currently paired iPhone before pairing another device."])).runModal()
                    return
                }
                let panel = PairingPanelController(
                    enrollment: enrollment,
                    invalidate: { [weak self] in self?.server.cancelPairing() },
                    refreshEnrollment: { [weak self] completion in self?.server.beginPairing(completion: completion) },
                    dismissed: { [weak self] in self?.pairingPanel = nil }
                )
                self.pairingPanel = panel
                panel.show()
            }
        }
    }

    @objc private func decoupleIPhone() {
        let alert = NSAlert()
        if let icon = appIconImage() {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        let deviceName = pairedIPhoneName ?? "iPhone"
        alert.messageText = "Decouple \(deviceName)?"
        alert.informativeText = "\(deviceName) will be notified and must scan a new QR code to reconnect."
        alert.addButton(withTitle: "Decouple")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        server.unpairDevice()
    }

    private func showPairingSuccess(for deviceName: String) {
        let alert = NSAlert()
        if let icon = appIconImage() {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.messageText = "iPhone Paired"
        alert.informativeText = "\(deviceName) is now paired with this Mac."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    @objc private func checkAccessibility() {
        if AXIsProcessTrusted() {
            NSAlert(error: NSError(domain: "MacRemote", code: 0, userInfo: [NSLocalizedDescriptionKey: "Accessibility permission is enabled."])).runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Accessibility permission is required"
            alert.informativeText = "Mac Remote can receive connections, but cannot move the pointer or send clicks until enabled."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
    @objc private func toggleRemote() {
        let enabled = remoteToggleMenuItem.state != .on
        remoteToggleMenuItem.state = enabled ? .on : .off
        server.setRemoteEnabled(enabled)
    }
    @objc private func toggleAutomaticUpdates() {
        let enabled = automaticUpdatesMenuItem.state != .on
        automaticUpdatesMenuItem.state = enabled ? .on : .off
        updateManager.setAutomaticUpdatesEnabled(enabled)
        guard !enabled else { return }
        let alert = NSAlert()
        if let icon = fullColorAppIconImage() {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.messageText = "Automatic updates turned off"
        alert.informativeText = "Your iPhone will notify you when a newer version needs to be installed on the Mac."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    @objc private func openDiagnostics() {
        if diagnosticsWindowController == nil { diagnosticsWindowController = DiagnosticsWindowController(server: server) }
        diagnosticsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func checkForUpdates() { updateManager.checkForUpdates(manual: true) }
    @objc private func showAbout() {
        let alert = NSAlert()
        if let icon = fullColorAppIconImage() {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.messageText = "Mac Remote"
        alert.informativeText = "App version: \(RemoteAppVersion.display)\nProtocol version: \(RemoteProtocol.version)\nAccepted protocol range: \(RemoteProtocol.acceptedRangeDescription)\n\nContact: pails.splits_60@icloud.com"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func resetAllSettings() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let icon = fullColorAppIconImage() {
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.messageText = "Uninstall Mac Remote?"
        alert.informativeText = "This removes the paired iPhone, settings, diagnostics, update files, and login item from this Mac. This action can’t be undone."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        resetStoredData()
        resetAccessibilityPermission()

        let completion = NSAlert()
        if let icon = fullColorAppIconImage() {
            icon.size = NSSize(width: 64, height: 64)
            completion.icon = icon
        }
        completion.messageText = "Mac Remote data deleted"
        completion.informativeText = "Move Mac Remote from Applications to the Bin to finish uninstalling."
        completion.addButton(withTitle: "OK")
        completion.runModal()
        NSApplication.shared.terminate(nil)
    }

    private func resetStoredData() {
        server.stop()
        setLaunchAtLoginEnabled(false)
        SecretStore.delete()
        PairingCredentialStore.delete()
        PairedDeviceNameStore.delete()

        let applicationSupportDirectory = LatencyDiagnostics.directoryURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: applicationSupportDirectory)
        if let identifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
        }
        UserDefaults.standard.synchronize()
    }

    private func resetAccessibilityPermission() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleIdentifier]
        do {
            try reset.run()
            reset.waitUntilExit()
        } catch { }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let pointerEventTap { CFMachPortInvalidate(pointerEventTap) }
        if let pointerEventTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), pointerEventTapSource, .commonModes) }
        server.stop()
    }

    private func rebasePhysicalPointer(_ event: CGEvent) {
        guard event.getIntegerValueField(.eventSourceUserData) != Input.pointerEventTag else { return }
        let pressed: Bool?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: pressed = true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: pressed = false
        default: pressed = nil
        }
        Input.rebasePointer(to: event.location,
            button: pressed == nil ? nil : event.getIntegerValueField(.mouseEventButtonNumber), pressed: pressed)
    }

    private func installPointerEventTap() {
        let eventTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, _, event, userInfo in
            if let userInfo {
                Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue().rebasePhysicalPointer(event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            NSLog("Mac Remote: could not install physical-pointer event tap")
            return
        }
        pointerEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        pointerEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
}

private final class DiagnosticsWindowController: NSWindowController {
    private let server: RemoteServer
    private let phoneStatusLabel = NSTextField(labelWithString: "Checking…")
    private let motionPeersLabel = NSTextField(labelWithString: "Checking…")
    private let accessibilityLabel = NSTextField(labelWithString: "Checking…")
    private let listenEventsLabel = NSTextField(labelWithString: "Checking…")
    private let secureInputLabel = NSTextField(labelWithString: "Checking…")
    private let listenerErrorLabel = NSTextField(labelWithString: "None")
    private let measurementLabel = NSTextField(labelWithString: "No measurement running.")
    private let assessmentLabel = NSTextField(labelWithString: "Overall assessment: Awaiting measurement")
    private let resultsTextView = NSTextView()
    private let resultsScrollView = NSScrollView()
    private let startButton = NSButton(title: "Start Measuring (10s)", target: nil, action: nil)
    private let revealButton = NSButton(title: "Open Raw Data Folder", target: nil, action: nil)
    private var refreshTimer: Timer?
    private var measurementStartedAt: Date?

    init(server: RemoteServer) {
        self.server = server
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 470),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Mac Remote Diagnostics"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface(in: window)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        resizeResultsDocument()
        startRefreshing()
    }

    private func buildInterface(in window: NSWindow) {
        let title = NSTextField(labelWithString: "Connection diagnostics")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        let instructions = NSTextField(wrappingLabelWithString: "A measurement exchanges timed probes with the connected iPhone for 10 seconds. Keep the iPhone app open; moving the cursor during the run adds input-path samples.")
        instructions.textColor = .secondaryLabelColor

        [phoneStatusLabel, motionPeersLabel, accessibilityLabel, listenEventsLabel, secureInputLabel, listenerErrorLabel, measurementLabel, assessmentLabel].forEach {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }
        assessmentLabel.textColor = .secondaryLabelColor
        resultsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        resultsTextView.textColor = .secondaryLabelColor
        resultsTextView.isEditable = false
        resultsTextView.isSelectable = true
        resultsTextView.drawsBackground = false
        resultsTextView.textContainerInset = NSSize(width: 6, height: 6)
        resultsTextView.isHorizontallyResizable = false
        resultsTextView.isVerticallyResizable = true
        resultsTextView.minSize = .zero
        resultsTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        resultsTextView.autoresizingMask = [.width]
        resultsTextView.textContainer?.widthTracksTextView = true
        resultsScrollView.borderType = .bezelBorder
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.autohidesScrollers = true
        resultsScrollView.drawsBackground = false
        resultsScrollView.documentView = resultsTextView
        setResultsText("No results yet. Start a 10-second measurement while the iPhone app is connected.")

        startButton.target = self; startButton.action = #selector(startMeasurement)
        revealButton.target = self; revealButton.action = #selector(revealRawData)
        let buttons = NSStackView(views: [startButton, revealButton])
        buttons.orientation = .horizontal; buttons.spacing = 8

        let connection = metricSection("Connection", rows: [
            ("iPhone", phoneStatusLabel),
            ("Motion peers", motionPeersLabel)
        ])
        let health = metricSection("Mac health", rows: [
            ("Accessibility", accessibilityLabel),
            ("Listen Events", listenEventsLabel),
            ("Secure Input", secureInputLabel),
            ("Server listener", listenerErrorLabel)
        ])
        let measurement = metricSection("Measurement", rows: [("Status", measurementLabel)])
        let results = resultsSection()
        let stack = NSStackView(views: [title, instructions, connection, health, measurement, results, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -22),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            results.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultsScrollView.widthAnchor.constraint(equalTo: results.widthAnchor),
            resultsScrollView.heightAnchor.constraint(equalToConstant: 150)
        ])
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        server.diagnosticsSnapshot { [weak self] snapshot in
            guard let self else { return }
            self.phoneStatusLabel.stringValue = snapshot.connected ? "Connected" : "Not connected"
            self.motionPeersLabel.stringValue = "\(snapshot.motionPeerCount)"
            self.accessibilityLabel.stringValue = snapshot.accessibilityGranted ? "Granted" : "Missing"
            self.listenEventsLabel.stringValue = snapshot.listenAccessGranted ? "Granted" : "Missing"
            self.secureInputLabel.stringValue = snapshot.secureInputEnabled ? "On" : "Off"
            self.listenerErrorLabel.stringValue = snapshot.listenerError ?? "No error"
            self.listenerErrorLabel.textColor = snapshot.listenerError == nil ? .secondaryLabelColor : .systemRed
            if snapshot.active, let started = self.measurementStartedAt {
                let remaining = max(0, 10 - Date().timeIntervalSince(started))
                self.measurementLabel.stringValue = String(format: "Measurement running — %.0f seconds remaining", ceil(remaining))
            } else if !snapshot.active, self.measurementStartedAt != nil {
                self.measurementStartedAt = nil
                self.startButton.isEnabled = snapshot.connected
            } else {
                self.startButton.isEnabled = snapshot.connected
            }
        }
    }

    @objc private func startMeasurement() {
        startButton.isEnabled = false
        measurementStartedAt = Date()
        measurementLabel.stringValue = "Measurement running — 10 seconds remaining"
        assessmentLabel.stringValue = "Overall assessment: Measuring…"
        assessmentLabel.textColor = .secondaryLabelColor
        setResultsText("Collecting iPhone↔Mac probes, queue timing, input-path samples, and connection health…")
        server.startDiagnosticsMeasurement { [weak self] result in
            guard let self else { return }
            self.measurementStartedAt = nil
            self.startButton.isEnabled = true
            switch result {
            case .success(let summary):
                self.measurementLabel.stringValue = String(format: "Completed in %.1f seconds", summary.duration)
                self.showAssessment(for: summary)
                self.setResultsText(self.format(summary))
            case .failure(let error):
                self.measurementLabel.stringValue = "Measurement aborted"
                self.assessmentLabel.stringValue = "Overall assessment: No result"
                self.assessmentLabel.textColor = .secondaryLabelColor
                self.setResultsText("Measurement stopped\n\n\(error.localizedDescription)")
            }
        }
    }

    @objc private func revealRawData() {
        let directory = LatencyDiagnostics.directoryURL
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private func format(_ summary: LatencyDiagnostics.Summary) -> String {
        let rtt = format(summary.probeRoundTrip)
        let processing = format(summary.macProcessing)
        let queue = format(summary.serverQueueWait)
        let health = summary.healthChecks.sorted { $0.key < $1.key }
            .map { "\($0.key.replacingOccurrences(of: "_", with: " ")): \($0.value)" }
            .joined(separator: "\n")
        return "Probe round trip\n\(rtt)\n\nMac input processing\n\(processing)\n\nServer queue wait\n\(queue)\n\nMotion samples: \(summary.motionSamples)\nRaw events: \(summary.eventCount)\n\nHealth\n\(health)\n\nRaw data\n\(summary.rawDataURL.path)"
    }

    private func showAssessment(for summary: LatencyDiagnostics.Summary) {
        guard let average = summary.probeRoundTrip.average else {
            assessmentLabel.stringValue = "Overall assessment: Limited data — no complete round-trip samples"
            assessmentLabel.textColor = .secondaryLabelColor
            return
        }
        let maximum = summary.probeRoundTrip.maximum
        let variation = maximum - summary.probeRoundTrip.minimum
        let title: String
        let detail: String
        let color: NSColor
        switch (average, maximum, variation) {
        case (...15, ...40, ...25):
            title = "Excellent"
            detail = "very responsive and stable"
            color = .systemGreen
        case (...35, ...80, ...50):
            title = "Good"
            detail = "responsive with low variation"
            color = .systemGreen
        case (...70, ...150, ...100):
            title = "Fair"
            detail = "noticeable delay or variation may occur"
            color = .systemOrange
        default:
            title = "Poor"
            detail = "high delay or instability detected"
            color = .systemRed
        }
        assessmentLabel.stringValue = "Overall assessment: \(title) — \(detail)"
        assessmentLabel.textColor = color
    }

    private func format(_ stats: LatencyDiagnostics.RunningStats) -> String {
        guard let average = stats.average else { return "no samples" }
        return String(format: "Average: %.1f ms\nRange: %.1f–%.1f ms\nSamples: %d", average, stats.minimum, stats.maximum, stats.count)
    }

    private func metricSection(_ title: String, rows: [(String, NSTextField)]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 16
        for (name, value) in rows {
            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.textColor = .secondaryLabelColor
            nameLabel.alignment = .right
            grid.addRow(with: [nameLabel, value])
        }
        grid.column(at: 0).width = 118
        let section = NSStackView(views: [heading, grid])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5
        return section
    }

    private func resultsSection() -> NSStackView {
        let heading = NSTextField(labelWithString: "Latest results")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let section = NSStackView(views: [heading, assessmentLabel, resultsScrollView])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5
        return section
    }

    private func setResultsText(_ text: String) {
        resultsTextView.string = text
        resizeResultsDocument()
    }

    private func resizeResultsDocument() {
        let width = resultsScrollView.contentSize.width
        guard width > 0, let container = resultsTextView.textContainer, let layout = resultsTextView.layoutManager else { return }
        resultsTextView.frame.size.width = width
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let textHeight = layout.usedRect(for: container).height + resultsTextView.textContainerInset.height * 2
        resultsTextView.frame.size.height = max(resultsScrollView.contentSize.height, ceil(textHeight))
    }
}

@main
struct MacRemoteMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

private enum SecretStore {
    private static let service = "MacRemotePSK"
    static func loadOrCreate() -> Data {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        let data = Data(bytes)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        return data
    }
    static func rotate() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        let data = Data(bytes)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        SecItemDelete(query as CFDictionary)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
        return data
    }
    static func delete() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
    static func displayString(_ secret: Data) -> String { secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

private enum PairingCredentialStore {
    private static let service = "MacRemotePairedDeviceCredential"
    static func load() -> Data? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return data
    }
    static func save(_ credential: Data) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        SecItemDelete(query as CFDictionary)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecValueData: credential, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }
    static func delete() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}

private enum PairedDeviceNameStore {
    private static let service = "MacRemotePairedDeviceName"

    static func load() -> String? {
        var result: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecReturnData: true]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let name = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(80))
    }

    static func save(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty else { return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        SecItemDelete(query as CFDictionary)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                    kSecValueData: Data(trimmed.utf8),
                    kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service] as CFDictionary)
    }
}

private enum PairingEnrollment {
    static let rotationInterval: TimeInterval = 60
    private struct Payload: Codable {
        let version: Int
        let secret: String
        let token: String
        let directHost: String?
        let directHostV6: String?
        let directPort: UInt16?
    }
    static func make(secret: Data, token: Data, directIPv4: String?, directIPv6: String?, port: UInt16) -> String? {
        let payload = Payload(version: 1, secret: secret.base64EncodedString(), token: token.base64EncodedString(),
                              directHost: directIPv4, directHostV6: directIPv6, directPort: port)
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return "macremote://pair/v1/" + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func randomToken() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
}

private enum LocalNetworkAddress {
    static func preferredIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                String(cString: inet_ntoa($0.pointee.sin_addr))
            }
            guard !value.hasPrefix("127.") else { continue }
            if name == "en0" { return value }
            if fallback == nil { fallback = value }
        }
        return fallback
    }
    static func preferredIPv6() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let flags = interface.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var addressCopy = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addressCopy, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { continue }
            let value = String(cString: buffer)
            // A link-local address needs an interface scope on iOS, so only
            // advertise globally routable IPv6 addresses in a QR code.
            guard !value.lowercased().hasPrefix("fe80:"), value != "::1" else { continue }
            if name == "en0" { return value }
            if fallback == nil { fallback = value }
        }
        return fallback
    }
}

private enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 5, y: 5)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

private enum DiagnosticsError: LocalizedError {
    case noPhoneConnected, alreadyRunning, couldNotCreateFile, noResults, iPhoneUnavailable, remoteDisabled

    var errorDescription: String? {
        switch self {
        case .noPhoneConnected: "Connect the iPhone app before starting a measurement."
        case .alreadyRunning: "A diagnostics measurement is already running."
        case .couldNotCreateFile: "Mac Remote could not create the diagnostics data file."
        case .noResults: "The measurement ended before results could be collected."
        case .iPhoneUnavailable: "The iPhone app was closed, backgrounded, or disconnected before the measurement finished."
        case .remoteDisabled: "The remote was turned off on this Mac before the measurement finished."
        }
    }
}

// The pointer stream is normally delivered several times per frame.  A few
// isolated late datagrams are harmless, but repeated long gaps make an
// absolute-position cursor visibly jump.  Keep this deliberately local to a
// recent active stream so an idle phone is never reported as poor Wi-Fi.
private struct MotionDeliveryHealth {
    private var lastPacketAt: Double?
    private var badGaps: [Double] = []
    private(set) var unstable = false

    mutating func reset() {
        lastPacketAt = nil
        badGaps.removeAll(keepingCapacity: false)
        unstable = false
    }

    mutating func recordPacket(at now: Double) -> Bool? {
        defer { lastPacketAt = now }
        guard let previous = lastPacketAt else { return nil }
        let gap = now - previous
        // Gaps after a pause in user movement are not a network signal.
        guard gap < 0.5 else { badGaps.removeAll(keepingCapacity: true); return nil }
        badGaps.removeAll { now - $0 > 4 }
        if gap >= 0.070 { badGaps.append(now) }
        let next = badGaps.count >= 3
        guard next != unstable else { return nil }
        unstable = next
        return next
    }

    mutating func clearIfRecovered(at now: Double) -> Bool {
        badGaps.removeAll { now - $0 > 6 }
        guard unstable, badGaps.isEmpty else { return false }
        unstable = false
        return true
    }
}

private final class RemoteServer {
    // A stable port keeps a direct-IP pairing usable after the Mac app restarts.
    private static let controlPort = NWEndpoint.Port(rawValue: 54_321)!
    private let queue = DispatchQueue(label: "MacRemoteServer.network")
    private var secret: Data
    private let status: (String) -> Void
    private let pairingStateChanged: (Bool, String?) -> Void
    private var pairingToken: Data?
    private var pairingTokenExpiry = -Double.infinity
    private var pairedCredential: Data?
    private var pairedDeviceName: String?
    private let macName = Host.current().localizedName ?? "Mac"
    private var listener: NWListener?
    private var client: NWConnection?
    // A LAN peer must complete TLS and identify itself promptly. These limits
    // are deliberately much higher than normal use (one app plus a handful of
    // short-lived widget connections) and only constrain incomplete peers.
    private static let maximumUnauthenticatedConnections = 24
    private static let unauthenticatedConnectionTimeout: DispatchTimeInterval = .seconds(10)
    private static let maximumControlMessageBytes = 64 * 1024
    private var unauthenticatedConnections: [ObjectIdentifier: NWConnection] = [:]
    private var unauthenticatedTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var clientActive = true
    private var remoteEnabled = true
    private var motionListener: NWListener?
    private var motionPeers: [ObjectIdentifier: NWConnection] = [:]
    private var motionPeerSeen: [ObjectIdentifier: Double] = [:]
    private var motionSession = UUID().uuidString
    private var motionOrder = MotionPacketOrder()
    private var motionAckTime = 0.0
    private var motionDeliveryHealth = MotionDeliveryHealth()
    private var motionRecoveryTimer: DispatchWorkItem?
    private var pointerReset = PointerResetState()
    // The authenticated connection changes on app relaunch; the pointing anchor
    // does not. A matching saved reference can resume without a cursor warp.
    private var savedPointerReference: String?
    private var focusTimer: DispatchSourceTimer?
    private struct FocusSnapshot {
        let state: (active: Bool?, text: String, safari: Bool, appPID: pid_t?)
        let muted: Bool?
        let fullscreen: Bool?
        let contextStable: Bool
        let start: Double
        let inputEnd: Double
        let audioEnd: Double
        let finished: Double
    }
    private let statusPoller = StatusPoller<FocusSnapshot>()
    private var lastFocusState = ""
    private var lastAccessibilityGranted: Bool?
    private var confirmedInputActive = false
    private var confirmedInputText = ""
    private var confirmedFullscreen = false
    private var focusedAppPID: pid_t?
    private let diagnostics = LatencyDiagnostics()
    // The menu communicates only the state. Keep technical listener errors for
    // diagnostics, rather than exposing lengthy Network.framework messages.
    private var lastListenerError: String?
    private let diagnosticClock = DispatchQueue(label: "MacRemote.diagnostics.clock", qos: .userInitiated)
    private var diagnosticTimer: DispatchSourceTimer?
    private var diagnosticCompletion: ((Result<LatencyDiagnostics.Summary, Error>) -> Void)?
    private let diagnosticEventLock = NSLock()
    private var observingDiagnostics = false
    private var systemSleeping = false
    private var powerObservers: [NSObjectProtocol] = []
    private struct QueuedWidgetMediaCommand {
        let action: String
        let commandID: String?
        let connection: NWConnection
    }
    private var queuedWidgetMediaCommands: [QueuedWidgetMediaCommand] = []
    private var sendingWidgetMediaCommand = false
    init(secret: Data, status: @escaping (String) -> Void, pairingStateChanged: @escaping (Bool, String?) -> Void) {
        self.secret = secret; self.status = status; self.pairingStateChanged = pairingStateChanged
        self.pairedCredential = PairingCredentialStore.load()
        self.pairedDeviceName = PairedDeviceNameStore.load()
        pairingStateChanged(self.pairedCredential != nil, self.pairedDeviceName)
        Input.keyboardActivityObserved = { [weak self] in
            self?.queue.async { [weak self] in self?.diagnostics.record("hardware_keyboard_activity", ["detected": true]) }
        }
    }
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.setSystemSleeping(true) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.setSystemSleeping(false) }
            }
        ]
        startSecureListeners()
    }
    func stop() {
        Input.releaseMouse()
        Input.setClientActive(true)
        for observer in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        powerObservers.removeAll()
        listener?.cancel()
        queue.async {
            self.motionListener?.cancel(); self.closeMotionPeers()
            self.cancelUnauthenticatedConnections()
            self.focusTimer?.cancel(); self.focusTimer = nil
            self.statusPoller.invalidate()
            self.setDiagnosticObservation(false); _ = self.diagnostics.stop(); self.diagnosticTimer?.cancel()
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.remoteEnabled != enabled else { return }
            self.remoteEnabled = enabled
            if !enabled {
                Input.releaseMouse()
                self.finishDiagnostics(session: self.diagnostics.session, error: DiagnosticsError.remoteDisabled)
            }
            self.lastFocusState = ""
            if let client = self.client {
                self.sendControl(["type": "remote_state", "enabled": enabled], on: client)
            }
        }
    }
    func beginPairing(completion: @escaping (String?) -> Void) {
        queue.async {
            guard self.pairedCredential == nil, let token = PairingEnrollment.randomToken(),
                  let enrollment = PairingEnrollment.make(
                    secret: self.secret,
                    token: token,
                    directIPv4: LocalNetworkAddress.preferredIPv4(),
                    directIPv6: LocalNetworkAddress.preferredIPv6(),
                    port: Self.controlPort.rawValue
                  ) else {
                completion(nil)
                return
            }
            self.pairingToken = token
            self.pairingTokenExpiry = ProcessInfo.processInfo.systemUptime + PairingEnrollment.rotationInterval
            completion(enrollment)
        }
    }
    func cancelPairing() {
        queue.async { self.pairingToken = nil; self.pairingTokenExpiry = -Double.infinity }
    }
    func unpairDevice() {
        queue.async {
            self.pairingToken = nil
            self.pairingTokenExpiry = -Double.infinity
            self.pairedCredential = nil
            self.pairedDeviceName = nil
            PairingCredentialStore.delete()
            PairedDeviceNameStore.delete()
            self.pairingStateChanged(false, nil)
            Input.releaseMouse()
            if let client = self.client {
                self.sendControl(["type": "unpaired"], on: client)
                // Give the peer a short chance to consume the revocation before
                // closing the transport; its local keychain is then cleared too.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    client.cancel()
                    self.rotateTransportSecretAndRestartListeners()
                }
            } else {
                self.rotateTransportSecretAndRestartListeners()
            }
            self.client = nil
            self.closeMotionPeers()
            self.statusPoller.invalidate()
            self.pointerReset = PointerResetState()
            self.publishIdleStatus()
        }
    }
    func hasConnectedPhone(_ completion: @escaping (Bool) -> Void) {
        queue.async { completion(self.client != nil) }
    }

    private func startSecureListeners() {
        do {
            let tls = TLS.pskOptions(secret)
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = CommandLine.arguments.contains("--test-tcp-nodelay")
            tcp.disableAckStretching = CommandLine.arguments.contains("--test-tcp-no-ack-stretching")
            let parameters = NWParameters(tls: tls, tcp: tcp)
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            let listener = try NWListener(using: parameters, on: Self.controlPort)
            listener.service = .init(name: macName, type: "_macremote._tcp")
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.lastListenerError = nil
                    self?.publishIdleStatus()
                case .failed(let error):
                    self?.recordListenerError(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            self.listener = listener
            listener.start(queue: queue)
            startMotionListener()
        } catch {
            recordListenerError(error)
        }
    }

    private func recordListenerError(_ error: Error) {
        lastListenerError = error.localizedDescription
        status("Error")
    }

    private func rotateTransportSecretAndRestartListeners() {
        // A previous QR is a capability for the current TLS key. Rotating on
        // decouple makes every old QR and transport connection unusable.
        secret = SecretStore.rotate()
        listener?.cancel(); listener = nil
        motionListener?.cancel(); motionListener = nil
        closeMotionPeers()
        cancelUnauthenticatedConnections()
        startSecureListeners()
    }

    private func cancelUnauthenticatedConnections() {
        let connections = Array(unauthenticatedConnections.values)
        unauthenticatedTimeouts.values.forEach { $0.cancel() }
        unauthenticatedTimeouts.removeAll()
        unauthenticatedConnections.removeAll()
        connections.forEach { $0.cancel() }
    }

    private func markConnectionAuthenticated(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        unauthenticatedConnections.removeValue(forKey: key)
        unauthenticatedTimeouts.removeValue(forKey: key)?.cancel()
    }

    private func forgetConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        unauthenticatedConnections.removeValue(forKey: key)
        unauthenticatedTimeouts.removeValue(forKey: key)?.cancel()
    }

    // Only absolute cursor targets use DTLS datagrams. All state-changing
    // controls and reset acknowledgments retain their reliable TLS channel.
    private func startMotionListener() {
        do {
            let parameters = NWParameters(dtls: TLS.pskOptions(secret, datagram: true), udp: .init())
            // Request low-latency scheduling for constant-rate cursor traffic.
            // This is a scheduling hint, not a guarantee against radio pauses.
            parameters.serviceClass = .interactiveVideo
            let listener = try NWListener(using: parameters, on: .any)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.offerMotionTransport() }
            }
            listener.newConnectionHandler = { [weak self] peer in
                guard let self, self.client != nil, self.motionPeers.count < 8 else { peer.cancel(); return }
                let key = ObjectIdentifier(peer)
                self.motionPeers[key] = peer
                self.motionPeerSeen[key] = LatencyDiagnostics.now()
                self.expireMotionPeer(peer)
                peer.stateUpdateHandler = { [weak self, weak peer] state in
                    guard let self, let peer else { return }
                    switch state {
                    case .ready: self.receiveMotion(on: peer)
                    case .failed, .cancelled:
                        self.motionPeers.removeValue(forKey: key); self.motionPeerSeen.removeValue(forKey: key); peer.cancel()
                    default: break
                    }
                }
                peer.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
                    guard let self, let peer, self.motionPeers[key] != nil else { return }
                    if case .ready = peer.state { return }
                    peer.cancel(); self.motionPeers.removeValue(forKey: key)
                }
            }
            motionListener = listener; listener.start(queue: queue)
        } catch { NSLog("Mac Remote: UDP unavailable; retaining secure WebSocket: %@", error.localizedDescription) }
    }
    private func closeMotionPeers() {
        let peers = Array(motionPeers.values); motionPeers.removeAll()
        motionPeerSeen.removeAll()
        for peer in peers { peer.cancel() }
    }

    private func observeMotionDelivery(at received: Double, on connection: NWConnection) {
        if let unstable = motionDeliveryHealth.recordPacket(at: received) {
            sendControl(["type": "connection_quality", "unstable": unstable], on: connection)
        }
        motionRecoveryTimer?.cancel()
        let timer = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.client === connection,
                  self.motionDeliveryHealth.clearIfRecovered(at: LatencyDiagnostics.now()) else { return }
            self.sendControl(["type": "connection_quality", "unstable": false], on: connection)
        }
        motionRecoveryTimer = timer
        queue.asyncAfter(deadline: .now() + 6.1, execute: timer)
    }
    private func expireMotionPeer(_ peer: NWConnection) {
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
            guard let self, let peer, let seen = self.motionPeerSeen[ObjectIdentifier(peer)] else { return }
            if LatencyDiagnostics.now() - seen >= 5 {
                self.motionPeers.removeValue(forKey: ObjectIdentifier(peer))
                self.motionPeerSeen.removeValue(forKey: ObjectIdentifier(peer)); peer.cancel()
            } else { self.expireMotionPeer(peer) }
        }
    }
    private func sendControl(_ object: [String: Any], on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let context = NWConnection.ContentContext(identifier: "motion-control", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
    private func offerMotionTransport() {
        guard let client else { return }
        if let port = motionListener?.port {
            sendControl(["type": "motion_udp", "port": Int(port.rawValue), "session": motionSession], on: client)
        }
    }
    private func receiveMotion(on peer: NWConnection) {
        peer.receiveMessage { [weak self, weak peer] data, _, _, error in
            guard let self, let peer, self.motionPeers[ObjectIdentifier(peer)] != nil else { return }
            let received = LatencyDiagnostics.now()
            if let data, data.count <= 1200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["motion_session"] as? String == self.motionSession, let client = self.client {
                self.motionPeerSeen[ObjectIdentifier(peer)] = received
                let type = object["type"] as? String
                if type == "motion_hello" || type == "pointer_target" {
                    if type == "motion_hello" || received - self.motionAckTime >= 1 {
                        self.motionAckTime = received
                        self.sendControl(["type": "motion_udp_ready", "session": self.motionSession], on: client)
                    }
                    if type == "pointer_target" {
                        // A datagram must carry an order number; never accept a
                        // delayed position from before a newer packet/reset.
                        if object["motion_seq"] as? Int != nil {
                            self.observeMotionDelivery(at: received, on: client)
                            self.handle(data, on: client, received: received, transport: "dtls-udp")
                        }
                    }
                }
            }
            if error == nil { self.receiveMotion(on: peer) }
            else {
                self.motionPeers.removeValue(forKey: ObjectIdentifier(peer))
                self.motionPeerSeen.removeValue(forKey: ObjectIdentifier(peer)); peer.cancel()
            }
        }
    }
    private func setSystemSleeping(_ sleeping: Bool) {
        if sleeping { Input.releaseMouse() }
        statusPoller.invalidate()
        systemSleeping = sleeping; lastFocusState = ""
        guard let connection = client,
              let data = try? JSONSerialization.data(withJSONObject: ["type": "system_state", "sleeping": sleeping]) else { return }
        let context = NWConnection.ContentContext(identifier: "system-state", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
    private func sleepMac() {
        // Ignore input before requesting sleep, including gyro frames already in
        // flight. Otherwise the remote itself can immediately wake the computer.
        setSystemSleeping(true)
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else { setSystemSleeping(false); return }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        if result != kIOReturnSuccess {
            NSLog("Mac Remote: system sleep request failed (%d)", result)
            setSystemSleeping(false)
        }
    }
    private func setDiagnosticObservation(_ enabled: Bool) {
        diagnosticEventLock.lock(); observingDiagnostics = enabled; diagnosticEventLock.unlock()
    }
    struct DiagnosticsSnapshot {
        let connected: Bool
        let active: Bool
        let motionPeerCount: Int
        let accessibilityGranted: Bool
        let listenAccessGranted: Bool
        let secureInputEnabled: Bool
        let listenerError: String?
        let lastSummary: LatencyDiagnostics.Summary?
    }

    private var lastDiagnosticsSummary: LatencyDiagnostics.Summary?

    func diagnosticsSnapshot(_ completion: @escaping (DiagnosticsSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = DiagnosticsSnapshot(
                connected: self.client != nil,
                active: self.diagnostics.active,
                motionPeerCount: self.motionPeers.count,
                accessibilityGranted: AXIsProcessTrusted(),
                listenAccessGranted: CGPreflightListenEventAccess(),
                secureInputEnabled: IsSecureEventInputEnabled(),
                listenerError: self.lastListenerError,
                lastSummary: self.lastDiagnosticsSummary
            )
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    func startDiagnosticsMeasurement(completion: @escaping (Result<LatencyDiagnostics.Summary, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.client != nil else {
                DispatchQueue.main.async { completion(.failure(DiagnosticsError.noPhoneConnected)) }
                return
            }
            guard !self.diagnostics.active else {
                DispatchQueue.main.async { completion(.failure(DiagnosticsError.alreadyRunning)) }
                return
            }
            let duration = 10.0
            guard self.diagnostics.start(duration: duration) != nil else {
                DispatchQueue.main.async { completion(.failure(DiagnosticsError.couldNotCreateFile)) }
                return
            }
            self.diagnosticCompletion = completion
            self.lastFocusState = "" // Prompt the phone to begin probe exchanges.
            self.diagnostics.recordHealth([
                "iphone_connection": "connected",
                "accessibility": AXIsProcessTrusted() ? "granted" : "missing",
                "listen_event_access": CGPreflightListenEventAccess() ? "granted" : "missing",
                "secure_input": IsSecureEventInputEnabled() ? "enabled" : "disabled",
                "motion_peers": "\(self.motionPeers.count)",
                "udp_motion": self.motionListener == nil ? "unavailable" : "available",
                "tcp_nodelay": CommandLine.arguments.contains("--test-tcp-nodelay") ? "enabled" : "default",
                "tcp_ack_stretching": CommandLine.arguments.contains("--test-tcp-no-ack-stretching") ? "disabled" : "default"
            ])
            self.setDiagnosticObservation(true)
            let session = self.diagnostics.session
            let timer = DispatchSource.makeTimerSource(queue: self.diagnosticClock)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20))
            timer.setEventHandler { [weak self] in
                let enqueued = LatencyDiagnostics.now()
                self?.queue.async { [weak self] in
                    guard let self, self.diagnostics.active, self.diagnostics.session == session else { return }
                    self.diagnostics.record("server_queue", ["enqueued_s": enqueued,
                        "wait_ms": (LatencyDiagnostics.now() - enqueued) * 1_000])
                }
            }
            self.diagnosticTimer?.cancel(); self.diagnosticTimer = timer; timer.resume()
            self.queue.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.finishDiagnostics(session: session)
            }
        }
    }

    private func finishDiagnostics(session: String, error: Error? = nil) {
        guard diagnostics.active, diagnostics.session == session else { return }
        setDiagnosticObservation(false)
        diagnosticTimer?.cancel(); diagnosticTimer = nil
        lastFocusState = "" // Tell the iPhone to stop sending probes and restore its UI.
        let summary = diagnostics.stop()
        if let summary { lastDiagnosticsSummary = summary }
        let result: Result<LatencyDiagnostics.Summary, Error>
        if let error { result = .failure(error) }
        else if let summary { result = .success(summary) }
        else { result = .failure(DiagnosticsError.noResults) }
        let completion = diagnosticCompletion
        diagnosticCompletion = nil
        DispatchQueue.main.async { completion?(result) }
    }
    func observePointerEvent(timestamp: UInt64, observed: Double) {
        diagnosticEventLock.lock()
        let enabled = observingDiagnostics
        diagnosticEventLock.unlock()
        guard enabled else { return }
        queue.async {
            self.diagnostics.record("pointer_observed", ["event_timestamp_ns": timestamp, "observed_s": observed])
        }
    }
    func observeKeyboardDetection(_ event: NSEvent) {
        // Diagnostic classifications only: no characters, key codes or text.
        let cgEvent = event.cgEvent
        let row: [String: Any] = ["appkit_type": event.type.rawValue,
            "has_cg_event": cgEvent != nil,
            "cg_type": cgEvent?.type.rawValue ?? 0,
            "own_source_pid": cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier),
            "remote_tag": cgEvent?.getIntegerValueField(.eventSourceUserData) == Input.pointerEventTag]
        queue.async { self.diagnostics.record("keyboard_detection", row) }
    }
    private func accept(_ connection: NWConnection) {
        NSLog("Mac Remote pairing: incoming control connection")
        let key = ObjectIdentifier(connection)
        guard unauthenticatedConnections.count < Self.maximumUnauthenticatedConnections else {
            connection.cancel()
            return
        }
        // Retain each accepted connection until it authenticates or fails.
        // The callbacks below deliberately use weak captures to avoid cycles.
        unauthenticatedConnections[key] = connection
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.unauthenticatedConnections[key] != nil else { return }
            self.forgetConnection(connection)
            connection.cancel()
        }
        unauthenticatedTimeouts[key] = timeout
        queue.asyncAfter(deadline: .now() + Self.unauthenticatedConnectionTimeout, execute: timeout)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                NSLog("Mac Remote pairing: secure control connection ready")
                if let connection { self?.receive(on: connection) }
            case .failed(let error):
                NSLog("Mac Remote pairing: control connection failed: %@", error.localizedDescription)
                if let connection { self?.forgetConnection(connection) }
                if self?.client === connection {
                    if let self { self.finishDiagnostics(session: self.diagnostics.session, error: DiagnosticsError.iPhoneUnavailable) }
                    Input.releaseMouse(); self?.client = nil
                    self?.closeMotionPeers()
                    self?.statusPoller.invalidate()
                    self?.pointerReset = PointerResetState(); self?.publishIdleStatus()
                }
            case .cancelled:
                NSLog("Mac Remote pairing: control connection cancelled")
                if let connection { self?.forgetConnection(connection) }
                if self?.client === connection {
                    if let self { self.finishDiagnostics(session: self.diagnostics.session, error: DiagnosticsError.iPhoneUnavailable) }
                    Input.releaseMouse(); self?.client = nil
                    self?.closeMotionPeers()
                    self?.statusPoller.invalidate()
                    self?.pointerReset = PointerResetState(); self?.publishIdleStatus()
                }
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func beginFocusPolling() {
        focusTimer?.cancel()
        statusPoller.invalidate()
        lastFocusState = ""
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            Input.expireMouseHold()
            guard let self, let connection = self.client, !self.systemSleeping else { return }
            let accessibilityGranted = AXIsProcessTrusted()
            if self.lastAccessibilityGranted != accessibilityGranted {
                self.lastAccessibilityGranted = accessibilityGranted
                self.sendControl(["type": "accessibility_state", "granted": accessibilityGranted], on: connection)
                self.status(accessibilityGranted ? "Connected" : "Connected — Accessibility required")
            }
            self.statusPoller.request(deliverOn: self.queue, read: {
                let start = LatencyDiagnostics.now()
                let state = Input.focusedInput()
                let inputEnd = LatencyDiagnostics.now()
                let muted = AudioOutput.isMuted()
                let audioEnd = LatencyDiagnostics.now()
                let fullscreen = Input.fullscreenState()
                // Do not publish mixed state if the frontmost app changed while
                // a slow AX/audio query was outstanding.
                let stable = state.appPID == NSWorkspace.shared.frontmostApplication?.processIdentifier
                let finished = LatencyDiagnostics.now()
                return FocusSnapshot(state: state, muted: muted, fullscreen: fullscreen,
                    contextStable: stable, start: start, inputEnd: inputEnd, audioEnd: audioEnd, finished: finished)
            }, deliver: { [weak self, weak connection] snapshot in
                guard let self, let connection, self.client === connection else { return }
                self.applyFocusSnapshot(snapshot, on: connection)
            })
        }
        focusTimer = timer
        timer.resume()
    }
    // Cached/confirmed state and connection writes remain on the network queue;
    // no Accessibility, Core Audio or window-state reads occur here.
    private func applyFocusSnapshot(_ snapshot: FocusSnapshot, on connection: NWConnection) {
        diagnostics.record("focus_poll", ["start_s": snapshot.start,
            "input_ms": (snapshot.inputEnd - snapshot.start) * 1000,
            "audio_ms": (snapshot.audioEnd - snapshot.inputEnd) * 1000,
            "fullscreen_ms": (snapshot.finished - snapshot.audioEnd) * 1000,
            "total_ms": (snapshot.finished - snapshot.start) * 1000,
            "delivery_wait_ms": (LatencyDiagnostics.now() - snapshot.finished) * 1000,
            "off_network_queue": true])
        guard snapshot.contextStable else { return }
        let state = snapshot.state
        if state.appPID != focusedAppPID {
            focusedAppPID = state.appPID
            confirmedInputActive = false
            confirmedInputText = ""
            confirmedFullscreen = false
        }
        // A failed AX read is unknown, not evidence that the user left the input.
        // Preserve confirmed focus only within the same frontmost application.
        if let active = state.active {
            confirmedInputActive = active
            confirmedInputText = state.text
        }
        let muted = snapshot.muted
        if let fullscreen = snapshot.fullscreen { confirmedFullscreen = fullscreen }
        let focusKey = confirmedInputActive ? "1:\(confirmedInputText):\(state.safari)" : "0:\(state.safari)"
        let key = "\(focusKey):\(String(describing: muted)):\(confirmedFullscreen):\(diagnostics.active):\(diagnostics.session):\(systemSleeping):\(remoteEnabled)"
        guard key != lastFocusState else { return }
        lastFocusState = key
        var object: [String: Any] = ["type": "input_focus", "active": confirmedInputActive, "text": confirmedInputText, "safari": state.safari]
        if let muted { object["muted"] = muted }
        object["fullscreen"] = confirmedFullscreen
        object["sleeping"] = systemSleeping
        object["remote_enabled"] = remoteEnabled
        object["diagnostics"] = diagnostics.active
        object["diagnostic_session"] = diagnostics.session
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let context = NWConnection.ContentContext(identifier: "focus", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            let received = LatencyDiagnostics.now()
            if let data {
                guard data.count <= Self.maximumControlMessageBytes else {
                    self?.forgetConnection(connection)
                    connection.cancel()
                    return
                }
                self?.handle(data, on: connection, received: received)
            }
            if error == nil { self?.receive(on: connection) } else { connection.cancel() }
        }
    }
    private func handle(_ data: Data, on connection: NWConnection, received: Double, transport: String = "websocket") {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return }
        if type == "pair_claim" {
            NSLog("Mac Remote pairing: received pairing claim")
            guard pairedCredential == nil else {
                NSLog("Mac Remote pairing: rejected claim because a phone is already paired")
                rejectPairing(on: connection, reason: "already_paired")
                return
            }
            guard ProcessInfo.processInfo.systemUptime <= pairingTokenExpiry else {
                NSLog("Mac Remote pairing: rejected expired claim")
                rejectPairing(on: connection, reason: "expired")
                return
            }
            guard let token = decodeCredential(object["token"]), token == pairingToken,
                  let credential = decodeCredential(object["credential"]) else {
                NSLog("Mac Remote pairing: rejected invalid claim")
                rejectPairing(on: connection, reason: "invalid")
                return
            }
            guard compatible(with: object, on: connection) else { return }
            // Consume before responding: a copied QR cannot win a second race.
            pairingToken = nil
            pairingTokenExpiry = -Double.infinity
            pairedCredential = credential
            PairingCredentialStore.save(credential)
            let deviceName = (object["device_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            pairedDeviceName = deviceName.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "iPhone"
            if let pairedDeviceName { PairedDeviceNameStore.save(pairedDeviceName) }
            pairingStateChanged(true, pairedDeviceName)
            activatePrimaryClient(connection)
            markConnectionAuthenticated(connection)
            NSLog("Mac Remote pairing: accepted claim")
            sendControl(connectionWelcome(type: "pair_accepted"), on: connection)
            return
        }
        if type == "authenticate" {
            guard let credential = decodeCredential(object["credential"]), credential == pairedCredential else { return }
            guard compatible(with: object, on: connection) else { return }
            if let deviceName = (object["device_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !deviceName.isEmpty {
                let name = String(deviceName.prefix(80))
                pairedDeviceName = name
                PairedDeviceNameStore.save(name)
                pairingStateChanged(true, name)
            }
            activatePrimaryClient(connection)
            markConnectionAuthenticated(connection)
            sendControl(connectionWelcome(type: "authenticated"), on: connection)
            return
        }
        guard client === connection else {
            // Widgets are intentionally restricted to discrete, safe commands.
            // They cannot move the cursor, type, or change the primary session.
            guard remoteEnabled, decodeCredential(object["credential"]) == pairedCredential else { return }
            markConnectionAuthenticated(connection)
            switch type {
            case "media": if let action = object["action"] as? String {
                enqueueWidgetMedia(action, commandID: object["widget_command_id"] as? String, on: connection)
            }
            case "sleep":
                sleepMac()
                sendWidgetAcknowledgement(commandID: object["widget_command_id"] as? String, on: connection)
            case "fullscreen":
                Input.fullscreen()
                sendWidgetAcknowledgement(commandID: object["widget_command_id"] as? String, on: connection)
            default: break
            }
            return
        }
        // Revocation must remain available even when remote input is disabled
        // or the Mac is preparing to sleep.
        if type == "unpair" {
            unpairDevice()
            return
        }
        if type == "client_active" {
            guard let active = object["active"] as? Bool else { return }
            clientActive = active
            if !active { finishDiagnostics(session: diagnostics.session, error: DiagnosticsError.iPhoneUnavailable) }
            let success = Input.setClientActive(active)
            diagnostics.record("cursor_visibility", ["client_active": active, "api_success": success])
            sendControl(["type": "cursor_visibility_ack", "active": active, "success": success], on: connection)
            return
        }
        // Ignore any gyro datagrams/control actions already in flight when the
        // iPhone went inactive, so they cannot reveal/move the hidden cursor.
        if !clientActive, !["ping", "motion_udp_request", "diagnostic_probe", "diagnostic_probe_result", "diagnostic_client_report"].contains(type) { return }
        // A system wake notification is the only event that re-enables input.
        if systemSleeping, !["ping", "diagnostic_probe", "diagnostic_probe_result", "diagnostic_client_report"].contains(type) { return }
        // The Mac-side toggle is authoritative: a connected iPhone cannot inject
        // input while the remote is turned off.
        guard remoteEnabled || type == "ping" else { return }
        switch type {
        case "motion_udp_request": offerMotionTransport()
        case "sleep": sleepMac()
        case "mouse_button":
            guard object["button"] as? String == "left", let down = object["down"] as? Bool,
                  let id = object["id"] as? String else { return }
            Input.mouseButton(id: id, down: down)
        case "diagnostic_probe":
            guard diagnostics.active, let id = object["id"] as? String, id.count < 80,
                  let sent = object["client_send_s"] as? Double else { return }
            let reply: [String: Any] = ["type": "diagnostic_probe_reply", "id": id,
                "session": diagnostics.session, "client_send_s": sent, "mac_receive_s": received,
                "mac_reply_s": LatencyDiagnostics.now()]
            guard let bytes = try? JSONSerialization.data(withJSONObject: reply) else { return }
            let context = NWConnection.ContentContext(identifier: "diagnostic", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        case "diagnostic_probe_result":
            var row: [String: Any] = [:]
            for key in ["client_send_s", "mac_receive_s", "mac_reply_s", "client_receive_s"] {
                if let value = object[key] as? Double, value.isFinite { row[key] = value }
            }
            diagnostics.record("clock_probe", row)
        case "diagnostic_client_report":
            if let rows = object["rows"] as? [[String: Double]], rows.count <= 256 {
                for row in rows { diagnostics.record("client_send_complete", row) }
            }
        case "ping":
            guard let id = object["id"] as? String, id.count <= 64,
                  let reply = try? JSONSerialization.data(withJSONObject: ["type": "pong", "id": id]) else { return }
            let context = NWConnection.ContentContext(identifier: "pong", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: reply, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        case "open_safari":
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            }
        case "open_spotify":
            DispatchQueue.main.async {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            }
        case "reset", "pointer_resume":
            if object["generation"] != nil {
                guard let id = object["generation"] as? String, UUID(uuidString: id) != nil else { return }
                let success: Bool
                if type == "pointer_resume" {
                    guard let x = object["x"] as? Double, let y = object["y"] as? Double,
                          x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return }
                    success = pointerReset.resume(id: id) {
                        Input.resume(x: x, y: y, sameReference: savedPointerReference == id)
                    }
                } else {
                    // Retrying an acknowledged reset must not center twice.
                    success = pointerReset.reset(id: id, center: { Input.center() })
                }
                if success { savedPointerReference = id }
                diagnostics.record(type == "reset" ? "pointer_reset" : "pointer_resume", ["generation": id, "success": success])
                guard let bytes = try? JSONSerialization.data(withJSONObject:
                    ["type": "reset_ack", "generation": id, "success": success]) else { return }
                let context = NWConnection.ContentContext(identifier: "reset", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                connection.send(content: bytes, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
            } else {
                guard type == "reset" else { return }
                savedPointerReference = nil
                pointerReset = PointerResetState()
                Input.center()
            }
        case "fullscreen": Input.fullscreen()
        case "shortcut":
            guard let key = object["key"] as? String else { return }
            Input.shortcut(key, command: object["command"] as? Bool ?? true)
        case "input_insert": if let text = object["text"] as? String { Input.insertText(text) }
        case "input_backspace": Input.key(51)
        case "input_delete": Input.key(117)
        case "input_return": Input.key(36)
        case "cursor_smoothing":
            guard let level = object["level"] as? String,
                  ["off", "normal", "high"].contains(level) else { return }
            Input.setCursorSmoothing(level)
        case "mouse_move", "pointer_target":
            let absolute = type == "pointer_target"
            let dx: Double, dy: Double
            if absolute {
                guard let id = object["generation"] as? String, pointerReset.accepts(id),
                      let x = object["x"] as? Double, let y = object["y"] as? Double,
                      x.isFinite, y.isFinite, abs(x) <= 1_000_000, abs(y) <= 1_000_000 else { return }
                dx = x; dy = y
                if let sequence = object["motion_seq"] as? Int {
                    guard motionOrder.accept(sequence) else { return }
                }
                if transport != "dtls-udp" { observeMotionDelivery(at: received, on: connection) }
            } else {
                guard pointerReset.generation == nil, let x = number(object["dx"]), let y = number(object["dy"]) else { return }
                dx = x; dy = y
            }
            let parsed = LatencyDiagnostics.now()
            let injectionStart = LatencyDiagnostics.now()
            let eventTimestamp = absolute
                ? Input.place(x: dx, y: dy, diagnosticTimestamp: diagnostics.active)
                : Input.move(dx: dx, dy: dy, diagnosticTimestamp: diagnostics.active)
            let finished = LatencyDiagnostics.now()
            if diagnostics.active {
                var row: [String: Any] = ["connection": String(ObjectIdentifier(connection).hashValue),
                    "receive_s": received, "parsed_s": parsed, "injection_start_s": injectionStart,
                    "injection_end_s": finished, "bytes": data.count, "moving": dx != 0 || dy != 0,
                    "transport": transport]
                row["cursor_target_accepted"] = eventTimestamp != nil
                if let eventTimestamp { row["event_timestamp_ns"] = eventTimestamp }
                for (key, value) in object where key.hasPrefix("diag_") {
                    if let value = value as? Double, value.isFinite { row[key] = value }
                }
                diagnostics.record("motion", row)
            }
        case "click": guard let button = object["button"] as? String, button == "left" || button == "right" else { return }; Input.click(button == "left" ? .left : .right)
        case "scroll": guard let dy = number(object["dy"]) else { return }; Input.scroll(dy: dy)
        case "media": guard let action = object["action"] as? String else { return }; Input.media(action)
        default: return
        }
    }

    private func rejectPairing(on connection: NWConnection, reason: String) {
        sendControl(["type": "pair_rejected", "reason": reason], on: connection)
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) {
            connection.cancel()
        }
    }

    private func decodeCredential(_ value: Any?) -> Data? {
        guard let text = value as? String, let data = Data(base64Encoded: text), data.count == 32 else { return nil }
        return data
    }

    // Widget intents are separate processes, so quick taps can arrive over
    // multiple connections at once. Serialize the actual media key events: macOS
    // otherwise coalesces very closely spaced system-defined key presses.
    private func enqueueWidgetMedia(_ action: String, commandID: String?, on connection: NWConnection) {
        queuedWidgetMediaCommands.append(.init(action: action, commandID: commandID, connection: connection))
        sendNextWidgetMediaCommand()
    }

    private func sendNextWidgetMediaCommand() {
        guard !sendingWidgetMediaCommand, !queuedWidgetMediaCommands.isEmpty else { return }
        sendingWidgetMediaCommand = true
        let command = queuedWidgetMediaCommands.removeFirst()
        Input.media(command.action)
        sendWidgetAcknowledgement(commandID: command.commandID, on: command.connection)
        queue.asyncAfter(deadline: .now() + .milliseconds(90)) { [weak self] in
            guard let self else { return }
            self.sendingWidgetMediaCommand = false
            self.sendNextWidgetMediaCommand()
        }
    }

    private func sendWidgetAcknowledgement(commandID: String?, on connection: NWConnection) {
        guard let commandID,
              let data = try? JSONSerialization.data(withJSONObject: ["type": "widget_ack", "widget_command_id": commandID]) else { return }
        let context = NWConnection.ContentContext(identifier: "widget-ack", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func activatePrimaryClient(_ connection: NWConnection) {
        Input.releaseMouse()
        closeMotionPeers()
        motionSession = UUID().uuidString
        motionOrder = MotionPacketOrder()
        motionRecoveryTimer?.cancel(); motionRecoveryTimer = nil
        motionDeliveryHealth.reset()
        diagnostics.record("connection_ready", ["connection": String(ObjectIdentifier(connection).hashValue)])
        let previous = client
        client = connection
        clientActive = true
        lastAccessibilityGranted = AXIsProcessTrusted()
        pointerReset = PointerResetState()
        previous?.cancel()
        beginFocusPolling()
        status(lastAccessibilityGranted == true ? "Connected" : "Connected — Accessibility required")
        offerMotionTransport()
    }
    private func compatible(with object: [String: Any], on connection: NWConnection) -> Bool {
        guard let phoneProtocol = object["protocol_version"] as? Int,
              let phoneMinimum = object["accepted_protocol_minimum"] as? Int,
              let phoneMaximum = object["accepted_protocol_maximum"] as? Int,
              phoneMinimum <= phoneMaximum,
              RemoteProtocol.accepts(phoneProtocol),
              (phoneMinimum...phoneMaximum).contains(RemoteProtocol.version) else {
            let phoneVersion = object["app_version"] as? String ?? "0"
            let macIsNewer = RemoteAppVersion.isNewer(RemoteAppVersion.short, than: phoneVersion)
            let reason = macIsNewer ? "iphone_update_required" : "mac_update_required"
            sendControl([
                "type": "incompatible",
                "reason": reason,
                "mac_name": macName,
                "mac_app_version": RemoteAppVersion.display
            ], on: connection)
            return false
        }
        return true
    }
    private func connectionWelcome(type: String) -> [String: Any] {
        [
            "type": type,
            "mac_name": macName,
            "accessibility_granted": AXIsProcessTrusted()
        ]
    }
    private func publishIdleStatus() {
        status(pairedCredential == nil ? "Not Paired" : "Waiting for iPhone")
    }
    private func number(_ value: Any?) -> Double? { guard let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }; return min(500, max(-500, n.doubleValue)) }
}

private enum TLS {
    static func pskOptions(_ secret: Data, datagram: Bool = false) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        if datagram {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .DTLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .DTLSv12)
        }
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A9)!) // TLS_PSK_WITH_AES_256_GCM_SHA384
        let psk: dispatch_data_t = secret.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        let identityBytes = Data("macremote".utf8)
        let identity: dispatch_data_t = identityBytes.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, psk, identity)
        return options
    }
}

private enum AudioOutput {
    static func isMuted() -> Bool? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return muted != 0
    }
}

private enum Input {
    static let pointerEventTag: Int64 = 0x4D_52_50_4F_49_4E_54
    private static let pointerLock = NSLock()
    private static var virtualCursor = VirtualCursor()
    private static var pointerAnchor = PhonePointerAnchor()
    private static var remoteMouseHold = RemoteMouseHoldState()
    private static var cursorSmoother = CursorSmoother()
    private static var cursorSmoothingMode: CursorSmoother.Mode = .normal
    private static let renderQueue = DispatchQueue(label: "MacRemote.cursor.render", qos: .userInteractive)
    private static var renderTimer: DispatchSourceTimer?
    private static var pendingMotionTimestamp: UInt64?
    private static var hardwareKeyboard = HardwareKeyboardActivity()
    private static var cursorVisibility = CursorVisibilityState()
    static var keyboardActivityObserved: (() -> Void)?
    private static let keyboardSource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    // Called under pointerLock before applying/rendering remote mouse input.
    // No keyboard identity, character, password or text is read here.
    private static func refreshHardwareKeyboard(at point: CGPoint? = nil) {
        let down = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        let up = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyUp)
        guard hardwareKeyboard.sample(down: down, up: up),
              let current = point ?? CGEvent(source: nil)?.location else { return }
        cancelSmoothing()
        setCursorHidden(false)
        virtualCursor.rebase(to: current)
        pointerAnchor.hardwareKeyboard(at: current, now: ProcessInfo.processInfo.systemUptime,
            clearObservedKeys: IsSecureEventInputEnabled())
        if !pointerAnchor.physicalLeftDown { postMouseButtons(remoteMouseHold.release(), at: current) }
        keyboardActivityObserved?()
    }

    // Called with pointerLock held; cancellation never waits for the timer.
    private static func cancelSmoothing() {
        cursorSmoother.cancel()
        renderTimer?.cancel(); renderTimer = nil
        pendingMotionTimestamp = nil
    }
    private static func startRendering() {
        guard renderTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { renderSmoothedPointer() }
        renderTimer = timer; timer.resume()
    }
    private static func renderSmoothedPointer() {
        pointerLock.lock(); defer { pointerLock.unlock() }
        refreshHardwareKeyboard()
        let now = ProcessInfo.processInfo.systemUptime
        guard AXIsProcessTrusted(), pointerAnchor.allowsRemote(now: now),
              let point = cursorSmoother.step(now: now) else { cancelSmoothing(); return }
        let target = VirtualCursor.project(point, displays: displayBounds())
        let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: remoteMouseHold.isDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: target, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        // Correlate the first rendered step for the latest traced target; older
        // targets can be superseded before a render tick, never replayed later.
        if let timestamp = pendingMotionTimestamp { event?.timestamp = timestamp }
        pendingMotionTimestamp = nil
        event?.post(tap: .cghidEventTap)
    }

    static func rebasePointer(to point: CGPoint, button: Int64? = nil, pressed: Bool? = nil) {
        pointerLock.lock(); defer { pointerLock.unlock() }
        setCursorHidden(false)
        cancelSmoothing()
        virtualCursor.rebase(to: point)
        pointerAnchor.physical(to: point, now: ProcessInfo.processInfo.systemUptime, button: button, pressed: pressed)
        let releases = remoteMouseHold.release()
        // A real left-down already owns the OS button: do not release that press.
        if !pointerAnchor.physicalLeftDown { postMouseButtons(releases, at: point) }
    }
    static func setCursorSmoothing(_ value: String) {
        pointerLock.lock(); defer { pointerLock.unlock() }
        cursorSmoothingMode = CursorSmoother.Mode(rawValue: value) ?? .normal
        cancelSmoothing()
    }
    static func physicalKeyboard(_ event: CGEvent) {
        // Record only held key codes/modifiers, never characters or typed text.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier),
              let current = CGEvent(source: nil)?.location else { return }
        pointerLock.lock(); defer { pointerLock.unlock() }
        setCursorHidden(false)
        cancelSmoothing()
        virtualCursor.rebase(to: current)
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        pointerAnchor.keyboard(at: current, now: ProcessInfo.processInfo.systemUptime,
            key: event.type == .flagsChanged ? nil : UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
            pressed: event.type == .keyDown,
            modifiersHeld: event.type == .flagsChanged ? !event.flags.intersection(modifiers).isEmpty : nil)
        if !pointerAnchor.physicalLeftDown { postMouseButtons(remoteMouseHold.release(), at: current) }
    }
    private static func postKeyboardEvent(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        event?.post(tap: .cghidEventTap)
    }
    // Called with pointerLock held. Public API only; never activate this menu
    // app or disturb the foreground movie just to change cursor visibility.
    @discardableResult
    private static func setCursorHidden(_ hidden: Bool) -> Bool {
        cursorVisibility.setHidden(hidden) { hidden in
            let result = hidden ? CGDisplayHideCursor(CGMainDisplayID()) : CGDisplayShowCursor(CGMainDisplayID())
            if result != .success { NSLog("Mac Remote: cursor visibility API failed (%d)", result.rawValue) }
            return result == .success
        }
    }
    @discardableResult
    static func setClientActive(_ active: Bool) -> Bool {
        pointerLock.lock(); defer { pointerLock.unlock() }
        if !active {
            cancelSmoothing()
            if !pointerAnchor.physicalLeftDown { postMouseButtons(remoteMouseHold.release()) }
        }
        return setCursorHidden(!active)
    }
    // These helpers are called with pointerLock held. Tag every synthetic event
    // so the physical-input monitor never mistakes our own drag for a takeover.
    private static func postMouseButtons(_ transitions: [Bool], at point: CGPoint? = nil) {
        let location = point ?? CGEvent(source: nil)?.location ?? .zero
        for down in transitions {
            let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
            event?.post(tap: .cghidEventTap)
        }
    }
    static func mouseButton(id: String, down: Bool) {
        pointerLock.lock(); defer { pointerLock.unlock() }
        refreshHardwareKeyboard()
        if down {
            guard AXIsProcessTrusted(), pointerAnchor.allowsRemote(now: ProcessInfo.processInfo.systemUptime) else { return }
        }
        postMouseButtons(remoteMouseHold.update(id: id, down: down, now: ProcessInfo.processInfo.systemUptime))
    }
    static func releaseMouse() {
        pointerLock.lock(); defer { pointerLock.unlock() }
        cancelSmoothing()
        let transitions = remoteMouseHold.release()
        if !pointerAnchor.physicalLeftDown { postMouseButtons(transitions) }
    }
    static func expireMouseHold() {
        pointerLock.lock(); defer { pointerLock.unlock() }
        // Also restore the cursor on physical typing while the iPhone is idle.
        refreshHardwareKeyboard()
        postMouseButtons(remoteMouseHold.expire(now: ProcessInfo.processInfo.systemUptime))
    }
    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }.filter { !$0.isEmpty }
    }
    static func fullscreenState() -> Bool? {
        let system = AXUIElementCreateSystemWide()
        var appValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appValue) == .success,
              let app = appValue as! AXUIElement? else { return nil }
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue)
        if windowResult == .noValue { return false }
        guard windowResult == .success, let window = windowValue as! AXUIElement? else { return nil }
        var fullscreenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenValue)
        if result == .attributeUnsupported { return false }
        guard result == .success else { return nil }
        return fullscreenValue as? Bool
    }

    static func shortcut(_ key: String, command: Bool = true) {
        guard AXIsProcessTrusted(), let source = keyboardSource,
              let code: CGKeyCode = ["w": 13, "t": 17, "l": 37, "f": 3, "space": 49, "ä": 39, "ö": 41][key] else { return }
        if command {
            // Use explicit Command key events so the modifier cannot remain latched
            // when the next normal text event is delivered.
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
            commandDown?.flags = .maskCommand
            postKeyboardEvent(commandDown)
        }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = command ? .maskCommand : []
        up?.flags = command ? .maskCommand : []
        postKeyboardEvent(down)
        postKeyboardEvent(up)
        if command {
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)
            commandUp?.flags = []
            postKeyboardEvent(commandUp)
        }
    }
    static func focusedInput() -> (active: Bool?, text: String, safari: Bool, appPID: pid_t?) {
        let system = AXUIElementCreateSystemWide()
        let app = NSWorkspace.shared.frontmostApplication
        let safari = app?.bundleIdentifier == "com.apple.Safari"
        let appPID = app?.processIdentifier
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success, let element = value as! AXUIElement? else { return (nil, "", safari, appPID) }
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success, let role = roleValue as? String else { return (nil, "", safari, appPID) }
        let roles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        guard roles.contains(role) else { return (false, "", safari, appPID) }
        var textValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &textValue)
        return (true, textValue as? String ?? "", safari, appPID)
    }
    static func insertText(_ text: String) {
        guard AXIsProcessTrusted(), !text.isEmpty, let source = keyboardSource else { return }
        var units = Array(text.utf16)
        units.withUnsafeMutableBufferPointer { buffer in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) else { return }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            postKeyboardEvent(event)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.flags = []
            postKeyboardEvent(up)
        }
    }
    static func key(_ code: CGKeyCode) {
        guard AXIsProcessTrusted(), let source = keyboardSource else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = []
        up?.flags = []
        postKeyboardEvent(down)
        postKeyboardEvent(up)
    }
    static func fullscreen() {
        key(3)
    }
    @discardableResult static func center() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        pointerLock.lock(); defer { pointerLock.unlock() }
        cancelSmoothing()
        postMouseButtons(remoteMouseHold.release())
        let frame = CGDisplayBounds(CGMainDisplayID())
        let p = CGPoint(x: frame.midX, y: frame.midY)
        // Update the actual cursor position before the next relative gyro event.
        // Posting a mouse event alone can leave its source's old position cached.
        guard CGWarpMouseCursorPosition(p) == .success else { return false }
        pointerAnchor.reset(to: p)
        virtualCursor.rebase(to: p)
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        event?.post(tap: .cghidEventTap)
        return true
    }
    @discardableResult static func place(x: Double, y: Double, diagnosticTimestamp: Bool = false) -> UInt64? {
        guard AXIsProcessTrusted(), x.isFinite, y.isFinite,
              let current = CGEvent(source: nil)?.location else { return nil }
        pointerLock.lock(); defer { pointerLock.unlock() }
        refreshHardwareKeyboard(at: current)
        guard let desired = pointerAnchor.target(offset: CGPoint(x: x, y: y), now: ProcessInfo.processInfo.systemUptime) else { return nil }
        let target = virtualCursor.place(at: desired,
                                         current: current, displays: displayBounds())
        let immediate = cursorSmoother.retarget(to: target, current: current,
                                                now: ProcessInfo.processInfo.systemUptime, mode: cursorSmoothingMode)
        let timestamp = diagnosticTimestamp ? DispatchTime.now().uptimeNanoseconds : nil
        if let immediate {
            let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                mouseType: remoteMouseHold.isDown ? .leftMouseDragged : .mouseMoved,
                                mouseCursorPosition: immediate, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
            if let timestamp { event?.timestamp = timestamp }
            event?.post(tap: .cghidEventTap)
        } else {
            pendingMotionTimestamp = timestamp
            startRendering()
        }
        return timestamp
    }
    @discardableResult static func resume(x: Double, y: Double, sameReference: Bool) -> Bool {
        guard AXIsProcessTrusted(), x.isFinite, y.isFinite,
              let current = CGEvent(source: nil)?.location else { return false }
        pointerLock.lock(); defer { pointerLock.unlock() }
        cancelSmoothing()
        pointerAnchor.resume(at: current, offset: CGPoint(x: x, y: y), sameReference: sameReference)
        virtualCursor.rebase(to: current)
        return true
    }
    @discardableResult static func move(dx: Double, dy: Double, diagnosticTimestamp: Bool = false) -> UInt64? {
        guard AXIsProcessTrusted(), dx != 0 || dy != 0,
              let p = CGEvent(source: nil)?.location else { return nil }
        pointerLock.lock(); defer { pointerLock.unlock() }
        refreshHardwareKeyboard(at: p)
        cancelSmoothing()
        guard pointerAnchor.allowsRemote(now: ProcessInfo.processInfo.systemUptime) else { return nil }
        let target = virtualCursor.move(dx: dx, dy: dy, current: p, displays: displayBounds())
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: remoteMouseHold.isDown ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: target, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        // Newly created CGEvents have timestamp zero until WindowServer fills it in.
        // Assign one only while tracing so the observer can correlate the same event.
        if diagnosticTimestamp { event?.timestamp = DispatchTime.now().uptimeNanoseconds }
        event?.post(tap: .cghidEventTap)
        return event?.timestamp
    }
    private static var lastClickTime = Date.distantPast
    private static var clickState = 0
    static func click(_ button: CGMouseButton) {
        guard AXIsProcessTrusted() else { return }
        pointerLock.lock(); defer { pointerLock.unlock() }
        refreshHardwareKeyboard()
        guard !remoteMouseHold.isDown, pointerAnchor.allowsRemote(now: ProcessInfo.processInfo.systemUptime) else { return }
        let now = Date()
        clickState = now.timeIntervalSince(lastClickTime) <= 0.5 ? 2 : 1
        lastClickTime = now
        let p = CGEvent(source: nil)?.location ?? .zero
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let downEvent = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
        let upEvent = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
        downEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        upEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        downEvent?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        upEvent?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        downEvent?.post(tap: .cghidEventTap)
        upEvent?.post(tap: .cghidEventTap)
    }
    static func scroll(dy: Double) {
        guard AXIsProcessTrusted() else { return }
        pointerLock.lock(); defer { pointerLock.unlock() }
        refreshHardwareKeyboard()
        guard pointerAnchor.allowsRemote(now: ProcessInfo.processInfo.systemUptime) else { return }
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0)
        event?.setIntegerValueField(.eventSourceUserData, value: pointerEventTag)
        event?.post(tap: .cghidEventTap)
    }
    static func media(_ action: String) { let codes = ["volume_up": 0, "volume_down": 1, "mute": 7, "play_pause": 16, "next": 17, "previous": 18, "brightness_up": 2, "brightness_down": 3]; guard let code = codes[action] else { return }; postMedia(code, down: true); postMedia(code, down: false) }
    private static func postMedia(_ code: Int, down: Bool) {
        let flags: UInt = down ? 0xA00 : 0xB00
        let data = (code << 16) | ((down ? 0xA : 0xB) << 8)
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: .init(rawValue: flags), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    }
}
