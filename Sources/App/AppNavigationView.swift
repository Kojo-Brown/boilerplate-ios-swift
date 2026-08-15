import SwiftUI

/// Coordinator-backed `NavigationStack` for the authenticated app flow.
///
/// This is the single source of truth for route→view resolution.
/// Child views navigate by calling `coordinator.push(_:)` rather than
/// embedding `NavigationLink(destination:)` directly — keeping navigation
/// logic out of view bodies and testable in isolation.
struct AppNavigationView: View {
    let container: AppContainer

    @Environment(AppCoordinator.self) private var coordinator

    /// Explicit because `coordinator` is `private`, which would otherwise make
    /// the synthesised memberwise initialiser private and unreachable from
    /// `RootView`.
    init(container: AppContainer) {
        self.container = container
    }

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            HomeView(container: container)
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .settings:
            SettingsView()
        case .itemDetail(let id, let title):
            ItemDetailView(id: id, title: title)
        case .textRecognition:
            TextRecognitionView(container: container)
        case .barcodeScanner:
            BarcodeScannerView(container: container)
        }
    }
}

#Preview {
    AppNavigationView(container: .preview)
        .environment(AppState())
        .environment(AppCoordinator())
}
