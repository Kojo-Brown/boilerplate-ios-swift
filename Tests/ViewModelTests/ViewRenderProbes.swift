import Foundation
import SwiftUI
import UIKit
@testable import Core
@testable import Features

// MARK: - Render harness

/// Hosts a view in a real `UIHostingController` so a test can watch SwiftUI
/// update it, rather than calling `body` by hand.
///
/// `_ = view.body` — what `ComponentPreviewProviderTests` does — proves a body
/// compiles and does not trap, and it is the right tool for that. It cannot be
/// the tool here: calling `body` yourself *is* the evaluation, so every count
/// would be one per call and the question "would SwiftUI have skipped this?"
/// would never be asked. Only the framework can answer that, and it only does
/// so for a tree it is driving.
///
/// The window is what makes the tree a driven one. A hosting controller whose
/// view is in no window lays out on demand but is not part of anything SwiftUI
/// considers on screen, so appearance callbacks never fire and updates have no
/// reason to be flushed. It is not attached to a scene — a package's test
/// bundle has none — which is enough for layout and appearance and is not
/// enough for anything that needs a real display link.
@MainActor
final class RenderHarness<Root: View> {

    /// Retained for the lifetime of the harness: releasing it unhosts the tree
    /// mid-measurement.
    private let window: UIWindow
    private let host: UIHostingController<Root>

    /// Hosts `root` and returns once its first render has happened.
    ///
    /// A factory rather than an initialiser because settling is `async`, and
    /// that is not an implementation detail — see ``settle(for:)``.
    /// - Parameter onScreen: puts the window on a real `UIWindowScene` and makes
    ///   it key, rather than merely unhiding it. Default `false`, which is what
    ///   every body-evaluation suite wants: those measure SwiftUI's work, which
    ///   a laid-out tree in an unhidden window is enough for, and a suite that
    ///   took key-window status would take it from whatever else in the process
    ///   had it.
    ///
    ///   `AccessibilityAuditTests` needs the stronger thing, because the
    ///   accessibility tree is not part of layout. SwiftUI builds its UIKit
    ///   accessibility bridge for a view that is genuinely on a screen, and a
    ///   window with no scene is not on one however laid out it is — which is
    ///   what an empty `accessibilityElements` on a perfectly rendered tree
    ///   turned out to mean.
    static func mount(_ root: Root, onScreen: Bool = false) async -> RenderHarness {
        let harness = RenderHarness(root, onScreen: onScreen)
        await harness.settle()
        return harness
    }

    private init(_ root: Root, onScreen: Bool) {
        let controller = UIHostingController(rootView: root)
        let frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let hostWindow = UIWindow(frame: frame)
        hostWindow.rootViewController = controller

        if onScreen, let scene = Self.foregroundScene {
            // The scene first, then the frame: adopting a scene resizes the
            // window to it, and these harnesses measure against a known width.
            hostWindow.windowScene = scene
            hostWindow.frame = frame
            hostWindow.makeKeyAndVisible()
        } else {
            hostWindow.isHidden = false
        }
        controller.view.frame = frame

        host = controller
        window = hostWindow

        host.view.layoutIfNeeded()
    }

    /// A scene to hang an on-screen window from, if the test host has one.
    ///
    /// It is an `if let` at the call site rather than a precondition because
    /// the absence is not this harness's to fail on: a bundle with no scene
    /// still runs every body-evaluation suite correctly, and the accessibility
    /// suites report the empty tree themselves, with the hierarchy that
    /// produced it.
    private static var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
    }

    /// Gives SwiftUI a chance to apply whatever the last mutation scheduled,
    /// then forces the layout pass that runs the bodies.
    ///
    /// An `@Observable` mutation does not re-render on the spot — it
    /// invalidates and schedules, and the scheduled work runs on the main run
    /// loop. The wait is therefore an `await`, and specifically not
    /// `RunLoop.run(until:)` or a `Task.yield()` loop: both of those hold the
    /// main actor while they wait, and this suite runs in parallel with every
    /// other one in the bundle. `SocialLoginViewModelXCTests` is `@MainActor`
    /// and has been hung into its execution allowance twice already by exactly
    /// that — a test elsewhere in the run pinning the actor it needs (SPEC.md,
    /// Phase 9 item 6). Suspending hands the main actor back, which is both
    /// what lets SwiftUI's transaction run and what keeps the rest of the
    /// bundle moving.
    func settle(for duration: Duration = .milliseconds(50)) async {
        host.view.setNeedsLayout()
        try? await Task.sleep(for: duration)
        host.view.layoutIfNeeded()
    }

    /// The hosted view, for a suite that reads the tree UIKit publishes rather
    /// than counting body evaluations.
    ///
    /// Everything above measures SwiftUI's *work*; `AccessibilityAuditTests`
    /// measures its *output* — the labels, values and traits an assistive
    /// client is handed — and that output only exists once a hosting
    /// controller has laid the tree out inside a window, which is precisely
    /// what this harness already builds.
    var rootView: UIView { host.view }

    /// The size the hosted view asks for, given `proposal`.
    ///
    /// `DynamicTypeTests` measures with this rather than off an accessibility
    /// element's frame, and the independence is the point: whether a control
    /// grows with the reader's text size is a layout question, and answering it
    /// through the accessibility tree would make every one of those assertions
    /// fail for a reason that has nothing to do with Dynamic Type — which is
    /// exactly what happened the first time round.
    func idealSize(fitting proposal: CGSize) -> CGSize {
        host.sizeThatFits(in: proposal)
    }

    /// Takes the window back down.
    ///
    /// A visible `UIWindow` is retained by UIKit, not only by whoever made it,
    /// so without this the harness outlives the test that built it and leaves a
    /// key-window candidate behind for every later test in the process. There
    /// is no `deinit` doing this because a `deinit` cannot touch main-actor
    /// state; `defer { harness.dismount() }` at the call site can.
    func dismount() {
        window.isHidden = true
        window.rootViewController = nil
        // Only ever set by `onScreen`, and clearing it is what hands key-window
        // status back rather than leaving this window holding it for the rest
        // of the process.
        window.windowScene = nil
    }
}

// MARK: - Labels

/// The labels the probes below record under. Naming them once keeps a typo in
/// a test from reading as "this body never ran", which is what an unrecorded
/// label looks like.
enum ProbeLabel {
    static let inline = "inline"
    static let memoized = "memoized"
    static let equatable = "equatable"
    static let stableRow = "stable-row"
    static let rebuiltRow = "rebuilt-row"
}

// MARK: - The state that drives an update

/// One value that changes and one that does not, so a test can invalidate a
/// root body without touching what the subtrees under it are keyed on.
@Observable
@MainActor
final class RenderTicker {
    var tick = 0
    var title = "Original title"

    init() {}
}

// MARK: - Memoisation harness

/// Three ways of building the same subtree, side by side under one root, so a
/// single update measures all three against each other rather than across runs.
///
/// * `inline` is built directly in this body, so it is rebuilt whenever this
///   body runs.
/// * `memoized` is behind ``Memoized``, keyed on the title.
/// * `equatable` is a named `Equatable` view with `.equatable()` applied.
struct MemoisationHarness: View {
    let ticker: RenderTicker
    let ledger: BodyEvaluationLedger

    var body: some View {
        VStack(spacing: 8) {
            Text("tick \(ticker.tick)")

            VStack(spacing: 4) {
                BodyEvaluationProbe(ProbeLabel.inline, into: ledger)
                Text(ticker.title)
            }

            Memoized(ticker.title) { title in
                VStack(spacing: 4) {
                    BodyEvaluationProbe(ProbeLabel.memoized, into: ledger)
                    Text(title)
                }
            }

            CountedEquatableRow(title: ticker.title, ledger: ledger)
                .equatable()
        }
    }
}

/// A named `Equatable` view, shaped like `HomeItemRow`: everything the body
/// renders is in `==`.
///
/// The ledger is the one stored property `==` ignores, and it is the exception
/// that proves the rule — it is the instrument, it is never replaced, and
/// nothing about it is rendered. A value that *was* rendered and left out of
/// `==` would freeze on screen.
///
/// The probe sits in `body` rather than in an initialiser here, because what is
/// being counted is this view's own evaluations — SwiftUI constructs the value
/// on every parent evaluation and then decides, via `==`, whether to run the
/// body.
struct CountedEquatableRow: View, Equatable {
    let title: String
    let ledger: BodyEvaluationLedger

    nonisolated static func == (lhs: CountedEquatableRow, rhs: CountedEquatableRow) -> Bool {
        lhs.title == rhs.title
    }

    var body: some View {
        VStack(spacing: 4) {
            BodyEvaluationProbe(ProbeLabel.equatable, into: ledger)
            Text(title)
        }
    }
}

// MARK: - Identity harness

/// The same row twice: once with the identity SwiftUI infers from its position
/// in this body, and once with an explicit identity tied to a value that keeps
/// changing.
///
/// Nothing about the two rows differs. What differs is what SwiftUI is told
/// they are: the second one is a different view every time `tick` changes, so
/// the framework has no choice but to destroy the old one and mount a new one.
struct IdentityHarness: View {
    let ticker: RenderTicker
    let ledger: BodyEvaluationLedger

    var body: some View {
        VStack(spacing: 8) {
            Text("tick \(ticker.tick)")

            AppearanceCountingRow(label: ProbeLabel.stableRow, ledger: ledger)

            AppearanceCountingRow(label: ProbeLabel.rebuiltRow, ledger: ledger)
                .id(ticker.tick)
        }
    }
}

/// Records once per lifetime rather than once per evaluation.
///
/// `onAppear` fires when a view is mounted and not again while it stays
/// mounted, which makes it the signal for identity specifically: a body that
/// re-runs a hundred times reports one appearance, and a row that is torn down
/// and rebuilt reports two.
struct AppearanceCountingRow: View {
    let label: String
    let ledger: BodyEvaluationLedger

    var body: some View {
        Text(label)
            .onAppear { ledger.record(label) }
    }
}
