import Foundation

/// Typed events broadcast across actor boundaries via `EventBus`.
enum AppEvent: Sendable, Equatable {
    case userLoggedIn(email: String)
    case userLoggedOut
    case profileUpdated(name: String)
    case itemRefreshRequested
}
