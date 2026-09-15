import Foundation
import SwiftUI
@testable import Core
@testable import Features

// MARK: - Labels

/// One label per element and per end of the transition, so a count answers
/// "was the card for item 2 mounted?" rather than "did something appear?".
enum HeroProbeLabel {
    static func cell(_ id: Int) -> String { "hero-cell:\(id)" }
    static func card(_ id: Int) -> String { "hero-card:\(id)" }
}

// MARK: - Selection

/// What the test drives, and what ``HeroScope`` binds to.
///
/// An `@Observable` class rather than a `@State` inside the harness, because
/// the mutation has to come from outside the view tree: a test that could only
/// change the selection by tapping would be measuring `onTapGesture` rather
/// than the transition.
@Observable
@MainActor
final class HeroSelection {
    var expanded: Int?

    init(expanded: Int? = nil) {
        self.expanded = expanded
    }
}

// MARK: - Harness

/// A column of cells and the card that grows out of one of them.
///
/// Both ends record an *appearance* rather than an evaluation, which is the
/// distinction the suite rests on: `onAppear` fires once per mount and not
/// again while a view stays mounted, so a collection that is rebuilt on every
/// body evaluation still reports one, and a collection that is torn down and
/// remade reports two.
struct HeroProbeHarness: View {
    @Bindable var selection: HeroSelection
    let ledger: BodyEvaluationLedger
    let ids: [Int]

    var body: some View {
        HeroScope(expanded: $selection.expanded) { proxy in
            VStack(spacing: 8) {
                ForEach(ids, id: \.self) { id in
                    AppearanceCountingRow(label: HeroProbeLabel.cell(id), ledger: ledger)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(Color.gray.opacity(0.2))
                        .heroSource(id, in: proxy)
                }
            }
            .padding(16)
        } detail: { id, proxy in
            AppearanceCountingRow(label: HeroProbeLabel.card(id), ledger: ledger)
                .frame(width: 280, height: 360)
                .background(Color.gray.opacity(0.6))
                .heroDestination(id, in: proxy)
        }
    }
}
