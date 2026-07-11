import Foundation

/// All programmatic navigation destinations within the authenticated app.
///
/// Add new cases here as features grow; `AppNavigationView.destination(for:)`
/// maps each case to its concrete view.
enum Route: Hashable {
    case settings
    case itemDetail(id: UUID, title: String)
    case textRecognition
    case barcodeScanner
}
