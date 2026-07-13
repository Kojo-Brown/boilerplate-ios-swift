import SwiftUI

// MARK: - LayoutContext

/// Resolved layout context combining both size-class axes with the physical geometry.
///
/// Injected into the environment by `AdaptiveContainer` and available via
/// `@Environment(\.layoutContext)`.
struct LayoutContext: Equatable {
    let horizontal: UserInterfaceSizeClass
    let vertical: UserInterfaceSizeClass
    let size: CGSize

    var isCompact: Bool { horizontal == .compact }
    var isRegular: Bool { horizontal == .regular }
    var isLandscape: Bool { size.width > size.height }

    /// Preferred grid column count derived from size class and orientation.
    var preferredColumnCount: Int {
        switch (horizontal, isLandscape) {
        case (.regular, true):  4
        case (.regular, false): 3
        case (.compact, true):  3
        default:                2
        }
    }
}

// MARK: - AdaptiveStack

/// A layout container that switches between `HStack` (regular width) and
/// `VStack` (compact width) based on the horizontal size class.
///
/// Usage:
/// ```swift
/// AdaptiveStack(spacing: 16) {
///     ProfileCard()
///     StatsCard()
/// }
/// // → HStack on iPad, VStack on iPhone
/// ```
struct AdaptiveStack<Content: View>: View {
    let alignment: Alignment
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(
        alignment: Alignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: alignment.vertical, spacing: spacing, content: content)
        } else {
            VStack(alignment: alignment.horizontal, spacing: spacing, content: content)
        }
    }
}

// MARK: - AdaptiveGrid

/// A scrollable lazy grid that adapts its column count to the horizontal size class
/// and the available width measured via `GeometryReader`.
///
/// Usage:
/// ```swift
/// AdaptiveGrid(items, minColumnWidth: 180) { item in
///     ItemCard(item: item)
/// }
/// // → 2 columns on iPhone, 3-4 on iPad
/// ```
struct AdaptiveGrid<Data: RandomAccessCollection, Content: View>: View
where Data.Element: Identifiable {
    let data: Data
    let spacing: CGFloat
    let minColumnWidth: CGFloat
    @ViewBuilder let content: (Data.Element) -> Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(
        _ data: Data,
        spacing: CGFloat = 16,
        minColumnWidth: CGFloat = 160,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.spacing = spacing
        self.minColumnWidth = minColumnWidth
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let columnCount = resolvedColumnCount(for: proxy.size)
            let columns = Array(
                repeating: GridItem(.flexible(minimum: minColumnWidth), spacing: spacing),
                count: columnCount
            )
            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(data) { item in
                        content(item)
                    }
                }
                .padding(spacing)
            }
        }
    }

    // MARK: - Private

    private func resolvedColumnCount(for size: CGSize) -> Int {
        let context = LayoutContext(
            horizontal: horizontalSizeClass ?? .compact,
            vertical: verticalSizeClass ?? .regular,
            size: size
        )
        let widthBased = max(1, Int(size.width / (minColumnWidth + spacing)))
        return min(context.preferredColumnCount, widthBased)
    }
}

// MARK: - AdaptiveContainer

/// A container that reads `GeometryReader` and size-class environment values to
/// produce a `LayoutContext`, passing it to `content` and injecting it into the
/// SwiftUI environment for descendant views.
///
/// Usage:
/// ```swift
/// AdaptiveContainer { ctx in
///     Text(ctx.isRegular ? "iPad layout" : "iPhone layout")
/// }
///
/// // Descendants can read the context:
/// struct ChildView: View {
///     @Environment(\.layoutContext) var ctx
///     var body: some View { Text("Columns: \(ctx.preferredColumnCount)") }
/// }
/// ```
struct AdaptiveContainer<Content: View>: View {
    @ViewBuilder let content: (LayoutContext) -> Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    init(@ViewBuilder content: @escaping (LayoutContext) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let context = LayoutContext(
                horizontal: horizontalSizeClass ?? .compact,
                vertical: verticalSizeClass ?? .regular,
                size: proxy.size
            )
            content(context)
                .environment(\.layoutContext, context)
        }
    }
}

// MARK: - LayoutContext environment key

private struct LayoutContextKey: EnvironmentKey {
    static let defaultValue = LayoutContext(
        horizontal: .compact,
        vertical: .regular,
        size: .zero
    )
}

extension EnvironmentValues {
    /// The `LayoutContext` injected by the nearest `AdaptiveContainer` ancestor.
    /// Falls back to a compact-portrait default when no container is present.
    var layoutContext: LayoutContext {
        get { self[LayoutContextKey.self] }
        set { self[LayoutContextKey.self] = newValue }
    }
}

// MARK: - Previews

private struct SampleItem: Identifiable {
    let id: Int
    let label: String
}

private let sampleItems = (1...12).map { SampleItem(id: $0, label: "Item \($0)") }

#Preview("AdaptiveGrid") {
    AdaptiveGrid(sampleItems) { item in
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(0.15))
            .overlay {
                Text(item.label)
                    .font(.headline)
            }
            .frame(height: 100)
    }
}

#Preview("AdaptiveStack") {
    AdaptiveStack(spacing: 12) {
        RoundedRectangle(cornerRadius: 8).fill(.blue.opacity(0.3)).frame(height: 80)
        RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.3)).frame(height: 80)
        RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.3)).frame(height: 80)
    }
    .padding()
}

#Preview("AdaptiveContainer") {
    AdaptiveContainer { ctx in
        VStack(spacing: 12) {
            Text(ctx.isRegular ? "Regular (iPad)" : "Compact (iPhone)")
                .font(.title2.bold())
            Text("Preferred columns: \(ctx.preferredColumnCount)")
                .foregroundStyle(.secondary)
            Text("Landscape: \(ctx.isLandscape ? "Yes" : "No")")
                .foregroundStyle(.secondary)
            Text("Size: \(Int(ctx.size.width)) × \(Int(ctx.size.height))")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
