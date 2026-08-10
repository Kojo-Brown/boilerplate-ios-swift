import CoreGraphics
import Foundation
import Testing
@testable import BoilerplateiOSSwift

// MARK: - The mistake, kept compiled and run

/// A struct that looks like a value and is not.
///
/// This is the shape `CopyOnWriteBox` exists to replace, kept here as real
/// compiled code for the same reason `SingleFlightCacheTests` keeps its naive
/// actor: the failure is worth demonstrating rather than describing. Nothing
/// about it is a data race, nothing warns, and Swift 6 accepts it — the setter
/// simply writes through a reference every copy of the struct shares.
private struct ReferenceBackedDraft {
    private final class Body {
        var text: String

        init(_ text: String) {
            self.text = text
        }
    }

    private var body: Body

    init(text: String) {
        body = Body(text)
    }

    var text: String {
        get { body.text }
        // The bug, and the only difference from `CopyOnWriteDraft` below: no
        // uniqueness check, so the write lands in storage the "copy" shares.
        set { body.text = newValue }
    }
}

/// The same shape, with the one line that makes it a value type.
private struct CopyOnWriteDraft {
    private var storage: CopyOnWriteBox<String>

    init(text: String) {
        storage = CopyOnWriteBox(text)
    }

    var text: String {
        get { storage.value }
        set { storage.value = newValue }
    }
}

// MARK: - Inspection helpers

/// Whether two arrays are currently backed by the same element buffer.
///
/// Both pointers are read inside the scopes that guarantee them, and neither
/// escapes or is dereferenced — the only question asked is whether the two
/// allocations are one. Meaningless for empty arrays, whose base address may be
/// `nil` on both sides without either owning anything, so the tests below only
/// ever pass non-empty ones.
private func sharesElementBuffer<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
    lhs.withUnsafeBufferPointer { left -> Bool in
        rhs.withUnsafeBufferPointer { right -> Bool in
            left.baseAddress == right.baseAddress
        }
    }
}

// MARK: - Value semantics

@Suite("A struct over a reference is not a value")
struct ReferenceSemanticsInDisguiseTests {

    @Test("Writing through a copy is visible through the original")
    func writingThroughCopyIsVisibleThroughOriginal() {
        var original = ReferenceBackedDraft(text: "first")
        var copy = original

        copy.text = "second"

        // `var copy = original` read as a copy at the call site and was not one.
        #expect(copy.text == "second")
        #expect(original.text == "second")

        // It goes the other way too, which is what makes the bug so hard to
        // localise: neither variable is the owner.
        original.text = "third"
        #expect(copy.text == "third")
    }

    @Test("The same shape with copy-on-write keeps the copies apart")
    func copyOnWriteKeepsCopiesApart() {
        var original = CopyOnWriteDraft(text: "first")
        var copy = original

        copy.text = "second"

        #expect(copy.text == "second")
        #expect(original.text == "first")

        original.text = "third"
        #expect(copy.text == "second")
    }
}

// MARK: - Copy-on-write inspection

@Suite("Copy-on-write inspection")
struct CopyOnWriteBoxTests {

    @Test("Assignment shares the allocation instead of copying it")
    func assignmentSharesTheAllocation() {
        let box = CopyOnWriteBox([1, 2, 3])
        let shared = box

        #expect(box.storageIdentity == shared.storageIdentity)
    }

    @Test("Mutating a shared box copies, and leaves the other copy alone")
    func mutatingSharedBoxCopies() {
        var box = CopyOnWriteBox([1, 2, 3])
        let shared = box
        let before = shared.storageIdentity

        box.withValue { $0.append(4) }

        #expect(box.storageIdentity != before)
        #expect(box.value == [1, 2, 3, 4])
        #expect(shared.value == [1, 2, 3])
        #expect(shared.storageIdentity == before)
    }

    @Test("Mutating a uniquely referenced box reuses the allocation")
    func mutatingUniqueBoxDoesNotCopy() {
        var box = CopyOnWriteBox([1, 2, 3])
        let before = box.storageIdentity

        box.withValue { $0.append(4) }

        #expect(box.storageIdentity == before)
        #expect(box.value == [1, 2, 3, 4])
    }

    @Test("Uniqueness tracks the copies that are actually alive")
    func uniquenessTracksLiveCopies() {
        // `isUniquelyReferenced()` is `mutating`, so each answer is read into a
        // `let` first rather than called inside the macro expansion.
        var box = CopyOnWriteBox(42)
        let uniqueBeforeCopy = box.isUniquelyReferenced()

        var copy = box
        let uniqueWhileCopyIsAlive = box.isUniquelyReferenced()

        // The copy takes its own allocation on write, which hands the original
        // back its exclusive ownership.
        copy.value = 7
        let uniqueAfterCopyDiverged = box.isUniquelyReferenced()

        #expect(uniqueBeforeCopy)
        #expect(uniqueWhileCopyIsAlive == false)
        #expect(uniqueAfterCopyDiverged)
        #expect(box.value == 42)
        #expect(copy.value == 7)
    }

    @Test("The property setter copies on a shared box too")
    func propertySetterCopiesOnSharedBox() {
        var box = CopyOnWriteBox("first")
        let shared = box

        box.value = "second"

        #expect(box.value == "second")
        #expect(shared.value == "first")
    }

    @Test("Equality short-circuits on shared storage and still compares values")
    func equalityUsesIdentityThenValue() {
        let box = CopyOnWriteBox([1, 2, 3])
        let shared = box
        let separate = CopyOnWriteBox([1, 2, 3])
        let different = CopyOnWriteBox([1, 2])

        #expect(box == shared)
        #expect(box == separate)
        #expect(box.storageIdentity != separate.storageIdentity)
        #expect(box != different)
    }

    @Test("Hashing follows the value, not the allocation")
    func hashingFollowsTheValue() {
        let box = CopyOnWriteBox([1, 2, 3])
        let separate = CopyOnWriteBox([1, 2, 3])

        #expect(box.hashValue == separate.hashValue)
        #expect(Set([box, separate]).count == 1)
    }
}

// MARK: - What the standard library already does

@Suite("Standard library copy-on-write")
struct StandardLibraryCopyOnWriteTests {

    @Test("Assigning an array shares its buffer")
    func assigningAnArraySharesItsBuffer() {
        let original = [1, 2, 3]
        let copy = original

        #expect(sharesElementBuffer(original, copy))
    }

    @Test("Mutating one of two sharers gives it its own buffer")
    func mutatingOneSharerCopiesTheBuffer() {
        let original = [1, 2, 3]
        var mutated = original

        mutated.append(4)

        #expect(sharesElementBuffer(original, mutated) == false)
        #expect(original == [1, 2, 3])
        #expect(mutated == [1, 2, 3, 4])
    }

    @Test("A struct of copy-on-write containers inherits the behaviour")
    func structOfContainersInheritsTheBehaviour() {
        // `ScanResult` stores an array and declares no copy-on-write of its own,
        // which is the point: it does not need any. This is why `CopyOnWriteBox`
        // has no production call site in this package.
        let barcode = DetectedBarcode(payload: "1", symbology: .qrCode, normalizedFrame: .zero)
        let original = ScanResult(barcodes: [barcode])
        let copy = original

        #expect(sharesElementBuffer(original.barcodes, copy.barcodes))
    }
}

// MARK: - let-first modelling

@Suite("let-first modelling and the with(_:) transform")
struct LetFirstModellingTests {

    private static let fixture = User(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
        email: "ada@example.com",
        name: "Ada",
        avatarURL: URL(string: "https://example.com/ada.png"),
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 2_000)
    )

    @Test("A transform with no arguments returns an equal user")
    func emptyTransformReturnsAnEqualUser() {
        #expect(Self.fixture.with() == Self.fixture)
    }

    @Test("Replacing one field leaves every other field alone")
    func replacingOneFieldLeavesTheRest() {
        let renamed = Self.fixture.with(name: .set("Grace"))

        #expect(renamed.name == "Grace")
        #expect(renamed.id == Self.fixture.id)
        #expect(renamed.email == Self.fixture.email)
        #expect(renamed.avatarURL == Self.fixture.avatarURL)
        #expect(renamed.createdAt == Self.fixture.createdAt)
        #expect(renamed.updatedAt == Self.fixture.updatedAt)
    }

    @Test("An optional field can be cleared without clearing anything else")
    func optionalFieldCanBeCleared() {
        let cleared = Self.fixture.with(avatarURL: .set(nil))

        #expect(cleared.avatarURL == nil)
        #expect(cleared.name == Self.fixture.name)
        #expect(cleared.updatedAt == Self.fixture.updatedAt)
    }

    @Test("Leaving an optional field alone is spelled differently from clearing it")
    func unchangedIsNotTheSameAsCleared() {
        // The distinction a `URL??` parameter cannot express: with plain
        // optionals both of these would be written `with(avatarURL: nil)`.
        #expect(Self.fixture.with(avatarURL: .unchanged).avatarURL == Self.fixture.avatarURL)
        #expect(Self.fixture.with(avatarURL: .set(nil)).avatarURL == nil)
    }

    @Test("Several fields can be replaced in one transform")
    func severalFieldsInOneTransform() {
        let stamp = Date(timeIntervalSince1970: 3_000)
        let updated = Self.fixture.with(name: .set("Grace"), updatedAt: .set(stamp))

        #expect(updated.name == "Grace")
        #expect(updated.updatedAt == stamp)
        #expect(updated.createdAt == Self.fixture.createdAt)
    }

    @Test("An unchanged update resolves to what it was applied to")
    func fieldUpdateAppliedToResolves() {
        #expect(FieldUpdate<Int>.unchanged.applied(to: 1) == 1)
        #expect(FieldUpdate<Int>.set(2).applied(to: 1) == 2)
        #expect(FieldUpdate<Int?>.set(nil).applied(to: 1) == nil)
    }
}

@Suite("The transform at the call site that used to lose fields")
@MainActor
struct ProfileUpdateTests {

    @Test("Updating the profile keeps the fields it was not asked about")
    func updatingProfileKeepsUntouchedFields() async throws {
        let repo = MockUserRepository()
        let avatar = URL(string: "https://example.com/mock.png")
        let created = Date(timeIntervalSince1970: 1_000)
        repo.stubbedUser = repo.stubbedUser.with(
            avatarURL: .set(avatar),
            createdAt: .set(created)
        )

        let updated = try await repo.updateProfile(name: "Renamed")

        #expect(updated.name == "Renamed")
        // All three of these were `nil` before `updateProfile` derived its new
        // value instead of rebuilding one.
        #expect(updated.avatarURL == avatar)
        #expect(updated.createdAt == created)
        #expect(updated.id == repo.stubbedUser.id)
    }
}
