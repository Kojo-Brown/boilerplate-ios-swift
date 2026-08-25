import Core
import SwiftUI

// MARK: - ScannerOverlayView

/// PreviewProvider-style catalogue for `ScannerOverlayView`.
/// `BarcodeScannerView` requires a live camera, so its preview uses the overlay only.
package struct ScannerOverlayView_Previews: PreviewProvider {
    package static var previews: some View {
        Group {
            ZStack {
                Color.black.ignoresSafeArea()
                ScannerOverlayView(isScanning: true)
            }
            .previewDisplayName("Scanning – Active")

            ZStack {
                Color.black.ignoresSafeArea()
                ScannerOverlayView(isScanning: false)
            }
            .previewDisplayName("Scanning – Paused")
        }
    }
}

// MARK: - BarcodeScannerView

/// PreviewProvider for `BarcodeScannerView`.
/// Renders within a NavigationStack to match the runtime embedding context.
package struct BarcodeScannerView_Previews: PreviewProvider {
    package static var previews: some View {
        NavigationStack {
            BarcodeScannerView(dependencies: PreviewBarcodeScannerDependencies())
                .environment(AppCoordinator())
        }
        .previewDisplayName("Barcode Scanner")
    }
}
