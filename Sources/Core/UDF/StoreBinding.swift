import SwiftUI

extension Store {

    /// A `Binding` that reads one part of the state and writes by sending an
    /// action.
    ///
    /// SwiftUI's editable controls want two-way access to a value, and a store
    /// deliberately has no settable property to hand them. This is the adapter:
    /// the read is a key path into the state, and the write is an action, so a
    /// keystroke goes through the reducer like everything else.
    ///
    /// ```swift
    /// TextField("Name", text: store.binding(\.draftName, sending: Action.draftNameEdited))
    /// ```
    ///
    /// The setter uses the unawaited `send`, which reduces before it returns.
    /// That ordering is the whole reason that overload exists: a setter that
    /// scheduled the change instead of making it would let the field render the
    /// old value once and drop the character the reader just typed.
    package func binding<Value>(
        _ keyPath: KeyPath<F.State, Value>,
        sending action: @escaping (Value) -> F.Action
    ) -> Binding<Value> {
        Binding(
            get: { self.state[keyPath: keyPath] },
            set: { self.send(action($0)) }
        )
    }
}
