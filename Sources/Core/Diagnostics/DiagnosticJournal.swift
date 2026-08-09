import Foundation

// MARK: - Records

/// What a journal entry is about. Deliberately coarse: a category is for
/// filtering a log after the fact, not for reconstructing control flow.
enum DiagnosticCategory: String, Sendable, CaseIterable {
    case lifecycle
    case network
    case persistence
    case auth
}

/// One journalled event.
///
/// A value type, so it crosses out of the diagnostics domain to whoever is
/// reading the buffer without any of it staying shared.
struct DiagnosticRecord: Sendable, Equatable {
    /// Position in the journal, assigned inside `DiagnosticsActor` and therefore
    /// gap-free and collision-free however many callers are recording at once.
    let sequence: UInt64
    /// When the caller says the event happened — passed in rather than read
    /// here, so a record's time is the moment it describes and not the moment it
    /// reached the queue.
    let timestamp: Date
    let category: DiagnosticCategory
    /// Human-readable detail.
    ///
    /// Never a credential, a token, a password, or a URL with either in it. This
    /// string is written to a file that survives the process and is routinely
    /// attached to bug reports; treat everything in it as published.
    let message: String

    /// The record as one line of the on-disk format: tab-separated, newest
    /// field last, and exactly one line however the message was written.
    ///
    /// Embedded newlines are escaped rather than dropped, because a record whose
    /// message spans lines would otherwise be read back as several records —
    /// silently, and with the sequence numbers still looking gap-free.
    var line: String {
        let flattened = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\(sequence)\t\(timestamp.formatted(.iso8601))\t\(category.rawValue)\t\(flattened)"
    }
}

// MARK: - Sinks

/// Where a flushed batch of records ends up.
///
/// Isolated to `DiagnosticsActor` rather than declared `Sendable` and left free:
/// a sink is called with the domain's buffer in hand, so putting it in the
/// domain means the call is synchronous and the batch never crosses a boundary.
/// It also states the contract that matters — a sink may block, because the
/// domain it runs in has a thread it is allowed to block.
@DiagnosticsActor
protocol DiagnosticSink: AnyObject {
    /// Writes `batch` in order. Throwing leaves the records unwritten; the
    /// journal will hand them back on the next flush.
    func write(_ batch: [DiagnosticRecord]) throws
}

/// A sink that keeps records in memory, bounded, and writes nothing.
///
/// The default for a debug build and the substitute in tests. `capacity` is a
/// ring bound rather than a hard stop: a diagnostics buffer that stops accepting
/// records is one that throws away the crash you are looking for and keeps the
/// launch you are not.
@DiagnosticsActor
final class InMemoryDiagnosticSink: DiagnosticSink {
    /// The most recent records, oldest first.
    private(set) var written: [DiagnosticRecord] = []
    private let capacity: Int

    init(capacity: Int = 1_000) {
        precondition(capacity > 0, "An in-memory sink with no capacity would discard every record.")
        self.capacity = capacity
    }

    func write(_ batch: [DiagnosticRecord]) {
        written.append(contentsOf: batch)
        if written.count > capacity {
            written.removeFirst(written.count - capacity)
        }
    }
}

// MARK: - Budget

/// The buffer bound, kept as its own type so the policy is one object to look at
/// and one object to substitute in a test.
///
/// It lives in the diagnostics domain so the journal can consult it without a
/// suspension point. That is the whole reason `DiagnosticsActor` is a global
/// actor rather than two separate actors: admitting a record is a check followed
/// by an act, and an `await` between them is a hole another caller fits through.
@DiagnosticsActor
final class DiagnosticBudget {
    /// How many records may sit unflushed before further ones are refused.
    let capacity: Int
    /// How many records have been refused over the life of this budget.
    ///
    /// Monotonic, and deliberately never reset: the number is itself a
    /// diagnostic — a flush cadence that cannot keep up shows here and nowhere
    /// else.
    private(set) var dropped: UInt64 = 0

    init(capacity: Int) {
        precondition(capacity > 0, "A budget with no capacity would refuse every record.")
        self.capacity = capacity
    }

    /// Whether one more record may join a buffer currently holding `buffered`.
    ///
    /// Refusing counts as a drop, so a caller that ignores the answer still
    /// leaves a trace of having been refused.
    func admit(buffered: Int) -> Bool {
        guard buffered < capacity else {
            dropped += 1
            return false
        }
        return true
    }
}

// MARK: - Journal

/// An append-only, ordered journal of app events, buffered in the diagnostics
/// domain and flushed to a sink in batches.
///
/// ```swift
/// await DiagnosticJournal.shared.record(.auth, "biometric prompt cancelled")
/// try await DiagnosticJournal.shared.flush()
/// ```
///
/// ## Why there is no fire-and-forget `log`
///
/// A `nonisolated static func log(_:)` that wrapped the hop in a `Task` would be
/// the ergonomic API, and it would quietly break the one property a journal
/// exists to have. Two such calls in a row from the same function are two
/// independent tasks, and nothing orders their arrival at the domain: the second
/// line can be journalled before the first. Awaiting the record keeps the
/// caller's own program order, which is the order anyone reading the log will
/// assume they are seeing.
///
/// The cost is that recording suspends the caller. For a `@MainActor` caller
/// that is a hop off the main actor and back — the same shape as
/// `OffMainActor.run`, and the same caveat applies: state read before the
/// `await` may be stale after it.
@DiagnosticsActor
final class DiagnosticJournal {
    /// The app-wide journal. Tests build their own instead of using this one —
    /// the domain is shared, the objects in it need not be.
    static let shared = DiagnosticJournal(
        sink: InMemoryDiagnosticSink(),
        budget: DiagnosticBudget(capacity: 512)
    )

    private let sink: any DiagnosticSink
    private let budget: DiagnosticBudget
    private var buffered: [DiagnosticRecord] = []
    private var nextSequence: UInt64 = 0

    init(sink: any DiagnosticSink, budget: DiagnosticBudget) {
        self.sink = sink
        self.budget = budget
    }

    /// The records recorded but not yet handed to the sink, oldest first.
    var pending: [DiagnosticRecord] { buffered }

    /// How many records the budget has refused.
    var dropped: UInt64 { budget.dropped }

    /// Appends one record to the buffer.
    ///
    /// The sequence number is read and incremented here rather than at the call
    /// site, which is what makes it meaningful. This method contains no `await`,
    /// so the whole of it — asking the budget, taking the next number, appending
    /// — runs without interruption on the domain's serial executor. Sixty-four
    /// callers racing to record produce sixty-four consecutive numbers.
    ///
    /// - Returns: The record, or `nil` if the budget refused it because the
    ///   buffer is full. A refusal is counted in `dropped`.
    @discardableResult
    func record(
        _ category: DiagnosticCategory,
        _ message: String,
        at timestamp: Date = Date()
    ) -> DiagnosticRecord? {
        guard budget.admit(buffered: buffered.count) else { return nil }
        nextSequence += 1
        let record = DiagnosticRecord(
            sequence: nextSequence,
            timestamp: timestamp,
            category: category,
            message: message
        )
        buffered.append(record)
        return record
    }

    /// Hands every buffered record to the sink, oldest first, and empties the
    /// buffer.
    ///
    /// The buffer is cleared *before* the write and restored if the write
    /// throws, rather than cleared after a write that succeeded. Both orders are
    /// correct here — `write` is synchronous, so nothing can observe the
    /// in-between state — and this one stays correct if a sink ever becomes
    /// `async`, where the other would let a second flush hand the same batch to
    /// the sink twice.
    ///
    /// Restoring puts the batch back at the front, so a transient failure costs
    /// ordering nothing. It can push the buffer over the budget's capacity,
    /// which is deliberate: the alternative is dropping records that were
    /// already accepted, and the next `record` will be refused anyway.
    func flush() throws {
        guard !buffered.isEmpty else { return }
        let batch = buffered
        buffered.removeAll(keepingCapacity: true)
        do {
            try sink.write(batch)
        } catch {
            buffered.insert(contentsOf: batch, at: 0)
            throw error
        }
    }
}
