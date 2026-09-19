import Core
import SwiftUI

// MARK: - Panel

/// The recognized text, one stop per block, with a rotor over the blocks.
///
/// This was a single `Text(result.fullText)` — every block Vision found,
/// joined with newlines into one string — and that is the shape of the problem
/// the rotor exists for. A paragraph is one accessibility element however long
/// it is, so a receipt with forty lines on it was one swipe that read for a
/// minute and a half with no way to stop part-way, go back a line, or skip to
/// the total. Sighted readers were not reading it that way; their eyes jump
/// between lines, and nothing in the tree offered the same jump.
///
/// Two changes, and they are a pair:
///
/// * **One `Text` per block.** That is what makes each block its own element,
///   so swiping moves block by block and each one can be read, re-read or
///   skipped on its own. Visually it is the same paragraph — the blocks were
///   already newline-separated — drawn as a stack instead of a string.
/// * **A rotor over the same blocks.** Swiping is linear; the rotor is the
///   random access. With "Text blocks" chosen, flicking up and down moves
///   between them from anywhere on the screen, which is the same affordance
///   VoiceOver's built-in Headings rotor gives a web page.
///
/// The rotor's entries are matched to the rendered views by `Identifiable`
/// conformance, which is why they are the *same* array the `ForEach` walks
/// rather than a mapped copy: a rotor entry whose id is in no `ForEach` is an
/// entry VoiceOver cannot move to.
struct RecognizedTextPanel: View {

    let result: RecognitionResult

    var body: some View {
        ScrollView {
            content
                .padding()
        }
        .accessibilityRotor(
            Text(FeatureStrings.TextScanner.rotorName),
            entries: result.blocks,
            entryLabel: \.text
        )
    }

    // MARK: - Private

    /// The fallback is not decoration. ``RecognitionResult`` carries its blocks
    /// and its joined text as two stored properties, so a result whose text was
    /// set without its blocks — a stub, a future decoder — would otherwise
    /// render an empty panel. It renders the string it does have, as the one
    /// element it can be.
    @ViewBuilder
    private var content: some View {
        if result.blocks.isEmpty {
            Text(result.fullText)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.blocks) { block in
                    Text(block.text)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Heading

/// How many blocks the pass found, and the heading of the results panel.
///
/// The trait is what puts it on VoiceOver's Headings rotor, which is the
/// difference between reaching the results by swiping past the camera controls
/// every time and flicking straight to them. It is a heading rather than plain
/// text for the same reason `<h2>` is not `<p>`: the sentence is what the
/// section is called, and a reader who wants the section wants to skip to it.
///
/// Its own view because the screen composes it into a row with two buttons, and
/// because the count and its pluralisation are the one part of this heading
/// with a decision in it.
struct RecognizedTextHeading: View {

    let blockCount: Int

    var body: some View {
        Label(title, systemImage: "text.viewfinder")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// The count and its plural form, from the catalog.
    ///
    /// This was `"\(blockCount) block\(blockCount == 1 ? "" : "s") detected"`,
    /// which is English's plural rule written in Swift — and English is the
    /// language with the fewest categories to get wrong. Russian needs three
    /// forms and picks between them on the last *two* digits; Arabic needs six
    /// and has a form for exactly two. No ternary reaches that, which is why
    /// the rule belongs in the catalog's `variations.plural` block and not
    /// here. Note also that a translator never sees this sentence otherwise:
    /// it is assembled at runtime out of fragments, so there is no string to
    /// send them.
    private var title: String {
        FeatureStrings.TextScanner.blocksDetected(blockCount).string
    }
}

// MARK: - Previews

#Preview("Several blocks") {
    RecognizedTextPanel(result: RecognitionResult.previewReceipt)
        .frame(maxHeight: 180)
        .background(.regularMaterial)
        .padding()
}

#Preview("At an accessibility text size") {
    RecognizedTextPanel(result: RecognitionResult.previewReceipt)
        .frame(maxHeight: 180)
        .background(.regularMaterial)
        .padding()
        .dynamicTypeSize(.accessibility3)
}

// MARK: - Preview support

extension RecognitionResult {

    /// Enough blocks that reading them as one paragraph is visibly the wrong
    /// shape, which is what the rotor is for.
    static var previewReceipt: RecognitionResult {
        let lines = [
            "CORNER STORE",
            "12 Rue Lafayette",
            "Flat white 3.40",
            "Almond croissant 2.95",
            "Total 6.35",
        ]
        let blocks = lines.enumerated().map { index, line in
            RecognizedTextBlock(
                text: line,
                normalizedFrame: CGRect(
                    x: 0.1,
                    y: 0.1 + (Double(index) * 0.12),
                    width: 0.8,
                    height: 0.1
                )
            )
        }
        return RecognitionResult(
            fullText: lines.joined(separator: "\n"),
            blocks: blocks
        )
    }
}
