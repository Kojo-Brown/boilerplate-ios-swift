import Foundation

/// Wraps a polling operation in a never-ending `AsyncStream`.
///
/// The inner `Task.detached` runs the polling loop on the cooperative thread pool.
/// When the consumer cancels its own `Task`, the `onTermination` handler propagates
/// the cancellation back into the inner task, stopping the poll and finishing the stream.
///
/// Example:
/// ```swift
/// let stream = PollingStream.make(interval: .seconds(30)) {
///     try await apiClient.fetchLatestItems()
/// }
/// for await items in stream {
///     self.items = items
/// }
/// ```
enum PollingStream {
    /// Creates an `AsyncStream<Value>` that re-polls at `interval`.
    /// - Parameters:
    ///   - interval: Time to wait between successive `fetch` calls.
    ///   - fetch: Async throwing closure that produces a value each poll cycle.
    static func make<Value: Sendable>(
        interval: Duration,
        fetch: @Sendable @escaping () async throws -> Value
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let task = Task.detached {
                while !Task.isCancelled {
                    do {
                        let value = try await fetch()
                        continuation.yield(value)
                        try await Task.sleep(for: interval)
                    } catch is CancellationError {
                        break
                    } catch {
                        // Transient errors keep the stream alive; retry after interval
                        try? await Task.sleep(for: interval)
                    }
                }
                continuation.finish()
            }
            // Propagate consumer cancellation into the polling task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
