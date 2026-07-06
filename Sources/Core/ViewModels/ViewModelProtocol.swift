import Foundation

/// Common interface for all ViewModels in the application.
/// Conforming types should be marked `@Observable` and `@MainActor`.
@MainActor
protocol ViewModelProtocol: AnyObject {
    /// Called when the associated view appears on screen.
    func onAppear() async

    /// Called when the associated view disappears from screen.
    func onDisappear()
}

extension ViewModelProtocol {
    func onAppear() async {}
    func onDisappear() {}
}
