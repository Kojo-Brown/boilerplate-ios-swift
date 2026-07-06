import Foundation

/// Represents the async loading lifecycle shared across ViewModels.
enum LoadingState<Value> {
    case idle
    case loading
    case success(Value)
    case failure(Error)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var value: Value? {
        if case .success(let v) = self { return v }
        return nil
    }

    var error: Error? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
