import Foundation
import Network
import Security

final class WidgetRemoteCommandSender {
    private let queue = DispatchQueue(label: "MacRemoteWidgets.command")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var timeout: DispatchWorkItem?
    private var continuation: CheckedContinuation<Void, Error>?
    private var message: [String: Any]?
    private let commandID = UUID().uuidString

    static func send(_ action: RemoteWidgetAction) async throws {
        guard let message = action.message else { return }
        let sender = WidgetRemoteCommandSender()
        try await sender.send(message)
    }

    private func send(_ message: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: WidgetCommandError.cancelled)
                    return
                }
                self.continuation = continuation
                self.message = message
                self.start()
            }
        }
    }

    private func start() {
        guard let credentials = WidgetPairingStore.load() else {
            finish(.failure(WidgetCommandError.notPaired))
            return
        }
        let browserParameters = NWParameters(tls: tlsOptions(credentials.secret), tcp: NWProtocolTCP.Options())
        let browser = NWBrowser(for: .bonjour(type: "_macremote._tcp", domain: nil), using: browserParameters)
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, self.browser === browser, self.connection == nil, let result = results.first else { return }
            self.connect(to: result.endpoint, credentials: credentials)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, self.browser === browser else { return }
            if case .failed = state { self.finish(.failure(WidgetCommandError.connectionFailed)) }
        }
        self.browser = browser
        browser.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(WidgetCommandError.timedOut)) }
        timeout = deadline
        queue.asyncAfter(deadline: .now() + 5, execute: deadline)
    }

    private func connect(to endpoint: NWEndpoint, credentials: WidgetPairingStore.Credentials) {
        let parameters = NWParameters(tls: tlsOptions(credentials.secret), tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready:
                self.timeout?.cancel(); self.timeout = nil
                self.browser?.cancel(); self.browser = nil
                self.receiveAcknowledgement(on: connection)
                self.sendMessage(on: connection, credential: credentials.credential)
            case .failed, .cancelled:
                self.finish(.failure(WidgetCommandError.connectionFailed))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func sendMessage(on connection: NWConnection, credential: Data) {
        guard var message else {
            finish(.failure(WidgetCommandError.encodingFailed))
            return
        }
        message["widget_command_id"] = commandID
        message["credential"] = credential.base64EncodedString()
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            finish(.failure(WidgetCommandError.encodingFailed))
            return
        }
        let context = NWConnection.ContentContext(identifier: "widget-command", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self else { return }
                if error != nil { self.finish(.failure(WidgetCommandError.connectionFailed)) }
            }
        })
    }

    private func receiveAcknowledgement(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }
            self.queue.async {
                if let data,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   object["type"] as? String == "widget_ack",
                   object["widget_command_id"] as? String == self.commandID {
                    self.finish(.success(()))
                } else if error != nil {
                    self.finish(.failure(WidgetCommandError.connectionFailed))
                } else {
                    self.receiveAcknowledgement(on: connection)
                }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
        message = nil
        continuation.resume(with: result)
    }

    private func tlsOptions(_ secret: Data) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A9)!)
        let psk: dispatch_data_t = secret.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        let identity = Data("macremote".utf8).withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, psk, identity)
        return options
    }
}

private enum WidgetCommandError: Error {
    case notPaired, connectionFailed, timedOut, encodingFailed, cancelled
}

private extension RemoteWidgetAction {
    var message: [String: Any]? {
        switch self {
        case .sleep: return ["type": "sleep"]
        case .previous: return ["type": "media", "action": "previous"]
        case .playPause: return ["type": "media", "action": "play_pause"]
        case .next: return ["type": "media", "action": "next"]
        case .mute: return ["type": "media", "action": "mute"]
        case .fullscreen: return ["type": "fullscreen"]
        case .volumeUp: return ["type": "media", "action": "volume_up"]
        case .volumeDown: return ["type": "media", "action": "volume_down"]
        case .brightnessUp: return ["type": "media", "action": "brightness_up"]
        case .brightnessDown: return ["type": "media", "action": "brightness_down"]
        }
    }
}

private enum WidgetPairingStore {
    private static let service = "MacRemotePSK"
    struct Credentials: Codable { let transportSecret: Data; let deviceCredential: Data
        var secret: Data { transportSecret }; var credential: Data { deviceCredential }
    }
    static func load() -> Credentials? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MacRemoteKeychainAccessGroup") as? String else { return nil }
        var output: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccessGroup: group, kSecReturnData: true]
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
              let data = output as? Data,
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              credentials.transportSecret.count == 32, credentials.deviceCredential.count == 32 else { return nil }
        return credentials
    }
}
