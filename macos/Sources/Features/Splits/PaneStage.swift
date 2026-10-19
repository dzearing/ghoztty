import AppKit
import SwiftUI

/// The live grid's panes, each in an AppKit card (`PaneCardView`) placed
/// where `PaneLayout` puts it.
///
/// AppKit rather than SwiftUI frames, for the slide. SwiftUI animates a pane by
/// moving its AppKit views from the main thread a frame at a time, so a busy
/// main thread stutters the slide, and the clip that cuts a card at its
/// stack's end is applied on a different schedule from the views it clips —
/// text showed past the stack's edge mid-slide. Here a slide is a Core
/// Animation animation of each card's layer, run by the render server the way
/// a browser runs a CSS transition: every part of a card (the terminal, its
/// chrome, its clip) moves together, on time.
///
/// A slide moves a card's frame and animates its layer additively from where
/// it was, so the terminal inside never changes size (nothing is told to
/// reflow), and a click mid-slide starts the next slide from where the cards
/// are on screen.
struct PaneStage: NSViewRepresentable {
    struct Card {
        let pane: PaneView
        let leaf: PaneLayout.Leaf
        /// The pane is a card of a stacked row: it casts a shadow on the card
        /// behind it.
        let isStacked: Bool
        let content: AnyView
    }

    struct Style {
        let cornerRadius: CGFloat
        let background: Color
        let isLight: Bool
    }

    /// In paint order (the tree's leaf order, which `PaneLayout` guarantees).
    let cards: [Card]
    let size: CGSize
    /// Each stack's visible run: when only these change, the cards slide.
    let runs: [ClosedRange<Int>]
    /// A divider or grip drag is under way (`PaneStackState.isGesturing`).
    let isGesturing: Bool
    let style: Style

    func makeNSView(context: Context) -> PaneStageView {
        PaneStageView()
    }

    func updateNSView(_ view: PaneStageView, context: Context) {
        // Each card hosts its own SwiftUI tree, which inherits nothing from
        // this one unless it is handed over.
        let environment = context.environment
        view.apply(
            cards: cards.map { card in
                Card(pane: card.pane, leaf: card.leaf, isStacked: card.isStacked,
                     content: AnyView(card.content.environment(\.self, environment)))
            },
            size: size,
            runs: runs,
            duration: isGesturing ? PaneStageView.gestureSlideDuration : PaneStageView.slideDuration,
            style: style)
    }
}

final class PaneStageView: NSView {
    private var cards: [UUID: PaneCardView] = [:]
    private var lastRuns: [ClosedRange<Int>]?
    private var lastSize: CGSize?

    /// How a card slides: the HTML mock's curve and duration — or, while a
    /// drag is reshaping the row, quicker, so the layout keeps up with the hand.
    static let slideDuration: CFTimeInterval = 0.38
    static let gestureSlideDuration: CFTimeInterval = 0.2
    static let slideTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func apply(
        cards: [PaneStage.Card], size: CGSize, runs: [ClosedRange<Int>],
        duration: CFTimeInterval, style: PaneStage.Style
    ) {
        // Only a change in which cards are on show slides anything: a window
        // resize lays out immediately, as it always has.
        let slides = lastRuns != nil && runs != lastRuns && size == lastSize
        lastRuns = runs
        lastSize = size

        var order: [NSView] = []
        var live = Set<UUID>()
        for card in cards {
            let id = card.pane.id
            live.insert(id)
            let view = self.cards[id] ?? {
                let view = PaneCardView()
                self.cards[id] = view
                return view
            }()
            view.apply(card, style: style, slides: slides ? duration : nil)
            order.append(view)
        }
        for (id, view) in self.cards where !live.contains(id) {
            view.removeFromSuperview()
            self.cards[id] = nil
        }
        if subviews != order { subviews = order }
    }

    // Points over no card fall through to whatever is behind the stage.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One pane on the stage: its SwiftUI content (the pane and its card chrome)
/// in a hosting view, and — when it is tucked into a stack — the scrim that
/// dims it and the tab that brings it forward.
///
/// The view is larger than the pane by `outset` all round, room for the
/// card's shadow and focus glow. Inside it, a clip view cuts the card off at
/// its stack's far end when it hangs past it (`PaneLayout.Leaf.clip`); the
/// content view inside the clip view holds everything else, and moves against
/// the clip so the card stays put as the cut moves.
final class PaneCardView: NSView {
    /// Room around the pane for what its card draws outside itself.
    static let outset: CGFloat = 32

    private let clipView = FlippedLayerView()
    private let contentView = FlippedLayerView()
    private let shadowView = FlippedLayerView()
    /// The card itself: the pane, its scrim and its tab. Cut to the tab for a
    /// card drawn as its sliver alone (`PaneLayout.Leaf.isSliver`).
    private let bodyView = FlippedLayerView()
    private let bodyMask = CAShapeLayer()
    private let scrimView = FlippedLayerView()
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let tab = PaneStackTabView()

    private var leaf: PaneLayout.Leaf?
    private var style: PaneStage.Style?
    /// The pane this card shows.
    private(set) var paneID: UUID?
    /// The cut that keeps a hanging card inside its stack, as a layer whose
    /// presentation can be read mid-slide.
    var clipLayer: CALayer? { clipView.layer }
    private var isTabHovered = false
    /// The tab, in this view's coordinates, of a card drawn as its sliver
    /// alone: the only part of it that shows or takes a click.
    private var sliver: CGRect?
    /// Bumped by every layout.
    private var generation = 0
    /// When the slide under way ends, and the cut the card should have then.
    private var slideEnds: CFTimeInterval = 0
    private var settledClip: CGRect?
    /// Whether the card shows its tab, and a count of the times that changed,
    /// so the hide at the end of a fade-out knows if it is stale.
    private var isTabShown = false
    private var tabGeneration = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipView.layer?.masksToBounds = true
        addSubview(clipView)
        clipView.addSubview(contentView)

        // The shadow a stacked card casts on the card behind it: a shadow
        // alone (no fill), masked to outside the card so it never darkens a
        // glass pane from underneath.
        shadowView.layer?.shadowColor = NSColor.black.cgColor
        shadowView.layer?.shadowOffset = .zero
        shadowView.layer?.shadowRadius = 10
        contentView.addSubview(shadowView)

        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        host.sizingOptions = []
        contentView.addSubview(bodyView)
        bodyView.layer?.mask = bodyMask
        bodyView.addSubview(host)

        scrimView.alphaValue = 0
        bodyView.addSubview(scrimView)

        tab.alphaValue = 0
        tab.isHidden = true
        tab.onHover = { [weak self] hovered in
            self?.isTabHovered = hovered
            self?.updateScrim(animated: true)
        }
        bodyView.addSubview(tab)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// - Parameter slides: how long a card that moved takes to slide there;
    ///   nil, it is placed there at once.
    func apply(_ card: PaneStage.Card, style: PaneStage.Style, slides: CFTimeInterval?) {
        let o = Self.outset
        let old = leaf
        leaf = card.leaf
        paneID = card.pane.id
        self.style = style
        generation += 1

        let frame = card.leaf.frame.insetBy(dx: -o, dy: -o)
        let size = frame.size
        let paneRect = CGRect(x: o, y: o, width: card.leaf.frame.width, height: card.leaf.frame.height)

        // The SwiftUI content, laid out exactly where the grid puts the pane.
        host.rootView = AnyView(
            card.content
                .frame(width: card.leaf.frame.width, height: card.leaf.frame.height)
                .padding(o)
                .ignoresSafeArea())

        let moved = slides != nil && old != nil && old!.frame.origin != card.leaf.frame.origin
        let slide = moved && old!.frame.size == card.leaf.frame.size
        let duration = slides ?? 0
        let now = CACurrentMediaTime()

        // The cut, in this view's coordinates. Mid-slide a card cut in either
        // layout is cut in both: the cut is fixed to the stack, so it only
        // has to hold still while the card moves under it.
        let finalClip = Self.visible(card.leaf, clip: card.leaf.clip).offsetBy(dx: -frame.minX, dy: -frame.minY)
        if slide, let old {
            let oldFrame = old.frame.insetBy(dx: -o, dy: -o)
            let startClip = Self.visible(old, clip: old.clip ?? card.leaf.clip)
                .offsetBy(dx: -oldFrame.minX, dy: -oldFrame.minY)
            let endClip = Self.visible(card.leaf, clip: card.leaf.clip ?? old.clip)
                .offsetBy(dx: -frame.minX, dy: -frame.minY)
            // Start from the old geometry with no animation, then slide.
            Self.place(clipView, startClip)
            Self.place(contentView, CGRect(origin: CGPoint(x: -startClip.minX, y: -startClip.minY), size: oldFrame.size))
            Self.slide(self, to: frame, duration: duration)
            Self.slide(clipView, to: endClip, duration: duration)
            Self.slide(contentView, to: CGRect(origin: CGPoint(x: -endClip.minX, y: -endClip.minY), size: size),
                       duration: duration)
            // The cut settles where it belongs once the card is there.
            slideEnds = now + duration
            settledClip = finalClip
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self, CACurrentMediaTime() >= self.slideEnds - 0.001 else { return }
                self.settleClip()
            }
        } else if moved, let old {
            // A card that changes size as it moves (a row collapsing or
            // widening): it takes its new size at once and slides from where
            // its leading edge was.
            Self.place(clipView, finalClip)
            Self.place(contentView, CGRect(origin: CGPoint(x: -finalClip.minX, y: -finalClip.minY), size: size))
            Self.slide(self, to: frame, from: old.frame.insetBy(dx: -o, dy: -o), duration: duration)
            slideEnds = now + duration
            settledClip = finalClip
        } else {
            Self.place(self, frame)
            settledClip = finalClip
            // Mid-slide the cut is held still; it settles when the slide ends.
            if now >= slideEnds { settleClip() }
        }
        clipView.layer?.cornerRadius = style.cornerRadius
        clipView.layer?.cornerCurve = .continuous

        Self.place(bodyView, CGRect(origin: .zero, size: size))
        Self.place(host, CGRect(origin: .zero, size: size))
        Self.place(shadowView, CGRect(origin: .zero, size: size))
        Self.place(scrimView, paneRect)

        // What of the card is drawn: all of it, or its sliver alone. The cut
        // moves with the card, and narrows or widens over a slide.
        let toCard = CGAffineTransform(translationX: o - card.leaf.frame.minX, y: o - card.leaf.frame.minY)
        sliver = card.leaf.isSliver ? card.leaf.tab?.applying(toCard) : nil
        let drawn = Self.rounded(sliver ?? CGRect(origin: .zero, size: size), style.cornerRadius)
        if bodyMask.path != drawn {
            let from = bodyMask.presentation()?.path ?? bodyMask.path
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bodyMask.path = drawn
            CATransaction.commit()
            if let from, slides != nil, old != nil {
                let animation = CABasicAnimation(keyPath: "path")
                animation.fromValue = from
                animation.toValue = drawn
                animation.duration = duration
                animation.timingFunction = PaneStageView.slideTiming
                bodyMask.add(animation, forKey: "path")
            }
        }

        // Shadow: only where cards overlap, cast by what of the card is drawn.
        let shape = Self.rounded(sliver ?? paneRect, style.cornerRadius)
        shadowView.layer?.shadowPath = shape
        shadowView.layer?.shadowOpacity = card.isStacked ? (style.isLight ? 0.16 : 0.4) : 0
        let outside = CAShapeLayer()
        let mask = CGMutablePath()
        mask.addRect(CGRect(origin: .zero, size: size))
        mask.addPath(shape)
        outside.path = mask
        outside.fillRule = .evenOdd
        shadowView.layer?.mask = outside

        scrimView.layer?.cornerRadius = style.cornerRadius
        scrimView.layer?.cornerCurve = .continuous
        scrimView.layer?.backgroundColor = NSColor.black.cgColor
        updateScrim(animated: old != nil)

        // The tab: the tucked card's visible sliver.
        if let tabRect = card.leaf.tab, let axis = card.leaf.tabAxis {
            tab.pane = card.pane
            tab.update(face: PaneStackTabFace(
                pane: card.pane,
                axis: axis,
                cornerRadius: style.cornerRadius,
                background: style.background,
                isLight: style.isLight))
            Self.place(tab, tabRect.offsetBy(dx: o - card.leaf.frame.minX, dy: o - card.leaf.frame.minY))
            tab.isHidden = false
            if !isTabShown {
                tabGeneration += 1
                Self.fade(tab, to: 1, duration: old == nil ? 0 : 0.2)
            }
        } else if isTabShown {
            isTabHovered = false
            Self.fade(tab, to: 0, duration: 0.15)
            tabGeneration += 1
            let shown = tabGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.tabGeneration == shown else { return }
                self.tab.isHidden = true
            }
        }
        isTabShown = card.leaf.tab != nil
        setAccessibilityElement(false)
    }

    /// Draw the card `offset` from its place, above every other card: it is
    /// being dragged by its tab.
    func lift(by offset: CGSize) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = 1000
        layer.transform = CATransform3DMakeTranslation(offset.width, offset.height, 0)
        // Out of the stack, the whole card shows, not just its sliver.
        bodyView.layer?.mask = nil
        CATransaction.commit()
    }

    /// Put a lifted card back where the layout has it, gliding there.
    func settle() {
        guard let layer, !CATransform3DIsIdentity(layer.transform) else { return }
        let from = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = PaneStageView.gestureSlideDuration
        animation.timingFunction = PaneStageView.slideTiming
        layer.add(animation, forKey: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) { [weak self] in
            guard let self, let layer = self.layer, CATransform3DIsIdentity(layer.transform) else { return }
            layer.zPosition = 0
            self.bodyView.layer?.mask = self.bodyMask
        }
    }

    private func settleClip() {
        guard let settledClip else { return }
        Self.place(clipView, settledClip)
        Self.place(contentView, CGRect(
            origin: CGPoint(x: -settledClip.minX, y: -settledClip.minY), size: bounds.size))
    }

    private func updateScrim(animated: Bool) {
        guard let leaf, let style else { return }
        let alpha: CGFloat = if !leaf.isTucked {
            0
        } else if style.isLight {
            isTabHovered ? 0.06 : 0.16
        } else {
            isTabHovered ? 0.2 : 0.45
        }
        Self.fade(scrimView, to: alpha, duration: animated ? 0.2 : 0)
    }

    // Only the pane itself, and only the part of it not cut off, takes clicks:
    // the outset is shadow, and overlaps the panes beside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        let pane = bounds.insetBy(dx: Self.outset, dy: Self.outset)
        guard pane.contains(local), clipView.frame.contains(local) else { return nil }
        if let sliver, !sliver.contains(local) { return nil }
        return super.hitTest(point)
    }

    /// The part of a card that may draw, in stage coordinates: everything,
    /// shadow included, unless `clip` cuts it — and where it does, the cut
    /// ends at the card's own sides, so its corners round where the card's do.
    static func visible(_ leaf: PaneLayout.Leaf, clip: CGRect?) -> CGRect {
        let outer = leaf.frame.insetBy(dx: -outset, dy: -outset)
        guard let clip else { return outer }
        var r = outer.intersection(clip)
        guard !r.isNull else { return CGRect(origin: outer.origin, size: .zero) }
        let far = PaneLayout.unbounded / 2
        if clip.minX > -far || clip.maxX < far {
            let top = Swift.max(r.minY, leaf.frame.minY)
            r = CGRect(x: r.minX, y: top, width: r.width, height: Swift.max(0, Swift.min(r.maxY, leaf.frame.maxY) - top))
        }
        if clip.minY > -far || clip.maxY < far {
            let left = Swift.max(r.minX, leaf.frame.minX)
            r = CGRect(x: left, y: r.minY, width: Swift.max(0, Swift.min(r.maxX, leaf.frame.maxX) - left), height: r.height)
        }
        return r
    }

    /// A rounded rect, its corners no larger than it can take.
    private static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let r = Swift.max(0, Swift.min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // MARK: Core Animation

    /// Set a frame with no animation.
    private static func place(_ view: NSView, _ frame: CGRect) {
        guard view.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
    }

    /// Set a frame, and animate the layer there from where it was.
    ///
    /// Additive: the animation is the offset from the new place back to the
    /// old, decaying to nothing. A second slide before the first finishes adds
    /// its own offset on top, so the card carries on from where it is on
    /// screen rather than jumping.
    private static func slide(_ view: NSView, to frame: CGRect, from: CGRect? = nil, duration: CFTimeInterval) {
        guard let layer = view.layer else { return place(view, frame) }
        var fromPosition = layer.position
        let fromSize = layer.bounds.size
        place(view, frame)
        let toPosition = layer.position
        let toSize = layer.bounds.size
        if let from {
            // Only the leading edge slides; the size is already the new one.
            // (The stage is flipped, and so is its layer geometry.)
            fromPosition = CGPoint(x: toPosition.x + from.minX - frame.minX,
                                   y: toPosition.y + from.minY - frame.minY)
            return animate(layer, position: fromPosition, to: toPosition, size: toSize, to: toSize, duration: duration)
        }
        animate(layer, position: fromPosition, to: toPosition, size: fromSize, to: toSize, duration: duration)
    }

    private static func animate(
        _ layer: CALayer,
        position fromPosition: CGPoint, to toPosition: CGPoint,
        size fromSize: CGSize, to toSize: CGSize,
        duration: CFTimeInterval
    ) {
        func add(_ keyPath: String, _ from: Any, _ to: Any) {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.isAdditive = true
            animation.duration = duration
            animation.timingFunction = PaneStageView.slideTiming
            animation.fillMode = .backwards
            layer.add(animation, forKey: "slide.\(keyPath).\(UUID().uuidString)")
        }
        if fromPosition != toPosition {
            add("position",
                NSValue(point: CGPoint(x: fromPosition.x - toPosition.x, y: fromPosition.y - toPosition.y)),
                NSValue(point: .zero))
        }
        if fromSize != toSize {
            add("bounds.size",
                NSValue(size: CGSize(width: fromSize.width - toSize.width, height: fromSize.height - toSize.height)),
                NSValue(size: .zero))
        }
    }

    private static func fade(_ view: NSView, to alpha: CGFloat, duration: CFTimeInterval) {
        guard let layer = view.layer else {
            view.alphaValue = alpha
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.alphaValue = alpha
        CATransaction.commit()
        guard duration > 0, from != Float(alpha) else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = Float(alpha)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "fade")
    }
}

/// A plain layer-backed view with a top-left origin, which only ever passes
/// clicks on to its subviews.
final class FlippedLayerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
