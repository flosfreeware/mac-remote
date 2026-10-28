import Foundation
import Network
import Security
import UIKit

enum RemoteCompatibilityIssue: Equatable {
    case iphoneNeedsUpdate(macVersion: String)
    case macNeedsUpdate(macVersion: String)

    var title: String {
        switch self {
        case .iphoneNeedsUpdate: "Update this iPhone"
        case .macNeedsUpdate: "Update Mac Remote"
        }
    }

    var message: String {
        switch self {
        case .iphoneNeedsUpdate(let macVersion):
            "Mac Remote \(macVersion) on your Mac requires a newer version of this iPhone app. Update Mac Remote in the App Store, then reconnect."
        case .macNeedsUpdate:
            "Mac Remote on this iPhone is newer than the version on your Mac. On your Mac, open the Mac Remote menu and choose Check for Updates."
        }
    }
}

enum RemoteProtocol {
    static let version = 1
    static let acceptedMinimum = 1
    static let acceptedMaximum = 1
    static var acceptedRangeDescription: String {
        acceptedMinimum == acceptedMaximum ? "\(acceptedMinimum)" : "\(acceptedMinimum)–\(acceptedMaximum)"
    }
}

enum RemoteAppVersion {
    static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static var display: String { "\(short) (\(build))" }
}

final class RemoteConnection: ObservableObject {
    enum Status: String { case searching = "Searching", connected = "Connected", disconnected = "Disconnected" }
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var controlSession: UUID?
    @Published private(set) var hasSecret: Bool
    @Published private(set) var pairedMacName = "Mac"
    @Published private(set) var compatibilityIssue: RemoteCompatibilityIssue?
    @Published private(set) var inputActive = false
    @Published private(set) var inputText = ""
    @Published private(set) var inSafari = false
    @Published private(set) var macMuted = false
    @Published private(set) var macFullscreen = false
    @Published private(set) var macSleeping = false
    @Published private(set) var remoteEnabled = true
    // nil means the connected Mac has not reported this optional capability.
    @Published private(set) var macAccessibilityGranted: Bool?
    @Published private(set) var diagnosticsEnabled = false
    @Published private(set) var connectionUnstable = false
    @Published private(set) var pairingFailure: String?
    @Published private var reconnectPresentation = ReconnectPresentationState()
    var reconnectGraceActive: Bool { reconnectPresentation.graceActive }
    var showConnectionHelp: Bool { reconnectPresentation.showHelp }
    var controlsEnabled: Bool { (status == .connected || reconnectGraceActive) && !macSleeping && remoteEnabled && macAccessibilityGranted != false }
    private var actionBuffer = ReconnectActionBuffer<() -> Void>()
    private var graceTimeout: DispatchWorkItem?
    private let queue = DispatchQueue(label: "MacRemoteClient.network")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var motionConnection: NWConnection?
    private var motionSession = ""
    private var motionReady = false
    private var motionSequence = 0
    private var motionLastAck = 0.0
    private var motionTimeout: DispatchWorkItem?
    private var motionSending = false
    private var pendingMotion: [String: Any]?
    private var credentials: PairingStore.Credentials?
    private var pendingCredentials: PairingStore.Credentials?
    private var reconnect: DispatchWorkItem?
    private var lastEndpoint: NWEndpoint?
    // Bonjour is retained as a fallback for a QR's direct LAN endpoint. Keep
    // the discovered endpoint separately so a fast browse result cannot
    // interrupt an in-flight direct connection.
    private var discoveredEndpoint: NWEndpoint?
    private var connectionTimeout: DispatchWorkItem?
    private var pairingAttemptTimeout: DispatchWorkItem?
    // Keep the actual transport failure during a QR claim. This is diagnostic
    // context for pairing only; it is cleared for every new scan.
    private var pairingAttemptFailureDetails: [String] = []
    private var pairingAttemptStage = "Starting"
    private var probeTimeout: DispatchWorkItem?
    private var probeID: String?
    private var controlReadiness = RemoteControlReadiness()
    private var foreground: Bool { controlReadiness.foreground }
    private var controlsReady: Bool { controlReadiness.ready }
    private var resetID: String?
    private var resetAcknowledged = false
    private var resetCompletion: ((String) -> Void)?
    private var resetTimeout: DispatchWorkItem?
    private var resetMessage: [String: Any] = [:]
    // An onboarding center tap can arrive while the secure pairing reply is
    // still transitioning this connection to control-ready. Unlike ordinary
    // actions, a reset is safe to retain until that handshake completes.
    private var deferredResetRequest: (message: [String: Any], generation: String, acknowledged: (String) -> Void)?
    private var mouseHoldID: String?
    private var mouseHoldTimer: DispatchSourceTimer?
    private var diagnosticSession = ""
    private var diagnosticActive = false
    private var diagnosticTimer: DispatchSourceTimer?
    private var diagnosticSequence = 0
    private var diagnosticInFlight = 0
    private var diagnosticStream = 0
    private var diagnosticCompletions: [[String: Double]] = []
    // Launch-only TCP experiments; normal launches keep the original TCP defaults.
    private let testNoDelay = CommandLine.arguments.contains("--test-tcp-nodelay")
    private let testAckStretching = CommandLine.arguments.contains("--test-tcp-no-ack-stretching")
    // LAN-only by default: peer discovery caused recurring Wi-Fi delivery stalls.
    // The opt-in flag is retained solely for diagnostic comparisons.
    private let testPeerDiscovery = CommandLine.arguments.contains("--test-peer-discovery")
    private func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = testNoDelay
        tcp.disableAckStretching = testAckStretching
        return tcp
    }

    init() {
        credentials = PairingStore.load()
        hasSecret = credentials != nil
        pairedMacName = credentials?.macName ?? "Mac"
        if credentials != nil { start() }
    }
    func pair(_ text: String) {
        // Start only after clearing a previous presentation on the main queue.
        // This avoids a fast failure racing the clear and leaving onboarding in
        // its loading state with no published error.
        DispatchQueue.main.async {
            self.pairingFailure = nil
            self.queue.async {
                guard let credentials = PairingStore.decode(text) else {
                    self.publishPairingFailure("This isn’t a Mac Remote pairing code. Scan the QR code shown by Mac Remote, then try again.")
                    return
                }
            guard LocalNetworkIdentity.hasActiveWiFi else {
                self.publishPairingFailure("Your iPhone isn't connected to Wi-Fi. Connect it to the same local network as your Mac, then scan a new QR code.")
                return
            }
            self.pendingCredentials = credentials
            self.pairingAttemptFailureDetails = []
            self.pairingAttemptStage = "Preparing the local connection"
            self.beginPairingAttemptTimeout()
            self.startBrowsing(credentials: credentials)
            }
        }
    }
    func cancelPairingAttempt() {
        queue.async {
            // A scanned code is not a pairing until the Mac accepts its
            // one-time claim. Stop discovery and discard only that pending
            // claim, leaving any established pairing untouched.
            guard self.pendingCredentials != nil else { return }
            self.pendingCredentials = nil
            self.browser?.cancel(); self.browser = nil
            let old = self.connection; self.connection = nil
            old?.cancel()
            self.connectionTimeout?.cancel(); self.connectionTimeout = nil
            self.pairingAttemptTimeout?.cancel(); self.pairingAttemptTimeout = nil
            self.probeTimeout?.cancel(); self.probeTimeout = nil
            self.controlReadiness.disconnect()
            self.publishStatus(.disconnected)
        }
    }

    private func rejectPairingAttempt(on connection: NWConnection, reason: String) {
        guard self.connection === connection else { return }
        pendingCredentials = nil
        browser?.cancel(); browser = nil
        self.connection = nil
        connection.cancel()
        connectionTimeout?.cancel(); connectionTimeout = nil
        pairingAttemptTimeout?.cancel(); pairingAttemptTimeout = nil
        probeTimeout?.cancel(); probeID = nil
        controlReadiness.disconnect()
        publishStatus(.disconnected)
        let message: String
        switch reason {
        case "expired":
            message = "This pairing code has expired. Scan the new QR code on your Mac."
        case "already_paired":
            message = "This Mac is already paired with another iPhone."
        default:
            message = "This pairing code is no longer valid. Scan the QR code again."
        }
        DispatchQueue.main.async { self.pairingFailure = message }
    }

    private func beginPairingAttemptTimeout() {
        pairingAttemptTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.endPendingPairingAttempt()
        }
        pairingAttemptTimeout = timeout
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func publishPairingFailure(_ message: String) {
        DispatchQueue.main.async { self.pairingFailure = message }
    }

    // The onboarding view also calls this as a presentation failsafe. Keeping
    // teardown on the networking queue makes both deadlines safe to race.
    func expirePendingPairingAttempt() {
        queue.async { [weak self] in self?.endPendingPairingAttempt() }
    }

    private func endPendingPairingAttempt() {
        guard pendingCredentials != nil else { return }
        pendingCredentials = nil
        browser?.cancel(); browser = nil
        let connection = connection; self.connection = nil
        connection?.cancel()
        connectionTimeout?.cancel(); connectionTimeout = nil
        pairingAttemptTimeout?.cancel(); pairingAttemptTimeout = nil
        probeTimeout?.cancel(); probeID = nil
        controlReadiness.disconnect()
        publishStatus(.disconnected)
        let details = pairingAttemptFailureDetails.isEmpty ? "" : "\n\nConnection detail: \(pairingAttemptFailureDetails.joined(separator: "\n"))"
        publishPairingFailure("Mac Remote couldn’t establish a local connection to your Mac.\n\nLast pairing step: \(pairingAttemptStage)\(details)")
    }

    private func recordPairingAttemptFailure(_ error: Error) {
        recordPairingAttemptFailure(error.localizedDescription)
    }

    private func recordPairingAttemptFailure(_ detail: String) {
        guard pendingCredentials != nil else { return }
        guard !pairingAttemptFailureDetails.contains(detail), pairingAttemptFailureDetails.count < 3 else { return }
        pairingAttemptFailureDetails.append(detail)
    }

    private func updatePairingAttemptStage(_ stage: String) {
        guard pendingCredentials != nil else { return }
        pairingAttemptStage = stage
    }
    func unpair() {
        queue.async {
            if let connection = self.connection { self.transmit(["type": "unpair"], on: connection) }
            self.clearLocalPairing()
            // Keep the authenticated socket alive just long enough to deliver
            // the revocation to the Mac, while immediately returning the UI to
            // its unpaired state.
            self.queue.asyncAfter(deadline: .now() + 1) { self.tearDownPairingConnection() }
        }
    }
    private func clearPairing() {
        clearLocalPairing()
        tearDownPairingConnection()
    }
    private func clearLocalPairing() {
        PairingStore.delete()
        credentials = nil
        pendingCredentials = nil
        DispatchQueue.main.async {
            self.hasSecret = false
            self.pairedMacName = "Mac"
        }
    }
    private func tearDownPairingConnection() {
        closeMotionTransport()
        browser?.cancel(); browser = nil
        let old = connection; connection = nil
        old?.cancel()
        controlReadiness.disconnect()
        publishStatus(.disconnected)
        DispatchQueue.main.async {
            self.inputActive = false
            self.connectionUnstable = false
        }
    }
    func start() {
        guard let credentials else { return }
        queue.async {
            self.startBrowsing(credentials: credentials)
        }
    }
    private func publishStatus(_ status: Status, controlSession: UUID? = nil) {
        DispatchQueue.main.async {
            self.status = status
            if status != .connected { self.macAccessibilityGranted = nil }
            self.reconnectPresentation.connectionChanged(connected: status == .connected)
            if let controlSession { self.controlSession = controlSession }
        }
    }
    private func startBrowsing(credentials: PairingStore.Credentials) {
        closeMotionTransport()
        motionSequence = 0
        configureDiagnostics(enabled: false, session: "")
        resetTimeout?.cancel(); resetID = nil; resetAcknowledged = false; resetCompletion = nil
        reconnect?.cancel(); reconnect = nil
        connectionTimeout?.cancel(); probeTimeout?.cancel(); probeID = nil
        let old = connection
        releaseMouse(on: old)
        connection = nil
        controlReadiness.disconnect()
        old?.cancel()
        browser?.cancel()
        discoveredEndpoint = nil
        publishStatus(.searching)
        let parameters = NWParameters(tls: TLS.pskOptions(credentials.transportSecret), tcp: tcpOptions())
        parameters.includePeerToPeer = testPeerDiscovery
        let browser = NWBrowser(for: .bonjour(type: "_macremote._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, self.browser === browser, let result = results.first else { return }
            self.discoveredEndpoint = result.endpoint
            guard self.connection == nil else { return }
            // No direct QR endpoint is currently in flight, so Bonjour is the
            // primary route (or the direct route has already failed).
            if self.pendingCredentials == nil || self.lastEndpoint == nil {
                self.connect(to: result.endpoint, credentials: credentials)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, self.browser === browser else { return }
            if case .failed(let error) = state {
                self.recordPairingAttemptFailure(error)
                // A QR supplies an exact local address. Bonjour can fail on a
                // perfectly usable LAN, and must never cancel that in-flight
                // direct pairing connection just because browsing failed.
                if self.pendingCredentials != nil, self.connection != nil { return }
                self.scheduleReconnect()
            }
        }
        self.browser = browser; browser.start(queue: queue)
        // New pairing QR codes carry the Mac's current LAN address and stable
        // listener port. Prefer that unicast endpoint to Bonjour. Retrying it
        // after a short failed attempt matters while the Mac listener is
        // restarting; previously, one transient direct failure forced all
        // remaining pairing attempts to rely on Bonjour alone.
        if let host = credentials.directHost ?? credentials.directHostV6,
           let port = credentials.directPort {
            // QR enrollment carries an IPv4 LAN address. Keep it an address,
            // rather than making Network.framework treat it as a host name and
            // potentially send a pairing attempt through name resolution.
            let endpointHost = IPv6Address(host).map(NWEndpoint.Host.ipv6)
                ?? IPv4Address(host).map(NWEndpoint.Host.ipv4)
                ?? .init(host)
            connect(to: .hostPort(host: endpointHost, port: .init(rawValue: port)!), credentials: credentials, isDirectPairingEndpoint: pendingCredentials != nil)
        } else if let endpoint = lastEndpoint {
            // Bonjour browsing continues while we try a recently successful
            // endpoint (including a direct pairing endpoint) again.
            connect(to: endpoint, credentials: credentials)
        }
    }
    private func connect(to endpoint: NWEndpoint, credentials: PairingStore.Credentials, isDirectPairingEndpoint: Bool = false) {
        reconnect?.cancel(); reconnect = nil
        lastEndpoint = endpoint
        updatePairingAttemptStage("Opening a secure connection to the Mac")
        let parameters = NWParameters(tls: TLS.pskOptions(credentials.transportSecret), tcp: tcpOptions())
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        // WebSocket needs a URL endpoint to construct its HTTP upgrade for a
        // literal address. A bare hostPort reaches TCP/TLS but aborts before
        // WebSocket becomes ready. Bonjour service endpoints work as-is.
        let webSocketEndpoint: NWEndpoint
        if case let .hostPort(host, port) = endpoint {
            let address = String(describing: host)
            let authority = address.contains(":") ? "[\(address)]" : address
            guard let url = URL(string: "wss://\(authority):\(port.rawValue)/") else {
                recordPairingAttemptFailure("The Mac’s WebSocket address is invalid.")
                return
            }
            webSocketEndpoint = .url(url)
        } else {
            webSocketEndpoint = endpoint
        }
        let connection = NWConnection(to: webSocketEndpoint, using: parameters)
        self.connection = connection
        let route = isDirectPairingEndpoint ? "Direct connection" : "Discovered connection"
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.connectionTimeout?.cancel()
                self.updatePairingAttemptStage("Secure connection ready; sending the pairing claim")
                self.authenticate(on: connection, credentials: credentials)
            case .failed(let error):
                self.recordPairingAttemptFailure("\(route) failed: \(error.localizedDescription)")
                self.lastEndpoint = nil
                if isDirectPairingEndpoint, self.fallbackToDiscoveredPairingEndpoint(from: connection, credentials: credentials) { return }
                self.dropConnection(connection)
            case .waiting(let error):
                self.recordPairingAttemptFailure("\(route) is waiting: \(error.localizedDescription)")
                if isDirectPairingEndpoint, self.fallbackToDiscoveredPairingEndpoint(from: connection, credentials: credentials) { return }
                self.dropConnection(connection)
            case .cancelled:
                self.dropConnection(connection)
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection else { return }
            // Leave time for discovery fallback within the overall 3-second
            // pairing deadline.
            self.recordPairingAttemptFailure("\(route) did not finish preparing in time.")
            self.lastEndpoint = nil
            if isDirectPairingEndpoint, self.fallbackToDiscoveredPairingEndpoint(from: connection, credentials: credentials) { return }
            self.dropConnection(connection)
        }
        connectionTimeout?.cancel(); connectionTimeout = timeout
        let connectionDeadline: DispatchTimeInterval = isDirectPairingEndpoint ? .seconds(1) : .seconds(2)
        queue.asyncAfter(deadline: .now() + connectionDeadline, execute: timeout)
        connection.start(queue: queue)
        receiveMessages(on: connection)
    }
    private func fallbackToDiscoveredPairingEndpoint(from connection: NWConnection, credentials: PairingStore.Credentials) -> Bool {
        guard pendingCredentials != nil, self.connection === connection, let endpoint = discoveredEndpoint else { return false }
        connectionTimeout?.cancel(); connectionTimeout = nil
        self.connection = nil
        connection.cancel()
        updatePairingAttemptStage("Connecting through local Mac discovery")
        connect(to: endpoint, credentials: credentials)
        return true
    }
    private func authenticate(on connection: NWConnection, credentials: PairingStore.Credentials) {
        var message: [String: Any] = ["credential": credentials.deviceCredential.base64EncodedString(),
                                      "device_name": UIDevice.current.name,
                                      "app_version": RemoteAppVersion.short,
                                      "protocol_version": RemoteProtocol.version,
                                      "accepted_protocol_minimum": RemoteProtocol.acceptedMinimum,
                                      "accepted_protocol_maximum": RemoteProtocol.acceptedMaximum]
        if let token = credentials.enrollmentToken {
            message["type"] = "pair_claim"
            message["token"] = token.base64EncodedString()
        } else {
            message["type"] = "authenticate"
        }
        transmit(message, on: connection)
        if credentials.enrollmentToken != nil {
            updatePairingAttemptStage("Pairing claim sent; waiting for the Mac")
        }
    }
    private func receiveMessages(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.connection === connection else { return }
            let received = ProcessInfo.processInfo.systemUptime
            if let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.updatePairingAttemptStage("Received a response from the Mac")
                if object["type"] as? String == "pair_rejected" {
                    self.rejectPairingAttempt(on: connection, reason: object["reason"] as? String ?? "invalid")
                    return
                }
                if object["type"] as? String == "pair_accepted", var credentials = self.pendingCredentials {
                    self.pairingAttemptTimeout?.cancel(); self.pairingAttemptTimeout = nil
                    credentials.enrollmentToken = nil
                    self.pendingCredentials = nil
                    self.credentials = credentials
                    PairingStore.save(credentials)
                    DispatchQueue.main.async { self.hasSecret = true }
                    self.finishConnectionCheck()
                } else if object["type"] as? String == "authenticated" {
                    self.finishConnectionCheck()
                }
                if object["type"] as? String == "incompatible" {
                    let macVersion = object["mac_app_version"] as? String ?? "the current version"
                    let issue: RemoteCompatibilityIssue = object["reason"] as? String == "iphone_update_required"
                        ? .iphoneNeedsUpdate(macVersion: macVersion)
                        : .macNeedsUpdate(macVersion: macVersion)
                    DispatchQueue.main.async { self.compatibilityIssue = issue }
                    self.dropConnection(connection)
                    return
                }
                if let macName = object["mac_name"] as? String {
                    self.storeMacName(macName)
                }
                if object["type"] as? String == "unpaired" {
                    self.clearPairing()
                    return
                }
                if object["type"] as? String == "motion_udp" {
                    self.startMotionTransport(object, control: connection)
                }
                if object["type"] as? String == "motion_udp_ready",
                   object["session"] as? String == self.motionSession, self.motionConnection != nil {
                    if !self.motionReady { NSLog("Mac Remote: cursor transport DTLS-UDP") }
                    self.motionReady = true
                    self.motionLastAck = received
                    self.motionTimeout?.cancel(); self.motionTimeout = nil
                }
                if object["type"] as? String == "system_state", let sleeping = object["sleeping"] as? Bool {
                    if sleeping { self.releaseMouse(on: connection) }
                    DispatchQueue.main.async { self.macSleeping = sleeping }
                }
                if object["type"] as? String == "remote_state", let enabled = object["enabled"] as? Bool {
                    if !enabled { self.releaseMouse(on: connection) }
                    DispatchQueue.main.async { self.remoteEnabled = enabled }
                }
                if let granted = object["accessibility_granted"] as? Bool
                    ?? (object["type"] as? String == "accessibility_state" ? object["granted"] as? Bool : nil) {
                    DispatchQueue.main.async { self.macAccessibilityGranted = granted }
                }
                if object["type"] as? String == "connection_quality", let unstable = object["unstable"] as? Bool {
                    DispatchQueue.main.async { self.connectionUnstable = unstable }
                }
                if object["type"] as? String == "reset_ack",
                   let id = object["generation"] as? String, id == self.resetID {
                    self.resetTimeout?.cancel()
                    if object["success"] as? Bool == true {
                        self.resetAcknowledged = true
                        let completion = self.resetCompletion; self.resetCompletion = nil
                        completion?(id)
                    }
                }
                if object["type"] as? String == "pong", let id = object["id"] as? String, id == self.probeID {
                    self.finishConnectionCheck()
                }
                if object["type"] as? String == "diagnostic_probe_reply",
                   object["session"] as? String == self.diagnosticSession, self.diagnosticActive {
                    var reply: [String: Any] = ["type": "diagnostic_probe_result", "client_receive_s": received]
                    for key in ["client_send_s", "mac_receive_s", "mac_reply_s"] { reply[key] = object[key] }
                    self.transmit(reply, on: connection)
                }
                if object["type"] as? String == "input_focus" {
                if object["sleeping"] as? Bool == true { self.releaseMouse(on: connection) }
                self.configureDiagnostics(enabled: object["diagnostics"] as? Bool ?? false,
                                          session: object["diagnostic_session"] as? String ?? "")
                DispatchQueue.main.async {
                    self.inputActive = object["active"] as? Bool ?? false
                    self.inputText = object["text"] as? String ?? ""
                    self.inSafari = object["safari"] as? Bool ?? false
                    if let muted = object["muted"] as? Bool { self.macMuted = muted }
                    if let fullscreen = object["fullscreen"] as? Bool { self.macFullscreen = fullscreen }
                    if let sleeping = object["sleeping"] as? Bool { self.macSleeping = sleeping }
                    if let enabled = object["remote_enabled"] as? Bool { self.remoteEnabled = enabled }
                }
                }
            }
            if error == nil { self.receiveMessages(on: connection) }
            else { self.dropConnection(connection) }
        }
    }

    private func storeMacName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if var credentials {
            credentials.macName = String(trimmed.prefix(80))
            self.credentials = credentials
            PairingStore.save(credentials)
        }
        DispatchQueue.main.async { self.pairedMacName = String(trimmed.prefix(80)) }
    }
    private func dropConnection(_ connection: NWConnection) {
        guard self.connection === connection else { return }
        closeMotionTransport()
        self.connection = nil
        releaseMouse(on: connection)
        controlReadiness.disconnect()
        resetTimeout?.cancel(); resetID = nil; resetAcknowledged = false; resetCompletion = nil
        connectionTimeout?.cancel(); probeTimeout?.cancel(); probeID = nil
        connection.cancel()
        configureDiagnostics(enabled: false, session: "")
        DispatchQueue.main.async { self.connectionUnstable = false }
        publishStatus(.disconnected)
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        reconnect?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let credentials = self.credentials ?? self.pendingCredentials else { return }
            self.startBrowsing(credentials: credentials)
        }; reconnect = item
        queue.asyncAfter(deadline: .now() + 0.35, execute: item)
    }
    func resumeControls() {
        let now = ProcessInfo.processInfo.systemUptime
        let graceID = reconnectPresentation.resume()
        status = .searching
        queue.async { [self] in
            self.graceTimeout?.cancel()
            self.actionBuffer.begin(now: now)
            let expiry = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.actionBuffer.cancel()
                DispatchQueue.main.async {
                    self.reconnectPresentation.expire(generation: graceID, connected: self.status == .connected)
                }
            }
            self.graceTimeout = expiry
            self.queue.asyncAfter(deadline: .now() + max(0, now + ReconnectActionBuffer<() -> Void>.graceDuration - ProcessInfo.processInfo.systemUptime), execute: expiry)
            self.controlReadiness.resume()
            self.reconnect?.cancel(); self.reconnect = nil
            if let connection = self.connection, case .ready = connection.state {
                self.transmit(["type": "client_active", "active": true], on: connection)
                // Validate a retained socket instead of waiting for TCP to time out.
                let id = UUID().uuidString
                self.probeID = id
                self.transmit(["type": "ping", "id": id], on: connection)
                self.probeTimeout?.cancel()
                let timeout = DispatchWorkItem { [weak self, weak connection] in
                    guard let self, let connection, self.probeID == id, self.connection === connection else { return }
                    self.dropConnection(connection)
                    if let credentials = self.credentials { self.startBrowsing(credentials: credentials) }
                }
                self.probeTimeout = timeout
                self.queue.asyncAfter(deadline: .now() + 0.5, execute: timeout)
            } else if self.connection == nil, let credentials = self.credentials {
                self.startBrowsing(credentials: credentials)
            }
        }
    }
    @MainActor func suspendControls() {
        reconnectPresentation.suspend()
        let backgroundSend = CursorVisibilityBackgroundTask()
        queue.async {
            // This bypasses controlsReady/the optimistic queue: send before iOS
            // suspends us, including when the user locks the phone.
            if self.foreground, let connection = self.connection, case .ready = connection.state {
                self.transmit(["type": "client_active", "active": false], on: connection)
            } else {
                DispatchQueue.main.async { backgroundSend.finish() }
            }
            // The task's one-second timeout keeps the process alive briefly for
            // networking; no ongoing background gyro or remote control is allowed.
            _ = backgroundSend
            self.graceTimeout?.cancel(); self.graceTimeout = nil
            self.actionBuffer.cancel()
            self.closeMotionTransport()
            self.releaseMouse(on: self.connection)
            self.controlReadiness.suspend()
            self.resetTimeout?.cancel(); self.resetID = nil
            self.resetAcknowledged = false; self.resetCompletion = nil
            self.deferredResetRequest = nil
            self.probeTimeout?.cancel(); self.probeID = nil
        }
    }
    private func finishConnectionCheck() {
        pairingAttemptTimeout?.cancel(); pairingAttemptTimeout = nil
        probeTimeout?.cancel(); probeID = nil
        let readySession = controlReadiness.confirm()
        if controlsReady, let deferred = deferredResetRequest {
            deferredResetRequest = nil
            beginPointerRequest(deferred.message, generation: deferred.generation, acknowledged: deferred.acknowledged)
        }
        if let connection { transmit(["type": "client_active", "active": foreground], on: connection) }
        graceTimeout?.cancel(); graceTimeout = nil
        let pending = actionBuffer.drain(now: ProcessInfo.processInfo.systemUptime)
        if controlsReady { for action in pending { action() } }
        publishStatus(.connected, controlSession: readySession)
        DispatchQueue.main.async { self.compatibilityIssue = nil }
        if foreground, let connection {
            transmit(["type": "motion_udp_request"], on: connection)
        }
    }
    private func closeMotionTransport() {
        motionTimeout?.cancel(); motionTimeout = nil
        let old = motionConnection; motionConnection = nil
        motionReady = false; motionSession = ""
        motionSending = false; pendingMotion = nil
        old?.cancel()
    }
    private func startMotionTransport(_ offer: [String: Any], control: NWConnection) {
        guard self.connection === control, let secret = credentials?.transportSecret,
              let rawPort = offer["port"] as? Int, (1...65535).contains(rawPort),
              let session = offer["session"] as? String, UUID(uuidString: session) != nil,
              case let .hostPort(host, _) = control.currentPath?.remoteEndpoint else { return }
        if motionConnection != nil, motionSession == session { return }
        closeMotionTransport()
        motionSession = session
        let parameters = NWParameters(dtls: TLS.pskOptions(secret, datagram: true), udp: .init())
        parameters.serviceClass = .interactiveVideo
        let udp = NWConnection(host: host, port: NWEndpoint.Port(rawValue: UInt16(rawPort))!, using: parameters)
        motionConnection = udp
        udp.stateUpdateHandler = { [weak self, weak udp] state in
            guard let self, let udp, self.motionConnection === udp else { return }
            switch state {
            case .ready:
                self.transmit(["type": "motion_hello", "motion_session": session], on: udp)
            case .failed, .cancelled, .waiting:
                NSLog("Mac Remote: UDP unavailable; retaining secure WebSocket")
                self.closeMotionTransport()
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak udp] in
            guard let self, let udp, self.motionConnection === udp, !self.motionReady else { return }
            NSLog("Mac Remote: UDP handshake/path timed out; retaining secure WebSocket")
            self.closeMotionTransport()
        }
        motionTimeout = timeout
        queue.asyncAfter(deadline: .now() + 4, execute: timeout)
        udp.start(queue: queue)
    }
    private func sendMotion(_ object: [String: Any], on udp: NWConnection) {
        // Keep only the newest pending absolute target, never a motion backlog.
        if motionSending { pendingMotion = object; return }
        motionSending = true
        transmit(object, on: udp)
    }
    func setMouseHeld(_ held: Bool) {
        queue.async { [self] in
            if !self.controlsReady {
                if !held { self.releaseMouse(on: self.connection) }
                if self.foreground {
                    let accepted = self.actionBuffer.enqueue({ [weak self] in self?.applyMouseHeld(held) }, now: ProcessInfo.processInfo.systemUptime)
                    // If a bounded queue cannot retain an up, discard its down
                    // too rather than replaying a hold whose finger is gone.
                    if !accepted && !held { self.actionBuffer.cancel() }
                }
                return
            }
            self.applyMouseHeld(held)
        }
    }
    private func applyMouseHeld(_ held: Bool) {
            guard held else { self.releaseMouse(on: self.connection); return }
            guard self.mouseHoldID == nil, self.foreground, self.controlsReady, let connection = self.connection else { return }
            let id = UUID().uuidString
            self.mouseHoldID = id
            self.transmit(["type": "mouse_button", "button": "left", "down": true, "id": id], on: connection)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
            timer.setEventHandler { [weak self, weak connection] in
                guard let self, let connection, self.connection === connection,
                      self.mouseHoldID == id, self.foreground, self.controlsReady else { return }
                self.transmit(["type": "mouse_button", "button": "left", "down": true, "id": id], on: connection)
            }
            self.mouseHoldTimer = timer; timer.resume()
    }
    private func releaseMouse(on connection: NWConnection?) {
        mouseHoldTimer?.cancel(); mouseHoldTimer = nil
        guard let id = mouseHoldID else { return }
        mouseHoldID = nil
        // Releases bypass controlsReady so backgrounding/reset cannot swallow up.
        if let connection {
            transmit(["type": "mouse_button", "button": "left", "down": false, "id": id], on: connection)
        }
    }
    func resetPointer(generation: String, acknowledged: @escaping (String) -> Void) {
        requestPointer(["type": "reset", "generation": generation], generation: generation, acknowledged: acknowledged)
    }
    func resumePointer(generation: String, x: Double, y: Double, acknowledged: @escaping (String) -> Void) {
        requestPointer(["type": "pointer_resume", "generation": generation, "x": x, "y": y],
                       generation: generation, acknowledged: acknowledged)
    }
    private func requestPointer(_ message: [String: Any], generation: String, acknowledged: @escaping (String) -> Void) {
        queue.async { [self] in
            guard self.foreground else { return }
            if !self.controlsReady {
                if message["type"] as? String == "reset" {
                    self.deferredResetRequest = (message, generation, acknowledged)
                }
                return
            }
            // Automatic pose restoration must not replace a user reset queued
            // during the optimistic reconnect window.
            if message["type"] as? String == "pointer_resume", self.resetMessage["type"] as? String == "reset",
               self.resetID == generation, !self.resetAcknowledged { return }
            self.beginPointerRequest(message, generation: generation, acknowledged: acknowledged)
        }
    }
    private func beginPointerRequest(_ message: [String: Any], generation: String, acknowledged: @escaping (String) -> Void) {
            guard self.foreground, self.controlsReady else { return }
            self.releaseMouse(on: self.connection)
            self.resetTimeout?.cancel()
            self.resetID = generation; self.resetAcknowledged = false
            self.resetMessage = message
            self.resetCompletion = acknowledged
            self.sendReset(attempt: 0)
    }
    private func sendReset(attempt: Int) {
        guard let id = resetID, let connection, controlsReady else { return }
        transmit(resetMessage, on: connection)
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.resetID == id, !self.resetAcknowledged else { return }
            if attempt < 2 { self.sendReset(attempt: attempt + 1) }
            else { self.dropConnection(connection) }
        }
        resetTimeout = timeout
        queue.asyncAfter(deadline: .now() + 0.75, execute: timeout)
    }
    func send(_ object: [String: Any]) {
        let enqueued = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            if !self.controlsReady {
                if self.foreground, ReconnectActionBuffer<() -> Void>.accepts(messageType: object["type"] as? String ?? "") {
                    self.actionBuffer.enqueue({ [weak self] in self?.sendNow(object, enqueued: enqueued) },
                                              now: ProcessInfo.processInfo.systemUptime)
                }
                return // Cursor/gyro samples are deliberately never queued.
            }
            self.sendNow(object, enqueued: enqueued)
        }
    }
    private func sendNow(_ object: [String: Any], enqueued: Double) {
            guard self.foreground, self.controlsReady, let connection = self.connection else { return }
            if object["type"] as? String == "pointer_target" {
                guard self.resetAcknowledged, object["generation"] as? String == self.resetID else { return }
            }
            var message = object
            if object["type"] as? String == "pointer_target" {
                self.motionSequence += 1
                message["motion_seq"] = self.motionSequence
                message["motion_session"] = self.motionSession
                if self.motionReady, ProcessInfo.processInfo.systemUptime - self.motionLastAck > 3 {
                    NSLog("Mac Remote: UDP acknowledgments stopped; retaining secure WebSocket")
                    self.closeMotionTransport()
                }
            }
            if self.diagnosticActive, ["mouse_move", "pointer_target"].contains(object["type"] as? String ?? "") {
                self.diagnosticSequence += 1
                message["diag_seq"] = self.diagnosticSequence
                message["diag_stream"] = self.diagnosticStream
                message["diag_enqueued_s"] = enqueued
                message["diag_tx_s"] = ProcessInfo.processInfo.systemUptime
                message["diag_inflight"] = self.diagnosticInFlight
                message["diag_tcp_nodelay"] = self.testNoDelay ? 1 : 0
                message["diag_tcp_no_ack_stretching"] = self.testAckStretching ? 1 : 0
                message["diag_peer_discovery"] = self.testPeerDiscovery ? 1 : 0
                message["diag_udp_priority"] = 1
            }
            if object["type"] as? String == "pointer_target", self.motionReady, let udp = self.motionConnection {
                self.sendMotion(message, on: udp)
            } else {
                self.transmit(message, on: connection)
            }
    }
    private func configureDiagnostics(enabled: Bool, session: String) {
        guard enabled != diagnosticActive || session != diagnosticSession else { return }
        diagnosticActive = enabled; diagnosticSession = session
        diagnosticTimer?.cancel(); diagnosticTimer = nil
        diagnosticSequence = 0; diagnosticInFlight = 0; diagnosticCompletions.removeAll()
        diagnosticStream = Int.random(in: 1...1_000_000_000)
        DispatchQueue.main.async { self.diagnosticsEnabled = enabled }
        guard enabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // A 10-second diagnostics run needs enough samples to describe jitter,
        // not merely a handful of one-second round trips.
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.diagnosticActive, self.foreground, let connection = self.connection else { return }
            self.transmit(["type": "diagnostic_probe", "id": UUID().uuidString,
                           "client_send_s": ProcessInfo.processInfo.systemUptime], on: connection)
            if !self.diagnosticCompletions.isEmpty {
                let rows = self.diagnosticCompletions
                self.diagnosticCompletions.removeAll(keepingCapacity: true)
                self.transmit(["type": "diagnostic_client_report", "rows": rows], on: connection)
            }
        }
        diagnosticTimer = timer; timer.resume()
    }
    private func transmit(_ object: [String: Any], on connection: NWConnection) {
        let datagram = self.motionConnection === connection
        let started = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        if datagram, data.count > 1200 {
            closeMotionTransport()
            if let reliable = self.connection { transmit(object, on: reliable) }
            return
        }
        let serialized = ProcessInfo.processInfo.systemUptime
        let sequence = object["diag_seq"] as? Int
        let stream = object["diag_stream"] as? Int ?? 0
        let session = diagnosticSession
        if sequence != nil { diagnosticInFlight += 1 }
        let context = datagram ? NWConnection.ContentContext.defaultMessage
            : NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak connection] error in
            if let self, let connection, (self.connection === connection || self.motionConnection === connection), let sequence,
               self.diagnosticActive, self.diagnosticSession == session {
                self.diagnosticInFlight = max(0, self.diagnosticInFlight - 1)
                if self.diagnosticCompletions.count < 256 {
                    self.diagnosticCompletions.append(["seq": Double(sequence), "stream": Double(stream), "started_s": started,
                        "completed_s": ProcessInfo.processInfo.systemUptime,
                        "serialization_ms": (serialized - started) * 1000])
                }
            }
            if datagram, let self, let connection, self.motionConnection === connection {
                self.motionSending = false
                if error != nil { self.closeMotionTransport() }
                else if let latest = self.pendingMotion {
                    self.pendingMotion = nil; self.sendMotion(latest, on: connection)
                }
            } else if let error, let connection {
                self?.recordPairingAttemptFailure(error)
                self?.dropConnection(connection)
            }
        })
    }
}

@MainActor
private final class CursorVisibilityBackgroundTask {
    private var task: UIBackgroundTaskIdentifier = .invalid
    init() {
        task = UIApplication.shared.beginBackgroundTask(withName: "MacRemote.cursorVisibility") { [weak self] in self?.finish() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.finish() }
    }
    func finish() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task); task = .invalid
    }
}

private enum TLS {
    static func pskOptions(_ secret: Data, datagram: Bool = false) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        if datagram {
            sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .DTLSv12)
            sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .DTLSv12)
        }
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A9)!)
        let psk: dispatch_data_t = secret.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        let identityBytes = Data("macremote".utf8)
        let identity: dispatch_data_t = identityBytes.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, psk, identity)
        return options
    }
}
