import Foundation

// MARK: - One frame

/// One frame of a captured call stack, in the form a symbolicator needs and no
/// other.
///
/// MetricKit's `MXFrame` carries five things. Three of them are here and two are
/// deliberately not, and the omission is the point of this type existing at all
/// rather than the raw `MXCallStackTree.jsonRepresentation()` being spooled.
///
/// * `binaryUUID` and `offsetIntoBinaryTextSegment` are kept, because together
///   they *are* symbolication: `atos -o <binary> -arch <arch> -l 0` over the
///   offset resolves a frame against the dSYM for that UUID, on a machine that
///   has never seen the device.
/// * `binaryName` is kept so a reader can tell "our code" from "UIKit" before
///   symbolicating anything, which is the first question asked of every crash.
/// * `address` is **dropped**. It is the frame's load address in a process that
///   no longer exists, so it symbolicates nothing without the slide — and the
///   slide is exactly what ASLR randomises per launch. What it does carry is a
///   pointer value out of somebody's address space. A field that cannot be used
///   and should not be sent is one to leave behind.
/// * `sampleCount` is dropped for crash and hang reports because it is 1 for
///   every frame of a crash stack; it is not dropped from the *shape* of the
///   tree, because `subFrames` is what records that a hang spent its time in one
///   branch.
///
/// Flattened rather than nested. `MXFrame.subFrames` is a tree, and a tree
/// round-tripped through `Codable` needs either an indirect enum or a class, both
/// of which buy recursion no reader of a stack trace wants: a stack is read top
/// to bottom. ``depth`` carries the nesting that mattered.
package struct StackFrame: Sendable, Equatable, Codable {

    /// The Mach-O UUID of the binary the frame is in. Half of a symbolication
    /// request; the dSYM with the same UUID is the other half.
    package let binaryUUID: UUID

    /// Byte offset of the return address into that binary's `__TEXT` segment.
    ///
    /// `Int` rather than `UInt64`: it is an offset into a segment rather than an
    /// address, so it is small, and `atos -l 0` wants it as a plain number.
    package let offset: Int

    /// The binary's name, when MetricKit knew it.
    package let binaryName: String?

    /// How deep in `subFrames` this frame was found; 0 for a root frame.
    ///
    /// Kept because a flattened tree with no depth is a list of frames in an
    /// order nobody can justify, and because an unexpectedly deep stack is itself
    /// the finding in a recursion crash.
    package let depth: Int

    package init(binaryUUID: UUID, offset: Int, binaryName: String?, depth: Int) {
        self.binaryUUID = binaryUUID
        self.offset = offset
        self.binaryName = binaryName
        self.depth = depth
    }

    /// The frame as the one line it contributes to a report's digest.
    ///
    /// The binary *name* is left out on purpose: it is a convenience for a human
    /// reader and it is not stable — MetricKit reports it as `nil` for some
    /// frames in some payloads — so including it would make two reports of the
    /// same crash hash differently depending on how much MetricKit happened to
    /// know. The UUID and the offset are the identity.
    package var canonicalForm: String {
        "\(depth):\(binaryUUID.uuidString):\(offset)"
    }
}

// MARK: - One thread

/// The frames of one thread, root frames first, flattened depth-first.
package struct CallStack: Sendable, Equatable, Codable {

    /// Whether MetricKit blamed this thread for the crash or the hang.
    ///
    /// The single most useful bit in the whole payload, and the one most easily
    /// lost: a crash report with eighteen threads and no attribution is eighteen
    /// stacks to read.
    package let isAttributed: Bool

    /// Frames in reading order: each root frame followed by its subtree.
    package let frames: [StackFrame]

    /// Whether ``frames`` stops short of what was captured, because the stack ran
    /// past the limit it was projected under.
    ///
    /// Carried rather than inferred. A truncated stack and a short stack look
    /// identical once the frames are counted, and the difference decides whether
    /// the bottom of the stack is missing or simply is not there.
    package let isTruncated: Bool

    package init(isAttributed: Bool, frames: [StackFrame], isTruncated: Bool) {
        self.isAttributed = isAttributed
        self.frames = frames
        self.isTruncated = isTruncated
    }

    package var canonicalForm: String {
        let body = frames.map(\.canonicalForm).joined(separator: "|")
        return "\(isAttributed ? "attributed" : "thread")/\(isTruncated ? "cut" : "full")/\(body)"
    }
}

// MARK: - The tree

/// Every thread MetricKit captured for one diagnostic.
package struct CallStackTree: Sendable, Equatable, Codable {

    /// The threads, attributed ones first.
    ///
    /// Reordered at projection rather than left in MetricKit's order, because the
    /// attributed thread is the one anybody opening the report wants first and
    /// MetricKit does not promise it is first. The order is stable — a sort that
    /// keeps the original relative order within each group — so it does not move
    /// the digest around.
    package let stacks: [CallStack]

    /// Whether whole threads were dropped to stay inside the projection limits.
    package let isTruncated: Bool

    package init(stacks: [CallStack], isTruncated: Bool) {
        self.stacks = stacks
        self.isTruncated = isTruncated
    }

    /// An empty tree, for a diagnostic MetricKit gave no stacks for.
    package static let empty = CallStackTree(stacks: [], isTruncated: false)

    package var canonicalForm: String {
        let body = stacks.map(\.canonicalForm).joined(separator: ";")
        return "\(isTruncated ? "cut" : "full")/\(body)"
    }

    /// The frames of the attributed thread, or of the first thread when MetricKit
    /// attributed none.
    ///
    /// The thing a log line wants. A report whose every thread is unattributed is
    /// not a malformed report — a disk-write exception has no guilty thread — so
    /// falling back is right and returning nothing would not be.
    package var blamedFrames: [StackFrame] {
        if let attributed = stacks.first(where: \.isAttributed) {
            return attributed.frames
        }
        return stacks.first?.frames ?? []
    }
}

// MARK: - Bounds

/// How much of a payload a projection will carry.
///
/// Limits rather than no limits, because the sizes MetricKit can hand over are
/// not bounded by anything the app controls. A payload covers up to 24 hours, a
/// crash loop inside those 24 hours produces one diagnostic per crash, and a
/// recursion crash produces a stack whose depth is however deep the stack got.
/// Spooling all of it means a disk write of unbounded size inside a callback that
/// must not block, and uploading all of it means a request body a server is
/// entitled to refuse — at which point the pipeline retries it forever.
///
/// Every limit is a *truncation* and never a drop: a report that hits one is
/// still spooled, still uploaded, and says so in `isTruncated`. The one exception
/// is ``maxReportsPerPayload``, which does drop, and which counts what it dropped
/// — see ``CrashReportPipeline``.
package struct CrashReportLimits: Sendable, Equatable {

    /// How many diagnostics one payload may produce reports for.
    ///
    /// 64 across all five kinds. A device that crashed more than 64 times in a
    /// day has one bug, not 64, and the 65th report of it buys nothing that the
    /// count of dropped reports does not say more cheaply.
    package let maxReportsPerPayload: Int

    /// How many threads one report may carry.
    package let maxStacksPerReport: Int

    /// How many frames one thread may carry.
    package let maxFramesPerStack: Int

    /// How deep into `MXFrame.subFrames` the projection will walk.
    ///
    /// A bound on recursion, and it is load-bearing rather than tidy: the input
    /// is a tree built by the system from a stack that may itself have crashed
    /// *because* it recursed without end, and a recursive walk over it with no
    /// depth limit is the same unbounded recursion in the reporting path.
    package let maxFrameDepth: Int

    /// How many characters of `MXCrashDiagnostic.terminationReason` to keep.
    ///
    /// The system's own text, which usually names a namespace and a code and
    /// occasionally embeds a path. Capped because it is the one free-form string
    /// in the report.
    package let maxTerminationReasonLength: Int

    /// How many reports may wait on disk for an upload that keeps failing.
    package let spoolCapacity: Int

    package init(
        maxReportsPerPayload: Int = 64,
        maxStacksPerReport: Int = 16,
        maxFramesPerStack: Int = 128,
        maxFrameDepth: Int = 128,
        maxTerminationReasonLength: Int = 256,
        spoolCapacity: Int = 128
    ) {
        precondition(maxReportsPerPayload > 0, "A limit of zero reports per payload reports nothing.")
        precondition(maxStacksPerReport > 0, "A report with no threads carries no stack.")
        precondition(maxFramesPerStack > 0, "A stack with no frames is not a stack.")
        precondition(maxFrameDepth > 0, "A depth limit of zero would drop every root frame.")
        precondition(maxTerminationReasonLength >= 0, "A negative length is not a length.")
        precondition(spoolCapacity > 0, "A spool with no capacity would discard every crash.")
        self.maxReportsPerPayload = maxReportsPerPayload
        self.maxStacksPerReport = maxStacksPerReport
        self.maxFramesPerStack = maxFramesPerStack
        self.maxFrameDepth = maxFrameDepth
        self.maxTerminationReasonLength = maxTerminationReasonLength
        self.spoolCapacity = spoolCapacity
    }

    /// The limits the app ships with.
    package static let standard = CrashReportLimits()

    /// `reason` capped to ``maxTerminationReasonLength``, or `nil` for nothing
    /// worth carrying.
    ///
    /// It lives here rather than in the projection on purpose. The projection is
    /// the one file in this feature that no test can execute, so a cap applied
    /// there is a cap held in place by nothing — and the way that cap breaks is a
    /// comparison against the wrong number, which still *mentions* the limit and
    /// so still satisfies a syntactic audit. Moved here it is three lines a test
    /// can drive, and the projection has one call to make.
    ///
    /// An empty reason becomes `nil`, because `""` and "the system said nothing"
    /// are the same fact and a report should spell it one way.
    package func truncating(terminationReason reason: String?) -> String? {
        guard let reason, !reason.isEmpty else { return nil }
        guard reason.count > maxTerminationReasonLength else { return reason }
        return String(reason.prefix(maxTerminationReasonLength))
    }
}
