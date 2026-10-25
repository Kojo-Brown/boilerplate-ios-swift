import Foundation

// MARK: - Recorded environment

/// What the goldens in `__Snapshots__` were recorded against.
///
/// Provenance, not a gate. A snapshot is a picture of what *one* renderer on
/// *one* OS version drew, and when a comparison fails the first question is
/// always whether anything in the code changed at all — so the answer, and the
/// re-record instruction that follows from it, is written down beside the
/// images rather than left for whoever is reading a red build to guess.
///
/// It is deliberately not a precondition. The gate's verdict is the pixels: a
/// run on a newer runtime whose pixels still match is a pass, and saying
/// otherwise would be failing a build over a number in a JSON file that no
/// reader would ever have seen a difference from.
struct SnapshotEnvironment: Codable, Equatable, Sendable {

    /// `UIDevice.current.systemVersion` on the simulator that recorded them.
    var iosVersion: String

    /// Points to pixels. The device model is deliberately absent: the renderer
    /// is handed an explicit width and an explicit scale, so what model of
    /// iPhone the simulator claims to be changes nothing about the output.
    var scale: Double

    var renderer: String

    /// Every golden this directory is supposed to hold, by file name, sorted.
    ///
    /// The inventory is here so that each of the two parties that can see half
    /// the picture checks its own half. `Tools/assert-snapshot-gate.py` runs on
    /// Linux with no simulator: it can read this list and the directory, and it
    /// fails on a PNG that is in one and not the other — an orphan left by a
    /// renamed subject, or a golden that was never recorded. The suite runs
    /// where the catalogue is compiled: it checks this list against
    /// `SnapshotCase.all`, so the inventory cannot go stale against the code.
    /// Neither check is possible from the other side.
    var cases: [String]

    var summary: String {
        "iOS \(iosVersion), \(renderer), scale \(scale)"
    }
}

// MARK: - Store

/// Where the recorded snapshots live, and the one switch that decides whether
/// this run reads them or writes them.
///
/// Paths come from `#filePath`, so they name the checkout this test was
/// compiled from rather than anything in the test bundle. That is what lets the
/// record lane write a file a human can commit, and it is also the reason these
/// tests need a source tree next to them — which CI and a developer's Mac both
/// have, and which is why no golden is declared as a package resource.
enum SnapshotStore {

    static let goldenDirectoryName = "__Snapshots__"
    static let environmentFileName = "environment.json"

    /// `Tests/SnapshotTests/__Snapshots__`.
    static var goldenDirectory: URL {
        sourceDirectory.appending(path: goldenDirectoryName)
    }

    /// Where a failing comparison leaves the three images to look at.
    ///
    /// Outside the package's source tree on purpose: anything inside a target's
    /// directory is a file SwiftPM has to be told about, and a failure artifact
    /// is not a resource. It is gitignored, so a local run cannot commit what
    /// it was only meant to show somebody.
    static var failureDirectory: URL {
        let overridden = ProcessInfo.processInfo.environment["SNAPSHOT_FAILURE_DIR"] ?? ""
        if !overridden.isEmpty {
            return URL(filePath: overridden)
        }
        return repositoryRoot.appending(path: "SnapshotFailures")
    }

    /// Whether this run writes the goldens instead of checking them.
    ///
    /// The only place in the suite that reads the variable, which is what
    /// `Tools/assert-snapshot-gate.py` holds it to: a second switch somewhere
    /// else is how a gate ends up recording in the job that is supposed to be
    /// verifying, and a gate that records always passes.
    static var isRecording: Bool {
        let raw = ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] ?? ""
        return ["1", "true", "TRUE", "yes", "YES"].contains(raw)
    }

    static func goldenURL(named name: String) -> URL {
        goldenDirectory.appending(path: "\(name).png")
    }

    /// The recorded snapshot, or `nil` when there is no file for this case.
    ///
    /// A missing golden and an unreadable one are different findings, so the
    /// unreadable one throws rather than coming back as "not recorded yet".
    static func readGolden(named name: String) throws -> SnapshotBitmap? {
        let url = goldenURL(named: name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        guard let bitmap = SnapshotBitmap.decoding(pngData: data) else {
            throw SnapshotStoreError.unreadableGolden(url)
        }
        return bitmap
    }

    static func writeGolden(_ bitmap: SnapshotBitmap, named name: String) throws {
        try write(bitmap, to: goldenURL(named: name))
    }

    /// Leaves the recorded image, the rendered one and their overlay where CI
    /// can upload them.
    ///
    /// Returns the files written, in that order, so the failure message can
    /// name them.
    static func writeFailure(
        named name: String,
        expected: SnapshotBitmap?,
        actual: SnapshotBitmap,
        difference: SnapshotBitmap?
    ) throws -> [URL] {
        var written: [URL] = []
        let candidates: [(role: String, bitmap: SnapshotBitmap?)] = [
            (role: "expected", bitmap: expected),
            (role: "actual", bitmap: actual),
            (role: "diff", bitmap: difference),
        ]
        for candidate in candidates {
            guard let bitmap = candidate.bitmap else { continue }
            let url = failureDirectory.appending(path: "\(name).\(candidate.role).png")
            try write(bitmap, to: url)
            written.append(url)
        }
        return written
    }

    static func readEnvironment() throws -> SnapshotEnvironment? {
        let url = goldenDirectory.appending(path: environmentFileName)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(SnapshotEnvironment.self, from: Data(contentsOf: url))
    }

    static func writeEnvironment(_ environment: SnapshotEnvironment) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(environment)
        data.append(contentsOf: [0x0A])
        let url = goldenDirectory.appending(path: environmentFileName)
        try FileManager.default.createDirectory(
            at: goldenDirectory,
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private static func write(_ bitmap: SnapshotBitmap, to url: URL) throws {
        guard let data = bitmap.pngData() else {
            throw SnapshotStoreError.encodingFailed(url)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static var sourceDirectory: URL {
        URL(filePath: #filePath).deletingLastPathComponent()
    }

    private static var repositoryRoot: URL {
        sourceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

// MARK: - Errors

enum SnapshotStoreError: Error, CustomStringConvertible {
    case unreadableGolden(URL)
    case encodingFailed(URL)

    var description: String {
        switch self {
        case let .unreadableGolden(url):
            return "\(url.lastPathComponent) is not a PNG this gate can decode."
        case let .encodingFailed(url):
            return "could not encode a PNG for \(url.lastPathComponent)."
        }
    }
}
