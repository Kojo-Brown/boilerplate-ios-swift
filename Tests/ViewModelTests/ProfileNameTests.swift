import Foundation
import Testing
@testable import Core

/// The rules, asserted where they now live.
///
/// `RenameProfileUseCaseTests` asserts the boundary — refused, and nothing left
/// for the server — and is deliberately indifferent to which rule was broken.
/// This suite is the other half: which rule, and what the refusal says.
@Suite("ProfileName — what may be a name")
struct ProfileNameTests {

    @Test("A name is its trimmed form, and two spellings of one name are equal")
    func normalisationIsPartOfIdentity() throws {
        let typed = try ProfileName(validating: " Ada Lovelace \n")
        let pasted = try ProfileName(validating: "Ada Lovelace")

        #expect(typed.value == "Ada Lovelace")
        #expect(typed == pasted)
    }

    @Test(
        "A name that is blank once trimmed is refused as empty",
        arguments: [
            "",
            " ",
            "   \n\t ",
        ]
    )
    func blankNamesAreRefusedAsEmpty(raw: String) {
        #expect(throws: ProfileNameError.empty) {
            try ProfileName(validating: raw)
        }
    }

    @Test("A name past the ceiling is refused, and the error carries the limit")
    func anOverlongNameIsRefusedWithItsLimit() {
        #expect(throws: ProfileNameError.tooLong(limit: 50)) {
            try ProfileName(validating: String(repeating: "a", count: 51))
        }
    }

    /// What the reader is told, rather than what the code threw. The limit is
    /// an argument to a localised string, and the failure worth pinning is the
    /// one where the key and its value disagree about taking an argument: the
    /// sentence then renders without the number, or with a literal `%lld`, and
    /// nothing else in the suite would notice.
    ///
    /// The prose itself is not asserted. It is a translation, and a test that
    /// pins English makes the catalog harder to edit without making the app
    /// more correct.
    @Test("The refusal for length states the limit it was refused against")
    func theLengthRefusalStatesItsLimit() throws {
        let message = try #require(ProfileNameError.tooLong(limit: 50).errorDescription)

        #expect(message.contains("50"))
        #expect(!message.contains("%"))
    }

    @Test("The refusal for a blank name is a sentence, not a key")
    func theBlankRefusalIsASentence() throws {
        let message = try #require(ProfileNameError.empty.errorDescription)

        #expect(message != "error.profileName.empty")
        #expect(!message.isEmpty)
    }
}
