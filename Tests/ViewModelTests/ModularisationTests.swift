import Foundation
import SwiftUI
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - What the split has to keep true

/// The two halves of Phase 8 item 7 that a test can hold.
///
/// The first half — that `Core` cannot see `Networking`, that a file cannot lean
/// on a module it never imported, that one feature cannot name another — is not
/// here, and deliberately not. Those are properties of the *whole tree*, and a
/// test that walked the tree would have to be handed the tree: XCTest bundles
/// carry resources, not the repository. `Tools/assert-module-boundaries.py`
/// checks them from the lint job, where it also runs on the Linux agent that
/// cannot build this package at all.
///
/// What is left over is exactly what a test is better at: the seam the split
/// created. Every screen now states what it needs, and two separate things have
/// to be true about that statement — the composition root has to satisfy it, and
/// the feature has to be able to satisfy it *without* the composition root. The
/// second is the one that says the module really came apart: if a screen could
/// only ever be built from `AppContainer`, `Features` would still depend on the
/// app in everything but the manifest.
@Suite("Modularisation — the seam between a screen and the composition root")
@MainActor
struct ModularisationTests {

    // MARK: - The root's side

    /// Each binding is the assertion: an `AppContainer` that stopped satisfying
    /// one of these would not compile here.
    @Test("The composition root satisfies every screen's dependency protocol")
    func compositionRootSatisfiesEveryScreen() {
        let container = AppContainer.preview

        let login: any LoginDependencies = container
        let home: any HomeDependencies = container
        let settings: any SettingsDependencies = container
        let text: any TextRecognitionDependencies = container
        let barcode: any BarcodeScannerDependencies = container

        // And the factories reached through the protocol are the container's,
        // not a default hiding behind one.
        #expect(login.makeLoginViewModel().isAuthenticated == false)
        #expect(home.makeHomeViewModel().items.isEmpty)
        #expect(settings.makeProfileStore().state.phase == .idle)
        #expect(text.makeTextRecognitionViewModel().isScanning == false)
        #expect(barcode.makeBarcodeScannerViewModel().isScanning == false)
    }

    @Test("The root's own bus reaches a view model it built through the protocol")
    func theRootBindsItsOwnBusThroughTheProtocol() async throws {
        let container = AppContainer.preview
        let login: any LoginDependencies = container

        let bus = try #require(login.eventPublisher as? EventBus)
        #expect(bus === (container.eventSubscriber as? EventBus))
    }

    // MARK: - The feature's side

    /// The property that makes `Features` a module rather than a directory: it
    /// can build its own screens with doubles it owns, and `AppContainer` is not
    /// one of them.
    @Test("Every screen builds from the double its own feature ships")
    func everyScreenBuildsWithoutTheCompositionRoot() {
        _ = LoginView(dependencies: PreviewLoginDependencies())
        _ = HomeView(dependencies: PreviewHomeDependencies())
        _ = SettingsView(dependencies: PreviewSettingsDependencies())
        _ = TextRecognitionView(dependencies: PreviewTextRecognitionDependencies())
        _ = BarcodeScannerView(dependencies: PreviewBarcodeScannerDependencies())
    }

    @Test("The Auth double wires the mocks, not the live graph")
    func authDoubleWiresMocks() {
        let dependencies = PreviewLoginDependencies()

        #expect(dependencies.eventPublisher is EventBus)
        #expect(dependencies.makeLoginViewModel().isFormValid == false)
        #expect(dependencies.makeSocialLoginViewModel().errorMessage == nil)
        // `MockBiometricAuthService` stubs availability on, which is what makes
        // the biometric section appear in the preview at all.
        #expect(dependencies.makeBiometricAuthViewModel().isAvailable)
    }

    /// The pairing `AppContainer.preview` makes and this double has to make too:
    /// the store and the factory hand back the *same* strategy, so a preview
    /// that pulls to refresh does not swap the data underneath itself.
    @Test("The Settings double vends one strategy to the store and the factory")
    func settingsDoubleSharesOneStrategy() async {
        let dependencies = PreviewSettingsDependencies()
        let store = dependencies.makeProfileStore()

        await store.send(.appeared)

        #expect(store.state.user != nil)
        #expect(store.state.origin == .remote)
    }

    @Test("The camera doubles produce a scanner that has not started")
    func cameraDoublesProduceIdleScanners() {
        #expect(PreviewTextRecognitionDependencies().makeTextRecognitionViewModel().recognitionResult == nil)
        #expect(PreviewBarcodeScannerDependencies().makeBarcodeScannerViewModel().scanResult == nil)
    }
}
