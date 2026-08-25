import Foundation

/// The body of the profile `PATCH`.
///
/// It lives beside `UserRepository`, the only thing that sends it, rather than
/// in `Features/Auth` where it used to sit next to `LoginRequest`. That was the
/// one edge in the whole tree that pointed the wrong way: the repository layer
/// named a type owned by a feature, so `Networking` could not have been split
/// out without dragging a screen's models along with it.
package struct UpdateProfileRequest: Encodable, Sendable {
    package let name: String

    package enum CodingKeys: String, CodingKey {
        case name
    }
}
