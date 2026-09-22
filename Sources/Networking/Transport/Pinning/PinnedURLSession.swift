import Foundation

// MARK: - Building the one session the app uses

extension URLSession {

    /// A session whose server-trust challenges go through `delegate`.
    ///
    /// This is the only place in `Sources/` that constructs a `URLSession`, and
    /// `Tools/assert-pinned-sessions.py` is what keeps it that way. The reason
    /// is the failure mode: an unpinned session is not broken. It resolves,
    /// connects, validates against the system's anchors and returns the right
    /// answer, on every device, in every test, in every review — the only thing
    /// it does not do is the one thing it was added for. Pinning that is
    /// present but not reached is indistinguishable from pinning that is
    /// absent, so "reached" has to be a property something checks rather than a
    /// habit.
    ///
    /// `delegateQueue: nil` lets `URLSession` create its own serial queue for
    /// the callbacks. The delegate is immutable and `Sendable`, so it does not
    /// care which queue it is called on; what it does care about is that the
    /// session holds it strongly until the session is invalidated, which is why
    /// the app builds exactly one of these and keeps it.
    package static func pinned(
        with delegate: CertificatePinningDelegate,
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// The same, building the delegate from a policy.
    ///
    /// The reporter has no default. Under `PinEnforcement.reportOnly` the
    /// reports *are* the feature, and under `enforced` they are the only
    /// account anyone will get of an outage that otherwise presents as the
    /// network being down — so where they go is a decision for the composition
    /// root, in the same way `AppContainer` decides where every other piece of
    /// this app's telemetry goes.
    package static func pinned(
        policy: CertificatePinningPolicy,
        reporter: any PinningReporting,
        configuration: URLSessionConfiguration = .default
    ) -> URLSession {
        pinned(
            with: CertificatePinningDelegate(policy: policy, reporter: reporter),
            configuration: configuration
        )
    }
}
