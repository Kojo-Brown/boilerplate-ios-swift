import Foundation

/// Represents the async loading lifecycle shared across ViewModels.
///
/// The failure payload is `any Error & Sendable`, not `any Error`. The bare
/// existential does not conform to `Sendable`, so `case failure(Error)` made
/// every `LoadingState` non-`Sendable` whatever `Value` was — an
/// `AsyncStream<LoadingState<User>>`, or a state handed from a detached task
/// back to a `@MainActor` view model, would not have compiled. Nothing in the
/// package had reached for either yet, which is the only reason this went
/// unnoticed: the type had no call sites at all.
///
/// A `catch` block binds `error` as `any Error`, which does not satisfy the new
/// payload. Errors thrown across an isolation boundary have to be `Sendable`
/// anyway, so the fix at such a site is to name the concrete error type —
/// `catch let error as APIError` — rather than to widen this back.
enum LoadingState<Value> {
    case idle
    case loading
    case success(Value)
    case failure(any Error & Sendable)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var value: Value? {
        if case .success(let value) = self { return value }
        return nil
    }

    var error: (any Error & Sendable)? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Conditional rather than unconditional, so the type stays usable with a
/// non-`Sendable` `Value` — a SwiftUI view state that never leaves the main
/// actor, say — and is `Sendable` exactly when it can be.
extension LoadingState: Sendable where Value: Sendable {}
