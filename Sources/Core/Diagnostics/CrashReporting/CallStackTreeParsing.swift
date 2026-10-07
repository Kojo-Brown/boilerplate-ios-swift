import Foundation

/// Reads MetricKit's call-stack-tree JSON into ``CallStackTree``.
///
/// ## Why this is a parser and not a field copy
///
/// Because `MXCallStackTree` is opaque. It has no `callStacks` property, no
/// `MXCallStack` type and no `MXFrame` type — the entire public surface is
/// `jsonRepresentation() -> Data` plus `NSSecureCoding`. Apple never exposed the
/// frames as objects, so the only way to read a stack out of a diagnostic is to
/// parse the document.
///
/// That turns out to be the better position, and not only because it is the one
/// available. A parser takes `Data`, so **this is testable** — the frame walk,
/// the depth and frame limits, the thread reordering and the truncation flags are
/// all driven by `CallStackTreeParserTests` from JSON fixtures. Had MetricKit
/// exposed the objects, every line of this would sit behind the one seam no test
/// in this repository can reach.
///
/// ## What it reads, and what it steps over
///
/// MetricKit's document looks like this (iOS 14 onwards):
///
/// ```json
/// {
///   "callStackPerThread": true,
///   "callStacks": [
///     {
///       "threadAttributed": true,
///       "callStackRootFrames": [
///         {
///           "binaryUUID": "E1C0E9A0-...",
///           "offsetIntoBinaryTextSegment": 123456,
///           "binaryName": "MyApp",
///           "sampleCount": 20,
///           "address": 4376268800,
///           "subFrames": [ … ]
///         }
///       ]
///     }
///   ]
/// }
/// ```
///
/// `binaryUUID`, `offsetIntoBinaryTextSegment` and `binaryName` are kept.
/// `address` and `sampleCount` are read by nothing here — see ``StackFrame`` for
/// why `address` in particular is left where it is. Because the projection is a
/// decode of named keys rather than a pass-through of the document, a key Apple
/// adds later is ignored by construction instead of being forwarded to a server
/// nobody told about it.
///
/// ## Why a failure is an empty tree rather than a thrown error
///
/// A report with no stack is a worse report; a report that does not exist is no
/// report. The kind, the signature, the build and the window are all still worth
/// having and all still correct, so a document this build cannot read costs the
/// stack and nothing else. MetricKit will not hand the payload over again, so
/// there is no version of "fail and retry" available.
package struct CallStackTreeParser: Sendable {

    private let limits: CrashReportLimits

    package init(limits: CrashReportLimits = .standard) {
        self.limits = limits
    }

    /// Projects `data` — the bytes from `MXCallStackTree.jsonRepresentation()` —
    /// into a bounded ``CallStackTree``.
    ///
    /// Returns ``CallStackTree/empty`` for a document that does not decode. That
    /// includes one nested deeper than Foundation's JSON parser will go, which is
    /// the parser's own bound on the recursion this input can contain: the tree
    /// being read may have come from a stack that crashed *because* it recursed
    /// without end.
    package func parse(_ data: Data) -> CallStackTree {
        guard let document = try? JSONDecoder().decode(TreeDocument.self, from: data) else {
            return .empty
        }
        let all = document.callStacks ?? []
        let kept = all.prefix(limits.maxStacksPerReport).map(stack(from:))
        return CallStackTree(
            stacks: attributedFirst(kept),
            isTruncated: all.count > kept.count
        )
    }

    // MARK: - Ordering

    /// Attributed threads first, keeping the original order within each group.
    ///
    /// The attributed thread is the one anybody opening the report wants first and
    /// MetricKit does not promise it is first. `enumerated()` is what makes the
    /// reordering *stable*: `sorted(by:)` is not a stable sort in Swift, so
    /// comparing on the flag alone would let the unattributed threads come back in
    /// a different order from one run to the next — and the digest covers them, so
    /// that would be the same crash under two names.
    private func attributedFirst(_ stacks: [CallStack]) -> [CallStack] {
        let ordered = stacks.enumerated().sorted { lhs, rhs in
            if lhs.element.isAttributed != rhs.element.isAttributed {
                return lhs.element.isAttributed
            }
            return lhs.offset < rhs.offset
        }
        return ordered.map(\.element)
    }

    // MARK: - One thread

    /// Flattens one thread's root frames depth-first, inside the limits.
    ///
    /// An explicit stack rather than recursion. Foundation's decoder has already
    /// bounded how deep the *document* could be — it refuses a document nested
    /// past its own limit, which is why `parse` can return an empty tree — but the
    /// walk over what it produced is this code's own, and a recursive one would
    /// reintroduce exactly the unbounded recursion that some of these stacks are a
    /// record of.
    private func stack(from captured: StackDocument) -> CallStack {
        var frames: [StackFrame] = []
        var truncated = false
        var pending: [(frame: FrameDocument, depth: Int)] = (captured.callStackRootFrames ?? [])
            .reversed()
            .map { root in (frame: root, depth: 0) }

        while let next = pending.popLast() {
            guard frames.count < limits.maxFramesPerStack else {
                truncated = true
                break
            }
            frames.append(
                StackFrame(
                    binaryUUID: next.frame.uuid ?? StackFrame.unknownBinaryUUID,
                    offset: next.frame.offsetIntoBinaryTextSegment ?? 0,
                    binaryName: next.frame.binaryName,
                    depth: next.depth
                )
            )
            let children = next.frame.subFrames ?? []
            guard next.depth + 1 < limits.maxFrameDepth else {
                truncated = truncated || !children.isEmpty
                continue
            }
            // Pushed reversed so the first sub-frame pops first, which is what
            // makes `frames` a depth-first pre-order walk and so readable top to
            // bottom.
            for child in children.reversed() {
                pending.append((frame: child, depth: next.depth + 1))
            }
        }
        return CallStack(
            isAttributed: captured.threadAttributed ?? false,
            frames: frames,
            isTruncated: truncated
        )
    }
}

// MARK: - The document

/// The top level of `MXCallStackTree.jsonRepresentation()`.
///
/// `callStackPerThread` is in the document and is deliberately not decoded: it
/// says whether MetricKit grouped by thread, which changes nothing this code does
/// with the result.
private struct TreeDocument: Decodable {
    let callStacks: [StackDocument]?
}

private struct StackDocument: Decodable {
    let threadAttributed: Bool?
    let callStackRootFrames: [FrameDocument]?
}

/// One frame as MetricKit writes it.
///
/// `address` and `sampleCount` are absent from this type on purpose rather than
/// decoded and ignored: a property that exists is a property somebody later
/// forwards. `Tools/assert-crash-reporting.py` fails if either name appears in
/// this file.
private struct FrameDocument: Decodable {
    let binaryUUID: String?
    let binaryName: String?
    let subFrames: [FrameDocument]?

    /// Decoded leniently because MetricKit has written this field as both a JSON
    /// number and a decimal string across OS versions, and a report whose every
    /// offset silently became zero is a report that symbolicates to the top of
    /// every binary.
    let offsetIntoBinaryTextSegment: Int?

    /// `binaryUUID` as a `UUID`, or `nil` when it is missing or malformed.
    var uuid: UUID? {
        binaryUUID.flatMap { UUID(uuidString: $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case binaryUUID
        case binaryName
        case subFrames
        case offsetIntoBinaryTextSegment
    }

    /// Every field is read with `try?`, so a frame MetricKit wrote in a shape this
    /// build does not expect costs *that field* rather than the whole document.
    ///
    /// Written with `try`, one unexpected value — a number where a string was, an
    /// object where a number was — would fail this frame, which would fail its
    /// parent's `subFrames`, which would fail the array, which would fail
    /// `TreeDocument`, which would turn the entire stack of every thread into
    /// `CallStackTree.empty`. The loss is bounded here instead, at the smallest
    /// unit that has one.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        binaryUUID = try? container.decodeIfPresent(String.self, forKey: .binaryUUID)
        binaryName = try? container.decodeIfPresent(String.self, forKey: .binaryName)
        subFrames = try? container.decodeIfPresent([FrameDocument].self, forKey: .subFrames)
        if let number = try? container.decodeIfPresent(Int.self, forKey: .offsetIntoBinaryTextSegment) {
            offsetIntoBinaryTextSegment = number
        } else {
            let text = try? container.decodeIfPresent(String.self, forKey: .offsetIntoBinaryTextSegment)
            offsetIntoBinaryTextSegment = text.flatMap { Int($0) }
        }
    }
}
