import Core
import SwiftUI

// MARK: - Chip

/// A single pill-shaped tag, sized to its own label.
///
/// It exists as its own view rather than as a modifier because it is the thing
/// ``FlowLayout`` is for: a chip's width is its text's width plus its padding,
/// nothing rounds it up to a column, and a row of them holds as many as happen
/// to fit. Every other way of laying these out has to decide the widths in
/// advance — see the note on ``FlowLayout`` — and a chip has no width to give
/// until its label has been measured.
///
/// ```swift
/// FlowLayout(spacing: 8, lineSpacing: 8) {
///     ForEach(tags, id: \.self) { TagChip($0) }
/// }
/// ```
package struct TagChip: View {

    private let title: String
    private let isSelected: Bool
    private let action: (() -> Void)?

    /// - Parameter action: `nil` makes the chip a label rather than a control,
    ///   which is the difference between "this article is tagged Swift" and
    ///   "filter by Swift". A chip with no action is not a disabled button: it
    ///   is not a button at all, so VoiceOver does not offer to activate it.
    package init(_ title: String, isSelected: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    package var body: some View {
        if let action {
            Button(action: action) {
                label
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(traits)
        } else {
            label
        }
    }

    // MARK: - Private

    private var traits: AccessibilityTraits {
        var resolved: AccessibilityTraits = .isButton
        if isSelected {
            resolved.formUnion(.isSelected)
        }
        return resolved
    }

    private var label: some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(isSelected ? Color.white : AppColors.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? AppColors.accent : AppColors.secondaryBackground)
            )
            .overlay(
                Capsule()
                    .strokeBorder(AppColors.accent.opacity(isSelected ? 0 : 0.35), lineWidth: 1)
            )
            // `.fixedSize` is the chip's half of the bargain with the flow.
            // `FlowLayout` measures at an unspecified proposal and then places
            // each subview at the size it measured, so a label that would
            // rather wrap than be narrow reports one width and draws at
            // another; pinning it means the width the line breaking used is
            // the width that ends up on screen.
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Preview support

/// The tags the previews below flow. Long enough to wrap at every width a
/// phone has, and deliberately uneven — a flow of equal-width chips is a grid,
/// and would demonstrate nothing a `LazyVGrid` could not.
private let sampleTags = [
    "Swift",
    "SwiftUI",
    "Structured Concurrency",
    "iOS",
    "Layout",
    "Accessibility",
    "Testing",
    "Observation",
    "Core Data",
]

/// The selectable form, which needs state and therefore a view of its own.
private struct TagFilterPreview: View {
    @State private var selected: Set<String> = ["SwiftUI"]

    var body: some View {
        FlowLayout(alignment: .center, spacing: 8, lineSpacing: 8) {
            ForEach(sampleTags, id: \.self) { tag in
                TagChip(tag, isSelected: selected.contains(tag)) {
                    if selected.contains(tag) {
                        selected.remove(tag)
                    } else {
                        selected.insert(tag)
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: - Previews

#Preview("Tags in a flow") {
    FlowLayout(spacing: 8, lineSpacing: 8) {
        ForEach(sampleTags, id: \.self) { tag in
            TagChip(tag)
        }
    }
    .padding()
}

#Preview("Selectable filters") {
    TagFilterPreview()
}

#Preview("Mixed type sizes, baseline aligned") {
    FlowLayout(lineAlignment: .firstBaseline, spacing: 8, lineSpacing: 12) {
        Text("Tagged")
            .font(.largeTitle)
        TagChip("Swift")
        TagChip("SwiftUI")
        Text("and 4 more")
            .font(.caption)
            .foregroundStyle(AppColors.secondaryLabel)
    }
    .padding()
}

#Preview("Narrow container") {
    FlowLayout(spacing: 6, lineSpacing: 6) {
        ForEach(sampleTags, id: \.self) { tag in
            TagChip(tag)
        }
    }
    .frame(width: 160)
    .padding()
}
