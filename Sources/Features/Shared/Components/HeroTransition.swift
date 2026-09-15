import Core
import SwiftUI

// MARK: - Proxy

/// The two things both ends of a hero transition have to agree on: the
/// namespace they are matched in, and which element is currently expanded.
///
/// It is handed to the caller rather than read from the environment because
/// `matchedGeometryEffect` is unforgiving about the second one. A pair is only
/// matched while exactly one of its two views claims to be the geometry
/// *source*; with two sources the effect reports a warning and picks one, and
/// with none the destination collapses to zero size. Neither failure is visible
/// in the source of either view — each one looks correct on its own — so the
/// decision is taken once, here, and the two modifiers below read it off rather
/// than each being told.
package struct HeroProxy<ID: Hashable>: Equatable {

    /// The namespace both ends are matched in. Owned by ``HeroScope``.
    package let namespace: Namespace.ID

    /// The element currently expanded, if any.
    package let expandedID: ID?

    package init(namespace: Namespace.ID, expandedID: ID?) {
        self.namespace = namespace
        self.expandedID = expandedID
    }

    /// Whether `id` is the element currently expanded.
    package func isExpanded(_ id: ID) -> Bool {
        expandedID == id
    }

    /// Whether the collapsed element for `id` is the one providing geometry.
    ///
    /// It is, right up until it is expanded: while the card is open the
    /// *expanded* view is the real one, and the cell left behind in the
    /// collection follows it. That is what makes a collapse animate — the cell
    /// is already where the card is, so removing the card hands the frame back
    /// along the same path it came.
    package func collapsedIsSource(_ id: ID) -> Bool {
        !isExpanded(id)
    }

    /// Whether the expanded element for `id` is the one providing geometry.
    ///
    /// The exact complement of ``collapsedIsSource(_:)``, and deliberately
    /// spelled as its own method rather than left for each call site to negate:
    /// the invariant the whole effect rests on is that these two never agree,
    /// and stated this way it is one line for a test to hold them to.
    package func expandedIsSource(_ id: ID) -> Bool {
        isExpanded(id)
    }
}

// MARK: - Marking the two ends

extension View {

    /// Marks this view as the collapsed end of a hero pair — the cell in the
    /// grid, the row in the list, the thumbnail.
    ///
    /// Apply it to the element whose frame the expanded card should grow out
    /// of, and *before* any offset or scale that element wears for its own
    /// reasons. `matchedGeometryEffect` records the frame of the view it is
    /// applied to, as that view stands at the moment it is applied, so a
    /// transform applied underneath is a transform baked into the frame the
    /// other end animates toward.
    package func heroSource<ID: Hashable>(_ id: ID, in proxy: HeroProxy<ID>) -> some View {
        matchedGeometryEffect(
            id: id,
            in: proxy.namespace,
            isSource: proxy.collapsedIsSource(id)
        )
    }

    /// Marks this view as the expanded end of a hero pair — the card, the
    /// full-screen photo, the detail.
    ///
    /// The same ordering rule applies, and it is what ``HeroScope`` exists to
    /// get right: the drag transform of an interactive dismissal is applied by
    /// the scope *outside* whatever this closure returns, so the frame recorded
    /// here is the card's resting frame. Applied the other way around, letting
    /// go half-way through a drag would send the cell back to wherever the
    /// finger had dragged the card to rather than to its slot in the grid.
    package func heroDestination<ID: Hashable>(_ id: ID, in proxy: HeroProxy<ID>) -> some View {
        matchedGeometryEffect(
            id: id,
            in: proxy.namespace,
            isSource: proxy.expandedIsSource(id)
        )
    }
}

// MARK: - Scope

/// A collection and the card that grows out of it, sharing one namespace.
///
/// ```swift
/// HeroScope(expanded: $expandedID) { proxy in
///     LazyVGrid(columns: columns) {
///         ForEach(items) { item in
///             Thumbnail(item)
///                 .heroSource(item.id, in: proxy)
///                 .onTapGesture { expandedID = item.id }
///         }
///     }
/// } detail: { id, proxy in
///     DetailCard(id: id)
///         .heroDestination(id, in: proxy)
/// }
/// ```
///
/// ## Why this is not a `NavigationStack` push
///
/// A matched pair has to be in one view tree for SwiftUI to interpolate
/// between the two frames, and a push is a change of tree: the source is on the
/// screen being covered and the destination is on the screen doing the
/// covering, in a different `Namespace` that the pushed view cannot reach. The
/// hero presentation is therefore an overlay in the same tree, which is also
/// what makes the dismissal interactive — the collection is still mounted
/// behind the card and still holds its scroll position, so a cancelled
/// dismissal returns to exactly what was there.
///
/// ## What it costs
///
/// The collection stays mounted and keeps its state, which is the point, and
/// it also keeps rendering: a hero overlay does not free the memory a pushed
/// screen would. For a grid of thumbnails that is the trade everyone makes. For
/// a detail screen that loads its own data, push and settle for a cross-fade.
package struct HeroScope<ID: Hashable, Content: View, Detail: View>: View {

    @Binding private var expanded: ID?
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let engine: InteractiveDismissEngine
    private let content: (HeroProxy<ID>) -> Content
    private let detail: (ID, HeroProxy<ID>) -> Detail

    /// - Parameters:
    ///   - expanded: the element currently presented. Setting it presents,
    ///     clearing it dismisses, and both animate — the scope owns the
    ///     animation so a caller cannot forget the `withAnimation` that makes
    ///     the effect an effect rather than a jump cut.
    ///   - detail: built only while something is expanded, and handed the same
    ///     proxy as `content` so it can mark its own matched end.
    package init(
        expanded: Binding<ID?>,
        engine: InteractiveDismissEngine = InteractiveDismissEngine(),
        @ViewBuilder content: @escaping (HeroProxy<ID>) -> Content,
        @ViewBuilder detail: @escaping (ID, HeroProxy<ID>) -> Detail
    ) {
        _expanded = expanded
        self.engine = engine
        self.content = content
        self.detail = detail
    }

    package var body: some View {
        ZStack {
            content(proxy)

            if let id = expanded {
                InteractiveDismissLayer(engine: engine, onDismiss: { expanded = nil }) {
                    detail(id, proxy)
                }
                // `.identity` rather than the default `.opacity`: the card is
                // already animating from the cell's frame, and a cross-fade on
                // top of that shows the cell through the card for the length of
                // the transition. The scrim inside the layer keeps a fade of
                // its own, which is the one piece that has nowhere to grow
                // from.
                .transition(.identity)
                // Opening a different element while one is already open is a
                // different presentation, not the same one with new contents.
                // Without this the card keeps its structural identity across
                // the switch and SwiftUI reuses it: the drag half-way through
                // when the second card opened stays applied, a scroll position
                // inside the first card carries into the second, and the new
                // pair never mounts, so it never animates out of its own cell.
                .id(id)
                .zIndex(1)
            }
        }
        .animation(presentationAnimation, value: expanded)
    }

    // MARK: - Private

    private var proxy: HeroProxy<ID> {
        HeroProxy(namespace: namespace, expandedID: expanded)
    }

    /// A spring, unless the reader has asked the system for less motion.
    ///
    /// Reduce Motion is not "no animation": an element that appears with no
    /// transition at all is harder to follow, not easier. What the setting asks
    /// for is the removal of the *movement* — the zoom across the screen — and
    /// a short cross-fade in its place. The matched geometry still runs, so the
    /// card still lands in the right place; it simply gets there without a
    /// spring's overshoot.
    private var presentationAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.42, dampingFraction: 0.82)
    }
}

// MARK: - Interactive dismissal

/// An expanded card, the scrim behind it, and the drag that takes both away.
///
/// Usable on its own — a sheet, a lightbox, anything presented over something
/// else — but it is the half of ``HeroScope`` that has to be its own view,
/// because the drag it tracks has to live somewhere that is not rebuilt when
/// the presentation changes.
///
/// The gesture state is `@GestureState` rather than `@State` on purpose. A
/// dismissal can be interrupted by something that is not a finger lifting — an
/// incoming call, a system gesture claiming the touch, the view being removed
/// under it — and `onEnded` does not run when a gesture is cancelled. `@State`
/// would keep the last translation it was given and leave the card stranded
/// half-dragged with nothing to put it back; `@GestureState` is reset by the
/// framework whenever the gesture stops for any reason, so the spring-back is
/// the default and the dismissal is the special case.
package struct InteractiveDismissLayer<Detail: View>: View {

    private let engine: InteractiveDismissEngine
    private let onDismiss: () -> Void
    private let detail: Detail

    @GestureState private var translation: CGSize = .zero

    package init(
        engine: InteractiveDismissEngine = InteractiveDismissEngine(),
        onDismiss: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail
    ) {
        self.engine = engine
        self.onDismiss = onDismiss
        self.detail = detail()
    }

    package var body: some View {
        GeometryReader { geometry in
            layer(in: geometry.size)
        }
        .ignoresSafeArea()
    }

    // MARK: - Private

    /// The card and its scrim, sized against the space the layer was given.
    ///
    /// The container's height is read here rather than assumed, because it is
    /// the unit the dismissal is measured in — see
    /// ``InteractiveDismissEngine/travelFraction``. A plain function rather
    /// than a computed property so the transform can be worked out once and
    /// read four times.
    private func layer(in size: CGSize) -> some View {
        let transform = engine.transform(forTranslation: translation, containerHeight: size.height)

        return ZStack {
            Color.black
                .opacity(Self.scrimOpacity * Double(transform.backdropOpacity))
                .ignoresSafeArea()
                // The scrim is a target for a tap and nothing else. VoiceOver
                // reaches the same exit through the escape action below, which
                // is the gesture it already has for "close this", so exposing a
                // full-screen unlabelled element here would add a second way to
                // do the same thing and one more stop to swipe past.
                .accessibilityHidden(true)
                .onTapGesture { onDismiss() }
                .transition(.opacity)

            detail
                .offset(transform.offset)
                .scaleEffect(transform.scale)
                // Everything behind the card is inert while it is open, and
                // VoiceOver should say so rather than letting a swipe wander
                // into a grid the reader cannot see.
                .accessibilityAddTraits(.isModal)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(dismissDrag(containerHeight: size.height))
        // Bound to the gesture's own value, so it animates the spring-back when
        // `@GestureState` resets and leaves everything else alone. An
        // interactive spring is the one that is meant to be re-targeted
        // mid-flight, which is what a finger that changes direction does.
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: translation)
        .accessibilityAction(.escape) { onDismiss() }
    }

    /// How dark the scrim gets with the card at rest.
    private static var scrimOpacity: Double { 0.5 }

    private func dismissDrag(containerHeight: CGFloat) -> some Gesture {
        // A minimum distance, so a tap on the card is a tap and not a
        // zero-length drag that resolves to `.restore` and eats it.
        DragGesture(minimumDistance: 8)
            .updating($translation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let drag = InteractiveDismissEngine.Drag(
                    translation: value.translation,
                    velocity: value.velocity
                )
                if engine.resolution(for: drag, containerHeight: containerHeight) == .dismiss {
                    onDismiss()
                }
            }
    }
}

// MARK: - Preview support

/// One card in the preview grid.
private struct HeroPreviewItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let tint: Color
}

private let heroPreviewItems: [HeroPreviewItem] = [
    HeroPreviewItem(id: 0, title: "Structured Concurrency", tint: .blue),
    HeroPreviewItem(id: 1, title: "Observation", tint: .green),
    HeroPreviewItem(id: 2, title: "SwiftData", tint: .orange),
    HeroPreviewItem(id: 3, title: "Custom Layout", tint: .purple),
    HeroPreviewItem(id: 4, title: "Vision", tint: .pink),
    HeroPreviewItem(id: 5, title: "Keychain", tint: .teal),
]

/// The whole component in one view: a grid that expands into a card, and a card
/// that can be thrown back down.
private struct HeroGalleryPreview: View {
    @State private var expanded: HeroPreviewItem.ID?

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        HeroScope(expanded: $expanded) { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(heroPreviewItems) { item in
                        thumbnail(item)
                            .heroSource(item.id, in: proxy)
                            .onTapGesture { expanded = item.id }
                    }
                }
                .padding(16)
            }
        } detail: { id, proxy in
            card(for: id)
                .heroDestination(id, in: proxy)
                .padding(24)
        }
    }

    private func thumbnail(_ item: HeroPreviewItem) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(item.tint.gradient)
            .frame(height: 100)
            .overlay(alignment: .bottomLeading) {
                Text(item.title)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func card(for id: HeroPreviewItem.ID) -> some View {
        if let item = heroPreviewItems.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(item.tint.gradient)
                    .frame(height: 220)
                Text(item.title)
                    .font(.title2.bold())
                Text("Drag down to dismiss, or throw it. Let go half-way and it springs back.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.secondaryLabel)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: 420, alignment: .topLeading)
            .background(AppColors.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

// MARK: - Previews

#Preview("Hero gallery") {
    HeroGalleryPreview()
}

#Preview("Hero gallery – reduce motion") {
    HeroGalleryPreview()
        .environment(\.accessibilityReduceMotion, true)
}

#Preview("Dismiss layer on its own") {
    ZStack {
        AppColors.secondaryBackground
            .ignoresSafeArea()
        Text("Behind the card")
            .foregroundStyle(AppColors.secondaryLabel)

        InteractiveDismissLayer(onDismiss: {}) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.indigo.gradient)
                .frame(width: 280, height: 380)
        }
    }
}
