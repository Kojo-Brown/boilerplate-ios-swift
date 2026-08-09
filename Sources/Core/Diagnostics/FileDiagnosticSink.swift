import Foundation

/// What can go wrong on the way to the file.
enum DiagnosticSinkError: Error, Equatable {
    /// The journal file did not exist and could not be created.
    case couldNotCreateFile(path: String)
}

/// A sink that appends each batch to a file, one line per record.
///
/// This is the type the whole `DiagnosticsActor` design is arranged around.
/// `write` is a blocking call — `FileHandle.write(contentsOf:)` is a `write(2)`
/// that returns when the kernel says so, and on a busy or encrypted volume that
/// is not instant. Running it on the cooperative pool would park one of the
/// pool's few threads inside a syscall, which is the one thing Swift concurrency
/// asks you not to do; running it on the main actor would do the same thing to
/// the frame. It runs in a domain with a `DispatchQueue` of its own precisely so
/// that blocking is a local cost.
///
/// Ordering is the file's other guarantee, and it comes from the same place: the
/// domain is serial, so batches reach `write` one at a time and in the order the
/// journal flushed them. Nothing here has to lock.
///
/// The handle is opened once and kept, because opening per batch would make a
/// two-line flush cost two `open`/`close` pairs. It is *not* closed in a
/// `deinit`: closing throws, deinitialisers cannot, and a journal that lives as
/// long as the process has no natural moment to close anyway. `close()` is the
/// caller's to call — and losing it costs one file descriptor at exit, not data,
/// because each `write` is a completed syscall rather than a buffered append.
@DiagnosticsActor
final class FileDiagnosticSink: DiagnosticSink {
    /// The file records are appended to.
    let url: URL
    private var handle: FileHandle?

    /// - Parameter url: Where to append. Missing intermediate directories are
    ///   created on first write, not here, so constructing a sink touches no
    ///   file system at all.
    init(url: URL) {
        self.url = url
    }

    func write(_ batch: [DiagnosticRecord]) throws {
        guard !batch.isEmpty else { return }
        let text = batch.map(\.line).joined(separator: "\n") + "\n"
        try openedHandle().write(contentsOf: Data(text.utf8))
    }

    /// Releases the file descriptor. Safe to call more than once; a later
    /// `write` reopens.
    func close() throws {
        guard let handle else { return }
        self.handle = nil
        try handle.close()
    }

    /// The write handle, positioned at the end of the file.
    ///
    /// Seeking to the end happens once, at open. Every subsequent `write`
    /// continues from where the previous one left the offset, and this sink is
    /// the only writer through this descriptor because the domain is serial — so
    /// re-seeking per batch would cost a syscall to learn something already
    /// known.
    private func openedHandle() throws -> FileHandle {
        if let handle { return handle }

        let path = url.path(percentEncoded: false)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: path) {
            guard fileManager.createFile(atPath: path, contents: nil) else {
                throw DiagnosticSinkError.couldNotCreateFile(path: path)
            }
        }

        let opened = try FileHandle(forWritingTo: url)
        // `seekToEnd` returns the new offset and is not `@discardableResult`;
        // this package fails its build on any warning, unused result included.
        _ = try opened.seekToEnd()
        handle = opened
        return opened
    }
}
