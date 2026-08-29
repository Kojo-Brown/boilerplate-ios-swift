import BackgroundTasks
import Foundation

// MARK: - Constraints

/// The conditions a background task will not be launched without.
///
/// Both of these are `BGProcessingTaskRequest` properties, and that is not an
/// implementation detail leaking through — it is the whole reason `kind` below
/// is an enum rather than a `Bool`. `BGAppRefreshTaskRequest` has exactly one
/// knob, `earliestBeginDate`, and no way to say "only on Wi-Fi" or "only on the
/// charger". A type that offered constraints on every request would be
/// advertising a guarantee the system never made for two thirds of its cases.
///
/// ## What the system does with them
///
/// `requiresNetworkConnectivity` is the one that changes the *shape* of the
/// work rather than merely its timing. Without it a processing task can be
/// launched with the radio down, so the handler has to treat "offline" as an
/// ordinary outcome and reschedule; with it, the launch is held until there is
/// a connection, and a run that starts is a run that had one. It also opts the
/// task into being killed when connectivity drops mid-run, which is why the
/// handler still cannot assume it will finish.
///
/// `requiresExternalPower` is much stronger, and much slower: it holds the task
/// until the device is plugged in, which on a phone that charges overnight
/// means once a day. Use it for work that would be rude on battery — a bulk
/// media re-encode, a full re-index — and not for a poll, where the cost of
/// waiting for a charger is that the feature silently stops working for anyone
/// who charges from a laptop during the day.
package struct BackgroundRefreshConstraints: Sendable, Equatable {

    /// Hold the launch until the device has a network connection.
    package let requiresNetworkConnectivity: Bool

    /// Hold the launch until the device is connected to external power.
    package let requiresExternalPower: Bool

    package init(
        requiresNetworkConnectivity: Bool = false,
        requiresExternalPower: Bool = false
    ) {
        self.requiresNetworkConnectivity = requiresNetworkConnectivity
        self.requiresExternalPower = requiresExternalPower
    }

    /// Launch whenever the system is willing, with no preconditions.
    package static let unconstrained = BackgroundRefreshConstraints()

    /// The constraint set for work that has to reach the API: a connection, but
    /// not a charger.
    package static let networkOnly = BackgroundRefreshConstraints(
        requiresNetworkConnectivity: true
    )
}

// MARK: - Which flavour of task

/// The two kinds of background launch this package models, which are the two
/// `BGTaskRequest` subclasses that matter to an app.
package enum BackgroundRefreshKind: Sendable, Equatable {

    /// A short opportunistic wake — `BGAppRefreshTaskRequest`.
    ///
    /// Budgeted in tens of seconds and scheduled against the system's model of
    /// when the app is normally used, so it is the right shape for "top up the
    /// data the app opens on". It carries no constraints, so a handler must
    /// assume it can be launched with no route to the network.
    case appRefresh

    /// A longer, deferrable run — `BGProcessingTaskRequest`.
    ///
    /// Minutes rather than seconds, launched when the system considers the
    /// device idle, and the only kind that can state preconditions. The cost is
    /// latency: a constrained processing task can wait hours for the conditions
    /// it asked for, so it is the wrong tool for anything a person would notice
    /// the absence of.
    case processing(BackgroundRefreshConstraints)
}

// MARK: - The request

/// What the app asks the system to launch, and when it may start.
///
/// A value type rather than a `BGTaskRequest`, for the same reason
/// `SyncStrategy` exists rather than a `Bool` on the repository: the decision
/// of *what to ask for* is policy, and policy that can only be expressed by
/// constructing a framework object is policy that can only be tested by owning
/// one. `BGTaskScheduler.submit` requires the `BGTaskSchedulerPermittedIdentifiers`
/// entitlement and an app to be entitled — a unit-test bundle has neither — so
/// a design that decides its constraints inline inside a call to `submit` is a
/// design where the constraint logic is unreachable from any test.
///
/// The translation to the framework's own type is `systemRequest()`, which is
/// where the asymmetry above becomes code, and which is checked directly by
/// `BackgroundRefreshTests` because building a `BGTaskRequest` needs no
/// entitlement — only submitting one does.
package struct BackgroundRefreshRequest: Sendable, Equatable {

    /// The reverse-DNS identifier the task is registered and launched under.
    ///
    /// It must also appear in the app's `BGTaskSchedulerPermittedIdentifiers`
    /// array; the system raises rather than returns an error when it does not,
    /// which is a crash on the first `submit` of a build whose Info.plist was
    /// not updated. See `docs/background-refresh.md`.
    package let identifier: String

    /// Which `BGTaskRequest` subclass this becomes, and its constraints.
    package let kind: BackgroundRefreshKind

    /// The earliest the system may launch the task.
    ///
    /// A floor, never a schedule: the system decides the actual moment from
    /// budget, usage patterns and Low Power Mode, and "not before" is the only
    /// part of the timing an app gets to state. `nil` means "as soon as the
    /// system is willing".
    package let earliestBeginDate: Date?

    package init(
        identifier: String,
        kind: BackgroundRefreshKind,
        earliestBeginDate: Date?
    ) {
        self.identifier = identifier
        self.kind = kind
        self.earliestBeginDate = earliestBeginDate
    }

    /// The framework request this describes.
    ///
    /// The `switch` is the asymmetry documented on `BackgroundRefreshConstraints`
    /// made explicit: an app-refresh request has nowhere to put a constraint, so
    /// there is no branch here that quietly drops one — `.appRefresh` cannot
    /// carry constraints in the first place.
    package func systemRequest() -> BGTaskRequest {
        let request: BGTaskRequest
        switch kind {
        case .appRefresh:
            request = BGAppRefreshTaskRequest(identifier: identifier)
        case let .processing(constraints):
            let processing = BGProcessingTaskRequest(identifier: identifier)
            processing.requiresNetworkConnectivity = constraints.requiresNetworkConnectivity
            processing.requiresExternalPower = constraints.requiresExternalPower
            request = processing
        }
        request.earliestBeginDate = earliestBeginDate
        return request
    }
}
