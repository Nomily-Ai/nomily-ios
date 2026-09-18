import Foundation

/// Single-consumer FIFO of inbound BLE notification frames with timeout-aware
/// async pop.
///
/// Thread-safe. Only one waiter at a time is supported: one outstanding
/// request per logical channel.
final class NotifyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?

    func push(_ data: Data) {
        lock.lock()
        if let cont = waiter {
            waiter = nil
            lock.unlock()
            cont.resume(returning: data)
        } else {
            buffer.append(data)
            lock.unlock()
        }
    }

    func drain() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    /// Fail any pending waiter and clear the buffer. Called when the
    /// peripheral disconnects so in-flight `recv()`s don't hang forever.
    func failAll(with error: Error) {
        lock.lock()
        let cont = waiter
        waiter = nil
        buffer.removeAll()
        lock.unlock()
        cont?.resume(throwing: error)
    }

    /// Pop the next frame, raising `DnoteError.timeout` if nothing arrives
    /// within `timeout` seconds.
    func pop(timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.popUnbounded() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw DnoteError.timeout
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                // If the timeout fired first, abandon the waiter so the next
                // arriving frame becomes a buffered item (instead of resuming
                // a continuation we no longer care about).
                self.cancelWaiter()
                throw error
            }
        }
    }

    private func popUnbounded() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            if !buffer.isEmpty {
                let item = buffer.removeFirst()
                lock.unlock()
                cont.resume(returning: item)
                return
            }
            // Replace any stale waiter (cancelled by an earlier timeout).
            if let stale = waiter {
                waiter = nil
                lock.unlock()
                stale.resume(throwing: CancellationError())
                lock.lock()
            }
            waiter = cont
            lock.unlock()
        }
    }

    private func cancelWaiter() {
        lock.lock()
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }
}
