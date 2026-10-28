import Foundation
import Network
import Security

// Isolated loopback check: no app secrets, pairing state, or input injection.
@main
struct WebSocketEndpointTests {
    static func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: 0x00A9)!)
        let key = Data(repeating: 42, count: 32).withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        let identity = Data("macremote".utf8).withUnsafeBytes { DispatchData(bytes: $0)._bridgeToObjectiveC() }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, key, identity)
        let parameters = NWParameters(tls: tls, tcp: .init())
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        return parameters
    }

    static func main() throws {
        let queue = DispatchQueue(label: "WebSocketEndpointTests")
        let listening = DispatchSemaphore(value: 0)
        let listener = try NWListener(using: parameters(), on: .any)
        var peers: [NWConnection] = []
        listener.newConnectionHandler = { peer in
            peers.append(peer)
            peer.stateUpdateHandler = { state in
                if case .ready = state {
                    peer.receiveMessage { data, _, _, error in
                        guard let data, error == nil else { return }
                        let context = NWConnection.ContentContext(identifier: "echo", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                        peer.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                    }
                }
            }
            peer.start(queue: queue)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.signal() }
        }
        listener.start(queue: queue)
        precondition(listening.wait(timeout: .now() + 3) == .success)
        for useURL in [false, true] {
            let done = DispatchSemaphore(value: 0)
            let port = listener.port!
            let endpoint: NWEndpoint = useURL
                ? .url(URL(string: "wss://127.0.0.1:\(port.rawValue)/")!)
                : .hostPort(host: .ipv4(.loopback), port: port)
            let connection = NWConnection(to: endpoint, using: parameters())
            var delivered = false
            connection.stateUpdateHandler = { state in
                print("\(useURL ? "URL" : "hostPort"): \(state)")
                switch state {
                case .ready:
                    print("remote endpoint: \(String(describing: connection.currentPath?.remoteEndpoint))")
                    let payload = Data("test-pairing-claim".utf8)
                    connection.receiveMessage { data, _, _, error in
                        delivered = data == payload && error == nil
                        done.signal()
                    }
                    let context = NWConnection.ContentContext(identifier: "claim", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                    connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
                case .failed, .waiting: done.signal()
                default: break
                }
            }
            connection.start(queue: queue)
            precondition(done.wait(timeout: .now() + 3) == .success, "endpoint test completes")
            queue.sync {
                precondition(delivered == useURL, "Only the URL endpoint should complete the secure WebSocket round trip")
                connection.cancel()
            }
            print(useURL ? "PASS: direct IP URL exchanges an encrypted WebSocket message" : "PASS: reproduced bare hostPort failure")
        }
        queue.sync {
            peers.forEach { $0.cancel() }
            listener.cancel()
        }
    }
}
