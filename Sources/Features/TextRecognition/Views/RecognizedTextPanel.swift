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
        .accessibilityRotor(Text("Text blocks"), entries: result.blocks, entryLabel: \.text)
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
/// because a heading with nothing else in it is the smallest thing
/// ``AccessibilityAuditTests`` can mount to check the trait survived.
struct RecognizedTextHeading: View {

    let blockCount: Int

    var body: some View {
        Label(title, systemImage: "text.viewfinder")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var title: String {
        "\(blockCount) block\(blockCount == 1 ? "" : "s") detected"
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
        // Single-spaced on purpose. A run of spaces is how a receipt lines its
        // columns up, and it is also the one thing in a fixture that an
        // assertion on a published label cannot rely on surviving: what a
        // reader hears is normalised, and the string compared against it here
        // should be the string the panel is actually asked to render.
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
