import Foundation
import SwiftUI
import Testing

// MARK: - Argument description

extension SnapshotCase: CustomTestStringConvertible {

    /// What Swift Testing prints for this argument, which is also the name of
    /// the file to go and look at.
    var testDescription: String { fileName }
}

// MARK: - The gate

/// Phase 12 item 3: snapshot tests with a CI diff gate.
///
/// What a snapshot test is for here is the class of regression the rest of this
/// bundle cannot see. `DesignSystemTests` asserts that `AppButton` exists and
/// is configured; `AccessibilityAuditTests` asserts that it is labelled;
/// `ViewIdentityTests` asserts that its row does not re-render needlessly. None
/// of them would notice a corner radius going from 12 to 4, a foreground
/// colour resolving white-on-white in dark mode, a padding dropping, or a
/// label clipping at an accessibility type size. Those are defects in the
/// pixels, and the only assertion that holds pixels still is a picture of them.
///
/// What makes it a *gate* rather than a formality is on the other side of this
/// file: the recorded images are committed, `.github/workflows/ci.yml` runs
/// this target on its own pinned-by-provenance simulator job, and
/// `Tools/assert-snapshot-gate.py` holds the committed state to the things a
/// green run cannot see — an orphaned golden, a subject with no golden, and
/// above all record mode being left on somewhere, because a snapshot suite in
/// record mode overwrites the evidence and then passes.
///
/// `.serialized` and the time limit follow the house rule for suites that drive
/// SwiftUI (see `docs/testing.md`). This one needs neither a window nor a run
/// loop turn — `ImageRenderer` is synchronous — but it is main-actor work all
/// the way down, and fifteen renders racing the rest of the bundle for the
/// main actor is how the starvation failures in this repository's history
/// started.
@Suite("Snapshot diff gate", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SnapshotGateTests {

    // MARK: - The diff

    @Test(
        "Every catalogued view still renders the pixels that were recorded",
        arguments: SnapshotCase.all
    )
    func rendersTheRecordedPixels(_ item: SnapshotCase) throws {
        let rendered = try SnapshotRenderer.bitmap(
            of: SnapshotCatalogue.view(for: item.subject),
            width: item.subject.width,
            appearance: item.appearance
        )

        guard !SnapshotStore.isRecording else {
            try record(rendered, as: item)
            return
        }

        guard let recorded = try SnapshotStore.readGolden(named: item.fileName) else {
            let written = try SnapshotStore.writeFailure(
                named: item.fileName,
                expected: nil,
                actual: rendered,
                difference: nil
            )
            Issue.record("""
                \(item.fileName).png has never been recorded, so there is nothing to \
                compare this render against. What it renders today is at \
                \(list(written)). Record it — see docs/snapshot-testing.md — and \
                commit the image after looking at it.
                """)
            return
        }

        let comparison = SnapshotComparison(
            expected: recorded,
            actual: rendered,
            tolerance: .standard
        )

        // A snapshot that is drifting and still passing is worth seeing. The
        // numbers are what a tolerance gets moved against, and a tolerance
        // moved against nothing is a tolerance nobody can defend.
        if let difference = comparison.difference, !difference.isExact {
            print("snapshot drift: \(item.fileName) — \(difference)")
        }

        guard !comparison.passes else { return }

        let overlay = SnapshotBitmap.difference(
            expected: recorded,
            actual: rendered,
            tolerance: .standard
        )
        let written = try SnapshotStore.writeFailure(
            named: item.fileName,
            expected: recorded,
            actual: rendered,
            difference: overlay
        )
        Issue.record("\(failureReport(for: item, comparison: comparison, written: written))")
    }

    // MARK: - What the recorded files have to be true of

    /// The instrument described on ``SnapshotSubject/semanticColourSwatches``,
    /// generalised: a subject recorded in both schemes whose two goldens are
    /// byte-identical was not rendered in two schemes.
    ///
    /// This is the assertion that would have caught the trait-collection trap
    /// in ``SnapshotRenderer`` — a dark snapshot drawn with light colours is
    /// stable, reproducible, and wrong, so the pixel comparison above would
    /// pass it forever.
    @Test(
        "A subject recorded in both schemes has two different pictures",
        .enabled(if: !SnapshotStore.isRecording, "this run is writing the goldens"),
        arguments: SnapshotSubject.schemePaired
    )
    func lightAndDarkGoldensDiffer(_ subject: SnapshotSubject) throws {
        let light = try goldenBitmap(subject, scheme: .light)
        let dark = try goldenBitmap(subject, scheme: .dark)
        let comparison = SnapshotComparison(expected: light, actual: dark, tolerance: .standard)
        #expect(
            !comparison.passes,
            """
            \(subject.rawValue)'s light and dark goldens are the same picture: \
            \(comparison). Either the colour scheme never reached the renderer, \
            or this subject draws nothing that depends on it.
            """
        )

        // The canvas, specifically, and not only the drawing on it. The two
        // can disagree: an environment modifier applies to the subtree under
        // it, so a background attached outside that subtree resolves in the
        // ambient scheme while everything inside resolves correctly. That is
        // not a hypothetical — it is what the first recording did, and the
        // expectation above passed on every subject while it happened, because
        // the difference in the *content* was real. The top-left pixel is
        // inside the canvas padding, so it is background and nothing else.
        #expect(
            light.pixel(x: 0, y: 0) != dark.pixel(x: 0, y: 0),
            """
            \(subject.rawValue) is drawn on the same canvas in both schemes — \
            \(light.pixel(x: 0, y: 0)). The background is resolving outside the \
            environment the rest of the snapshot is rendered in.
            """
        )
    }

    /// Dynamic type is a layout change, not a font change: the controls in this
    /// design system are supposed to grow. A golden recorded at
    /// `.accessibility3` that is no taller than the standard one means the type
    /// size did not reach the render.
    @Test(
        "A subject recorded at an accessibility type size is taller for it",
        .enabled(if: !SnapshotStore.isRecording, "this run is writing the goldens"),
        arguments: SnapshotSubject.typeSizePaired
    )
    func accessibilityGoldensAreTaller(_ subject: SnapshotSubject) throws {
        let standard = try goldenBitmap(subject, scheme: .light)
        let scaled = try goldenBitmap(subject, scheme: .light, typeSize: .accessibility3)
        #expect(
            scaled.extent.height > standard.extent.height,
            """
            \(subject.rawValue) is \(scaled.extent) at accessibility3 and \
            \(standard.extent) at the standard size: the type size changed nothing.
            """
        )
    }

    /// The goldens say what they were recorded against, because a failing
    /// comparison's first question is whether anything in the code moved at
    /// all. A directory of images with no provenance cannot answer it.
    @Test(
        "The recorded goldens carry the environment they were recorded in",
        .enabled(if: !SnapshotStore.isRecording, "this run is writing the goldens")
    )
    func environmentIsRecorded() throws {
        let environment = try #require(
            try SnapshotStore.readEnvironment(),
            "\(SnapshotStore.environmentFileName) is missing from the goldens directory"
        )
        #expect(!environment.iosVersion.isEmpty)
        #expect(environment.renderer == "SwiftUI.ImageRenderer")
        #expect(environment.scale == Double(SnapshotRenderer.scale))

        // The half of the inventory check only this side can make. The audit
        // compares the manifest against the directory; nothing but a compiled
        // test can compare it against the catalogue.
        #expect(
            environment.cases == SnapshotCase.all.map(\.fileName).sorted(),
            """
            the recorded inventory is not the catalogue's: \(environment.cases) \
            against \(SnapshotCase.all.map(\.fileName).sorted()). Re-record, so \
            that the audit is comparing the directory against today's list.
            """
        )
    }

    // MARK: - Recording

    /// Writes the golden, then reads it back and holds the round trip to the
    /// byte.
    ///
    /// The record lane is a lane that can fail, which matters: it is the one
    /// place a mistake is written to disk rather than reported. PNG carries
    /// un-premultiplied alpha and this renderer produces premultiplied bytes,
    /// so a snapshot with any transparency in it would come back rounded — the
    /// canvas is opaque precisely so that it does not, and this is where that
    /// claim is checked instead of assumed.
    private func record(_ rendered: SnapshotBitmap, as item: SnapshotCase) throws {
        try SnapshotStore.writeGolden(rendered, named: item.fileName)
        try SnapshotStore.writeEnvironment(SnapshotRenderer.currentEnvironment)

        let reloaded = try #require(
            try SnapshotStore.readGolden(named: item.fileName),
            "\(item.fileName).png was written and could not be read back"
        )
        let comparison = SnapshotComparison(expected: rendered, actual: reloaded, tolerance: .exact)
        #expect(
            comparison.passes,
            """
            \(item.fileName).png does not survive a PNG round trip: \(comparison). \
            A golden that decodes differently than it encoded fails the gate on \
            every later run, against no change at all.
            """
        )
    }

    // MARK: - Helpers

    private func goldenBitmap(
        _ subject: SnapshotSubject,
        scheme: SnapshotScheme,
        typeSize: SnapshotTypeSize = .standard
    ) throws -> SnapshotBitmap {
        let appearance = SnapshotAppearance(scheme: scheme, typeSize: typeSize)
        let name = SnapshotCase(subject: subject, appearance: appearance).fileName
        return try #require(
            try SnapshotStore.readGolden(named: name),
            "\(name).png is not recorded"
        )
    }

    private func failureReport(
        for item: SnapshotCase,
        comparison: SnapshotComparison,
        written: [URL]
    ) -> String {
        let recorded = (try? SnapshotStore.readEnvironment())?.summary ?? "unknown"
        return """
            \(item.fileName) no longer matches its recorded golden.

              \(comparison)
              recorded against: \(recorded)
              running on: \(SnapshotRenderer.currentEnvironment.summary)
              written for inspection: \(list(written))

            If the change is intended, re-record the goldens and read the diff image
            before committing them — docs/snapshot-testing.md. If it is not, the
            region above is where to look.
            """
    }

    private func list(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: ", ")
    }
}
