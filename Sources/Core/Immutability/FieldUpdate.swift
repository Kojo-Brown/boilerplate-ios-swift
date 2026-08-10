import Foundation

/// One field of a `with(...)` transform: left as it was, or replaced.
///
/// `let`-first modelling removes the setters, so every edit has to be spelled
/// as "the same value, except". The usual way to write that is a method whose
/// parameters all default to `nil`, meaning "not supplied":
///
/// ```swift
/// func with(name: String? = nil, avatarURL: URL?? = nil) -> User
/// ```
///
/// That works for `name` and is a trap for `avatarURL`. The field is already
/// optional, so "not supplied" and "set it to nil" collide, and the usual fix is
/// a double optional. Then `user.with(avatarURL: nil)` compiles, reads at the
/// call site as *clear the avatar*, and means *leave the avatar alone* — `nil`
/// binds to the outer optional. There is no diagnostic, because both readings
/// type-check.
///
/// Naming the two cases removes the ambiguity instead of documenting it.
/// `.unchanged` is the default, `.set(nil)` clears, and neither can be spelled
/// as the other by accident:
///
/// ```swift
/// user.with(name: .set("Ada"))       // rename, keep the avatar
/// user.with(avatarURL: .set(nil))    // clear the avatar, keep the name
/// user.with()                        // a copy, which is `user`
/// ```
enum FieldUpdate<Value> {
    /// Keep whatever the source value holds for this field.
    case unchanged
    /// Replace the field, including with `nil` when `Value` is itself optional.
    case set(Value)

    /// Resolve the update against the value it is being applied to.
    func applied(to current: Value) -> Value {
        switch self {
        case .unchanged: current
        case .set(let replacement): replacement
        }
    }
}

/// Conditional rather than unconditional, matching `LoadingState`: an update
/// carrying a non-`Sendable` `Value` stays usable on the actor that owns it.
extension FieldUpdate: Sendable where Value: Sendable {}

extension FieldUpdate: Equatable where Value: Equatable {}
