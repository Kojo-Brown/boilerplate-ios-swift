import Foundation

/// A value type that owns one heap allocation and duplicates it only when a
/// shared copy is mutated.
///
/// ## When this is the wrong tool
///
/// Almost always. `Array`, `Dictionary`, `Set`, `String` and `Data` are already
/// copy-on-write, and a struct built out of them inherits the behaviour for
/// free — every model in this package is that shape and none of them needs this
/// type. Reaching for a hand-rolled box in front of a stdlib container adds an
/// allocation and buys nothing.
///
/// It earns its place in exactly one situation: a value type that must store a
/// **reference** — a class you do not own, an expensive-to-recreate handle, a
/// payload large enough that copying it per assignment shows up in a profile —
/// and must still behave like a value. Without something like this, the struct
/// *looks* like a value and silently is not:
///
/// ```swift
/// struct Draft {
///     private final class Body { var text = "" }
///     private var body = Body()
///     var text: String {
///         get { body.text }
///         set { body.text = newValue }   // writes through every copy
///     }
/// }
///
/// var a = Draft(); var b = a
/// b.text = "edited"
/// a.text        // "edited" — `b` was never a copy of anything
/// ```
///
/// Nothing there is a data race and nothing warns. `Draft` has reference
/// semantics wearing a struct's syntax, which is worse than a class: the call
/// site was written by someone who read `var b = a` as a copy.
/// `ImmutabilityTests` keeps that exact type compiled and run, so the failure is
/// demonstrated rather than asserted.
///
/// The only difference between it and this type is `makeUnique()`.
///
/// ## Usage
///
/// ```swift
/// var box = CopyOnWriteBox(HugePayload())
/// let shared = box                 // no copy: both point at one allocation
/// box.withValue { $0.append(1) }   // copies, because `shared` is still alive
/// shared.value                     // unchanged
/// ```
///
/// ## Mutate through `withValue`, not through `value`
///
/// `value` is a computed property, so `box.value.append(1)` is a get, a mutation
/// of the temporary, and a set — which copies the payload out and back on every
/// call and defeats the payload's own copy-on-write while it does. `withValue`
/// hands the storage out `inout` and mutates in place. The subscript-style
/// spelling that would close this gap is the underscored `_modify` accessor,
/// which is not language surface this package is willing to depend on.
package struct CopyOnWriteBox<Value> {

    /// The single allocation.
    ///
    /// Deliberately unexposed. The `@unchecked Sendable` conformance below is
    /// sound only while every mutation funnels through `makeUnique()`, and that
    /// stays checkable by reading one file exactly as long as nothing outside
    /// this file can reach a `Storage`.
    private final class Storage {
        var value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private var storage: Storage

    package init(_ value: Value) {
        storage = Storage(value)
    }

    /// The boxed value.
    ///
    /// Reading is free. Writing copies first if this box is not the only owner,
    /// which is what stops the write being visible through every other copy.
    package var value: Value {
        get { storage.value }
        set {
            makeUnique()
            storage.value = newValue
        }
    }

    /// Mutate the boxed value in place, copying first only if the storage is
    /// shared.
    ///
    /// Prefer this to `box.value = ...` whenever the new value is derived from
    /// the old one: it performs at most one copy, where the property does two.
    package mutating func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        makeUnique()
        return try body(&storage.value)
    }

    // MARK: - Inspection
    //
    // Copy-on-write is a performance claim, and a performance claim nothing
    // measures is a hope. These two are how the tests observe when a copy did
    // and did not happen; they are also what a future reader can reach for
    // instead of trusting this comment.

    /// Identity of the allocation this box currently points at.
    ///
    /// Two boxes sharing an allocation report the same identity; the moment one
    /// of them is mutated, they stop. Only ever compared — an identity outlives
    /// nothing, so holding one past the box that produced it says nothing.
    package var storageIdentity: ObjectIdentifier {
        ObjectIdentifier(storage)
    }

    /// Whether this box is the sole owner of its allocation, and so whether the
    /// next mutation will copy.
    ///
    /// `mutating` because `isKnownUniquelyReferenced(_:)` needs exclusive access
    /// to the reference it is asked about — which is also why a box held in a
    /// `let` cannot be asked.
    package mutating func isUniquelyReferenced() -> Bool {
        isKnownUniquelyReferenced(&storage)
    }

    // MARK: - Private

    /// The whole mechanism.
    ///
    /// `isKnownUniquelyReferenced(_:)` reads the object's reference count, which
    /// is exactly the question "does anyone else see the write I am about to
    /// make". A shared allocation is replaced by a fresh one holding a copy, so
    /// the caller mutates something only it can observe.
    private mutating func makeUnique() {
        guard !isKnownUniquelyReferenced(&storage) else { return }
        storage = Storage(storage.value)
    }
}

// MARK: - Conformances

/// The one `@unchecked Sendable` in this package that is not AVFoundation's
/// shape, and the reason value semantics belongs in a document about
/// concurrency: an unsynchronised mutable heap buffer is safe to send precisely
/// because sending copies the struct, and a mutation through one copy allocates
/// rather than writing where another copy can see it.
///
/// `Array` makes the identical bargain for the identical reason. The check the
/// compiler cannot make is that `Storage` never escapes and that every write
/// goes through `makeUnique()`; both hold in the file above, and
/// `.github/scripts/assert-sendable-audit.py` records the claim.
///
/// Concurrent mutation of two copies is safe because the only access either
/// makes to the shared allocation is a *read* — of the reference count, and
/// then of the value being copied out of it. Neither can observe a torn write,
/// because no write to shared storage ever happens.
///
/// Conditional on `Value`, so a box of a non-`Sendable` payload is simply not
/// sendable rather than being an unchecked promise about someone else's type.
extension CopyOnWriteBox: @unchecked Sendable where Value: Sendable {}

extension CopyOnWriteBox: Equatable where Value: Equatable {
    /// Boxes sharing an allocation are equal without looking at the value, which
    /// is the one comparison copy-on-write makes cheaper rather than dearer.
    package static func == (lhs: CopyOnWriteBox, rhs: CopyOnWriteBox) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.value == rhs.storage.value
    }
}

extension CopyOnWriteBox: Hashable where Value: Hashable {
    package func hash(into hasher: inout Hasher) {
        hasher.combine(storage.value)
    }
}
