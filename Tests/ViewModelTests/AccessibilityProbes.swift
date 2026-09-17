import SwiftUI
import UIKit
@testable import Core
@testable import Features

// MARK: - What an element publishes

/// One element of the accessibility tree a view actually hands to an assistive
/// client.
///
/// Reading it rather than reading the source is the whole point of the suites
/// that use it. Accessibility in SwiftUI is not what the modifiers say: it is
/// what survives the framework's own combining, hiding and inference by the
/// time UIKit publishes the tree. `.accessibilityLabel` on a container with
/// two children, `.accessibilityHidden` on a view that was not an element
/// anyway, a `Button` whose label branch holds no text — each of those reads
/// as obviously correct in a diff and produces something different from what
/// it looks like it produces. Only the published tree says which.
struct AccessibilityNode: CustomStringConvertible {

    let label: String
    let value: String
    let hint: String
    let traits: UIAccessibilityTraits
    let frame: CGRect

    /// `@MainActor` because every property it reads is. UIKit's accessibility
    /// properties are declared on `NSObject` and isolated to the main actor in
    /// the iOS 18 SDK, so a plain `init` — nonisolated, like any struct's —
    /// cannot touch one. Taking the reading on the main actor is also correct
    /// rather than merely permitted: these are live view state, and this type
    /// exists to freeze them into a value a nonisolated assertion can hold.
    @MainActor
    init(_ element: NSObject) {
        label = element.accessibilityLabel ?? ""
        value = element.accessibilityValue ?? ""
        hint = element.accessibilityHint ?? ""
        traits = element.accessibilityTraits
        frame = element.accessibilityFrame
    }

    var isButton: Bool { traits.contains(.button) }
    var isHeader: Bool { traits.contains(.header) }
    var isSelected: Bool { traits.contains(.selected) }
    var isDisabled: Bool { traits.contains(.notEnabled) }
    var isStaticText: Bool { traits.contains(.staticText) }

    /// Spelled out in full because it is what a failure prints. A test that
    /// says "no button was published" and nothing else costs a CI round to
    /// diagnose; one that prints the tree it did find usually costs none.
    var description: String {
        "[label: \(label.debugDescription), value: \(value.debugDescription), "
            + "hint: \(hint.debugDescription), button: \(isButton), header: \(isHeader), "
            + "selected: \(isSelected), disabled: \(isDisabled), height: \(Int(frame.height))]"
    }
}

// MARK: - Reading the tree

/// Walks what a hosted view publishes, the way VoiceOver does.
///
/// UIKit exposes an accessibility tree through three mechanisms that a reader
/// has to try in order, because SwiftUI uses all three: a view can *be* an
/// element, it can vend an `accessibilityElements` array, or it can implement
/// the indexed `UIAccessibilityContainer` methods. Only when none of those
/// applies does the walk fall through to `subviews`, which is the ordinary
/// UIKit hierarchy and is not the accessibility one.
///
/// The recursion stops at an element rather than descending into it, which is
/// the rule that makes a count meaningful: a combined element has children in
/// the view hierarchy and is, to VoiceOver, one stop. Counting the views
/// underneath it would report the very thing `.accessibilityElement(children:
/// .combine)` exists to remove.
@MainActor
enum AccessibilityTree {

    /// A tree deep enough to hit this is a cycle, not a screen.
    private static let maximumDepth = 64

    /// Every element published under `root`, in the order UIKit hands them
    /// over — which is the order VoiceOver swipes through them.
    static func elements(under root: NSObject) -> [AccessibilityNode] {
        var found: [AccessibilityNode] = []
        var seen: Set<ObjectIdentifier> = []
        collect(root, depth: 0, into: &found, seen: &seen)
        return found
    }

    /// The names of every custom rotor published anywhere under `root`.
    ///
    /// Rotors are not elements and do not appear in ``elements(under:)``: they
    /// hang off whichever object the modifier was applied to, which may be a
    /// container that is not itself a stop. So this is a separate walk, and it
    /// descends *through* elements rather than stopping at them.
    static func rotorNames(under root: NSObject) -> [String] {
        var names: [String] = []
        var seen: Set<ObjectIdentifier> = []
        collectRotors(root, depth: 0, into: &names, seen: &seen)
        return names
    }

    // MARK: - Private

    private static func collect(
        _ node: NSObject,
        depth: Int,
        into found: inout [AccessibilityNode],
        seen: inout Set<ObjectIdentifier>
    ) {
        guard depth < maximumDepth, seen.insert(ObjectIdentifier(node)).inserted else { return }

        if node.isAccessibilityElement {
            found.append(AccessibilityNode(node))
            return
        }
        for child in children(of: node) {
            collect(child, depth: depth + 1, into: &found, seen: &seen)
        }
    }

    private static func collectRotors(
        _ node: NSObject,
        depth: Int,
        into names: inout [String],
        seen: inout Set<ObjectIdentifier>
    ) {
        guard depth < maximumDepth, seen.insert(ObjectIdentifier(node)).inserted else { return }

        for rotor in node.accessibilityCustomRotors ?? [] {
            names.append(rotor.name)
        }
        for child in everythingUnder(node) {
            collectRotors(child, depth: depth + 1, into: &names, seen: &seen)
        }
    }

    /// The accessibility children of `node`, by whichever of the three
    /// mechanisms it uses.
    private static func children(of node: NSObject) -> [NSObject] {
        if let elements = node.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { $0 as? NSObject }
        }
        let count = node.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0..<count).compactMap { node.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = node as? UIView {
            return view.subviews
        }
        return []
    }

    /// Both hierarchies at once, for the rotor walk: a rotor can be attached to
    /// a view that vends elements, and to one that does not.
    private static func everythingUnder(_ node: NSObject) -> [NSObject] {
        var result = (node.accessibilityElements ?? []).compactMap { $0 as? NSObject }
        if let view = node as? UIView {
            result.append(contentsOf: view.subviews)
        }
        return result
    }
}

// MARK: - Harness

/// Hosts one control with nothing around it, at a chosen text size.
///
/// The `Spacer` is what keeps the control at its natural height: a
/// ``RenderHarness`` fills a 402x874 window, and a lone control inside it would
/// otherwise be stretched to the window and report the window's height as its
/// own — which would make every Dynamic Type measurement below read 874.
struct ControlHarness<Content: View>: View {

    let typeSize: DynamicTypeSize
    let content: Content

    init(typeSize: DynamicTypeSize = .large, content: Content) {
        self.typeSize = typeSize
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .padding()
        .dynamicTypeSize(typeSize)
    }
}

// MARK: - Mounting

/// Mounts `content`, reads the tree it publishes, and takes the window down.
///
/// A free function rather than a method on the suites, because three of them
/// want it and it is the same four lines each time — mount, settle, read,
/// dismount, in that order. Skipping the second leaves the tree empty often
/// enough to be a flake; skipping the fourth leaves a key-window candidate
/// behind for every later test in the process.
@MainActor
func publishedElements(
    at typeSize: DynamicTypeSize = .large,
    of content: some View
) async -> [AccessibilityNode] {
    let harness = await RenderHarness.mount(ControlHarness(typeSize: typeSize, content: content))
    defer { harness.dismount() }
    await harness.settle()
    return AccessibilityTree.elements(under: harness.rootView)
}

/// The same, for the rotors rather than the elements.
@MainActor
func publishedRotorNames(of content: some View) async -> [String] {
    let harness = await RenderHarness.mount(ControlHarness(content: content))
    defer { harness.dismount() }
    await harness.settle()
    return AccessibilityTree.rotorNames(under: harness.rootView)
}
