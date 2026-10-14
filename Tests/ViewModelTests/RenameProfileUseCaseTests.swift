import Foundation
import Testing
@testable import Core
@testable import Networking

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
}
