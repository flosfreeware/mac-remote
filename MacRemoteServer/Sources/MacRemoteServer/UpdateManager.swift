import AppKit
import CryptoKit
import Foundation
import Security

private struct MacRemoteUpdateManifest: Decodable {
    let version: String
    let build: Int
    let protocolVersion: Int
    let acceptedProtocolMinimum: Int
    let acceptedProtocolMaximum: Int
    let downloadURL: URL?
    let sha256: String?

    enum CodingKeys: String, CodingKey {
        case version, build, protocolVersion = "protocol_version"
        case acceptedProtocolMinimum = "accepted_protocol_minimum"
        case acceptedProtocolMaximum = "accepted_protocol_maximum"
        case downloadURL = "download_url", sha256
    }
}

/// Downloads releases in the background, verifies both their digest and their
/// Developer ID signature, then defers replacement until the phone is gone.
final class UpdateManager {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(String)
        case staged(String)
        case failed(String)
    }

    private let feedURL = URL(string: "https://flosfreeware.github.io/mac-remote/update.json")!
    private let installSafetyCheck: (@escaping (Bool) -> Void) -> Void
    private let statusChanged: (Status) -> Void
    private var stagedAppURL: URL?
    private var stagedByManualCheck = false
    private var installTimer: Timer?
    private var isChecking = false
    private(set) var automaticUpdatesEnabled: Bool

    init(installSafetyCheck: @escaping (@escaping (Bool) -> Void) -> Void,
         statusChanged: @escaping (Status) -> Void) {
        self.installSafetyCheck = installSafetyCheck
        self.statusChanged = statusChanged
        automaticUpdatesEnabled = UserDefaults.standard.object(forKey: "automaticUpdatesEnabled") as? Bool ?? true
    }

    func start() {
        if automaticUpdatesEnabled { checkForUpdates(manual: false) }
        installTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.installWhenSafe(allowWhenAutomaticUpdatesAreOff: self.stagedByManualCheck)
        }
        RunLoop.main.add(installTimer!, forMode: .common)
        Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { [weak self] _ in
            guard self?.automaticUpdatesEnabled == true else { return }
            self?.checkForUpdates(manual: false)
        }
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        automaticUpdatesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "automaticUpdatesEnabled")
        if enabled {
            checkForUpdates(manual: false)
            installWhenSafe()
        }
    }

    func checkForUpdates(manual: Bool) {
        guard manual || automaticUpdatesEnabled else { return }
        guard !isChecking else { return }
        isChecking = true
        statusChanged(.checking)
        URLSession.shared.dataTask(with: feedURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                guard error == nil,
                      let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let data,
                      let manifest = try? JSONDecoder().decode(MacRemoteUpdateManifest.self, from: data) else {
                    self.statusChanged(.failed("Couldn’t check for updates."))
                    if manual { self.showMessage(title: "Couldn’t check for updates", text: "Mac Remote couldn’t reach the update service. Please try again.") }
                    return
                }
                let newerBuild = manifest.version == RemoteAppVersion.short && manifest.build > (Int(RemoteAppVersion.build) ?? 0)
                guard RemoteAppVersion.isNewer(manifest.version) || newerBuild else {
                    self.statusChanged(.idle)
                    if manual { self.showMessage(title: "Mac Remote is up to date", text: "You’re using version \(RemoteAppVersion.display).") }
                    return
                }
                guard let downloadURL = manifest.downloadURL,
                      let digest = manifest.sha256, digest.count == 64 else {
                    self.statusChanged(.failed("The update release is incomplete."))
                    if manual { self.showMessage(title: "Update unavailable", text: "A newer version exists, but its release download is not ready yet.") }
                    return
                }
                self.download(manifest, from: downloadURL, expectedDigest: digest, manual: manual)
            }
        }.resume()
    }

    private func download(_ manifest: MacRemoteUpdateManifest, from url: URL, expectedDigest: String, manual: Bool) {
        statusChanged(.downloading(manifest.version))
        URLSession.shared.downloadTask(with: url) { [weak self] temporaryURL, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil,
                      let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let temporaryURL else {
                    self.statusChanged(.failed("Couldn’t download version \(manifest.version)."))
                    if manual { self.showMessage(title: "Download failed", text: "Mac Remote couldn’t download version \(manifest.version).") }
                    return
                }
                self.stage(archive: temporaryURL, manifest: manifest, expectedDigest: expectedDigest, manual: manual)
            }
        }.resume()
    }

    private func stage(archive: URL, manifest: MacRemoteUpdateManifest, expectedDigest: String, manual: Bool) {
        guard sha256(of: archive) == expectedDigest.lowercased() else {
            statusChanged(.failed("The downloaded update could not be verified."))
            if manual { showMessage(title: "Update verification failed", text: "The downloaded update didn’t match its expected signature.") }
            return
        }
        let stagingRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRemote/Updates", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            task.arguments = ["-x", "-k", archive.path, stagingRoot.path]
            try task.run(); task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let appURL = findApp(in: stagingRoot), verifyDeveloperSignature(at: appURL) else {
                try? FileManager.default.removeItem(at: stagingRoot)
                statusChanged(.failed("The update app could not be verified."))
                if manual { showMessage(title: "Update verification failed", text: "The downloaded app was not signed by Mac Remote’s developer identity.") }
                return
            }
            stagedAppURL = appURL
            stagedByManualCheck = manual
            statusChanged(.staged(manifest.version))
            installWhenSafe(allowWhenAutomaticUpdatesAreOff: manual)
            if manual { showMessage(title: "Update downloaded", text: "Version \(manifest.version) will install automatically once the iPhone disconnects.") }
        } catch {
            statusChanged(.failed("Mac Remote could not prepare the update."))
            if manual { showMessage(title: "Update failed", text: "Mac Remote couldn’t prepare the downloaded update.") }
        }
    }

    private func installWhenSafe(allowWhenAutomaticUpdatesAreOff: Bool = false) {
        guard stagedAppURL != nil else { return }
        guard automaticUpdatesEnabled || allowWhenAutomaticUpdatesAreOff else { return }
        installSafetyCheck { [weak self] phoneConnected in
            DispatchQueue.main.async {
                guard let self, !phoneConnected, let stagedAppURL = self.stagedAppURL else { return }
                self.replaceAndRelaunch(with: stagedAppURL)
            }
        }
    }

    private func replaceAndRelaunch(with stagedAppURL: URL) {
        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            statusChanged(.failed("Mac Remote must be run from its app bundle to update."))
            return
        }
        let backupURL = currentAppURL.deletingLastPathComponent()
            .appendingPathComponent(".Mac Remote.previous.\(UUID().uuidString).app")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; mv \"$3\" \"$4\" && mv \"$2\" \"$3\" && /usr/bin/open -n \"$3\"; rm -rf \"$4\"", "macremote-updater", "\(getpid())", stagedAppURL.path, currentAppURL.path, backupURL.path]
        do {
            try helper.run()
            statusChanged(.idle)
            NSApplication.shared.terminate(nil)
        } catch {
            statusChanged(.failed("Mac Remote could not install the update."))
        }
    }

    private func findApp(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "app" && url.lastPathComponent == "Mac Remote.app" { return url }
        return nil
    }

    private func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func verifyDeveloperSignature(at appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var requirement: SecRequirement?
        let source = "identifier \"local.macremote.server\" and anchor apple generic and certificate leaf[subject.OU] = SF3DHL8Y67"
        guard SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    private func showMessage(title: String, text: String) {
        let alert = NSAlert()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url) {
            icon.isTemplate = false
            icon.size = NSSize(width: 64, height: 64)
            alert.icon = icon
        }
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
