import Foundation

// MARK: - The decorator seam

/// A `UserRepository` that adds one behaviour to another `UserRepository`.
///
/// The Decorator, in the form the pattern actually takes when a protocol has
/// been kept narrow: same interface in, same interface out, one concern added,
/// composition decided by whoever builds the graph. `AppContainer` is the only
/// place in this package that decides which wrappers are in the chain and in
/// what order — see `docs/decorators.md`.
///
/// ## Why this exists rather than three unrelated wrappers
///
/// `base` is a requirement, not an implementation detail, because the *order*
/// of the chain is the design and a chain that cannot be walked cannot be
/// pinned. `decoratorChainIsTelemetryOverCacheOverRetry` reads the container's
/// resolved repository and asserts the four names in sequence; without this
/// requirement the only assertable fact would be the outermost type, and every
/// reordering below it — the ones that change what the cache costs and what the
/// telemetry measures — would be invisible to the suite.
///
/// ## What a decorator here may not do
///
/// It may not change the vocabulary of what it throws. `docs/solid.md`
/// finding 4 wants exactly that, and this item deliberately does not do it:
/// `RetryingUserRepository` classifies `APIError.httpError(503)` as worth
/// another attempt and `URLError(.timedOut)` as not, so a translation into
/// `UserRepositoryError`'s three cases underneath it would erase the evidence
/// the policy above it runs on. Translation belongs outside the chain, on an
/// error type designed to carry a cause — which is a change to this package's
/// error vocabulary rather than a wrapper around its repository.
package protocol UserRepositoryDecorator: UserRepository {
    /// The repository this one wraps.
    var base: any UserRepository { get }
}
