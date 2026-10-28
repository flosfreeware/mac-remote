import Foundation
import Network
import Security

// Standalone loopback smoke test. Never connects to the real remote server or
// injects input. Tests the same PSK cipher/version as the app's UDP channel.
@main
struct DTLSIntegrationTests {
    static func parameters(_ secret: Data) -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options.securityProtocolOptions, .DTLSv12)
        sec_protocol_options_append_tls_ciphersuite(options.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A9)!)
        let key: dispatch_data_t = secret.withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        let identity: dispatch_data_t = Data("macremote".utf8).withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        sec_protocol_options_add_pre_shared_key(options.securityProtocolOptions, key, identity)
        let parameters = NWParameters(dtls: options, udp: .init())
        parameters.serviceClass = .interactiveVideo
        return parameters
    }
    static func main() throws {
        let queue = DispatchQueue(label: "DTLS.test")
        let secret = Data((0..<32).map(UInt8.init))
        let listener = try NWListener(using: parameters(secret), on: .any)
        let listening = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        let denied = DispatchSemaphore(value: 0)
        var peers: [NWConnection] = []
        var validMessages = 0
        var unexpectedMessages = 0
        var badReady = false
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.signal() }
        }
        listener.newConnectionHandler = { peer in
            peers.append(peer)
            peer.stateUpdateHandler = { state in
                if case .ready = state {
                    peer.receiveMessage { data, _, _, _ in
                        if data == Data("cursor-target".utf8) {
                            validMessages += 1; delivered.signal()
                        } else if data != nil { unexpectedMessages += 1 }
                    }
                }
                if case .failed = state { denied.signal() }
            }
            peer.start(queue: queue)
        }
        listener.start(queue: queue)
        precondition(listening.wait(timeout: .now() + 5) == .success, "listener starts")
        let good = NWConnection(host: "127.0.0.1", port: listener.port!, using: parameters(secret))
        good.stateUpdateHandler = { state in
            if case .ready = state {
                good.send(content: Data("cursor-target".utf8), completion: .contentProcessed { _ in })
            }
        }
        good.start(queue: queue)
        precondition(delivered.wait(timeout: .now() + 5) == .success, "PSK DTLS round trip")
        print("PASS: DTLS 1.2 PSK AES-256-GCM delivers authenticated datagram")

        let bad = NWConnection(host: "127.0.0.1", port: listener.port!, using: parameters(Data(repeating: 99, count: 32)))
        bad.stateUpdateHandler = { state in
            if case .failed = state { denied.signal() }
            if case .ready = state {
                badReady = true
                bad.send(content: Data("wrong-secret".utf8), completion: .contentProcessed { _ in })
            }
        }
        bad.start(queue: queue)
        // DTLS may silently discard a bad-key handshake instead of emitting an
        // immediate failure (UDP has no reliable error delivery).
        _ = denied.wait(timeout: .now() + 3)
        queue.sync {
            precondition(!badReady && validMessages == 1 && unexpectedMessages == 0, "wrong secret cannot complete handshake or inject data")
            good.cancel(); bad.cancel()
            for peer in peers { peer.cancel() }
            listener.cancel()
        }
        print("PASS: wrong PSK did not complete handshake or deliver data during test window")
    }
}
