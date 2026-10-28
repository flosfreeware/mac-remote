import Foundation

// Slow system queries must never execute on the input/network queue. Only one
// read/result can be outstanding, even if a query hangs across several ticks.
final class StatusPoller<Value> {
    private let worker = DispatchQueue(label: "MacRemoteServer.status", qos: .utility)
    private let lock = NSLock()
    private var busy = false
    private var generation = UUID()

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return busy
    }

    // Invalidate results without waiting for an in-progress OS call to return.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID()
    }

    @discardableResult
    func request(deliverOn queue: DispatchQueue, read: @escaping () -> Value,
                 deliver: @escaping (Value) -> Void) -> Bool {
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true
        let token = generation
        lock.unlock()
        worker.async {
            let value = read()
            queue.async {
                self.lock.lock()
                self.busy = false
                let valid = self.generation == token
                self.lock.unlock()
                if valid { deliver(value) }
            }
        }
        return true
    }
}
