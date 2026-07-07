import SwiftUI

/// Detail view for a `HomeItem`. Reached by pushing `.itemDetail` via `AppCoordinator`.
struct ItemDetailView: View {
    let id: UUID
    let title: String

    var body: some View {
        List {
            Section("Details") {
                LabeledContent("Title", value: title)
                LabeledContent("ID", value: id.uuidString)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ItemDetailView(id: UUID(), title: "Preview Item")
    }
}
