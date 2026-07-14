import SwiftUI

// MARK: - ScannerOverlayView

/// PreviewProvider-style catalogue for `ScannerOverlayView`.
/// `BarcodeScannerView` requires a live camera, so its preview uses the overlay only.
struct ScannerOverlayView_Previews: PreviewProvider {
    static var previews: some View {
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
struct BarcodeScannerView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            BarcodeScannerView()
                .environment(AppCoordinator())
        }
        .previewDisplayName("Barcode Scanner")
    }
}
