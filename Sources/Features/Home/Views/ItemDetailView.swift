import SwiftUI

/// Detail view for a `HomeItem`. Reached by pushing `.itemDetail` via `AppCoordinator`.
package struct ItemDetailView: View {
    package let id: UUID
    package let title: String

    package init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    package var body: some View {
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
