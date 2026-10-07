import Foundation
import Testing
@testable import Core

/// The one half of the MetricKit projection that *is* testable, and only because
/// `MXCallStackTree` is opaque.
///
/// Its whole public surface is `jsonRepresentation() -> Data` — there is no
/// `MXCallStack` type and no `MXFrame` type — so the frames have to be parsed
/// rather than read off objects nothing can construct. Everything the parse
/// decides is therefore driven from here: the depth-first order, the three bounds,
/// the thread reordering, and what a malformed document costs.
@Suite("The call-stack parser reads MetricKit's document and bounds it")
struct CallStackTreeParserTests {

    // MARK: - Fixtures

    /// A frame as MetricKit writes one, `address` and `sampleCount` included —
    /// because the assertion worth making is that they are *there* and are not
    /// carried, which a fixture without them cannot make.
    private func frameJSON(
        uuid: String = "00000000-0000-4000-8000-000000000001",
        offset: Int = 4_096,
        name: String = "MockApp",
        subFrames: String = ""
    ) -> String {
        let children = subFrames.isEmpty ? "" : ", \"subFrames\": [\(subFrames)]"
        return """
        {"binaryUUID": "\(uuid)", "offsetIntoBinaryTextSegment": \(offset), \
        "binaryName": "\(name)", "sampleCount": 20, "address": 4376268800\(children)}
        """
    }

    private func treeJSON(_ stacks: String) -> Data {
        Data("""
        {"callStackPerThread": true, "callStacks": [\(stacks)]}
        """.utf8)
    }

    private func stackJSON(attributed: Bool, roots: String) -> String {
        """
        {"threadAttributed": \(attributed), "callStackRootFrames": [\(roots)]}
        """
    }

    /// A chain `depth` frames deep, each frame the single sub-frame of the last.
    private func chainJSON(depth: Int) -> String {
        var json = frameJSON(offset: depth)
        for level in stride(from: depth - 1, through: 1, by: -1) {
            json = frameJSON(offset: level, subFrames: json)
        }
        return json
    }

    // MARK: - Reading it at all

    @Test("A frame's UUID, offset, name and depth come through")
    func framesDecode() throws {
        let data = treeJSON(stackJSON(attributed: true, roots: frameJSON()))
        let tree = CallStackTreeParser().parse(data)

        #expect(tree.stacks.count == 1)
        let frame = try #require(tree.stacks.first?.frames.first)
        #expect(frame.binaryUUID == CrashReportFixture.binaryUUID)
        #expect(frame.offset == 4_096)
        #expect(frame.binaryName == "MockApp")
        #expect(frame.depth == 0)
        #expect(tree.stacks.first?.isAttributed == true)
    }

    /// `subFrames` is a tree and a stack is read top to bottom, so the walk is
    /// depth-first pre-order: each frame followed by its own subtree.
    @Test("Sub-frames are flattened depth-first, with depth recorded")
    func subFramesFlattenInReadingOrder() {
        let leaf = frameJSON(offset: 3)
        let middle = frameJSON(offset: 2, subFrames: leaf)
        let sibling = frameJSON(offset: 9)
        let root = frameJSON(offset: 1, subFrames: "\(middle), \(sibling)")
        let tree = CallStackTreeParser().parse(treeJSON(stackJSON(attributed: true, roots: root)))

        let frames = tree.stacks.first?.frames ?? []
        #expect(frames.map(\.offset) == [1, 2, 3, 9])
        #expect(frames.map(\.depth) == [0, 1, 2, 1])
    }

    /// The attributed thread is the one anybody opening the report wants first, and
    /// MetricKit does not promise it is first.
    @Test("The attributed thread is moved to the front")
    func attributedThreadComesFirst() {
        let quiet = stackJSON(attributed: false, roots: frameJSON(offset: 10))
        let blamed = stackJSON(attributed: true, roots: frameJSON(offset: 20))
        let tree = CallStackTreeParser().parse(treeJSON("\(quiet), \(blamed)"))

        #expect(tree.stacks.first?.isAttributed == true)
        #expect(tree.blamedFrames.map(\.offset) == [20])
    }

    /// `sorted(by:)` is not stable in Swift, so comparing on the flag alone would
    /// let the unattributed threads come back in a different order from one run to
    /// the next — and the digest covers them, which would make one crash two.
    @Test("The reordering is stable, so the digest does not move")
    func reorderingIsStable() {
        let stacks = (1...6).map { index in
            stackJSON(attributed: index == 4, roots: frameJSON(offset: index))
        }
        let data = treeJSON(stacks.joined(separator: ", "))

        let first = CallStackTreeParser().parse(data)
        let second = CallStackTreeParser().parse(data)

        #expect(first == second)
        #expect(first.stacks.map { $0.frames.first?.offset } == [4, 1, 2, 3, 5, 6])
    }

    // MARK: - What is not carried

    /// `address` is a load address in a process that no longer exists and
    /// `sampleCount` is 1 for every frame of a crash stack. Both are in the
    /// document the fixture builds; neither reaches a frame.
    @Test("address and sampleCount are in the document and not in the result")
    func droppedKeysAreNotCarried() throws {
        let json = frameJSON()
        #expect(json.contains("\"address\""))
        #expect(json.contains("\"sampleCount\""))

        let tree = CallStackTreeParser().parse(treeJSON(stackJSON(attributed: true, roots: json)))
        let encoded = try JSONEncoder().encode(tree)
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(!text.contains("address"))
        #expect(!text.contains("sampleCount"))
        #expect(!text.contains("4376268800"))
    }

    // MARK: - The bounds

    @Test("Threads past the limit are dropped and the tree says so")
    func threadLimitTruncates() {
        let stacks = (1...5).map { index in
            stackJSON(attributed: false, roots: frameJSON(offset: index))
        }
        let limits = CrashReportLimits(maxStacksPerReport: 2)
        let tree = CallStackTreeParser(limits: limits).parse(treeJSON(stacks.joined(separator: ", ")))

        #expect(tree.stacks.count == 2)
        #expect(tree.isTruncated)
    }

    @Test("Frames past the limit are dropped and the stack says so")
    func frameLimitTruncates() {
        let limits = CrashReportLimits(maxFramesPerStack: 3)
        let roots = chainJSON(depth: 10)
        let tree = CallStackTreeParser(limits: limits).parse(
            treeJSON(stackJSON(attributed: true, roots: roots))
        )

        let stack = tree.stacks.first
        #expect(stack?.frames.count == 3)
        #expect(stack?.isTruncated == true)
        // The tree itself is not truncated: no thread was dropped.
        #expect(!tree.isTruncated)
    }

    /// The bound that matters most, because some of these stacks are a record of
    /// unbounded recursion and the walk over them must not be another one.
    @Test("The depth limit stops the walk and reports it")
    func depthLimitTruncates() {
        let limits = CrashReportLimits(maxFramesPerStack: 1_000, maxFrameDepth: 4)
        let tree = CallStackTreeParser(limits: limits).parse(
            treeJSON(stackJSON(attributed: true, roots: chainJSON(depth: 40)))
        )

        let frames = tree.stacks.first?.frames ?? []
        #expect(frames.map(\.depth) == [0, 1, 2, 3])
        #expect(tree.stacks.first?.isTruncated == true)
    }

    /// A stack that ends exactly at the depth limit has lost nothing, so saying it
    /// was truncated would be wrong — and `isTruncated` is in the digest.
    @Test("A stack that fits the depth limit exactly is not truncated")
    func depthLimitDoesNotFalselyTruncate() {
        let limits = CrashReportLimits(maxFramesPerStack: 1_000, maxFrameDepth: 4)
        let tree = CallStackTreeParser(limits: limits).parse(
            treeJSON(stackJSON(attributed: true, roots: chainJSON(depth: 4)))
        )

        let stack = tree.stacks.first
        #expect(stack?.frames.count == 4)
        #expect(stack?.isTruncated == false)
    }

    // MARK: - Malformed input

    /// A report with no stack is a worse report; a report that does not exist is no
    /// report. MetricKit will not hand the payload over again, so there is no
    /// version of "fail and retry" to choose instead.
    @Test("A document that does not decode costs the stack and nothing else")
    func malformedDocumentBecomesAnEmptyTree() {
        #expect(CallStackTreeParser().parse(Data("not json".utf8)) == .empty)
        #expect(CallStackTreeParser().parse(Data()) == .empty)
        #expect(CallStackTreeParser().parse(Data("{}".utf8)) == .empty)
    }

    /// MetricKit has written this field as both a JSON number and a decimal string
    /// across OS versions. A report whose every offset silently became zero
    /// symbolicates to the top of every binary.
    @Test("An offset written as a string is read as a number")
    func offsetDecodesFromAString() {
        let json = """
        {"binaryUUID": "00000000-0000-4000-8000-000000000001", \
        "offsetIntoBinaryTextSegment": "4096", "binaryName": "MockApp"}
        """
        let tree = CallStackTreeParser().parse(treeJSON(stackJSON(attributed: true, roots: json)))
        #expect(tree.stacks.first?.frames.first?.offset == 4_096)
    }

    /// A frame with no usable binary is still a frame: dropping it would renumber
    /// the depths of everything below it.
    @Test("A missing or malformed UUID becomes the unknown binary, not a dropped frame")
    func missingUUIDKeepsTheFrame() {
        let json = """
        {"binaryUUID": "not-a-uuid", "offsetIntoBinaryTextSegment": 8, \
        "subFrames": [{"offsetIntoBinaryTextSegment": 9}]}
        """
        let tree = CallStackTreeParser().parse(treeJSON(stackJSON(attributed: true, roots: json)))

        let frames = tree.stacks.first?.frames ?? []
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { $0.binaryUUID == StackFrame.unknownBinaryUUID })
        #expect(frames.map(\.offset) == [8, 9])
    }

    /// Each field is read with `try?`, so one frame written in an unexpected shape
    /// costs that field rather than cascading up through `subFrames` and turning
    /// every thread's stack into nothing.
    @Test("A frame with an unreadable field keeps the rest of the tree")
    func oneBadFieldDoesNotLoseTheTree() {
        let json = """
        {"binaryUUID": "00000000-0000-4000-8000-000000000001", \
        "offsetIntoBinaryTextSegment": {"nested": true}, "binaryName": 17, \
        "subFrames": [{"offsetIntoBinaryTextSegment": 9}]}
        """
        let tree = CallStackTreeParser().parse(treeJSON(stackJSON(attributed: true, roots: json)))

        let frames = tree.stacks.first?.frames ?? []
        #expect(frames.count == 2)
        #expect(frames.first?.binaryUUID == CrashReportFixture.binaryUUID)
        #expect(frames.first?.offset == 0)
        #expect(frames.first?.binaryName == nil)
        #expect(frames.last?.offset == 9)
    }

    /// `threadAttributed` is absent from some documents, and "absent" is not
    /// "blamed".
    @Test("A thread with no attribution flag is not attributed")
    func absentAttributionIsFalse() {
        let json = """
        {"callStackRootFrames": [\(frameJSON())]}
        """
        let tree = CallStackTreeParser().parse(treeJSON(json))
        #expect(tree.stacks.first?.isAttributed == false)
    }
}
