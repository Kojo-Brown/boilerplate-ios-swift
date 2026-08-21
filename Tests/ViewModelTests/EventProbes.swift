import Foundation
@testable import BoilerplateiOSSwift

// MARK: - Draining a subscription

/// Everything left on `stream`, read to the end.
///
/// **The bus must already have been finished.** `EventBus.finish()` ends every
/// live subscription, which is what lets this `for await` return instead of
/// waiting for an event that is never coming. Calling it on a live subscription
/// hangs, exactly as `for await` on any open stream does.
///
/// That precondition is the reason this is spelled as "finish, then drain"
/// rather than as "await the next event with a timeout". A deadline would let a
/// test pass while the bus was merely slow, and would turn every assertion into
/// a question about how long is long enough. Finishing first makes the drain
/// total: what comes back is everything that was published to that subscription,
/// in order, and an empty array means nothing was — not that nothing had arrived
/// yet.
func collect<Event: AppEvent>(from stream: AsyncStream<Event>) async -> [Event] {
    var received: [Event] = []
    for await event in stream {
        received.append(event)
    }
    return received
}
