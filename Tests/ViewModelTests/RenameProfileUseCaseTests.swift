import Foundation
import Testing
@testable import Core
@testable import Networking

// Phase 12 item 2. This suite was written four cases at a time, each one
// before the behaviour it describes; `docs/tdd-kata.md` is the walk-through,
// including why cycle 4's second case was green the moment it was written.

// MARK: - Fixture

/// A strategy standing in for the server, with a profile already on it.
///
/// Every case in this suite is about what does and does not reach that server,
/// so the recording double is the whole fixture: `requestedNames` answers "this
/// is what was sent", and `updateCount` answers "nothing was sent" — which the
/// first of those cannot, since an empty list is also what a rejected name
/// looks like one assertion earlier.
private func strategyHolding(name: String) -> MockSyncStrategy {
    let strategy = MockSyncStrategy()
    strategy.stubbedUser = User(email: "ada@example.invalid", name: name)
    return strategy
}

// MARK: - Tests

@Suite("RenameProfileUseCase — the rules a profile name is held to")
struct RenameProfileUseCaseTests {

    // MARK: - The write itself

    /// The first thing the use-case has to do is the thing it is for: take a
    /// name, put it on the server, hand back what came off it. Everything after
    /// this is a rule about which names get that far.
    @Test("A valid name is written through and the saved profile comes back")
    func aValidNameIsWrittenThrough() async throws {
        let strategy = strategyHolding(name: "Ada")
        let rename = RenameProfileUseCase(strategy: strategy)

        let saved = try await rename.rename(to: "Ada Lovelace")

        #expect(saved.name == "Ada Lovelace")
        #expect(strategy.requestedNames == ["Ada Lovelace"])
    }

    // MARK: - Surrounding whitespace

    /// A name is typed into a `TextField`, so a leading or trailing space is
    /// not a caller's mistake — it is what a thumb produces, and iOS's own
    /// autocorrection adds one after a completed word. Sending it means the
    /// server stores `"Ada Lovelace "`, every later comparison against the name
    /// the reader believes they chose is false, and the profile row renders with
    /// a gap nobody can see to delete.
    @Test(
        "Surrounding whitespace never reaches the server",
        arguments: [
            "  Ada Lovelace",
            "Ada Lovelace  ",
            " \n Ada Lovelace \n ",
        ]
    )
    func surroundingWhitespaceIsRemoved(typed: String) async throws {
        let strategy = strategyHolding(name: "Ada")
        let rename = RenameProfileUseCase(strategy: strategy)

        let saved = try await rename.rename(to: typed)

        #expect(saved.name == "Ada Lovelace")
        #expect(strategy.requestedNames == ["Ada Lovelace"])
    }

    // MARK: - A name that is not a name

    /// The screen already refuses to enable Save for a blank field, and that is
    /// not the same as this. `canSave` guards a control; this guards the write,
    /// which `ProfileEffectHandler.perform(.saveName(_:))` reaches without
    /// asking any control whether it was enabled.
    ///
    /// What makes the second assertion the load-bearing one: a blank name sent
    /// to the server is accepted by it. The profile row then renders empty, the
    /// reader has no way back to a name they can see, and nothing failed.
    ///
    /// The error's own identity is asserted where the rule lives rather than
    /// here — see `ProfileNameTests` after cycle 4's refactor. What this suite
    /// is for is the boundary: refused, and nothing left for the server.
    @Test(
        "A name that is blank once trimmed is refused with no request made",
        arguments: [
            "",
            " ",
            "   \n\t ",
        ]
    )
    func blankNamesAreRefusedWithNoRequestMade(typed: String) async {
        let strategy = strategyHolding(name: "Ada")
        let rename = RenameProfileUseCase(strategy: strategy)

        await #expect(throws: (any Error).self) {
            try await rename.rename(to: typed)
        }

        #expect(strategy.updateCount == 0)
    }

    // MARK: - How long a name may be

    /// Asserted on both sides of the boundary, because a limit is the one kind
    /// of rule where the off-by-one is the whole defect: a ceiling checked with
    /// `<` instead of `<=` refuses a name that satisfies the rule the error
    /// message states, and no test that only tries 51 characters can tell.
    ///
    /// The number is written out rather than read off the type under test. A
    /// test that says `maximumLength` asserts that the code agrees with itself,
    /// and goes on passing when the constant moves — which is the change a
    /// reader of this suite most needs to see fail.
    @Test("A name at the ceiling is accepted and one character past it is not")
    func theCeilingIsEnforcedAtItsBoundary() async throws {
        let strategy = strategyHolding(name: "Ada")
        let rename = RenameProfileUseCase(strategy: strategy)
        let atTheCeiling = String(repeating: "a", count: 50)

        let saved = try await rename.rename(to: atTheCeiling)
        #expect(saved.name == atTheCeiling)

        await #expect(throws: (any Error).self) {
            try await rename.rename(to: atTheCeiling + "b")
        }

        #expect(strategy.requestedNames == [atTheCeiling])
    }

    /// This one is green the moment it is written, and it is in the red step
    /// anyway: its job is to fail on the *wrong* green rather than on the
    /// missing one. "At most 50 characters" has three plausible spellings in
    /// Swift and only one of them is the rule a reader would recognise.
    ///
    /// Twenty of these count as 20 characters, 140 Unicode scalars and 220
    /// UTF-16 code units, because each is four emoji joined by three
    /// zero-width joiners. `String.count` counts grapheme clusters — what a
    /// reader calls a character, and what the text cursor moves over — so a
    /// ceiling checked against `utf16.count` or `unicodeScalars.count` would
    /// refuse a name four to eleven times shorter than the one the error
    /// message promises, and every name it refused would be somebody's.
    @Test("The ceiling counts characters as a reader counts them")
    func theCeilingCountsCharactersNotCodeUnits() async throws {
        let strategy = strategyHolding(name: "Ada")
        let rename = RenameProfileUseCase(strategy: strategy)
        let families = String(repeating: "👩‍👩‍👧‍👦", count: 20)

        #expect(families.count == 20)
        #expect(families.unicodeScalars.count == 140)
        #expect(families.utf16.count == 220)

        let saved = try await rename.rename(to: families)

        #expect(saved.name == families)
    }
}
