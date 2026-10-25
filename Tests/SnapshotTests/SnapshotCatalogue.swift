import SwiftUI
@testable import Core
@testable import Features

// MARK: - Subjects

/// What this gate holds still.
///
/// A list rather than "every view in the package", because a snapshot is only
/// worth taking of something that renders as a pure function of its state.
/// Three kinds of view are deliberately absent, and `docs/snapshot-testing.md`
/// says so in full:
///
/// * anything with an indeterminate `ProgressView` — `LoadingView`,
///   `InlineLoadingView`, `PaginationFooter`, and `AppButton` while it is
///   loading. A spinner is an animation, so its pixels are a function of the
///   clock;
/// * anything platform-backed — `CameraPreviewView`, the Google sign-in
///   button, `NavigationStack` chrome, a `List`. `ImageRenderer` draws
///   SwiftUI's display list and a `UIView` is not in it;
/// * `AppTextField`, in any state. Its resting background is a `Material`,
///   which `ImageRenderer` does not draw — and the error state, which replaces
///   the material with a flat red wash, was in this catalogue until the first
///   recording was looked at: the `TextField` and `SecureField` inside it come
///   out as the renderer's own "cannot draw this" placeholder, a yellow bar
///   with a no-entry sign. Everything around them renders. A golden of that is
///   a picture of the renderer's limits, and committing it would have frozen
///   those limits into the gate.
///
/// The raw values are the subject half of every golden's file name, and
/// `Tools/assert-snapshot-gate.py` checks the directory against this list in
/// both directions — a renamed subject that left its old PNG behind is a
/// golden nothing compares against, which is the quiet way a snapshot suite
/// stops covering what it claims to.
enum SnapshotSubject: String, CaseIterable, Sendable {

    /// The design system's `UIColor`-backed tokens, drawn as swatches and
    /// nothing else.
    ///
    /// This subject is an instrument. Every other one contains text, and text
    /// takes its colour from SwiftUI's own environment, so every other golden
    /// would differ between light and dark even if the `UIColor` tokens were
    /// resolving against the wrong trait collection. Here there is no text:
    /// if these two goldens are identical, `AppColors` is being resolved
    /// light in a dark snapshot. See ``SnapshotRenderer``.
    case semanticColourSwatches = "semantic-colour-swatches"

    case appButtonStyles = "app-button-styles"
    case inlineErrorBanner = "inline-error-banner"
    case tagChipFlow = "tag-chip-flow"

    /// The same chips in a container too narrow for them, which is what
    /// `FlowLayout` exists for: the line breaking is the thing under test, and
    /// it is invisible at a width where everything fits.
    case tagChipFlowNarrow = "tag-chip-flow-narrow"

    case homeItemRow = "home-item-row"
    case homeItemCard = "home-item-card"

    /// The canvas width in points.
    var width: CGFloat {
        switch self {
        case .semanticColourSwatches: 320
        case .tagChipFlowNarrow: 220
        case .appButtonStyles, .inlineErrorBanner, .tagChipFlow: 390
        case .homeItemRow, .homeItemCard: 390
        }
    }

    /// The appearances this subject is recorded in.
    ///
    /// Light and dark for everything, because a design system that only works
    /// in one of them is the normal way this goes wrong. An accessibility type
    /// size for the two subjects where it changes the layout rather than only
    /// the glyph sizes: `AppButton` grows past the 50-point floor
    /// `ScaledControlHeight` gives it, and the banner's sentence wraps onto a
    /// second and third line.
    var appearances: [SnapshotAppearance] {
        switch self {
        case .appButtonStyles, .inlineErrorBanner:
            return [
                SnapshotAppearance(scheme: .light),
                SnapshotAppearance(scheme: .dark),
                SnapshotAppearance(scheme: .light, typeSize: .accessibility3),
            ]
        case .tagChipFlowNarrow:
            return [SnapshotAppearance(scheme: .light)]
        default:
            return [
                SnapshotAppearance(scheme: .light),
                SnapshotAppearance(scheme: .dark),
            ]
        }
    }
}

// MARK: - Catalogue

/// The views themselves.
///
/// Built here rather than taken from the `#Preview` macros or the
/// `PreviewProvider` catalogues next to each component, which was the first
/// idea and is wrong twice over: a `#Preview` body is not addressable from
/// code at all, and a `PreviewProvider` returns a `Group` of variants whose
/// layout outside a preview canvas is not the one anybody sees. A golden has
/// to be a picture of something a reader can point at.
@MainActor
enum SnapshotCatalogue {

    static func view(for subject: SnapshotSubject) -> AnyView {
        switch subject {
        case .semanticColourSwatches: AnyView(semanticColourSwatches)
        case .appButtonStyles: AnyView(appButtonStyles)
        case .inlineErrorBanner: AnyView(inlineErrorBanner)
        case .tagChipFlow: AnyView(tagChips)
        case .tagChipFlowNarrow: AnyView(tagChips)
        case .homeItemRow: AnyView(homeItemRow)
        case .homeItemCard: AnyView(homeItemCard)
        }
    }

    // MARK: - Subjects

    private static var semanticColourSwatches: some View {
        VStack(spacing: 8) {
            swatchRow(AppColors.surface, AppColors.secondaryBackground)
            swatchRow(AppColors.elevatedSurface, AppColors.label)
            swatchRow(AppColors.success, AppColors.warning)
            swatchRow(AppColors.destructive, AppColors.accent)
        }
    }

    private static var appButtonStyles: some View {
        VStack(spacing: 16) {
            AppButton("Sign In") {}
            AppButton("Cancel", style: .secondary) {}
            AppButton("Delete Account", style: .destructive) {}
            AppButton("Sign In", isDisabled: true) {}
        }
    }

    private static var inlineErrorBanner: some View {
        InlineErrorBanner("Incorrect email or password. Please try again.") {}
    }

    private static var tagChips: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(sampleTags, id: \.self) { tag in
                TagChip(tag, isSelected: tag == "SwiftUI")
            }
        }
    }

    private static var homeItemRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeItemRow(item: sampleItem)
            Divider()
            HomeItemRow(item: longSampleItem)
        }
    }

    private static var homeItemCard: some View {
        HomeItemCard(item: longSampleItem)
    }


    // MARK: - Fixtures

    /// Uneven on purpose: a flow of equal-width chips is a grid, and would
    /// demonstrate nothing a `LazyVGrid` could not.
    private static let sampleTags = [
        "Swift",
        "SwiftUI",
        "Structured Concurrency",
        "iOS",
        "Layout",
        "Accessibility",
        "Testing",
    ]

    /// Fixed rather than fresh. The identifier is not drawn, so a `UUID()` here
    /// would change nothing about any golden — and would still leave the next
    /// reader checking whether it does.
    private static let sampleItem = HomeItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000f00d") ?? UUID(),
        title: "Item 1",
        subtitle: "Description for item 1"
    )

    private static let longSampleItem = HomeItem(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000beef") ?? UUID(),
        title: "An item whose title is long enough to wrap onto a second line",
        subtitle: """
            And a subtitle that carries on for long enough to wrap as well, \
            which is the case a one-line fixture never covers.
            """
    )

    private static func swatchRow(_ leading: Color, _ trailing: Color) -> some View {
        HStack(spacing: 8) {
            swatch(leading)
            swatch(trailing)
        }
    }

    private static func swatch(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(color)
            .frame(height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(AppColors.label.opacity(0.25), lineWidth: 1)
            )
    }
}

// MARK: - Cases

/// One golden: a subject in one appearance.
///
/// The file name is derived rather than written down, which is what keeps the
/// catalogue, the directory and the audit talking about the same thing.
struct SnapshotCase: Equatable, Sendable {
    let subject: SnapshotSubject
    let appearance: SnapshotAppearance

    var fileName: String {
        "\(subject.rawValue).\(appearance.fileNameSuffix)"
    }

    static let all: [SnapshotCase] = SnapshotSubject.allCases.flatMap { subject in
        subject.appearances.map { appearance in
            SnapshotCase(subject: subject, appearance: appearance)
        }
    }
}

extension SnapshotSubject {

    /// The subjects recorded in both schemes, which are the ones the
    /// light-versus-dark invariant can be asserted on.
    static let schemePaired: [SnapshotSubject] = allCases.filter { subject in
        let schemes = Set(subject.appearances.map(\.scheme))
        return schemes.contains(.light) && schemes.contains(.dark)
    }

    /// The subjects recorded at an accessibility type size as well as the
    /// standard one.
    static let typeSizePaired: [SnapshotSubject] = allCases.filter { subject in
        let sizes = Set(subject.appearances.map(\.typeSize))
        return sizes.contains(.standard) && sizes.contains(.accessibility3)
    }
}
