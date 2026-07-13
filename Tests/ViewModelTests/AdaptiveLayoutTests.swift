import Testing
import SwiftUI
@testable import BoilerplateiOSSwift

// MARK: - LayoutContext Tests

@MainActor
struct LayoutContextTests {
    @Test func compactHorizontalIsCompact() {
        let ctx = LayoutContext(
            horizontal: .compact,
            vertical: .regular,
            size: CGSize(width: 390, height: 844)
        )
        #expect(ctx.isCompact)
        #expect(!ctx.isRegular)
    }

    @Test func regularHorizontalIsRegular() {
        let ctx = LayoutContext(
            horizontal: .regular,
            vertical: .regular,
            size: CGSize(width: 1024, height: 1366)
        )
        #expect(ctx.isRegular)
        #expect(!ctx.isCompact)
    }

    @Test func portraitIsNotLandscape() {
        let ctx = LayoutContext(
            horizontal: .compact,
            vertical: .regular,
            size: CGSize(width: 390, height: 844)
        )
        #expect(!ctx.isLandscape)
    }

    @Test func landscapeIsDetected() {
        let ctx = LayoutContext(
            horizontal: .compact,
            vertical: .compact,
            size: CGSize(width: 844, height: 390)
        )
        #expect(ctx.isLandscape)
    }

    @Test func squareSizeIsNotLandscape() {
        let ctx = LayoutContext(
            horizontal: .regular,
            vertical: .regular,
            size: CGSize(width: 500, height: 500)
        )
        #expect(!ctx.isLandscape)
    }

    // MARK: - Column counts

    @Test func compactPortraitPrefersTwoColumns() {
        let ctx = LayoutContext(
            horizontal: .compact,
            vertical: .regular,
            size: CGSize(width: 390, height: 844)
        )
        #expect(ctx.preferredColumnCount == 2)
    }

    @Test func regularPortraitPrefersThreeColumns() {
        let ctx = LayoutContext(
            horizontal: .regular,
            vertical: .regular,
            size: CGSize(width: 768, height: 1024)
        )
        #expect(ctx.preferredColumnCount == 3)
    }

    @Test func regularLandscapePrefersFourColumns() {
        let ctx = LayoutContext(
            horizontal: .regular,
            vertical: .compact,
            size: CGSize(width: 1366, height: 1024)
        )
        #expect(ctx.preferredColumnCount == 4)
    }

    @Test func compactLandscapePrefersThreeColumns() {
        let ctx = LayoutContext(
            horizontal: .compact,
            vertical: .compact,
            size: CGSize(width: 844, height: 390)
        )
        #expect(ctx.preferredColumnCount == 3)
    }

    // MARK: - Equatable

    @Test func equalContextsAreEqual() {
        let size = CGSize(width: 390, height: 844)
        let a = LayoutContext(horizontal: .compact, vertical: .regular, size: size)
        let b = LayoutContext(horizontal: .compact, vertical: .regular, size: size)
        #expect(a == b)
    }

    @Test func differentSizesAreUnequal() {
        let a = LayoutContext(
            horizontal: .compact, vertical: .regular,
            size: CGSize(width: 390, height: 844)
        )
        let b = LayoutContext(
            horizontal: .compact, vertical: .regular,
            size: CGSize(width: 430, height: 932)
        )
        #expect(a != b)
    }

    @Test func differentHorizontalSizeClassesAreUnequal() {
        let size = CGSize(width: 768, height: 1024)
        let a = LayoutContext(horizontal: .compact, vertical: .regular, size: size)
        let b = LayoutContext(horizontal: .regular, vertical: .regular, size: size)
        #expect(a != b)
    }

    @Test func differentVerticalSizeClassesAreUnequal() {
        let size = CGSize(width: 390, height: 844)
        let a = LayoutContext(horizontal: .compact, vertical: .regular, size: size)
        let b = LayoutContext(horizontal: .compact, vertical: .compact, size: size)
        #expect(a != b)
    }
}

// MARK: - AdaptiveStack Tests

@MainActor
struct AdaptiveStackTests {
    @Test func defaultAlignmentIsCenter() {
        let sut = AdaptiveStack { Text("A") }
        #expect(sut.alignment == .center)
    }

    @Test func defaultSpacingIsNil() {
        let sut = AdaptiveStack { Text("A") }
        #expect(sut.spacing == nil)
    }

    @Test func customSpacingIsPreserved() {
        let sut = AdaptiveStack(spacing: 20) { Text("A") }
        #expect(sut.spacing == 20)
    }

    @Test func zeroSpacingIsPreserved() {
        let sut = AdaptiveStack(spacing: 0) { Text("A") }
        #expect(sut.spacing == 0)
    }

    @Test func leadingAlignmentIsPreserved() {
        let sut = AdaptiveStack(alignment: .leading) { Text("A") }
        #expect(sut.alignment == .leading)
    }

    @Test func bodyRendersWithSingleChild() {
        let sut = AdaptiveStack { Text("Hello") }
        _ = sut.body
    }

    @Test func bodyRendersWithMultipleChildren() {
        let sut = AdaptiveStack(spacing: 8) {
            Text("First")
            Text("Second")
            Text("Third")
        }
        _ = sut.body
    }

    @Test func bodyRendersWithCustomAlignment() {
        let sut = AdaptiveStack(alignment: .trailing, spacing: 16) {
            Image(systemName: "star")
            Text("Starred")
        }
        _ = sut.body
    }
}

// MARK: - AdaptiveGrid Tests

@MainActor
struct AdaptiveGridTests {
    private struct Item: Identifiable {
        let id: Int
        let name: String
    }

    @Test func defaultSpacingIsSixteen() {
        let sut = AdaptiveGrid([Item(id: 1, name: "A")]) { item in Text(item.name) }
        #expect(sut.spacing == 16)
    }

    @Test func defaultMinColumnWidthIsOneSixty() {
        let sut = AdaptiveGrid([Item(id: 1, name: "A")]) { item in Text(item.name) }
        #expect(sut.minColumnWidth == 160)
    }

    @Test func customSpacingIsPreserved() {
        let sut = AdaptiveGrid([Item(id: 1, name: "A")], spacing: 24) { item in Text(item.name) }
        #expect(sut.spacing == 24)
    }

    @Test func customMinColumnWidthIsPreserved() {
        let sut = AdaptiveGrid([Item(id: 1, name: "A")], minColumnWidth: 200) { item in Text(item.name) }
        #expect(sut.minColumnWidth == 200)
    }

    @Test func bodyRendersWithItems() {
        let items = (1...6).map { Item(id: $0, name: "Item \($0)") }
        let sut = AdaptiveGrid(items) { item in
            Text(item.name)
        }
        _ = sut.body
    }

    @Test func bodyRendersWithEmptyData() {
        let sut = AdaptiveGrid([Item]()) { item in Text(item.name) }
        _ = sut.body
    }

    @Test func bodyRendersWithCustomSpacing() {
        let items = [Item(id: 1, name: "Solo")]
        let sut = AdaptiveGrid(items, spacing: 32, minColumnWidth: 120) { item in
            RoundedRectangle(cornerRadius: 8).frame(height: 80)
        }
        _ = sut.body
    }
}

// MARK: - AdaptiveContainer Tests

@MainActor
struct AdaptiveContainerTests {
    @Test func bodyRendersWithoutCrash() {
        let sut = AdaptiveContainer { ctx in
            Text(ctx.isRegular ? "iPad" : "iPhone")
        }
        _ = sut.body
    }

    @Test func bodyRendersWithContextInspection() {
        let sut = AdaptiveContainer { ctx in
            VStack {
                Text("Columns: \(ctx.preferredColumnCount)")
                Text("Landscape: \(ctx.isLandscape ? "Yes" : "No")")
            }
        }
        _ = sut.body
    }

    @Test func bodyRendersWithNestedGrid() {
        struct InnerItem: Identifiable { let id: Int }
        let items = (1...4).map { InnerItem(id: $0) }
        let sut = AdaptiveContainer { ctx in
            let columns = Array(
                repeating: GridItem(.flexible()),
                count: ctx.preferredColumnCount
            )
            LazyVGrid(columns: columns) {
                ForEach(items) { item in
                    Text("\(item.id)")
                }
            }
        }
        _ = sut.body
    }
}

// MARK: - LayoutContext environment key Tests

@MainActor
struct LayoutContextEnvironmentTests {
    @Test func defaultEnvironmentLayoutContextIsCompact() {
        var env = EnvironmentValues()
        let ctx = env.layoutContext
        #expect(ctx.isCompact)
        #expect(!ctx.isRegular)
    }

    @Test func defaultEnvironmentLayoutContextHasZeroSize() {
        let env = EnvironmentValues()
        #expect(env.layoutContext.size == .zero)
    }

    @Test func settingLayoutContextRoundTrips() {
        var env = EnvironmentValues()
        let expected = LayoutContext(
            horizontal: .regular,
            vertical: .regular,
            size: CGSize(width: 1024, height: 1366)
        )
        env.layoutContext = expected
        #expect(env.layoutContext == expected)
    }
}
