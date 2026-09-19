import Foundation
import Testing
@testable import Core
@testable import Features
@testable import Networking

// MARK: - The defect these suites exist for

/// Every string this package shows, resolved.
///
/// The assertion is the same in all three suites and it is not a formality: a
/// `LocalizedStringResource` built without a `bundle:` argument resolves
/// against `Bundle.main`, a package target's catalog is not in `Bundle.main`,
/// and Foundation's documented fallback for a missing key is to hand back
/// **the key**. So the whole of this package's text would render as
/// `home.title`, `settings.signOut`, `error.api.unauthorized` — in every
/// language, including the one the catalog is written in.
///
/// Nothing else catches it. It compiles, it does not warn, it does not crash,
/// and a preview built into the same module as its catalog resolves correctly
/// because both are in the same bundle — the failure needs them to be in
/// *different* ones, which is the arrangement every shipped call site is in.
/// Comparing the resolved string to its own key is what separates "looked it
/// up" from "gave up and echoed the key back".
///
/// The pairs below are one per key in each target's catalog, and
/// `Tools/assert-localisation.py` fails if the two lists ever disagree — so a
/// key added to a catalog without a test, or tested without existing, is a red
/// lint job rather than a gap nobody notices.
func expectResolves(_ resource: LocalizedStringResource, key: String) {
    let resolved = String(localized: resource)

    #expect(resolved != key, "\(key) resolved to its own key — the catalog was not consulted")
    #expect(!resolved.isEmpty, "\(key) resolved to an empty string")
}

// MARK: - Core

@Suite("Core's String Catalog")
struct CoreLocalisationTests {

    static let everyString: [(LocalizedStringResource, String)] = [
        (CoreStrings.appearance(.system), "appearance.system"),
        (CoreStrings.appearance(.light), "appearance.light"),
        (CoreStrings.appearance(.dark), "appearance.dark"),
        (CoreStrings.API.invalidURL, "error.api.invalidURL"),
        (CoreStrings.API.invalidResponse, "error.api.invalidResponse"),
        (CoreStrings.API.unauthorized, "error.api.unauthorized"),
        (CoreStrings.API.tokenRefreshFailed, "error.api.tokenRefreshFailed"),
        (CoreStrings.API.httpStatus(503), "error.api.httpStatus %lld"),
        (CoreStrings.API.decodingFailed("keyNotFound"), "error.api.decodingFailed %@"),
        (CoreStrings.Biometrics.notAvailable, "error.biometrics.notAvailable"),
        (CoreStrings.Biometrics.notEnrolled, "error.biometrics.notEnrolled"),
        (CoreStrings.Biometrics.userCancelled, "error.biometrics.userCancelled"),
        (CoreStrings.Biometrics.userFallback, "error.biometrics.userFallback"),
        (CoreStrings.Biometrics.systemCancelled, "error.biometrics.systemCancelled"),
        (CoreStrings.Biometrics.passcodeNotSet, "error.biometrics.passcodeNotSet"),
        (CoreStrings.Biometrics.lockout, "error.biometrics.lockout"),
        (CoreStrings.Pagination.moreItemsPromisedWithoutCursor, "error.pagination.moreItemsPromisedWithoutCursor"),
        (CoreStrings.Pagination.unusableCursor, "error.pagination.unusableCursor"),
        (CoreStrings.Pagination.cursorDidNotAdvance, "error.pagination.cursorDidNotAdvance"),
        (CoreStrings.Pagination.emptyPageLimit(4), "error.pagination.emptyPageLimit %lld"),
        (CoreStrings.Persistence.userNotFound, "error.persistence.userNotFound"),
        (CoreStrings.Persistence.staleServerCopy, "error.merge.staleServerCopy"),
    ]

    /// Written as a loop rather than `@Test(arguments:)`, and the reason is
    /// worth recording because it will come up for anything else this table
    /// holds. Swift Testing requires a parameterised test's arguments to be
    /// `Sendable`, and `LocalizedStringResource`'s conformance to `Sendable`
    /// is annotated `@available(iOS 18, *)` while this package deploys to iOS
    /// 17 — so the macro expansion warns at every such `@Test`, four times
    /// each, and this repo fails a build that emits any warning at all
    /// (Phase 0 item 4). Raising the deployment target to satisfy a test would
    /// be the tail wagging the dog. What is lost is per-case reporting, not
    /// coverage: the loop asserts the same keys and each expectation names the
    /// one it failed on.
    @Test("Every string Core declares resolves out of Core's own catalog")
    func everyCoreStringResolves() {
        for (resource, key) in Self.everyString {
            expectResolves(resource, key: key)
        }
    }

    /// The error vocabulary is reached through `LocalizedError`, not through
    /// the namespace, and that path has its own way of going wrong: a
    /// `localizedDescription` that echoes a key is what a reader sees.
    @Test("An error's localizedDescription is the catalog's sentence")
    func errorDescriptionsResolve() {
        #expect(APIError.unauthorized.localizedDescription == CoreStrings.API.unauthorized.string)
        #expect(!APIError.unauthorized.localizedDescription.contains("error.api"))
        #expect(PersistenceError.userNotFound.localizedDescription == CoreStrings.Persistence.userNotFound.string)
    }

    /// An interpolated argument has to survive the round trip through the
    /// catalog. A key built as `error.api.httpStatus %lld` and a catalog entry
    /// spelled any other way would resolve to the key and take the number with
    /// it.
    @Test("An interpolated number reaches the resolved sentence")
    func interpolationSurvives() {
        #expect(CoreStrings.API.httpStatus(503).string.contains("503"))
        #expect(CoreStrings.API.decodingFailed("keyNotFound").string.contains("keyNotFound"))
        #expect(APIError.httpError(statusCode: 418, data: Data()).localizedDescription.contains("418"))
    }
}

// MARK: - Networking

@Suite("Networking's String Catalog")
struct NetworkingLocalisationTests {

    static let everyString: [(LocalizedStringResource, String)] = [
        (NetworkingStrings.UserRepository.notFound, "error.user.notFound"),
        (NetworkingStrings.UserRepository.unauthorized, "error.user.unauthorized"),
        (NetworkingStrings.UserRepository.networkUnavailable, "error.user.networkUnavailable"),
    ]

    /// Three keys, and a catalog of its own to hold them. `Bundle.module` is
    /// generated per target and resolves to the bundle of the module it is
    /// compiled into, so `Core`'s catalog is reachable only from `Core` — this
    /// suite is what would fail if these three were ever moved there and
    /// looked up across the boundary.
    ///
    /// A loop rather than `@Test(arguments:)` — see
    /// ``CoreLocalisationTests/everyCoreStringResolves()``.
    @Test("Every string Networking declares resolves")
    func everyNetworkingStringResolves() {
        for (resource, key) in Self.everyString {
            expectResolves(resource, key: key)
        }
    }

    @Test("The repository's errors describe themselves from the catalog")
    func repositoryErrorsResolve() {
        #expect(UserRepositoryError.notFound.localizedDescription == NetworkingStrings.UserRepository.notFound.string)
        #expect(!UserRepositoryError.notFound.localizedDescription.contains("error.user"))
    }
}
