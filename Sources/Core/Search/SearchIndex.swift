import Foundation

/// A corpus whose searchable text has already been folded, so that matching a
/// query is a substring test rather than a locale-aware collation.
///
/// ## The hotspot this replaces
///
/// The home screen filtered like this, which is the shape almost every
/// SwiftUI list starts with:
///
/// ```swift
/// var filteredItems: [Item] {
///     items.filter {
///         $0.title.localizedCaseInsensitiveContains(query)
///             || $0.subtitle.localizedCaseInsensitiveContains(query)
///     }
/// }
/// ```
///
/// Two costs are hiding in it, and neither is visible in the source.
///
/// **Per comparison.** `localizedCaseInsensitiveContains` is a *collation*: it
/// resolves the current locale, and asks ICU for a case-insensitive search
/// under that locale's rules, for every element, on every call. In a Time
/// Profiler trace of a keystroke this is a tower of `CFStringFindWithOptions`
/// and locale lookups under the getter, on the main thread, between the touch
/// and the frame.
///
/// **Per call.** It is a computed property, so it does the whole pass again
/// every time anything reads it — and `HomeView.content` reads it up to four
/// times in a single body evaluation. See ``MemoizedSearch`` for that half.
///
/// This type fixes the first cost by moving the locale-sensitive work to where
/// the corpus changes instead of where it is read: each key is folded once,
/// case and diacritics and full-width forms collapsed, and a query folded the
/// same way matches with a plain substring test.
///
/// ## What that changes about matching
///
/// Folding is not the same predicate, and the difference is deliberate rather
/// than incidental:
///
/// * **Case**, as before — `"item"` matches `"Item 3"`.
/// * **Diacritics**, which is new — `"cafe"` now matches `"Café"`, and so does
///   `"café"`. For a search field this is the behaviour a user expects and the
///   one they cannot get from a keyboard that has no `é` on it.
/// * **Full-width forms**, which is new and matters for CJK input — the
///   full-width `"Ａ"` a Japanese IME produces matches `"A"`.
///
/// Keys are normalised to their precomposed form after folding, so `"é"`
/// typed as one code point and `"é"` typed as `e` plus a combining accent fold
/// to the same key. Without that step the two would differ as `Character`
/// sequences and the substring test would miss.
///
/// ## Why it is `Sendable`
///
/// Folding a corpus is pure, proportional to its size, and exactly the kind of
/// work that turns into a hang when a screen does it on the main actor with
/// ten thousand rows. This type carries nothing isolated, so
/// `OffMainActor.run { SearchIndex(rows, keys: …) }` is all it takes to move a
/// build off the main thread — see `docs/profiling.md`. Ten rows do not need
/// it, which is why `HomeViewModel` builds inline and says so.
package struct SearchIndex<Element: Sendable>: Sendable {

    /// The corpus, in the order it was given.
    package let elements: [Element]

    /// `keys[i]` is the folded searchable text of `elements[i]`.
    private let keys: [[String]]

    private let locale: Locale?
    private let ledger: SearchWorkLedger?

    /// Folds `elements` into search keys.
    ///
    /// - Parameters:
    ///   - elements: The corpus to index.
    ///   - locale: The locale whose case-folding rules apply. Defaulted to the
    ///     current one and captured *once*, rather than read per comparison as
    ///     `localizedCaseInsensitiveContains` does. It is a parameter at all
    ///     because case folding is locale-dependent in ways that surprise
    ///     people — Turkish `"I"` folds to `"ı"`, not `"i"` — and a test that
    ///     wants a stable answer has to be able to say which rules it means.
    ///   - ledger: Optional. Counts the work, for the tests that assert how
    ///     much of it there is.
    ///   - searchableText: The strings an element can be found by. Not stored:
    ///     it is called once per element here and never again.
    package init(
        _ elements: [Element],
        locale: Locale? = .current,
        ledger: SearchWorkLedger? = nil,
        searchableText: (Element) -> [String]
    ) {
        self.elements = elements
        self.locale = locale
        self.ledger = ledger
        keys = elements.map { element in
            searchableText(element).map { Self.fold($0, locale: locale) }
        }
        ledger?.recordIndexBuild(foldedKeys: keys.reduce(0) { $0 + $1.count })
    }

    private init(
        elements: [Element],
        keys: [[String]],
        locale: Locale?,
        ledger: SearchWorkLedger?
    ) {
        self.elements = elements
        self.keys = keys
        self.locale = locale
        self.ledger = ledger
    }

    /// An index over this corpus plus `newElements`, folding only the new keys.
    ///
    /// The alternative is to rebuild, and rebuilding is how an append becomes
    /// quadratic: a stream that adds one row every few seconds would refold
    /// every row already held, each time, for the life of the screen. That
    /// cost does not show up at ten rows and is the whole frame budget at ten
    /// thousand — which is the general shape of what a profiler is for, and
    /// the reason `HomeViewModel`'s live-update path calls this rather than
    /// `MemoizedSearch.replace(_:)`.
    package func appending(
        _ newElements: [Element],
        searchableText: (Element) -> [String]
    ) -> SearchIndex<Element> {
        let newKeys = newElements.map { element in
            searchableText(element).map { Self.fold($0, locale: locale) }
        }
        ledger?.recordIndexBuild(foldedKeys: newKeys.reduce(0) { $0 + $1.count })
        return SearchIndex(
            elements: elements + newElements,
            keys: keys + newKeys,
            locale: locale,
            ledger: ledger
        )
    }

    /// The elements whose folded keys contain the folded `query`.
    ///
    /// An empty query — and a query that folds to nothing, which is what a
    /// field holding only whitespace-adjacent marks can produce — returns the
    /// whole corpus without comparing anything. That is the state a list is in
    /// almost all of the time, and it should not cost a pass.
    package func matches(_ query: String) -> [Element] {
        guard !query.isEmpty else { return elements }
        let needle = Self.fold(query, locale: locale)
        guard !needle.isEmpty else { return elements }

        var comparisons = 0
        var results: [Element] = []
        results.reserveCapacity(elements.count)

        for index in elements.indices {
            for key in keys[index] {
                comparisons += 1
                if key.contains(needle) {
                    results.append(elements[index])
                    break
                }
            }
        }

        ledger?.recordScan(comparisons: comparisons)
        return results
    }

    /// The folded form of `text`: case, diacritics and width collapsed, then
    /// normalised so that canonically equivalent spellings are one string.
    package static func fold(_ text: String, locale: Locale? = .current) -> String {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .precomposedStringWithCanonicalMapping
    }
}
