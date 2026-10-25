import CoreGraphics
import SwiftUI
import UIKit

// MARK: - Scheme

/// The colour scheme one snapshot is taken in.
///
/// SwiftUI has `ColorScheme` and this is not it, for two reasons. The raw value
/// is part of the golden's file name, so the vocabulary on disk and the
/// vocabulary in the catalogue cannot drift apart; and a parameterised Swift
/// Testing argument has to be `Sendable`, which a type this suite owns
/// certainly is.
enum SnapshotScheme: String, CaseIterable, Sendable {
    case light
    case dark

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    /// The same choice said to UIKit — see ``SnapshotRenderer`` for why it has
    /// to be said twice.
    var userInterfaceStyle: UIUserInterfaceStyle {
        self == .dark ? .dark : .light
    }
}

// MARK: - Type size

/// The dynamic type size one snapshot is taken at.
enum SnapshotTypeSize: String, CaseIterable, Sendable {

    /// `.large`, the size a device ships at. Set explicitly rather than left
    /// alone, so that a golden does not record whatever the simulator this ran
    /// on happened to be configured with.
    case standard

    /// One of the accessibility sizes, where a control that pinned its height
    /// clips and a label that assumed one line does not get one. This is the
    /// size the design system's `ScaledControlHeight` exists for.
    case accessibility3

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .standard: .large
        case .accessibility3: .accessibility3
        }
    }
}

// MARK: - Appearance

/// One point in the matrix a subject is rendered across.
struct SnapshotAppearance: Equatable, Sendable {
    var scheme: SnapshotScheme
    var typeSize: SnapshotTypeSize = .standard

    /// The suffix the two values contribute to a golden's file name.
    var fileNameSuffix: String {
        typeSize == .standard ? scheme.rawValue : "\(scheme.rawValue).\(typeSize.rawValue)"
    }
}

// MARK: - Renderer

/// Draws a view to a bitmap, deterministically.
///
/// `ImageRenderer` rather than a hosted `UIHostingController` and
/// `drawHierarchy(in:afterScreenUpdates:)`, which is what a snapshot library
/// would reach for. The hosted route has higher fidelity — it is the real
/// render server, so it draws materials, platform-backed controls and
/// everything else — and that fidelity is exactly the problem for a gate:
/// it needs a window, a run loop turn to settle, and it happily captures a
/// spinner mid-rotation. `ImageRenderer` walks SwiftUI's own display list
/// synchronously, on the main actor, with no window anywhere, and draws the
/// subset of a view tree that is a pure function of its state.
///
/// The cost is that the subset is real: a `UIViewRepresentable`, a
/// `Material`, an animating `ProgressView` and `NavigationStack` chrome either
/// come out blank or come out differently each time. That is why the catalogue
/// is a list rather than "every view in the package", and why
/// `docs/snapshot-testing.md` names what is excluded and why.
///
/// **The appearance is set twice on purpose.** `.environment(\.colorScheme, …)`
/// is what SwiftUI's own semantic colours read. The design system's tokens are
/// `Color(uiColor:)` wrappers around `UIColor`s with a dynamic provider
/// (`AppColors.surface`, `AppColors.success`), and a `UIColor` resolves against
/// the *current trait collection*. Setting only the environment leaves those
/// resolving light in a dark snapshot — a golden that is wrong in a way no
/// assertion about pixels can see, because it is perfectly reproducible. The
/// `semantic-colour-swatches` subject in the catalogue is the one that would
/// catch it: it draws nothing but those tokens, and its light and dark goldens
/// have to differ.
@MainActor
enum SnapshotRenderer {

    /// Points to pixels, which is a device's own scale and not the host's.
    static let scale: CGFloat = 2

    /// The margin between a subject and the edge of its canvas.
    ///
    /// Not cosmetic: `HomeItemCard` casts a shadow outside its own bounds, and
    /// a subject flush against the canvas edge records a clipped shadow that
    /// changes shape the first time the card's corner radius does.
    static let canvasPadding: CGFloat = 16

    static var currentEnvironment: SnapshotEnvironment {
        SnapshotEnvironment(
            iosVersion: UIDevice.current.systemVersion,
            scale: Double(scale),
            renderer: "SwiftUI.ImageRenderer",
            cases: SnapshotCase.all.map(\.fileName).sorted()
        )
    }

    enum Failure: Error, CustomStringConvertible {
        case rendererProducedNoImage
        case imageCouldNotBeNormalised

        var description: String {
            switch self {
            case .rendererProducedNoImage:
                return "ImageRenderer returned no image for this subject."
            case .imageCouldNotBeNormalised:
                return "the rendered image could not be read back as 8-bit sRGB."
            }
        }
    }

    /// Renders `content` on an opaque canvas `width` points wide.
    ///
    /// The height is whatever the subject asks for. Proposing one would hide
    /// the most legible failure this gate has: a view that grew a line reports
    /// a changed extent, which names both sizes, rather than a diff of a
    /// clipped image.
    ///
    /// The canvas is opaque for the same reason it is a canvas at all. A
    /// snapshot over transparency records antialiased edges as partial alpha,
    /// and partial alpha is the one case where a PNG round trip is lossy —
    /// premultiplied bytes in, unpremultiplied bytes on disk, and a rounding
    /// error back. The record lane asserts the round trip rather than assuming
    /// it, and this is what makes the assertion hold.
    static func bitmap(
        of content: some View,
        width: CGFloat,
        appearance: SnapshotAppearance
    ) throws -> SnapshotBitmap {
        // The order is load-bearing, and the first version had it wrong. An
        // environment modifier applies to the subtree *underneath* it, so with
        // `.background` written after `.environment` the canvas is a sibling
        // layer outside the subtree: it resolved `systemBackground` in the
        // ambient scheme and came out white behind every dark snapshot — which
        // made `home-item-row.dark` white text on a white page, and left the
        // white `AppColors.label` swatch invisible in the subject whose job is
        // to prove the tokens resolve. Environment modifiers go last.
        let canvas = content
            .padding(canvasPadding)
            .frame(width: width)
            .background(Color(uiColor: .systemBackground))
            .environment(\.colorScheme, appearance.scheme.colorScheme)
            .dynamicTypeSize(appearance.typeSize.dynamicTypeSize)

        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)

        // `performAsCurrent` hands back nothing — its closure is `() -> Void`,
        // not the generic form — so the render's result comes out through a
        // local. The closure is non-escaping and called synchronously, which is
        // what lets it touch this main-actor renderer at all.
        let traits = UITraitCollection(userInterfaceStyle: appearance.scheme.userInterfaceStyle)
        var rendered: CGImage?
        traits.performAsCurrent {
            rendered = renderer.cgImage
        }
        guard let image = rendered else {
            throw Failure.rendererProducedNoImage
        }
        guard let bitmap = SnapshotBitmap(image) else {
            throw Failure.imageCouldNotBeNormalised
        }
        return bitmap
    }
}
