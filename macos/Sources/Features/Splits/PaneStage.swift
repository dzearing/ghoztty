import AppKit
import Combine
import SwiftUI

/// The live grid's panes, each in an AppKit card (`PaneCardView`) placed
/// where `PaneLayout` puts it.
///
/// AppKit rather than SwiftUI frames, for the glide: every part of a card
/// (the pane, its chrome, its clip, its title) is placed in the same step,
/// so it moves as one.
///
/// A change in which cards are on show — a strip's pane coming out, a pane
/// tucking away, whether a drag or a click made it — glides
/// (`PaneStageView.glide`): every card and strip eases from where it is
/// drawn toward where the layout puts it, a frame at a time. A card's
/// content is held at one size while it glides (`paneContentFreeze`) —
/// clipped by the card, or with sheet to spare — so a terminal is resized
/// at most once, never per frame. A tucked card is its strip, its pane held
/// at its last size on show until it is back: a program nobody can see is
/// never resized.
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
        /// Panes are cards (the elevated style), so a strip is one too; in
        /// the flat style a strip is a filled bar.
        let isCard: Bool
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
    /// Told when a drag ends, so a glide settles though nothing redraws the
    /// grid then.
    let stackState: PaneStackState
    let style: Style

    func makeNSView(context: Context) -> PaneStageView {
        PaneStageView()
    }

    func updateNSView(_ view: PaneStageView, context: Context) {
        view.observe(stackState)
        // Each card hosts its own SwiftUI tree, which inherits nothing from
        // this one unless it is handed over.
        view.apply(
            cards: cards,
            environment: context.environment,
            size: size,
            runs: runs,
            isGesturing: isGesturing,
            style: style)
    }
}

final class PaneStageView: NSView {
    private var cards: [UUID: PaneCardView] = [:]
    private var lastRuns: [ClosedRange<Int>]?
    private var lastSize: CGSize?

    /// A strip let go of mid-drag gliding back to its place (`settle`).
    static let settleDuration: CFTimeInterval = 0.2
    static let settleTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Where the stage was, in the window, when its cards were last placed.
    /// The grid moving over for the sidebar (`noteColumnShift`) moves the
    /// stage — through an ANCESTOR's frame: its own origin stays at zero —
    /// and that move need not land in the same pass as the layout that
    /// starts the glide. So the glide is seeded by how far the stage has
    /// REALLY moved (`seedOffset`), and a move while it glides shifts the
    /// cards back by as much, at once (every ancestor's frame-change
    /// notification, and its own `frame`), so no card is ever drawn a shift
    /// away from where it was: missed, every card jumped the shift for a
    /// frame — under the sidebar, or a blade pulled off its edge and back.
    private var placedOrigin: CGPoint?
    private var originInWindow: CGPoint { convert(CGPoint.zero, to: nil) }
    private var ancestorObservers: [NSObjectProtocol] = []

    override var frame: NSRect {
        didSet { holdCardsOnScreen() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeAncestors()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeAncestors()
    }

    /// Hear every ancestor move, as it moves.
    private func observeAncestors() {
        for observer in ancestorObservers { NotificationCenter.default.removeObserver(observer) }
        ancestorObservers = []
        var view = superview
        while let ancestor = view {
            ancestor.postsFrameChangedNotifications = true
            ancestorObservers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: ancestor, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdCardsOnScreen() }
            })
            view = ancestor.superview
        }
    }

    deinit {
        for observer in ancestorObservers { NotificationCenter.default.removeObserver(observer) }
        // Freed mid-glide: stop its clock now (it would stop itself on its
        // next tick — see `startGlideTimer`).
        glideTimer?.invalidate()
    }

    /// The stage moved. Not gliding, its cards move with it — they are where
    /// it puts them — unless the grid is about to glide over for the
    /// sidebar (`hasColumnShift`): then where they were drawn is kept for the
    /// glide's seed. While they glide, keep them where they are drawn.
    private func holdCardsOnScreen() {
        guard glide != nil || observed?.hasColumnShift == true else {
            placedOrigin = originInWindow
            return
        }
        guard glide != nil, absorbStageMove() else { return }
        stepGlide()
    }

    /// While gliding: shift the cards back by however far the stage moved
    /// since they were placed. Whether it had moved.
    @discardableResult
    private func absorbStageMove() -> Bool {
        guard var glide, let placed = placedOrigin else { return false }
        let now = originInWindow
        let dx = placed.x - now.x, dy = placed.y - now.y
        guard abs(dx) >= 0.5 || abs(dy) >= 0.5 else { return false }
        for (id, rect) in glide.drawn { glide.drawn[id] = rect.offsetBy(dx: dx, dy: dy) }
        // A move the glide was waiting for (its sign: the shift's). Made in
        // full — or past it, the edge still dragged on in the same pass — it
        // has arrived; waiting on an exact match held every card still until
        // `moveWait` ran out, and the sidebar card grew over the grid.
        if glide.awaitingMove != 0 {
            let left = glide.awaitingMove + dx
            glide.awaitingMove = abs(left) < 0.5 || left * glide.awaitingMove < 0 ? 0 : left
        }
        self.glide = glide
        placedOrigin = now
        return true
    }

    func apply(
        cards: [PaneStage.Card], environment: EnvironmentValues, size: CGSize, runs: [ClosedRange<Int>],
        isGesturing: Bool, style: PaneStage.Style
    ) {
        // A change in which cards are on show glides (`glide`), and so does
        // every layout after it until the glide is over: each eases toward
        // its latest. So does the grid moving over for the pane sidebar
        // collapsing or expanding (`PaneStackState.noteColumnShift`): the
        // cards start where they are on screen — the stage itself moved by
        // the shift — and glide to their new places. A window resize lays
        // out immediately, as it always has.
        let resized = lastSize != nil && size != lastSize
        let shift = resized ? observed?.takeColumnShift() : nil
        let changed = lastRuns != nil && runs != lastRuns && size == lastSize
        lastRuns = runs
        lastSize = size
        if changed || shift != nil || glide != nil {
            // How far the stage has moved since its cards were placed: the
            // whole shift once it has moved, nothing yet if it has not (its
            // move then holds the cards, `holdCardsOnScreen`).
            let moved = placedOrigin.map { $0.x - originInWindow.x } ?? shift.map { -$0 } ?? 0
            startGlide(cards, environment: environment, style: style, isGesturing: isGesturing,
                       seedOffset: shift == nil ? 0 : moved, awaitingMove: shift.map { $0 + moved } ?? 0,
                       resized: resized)
            return
        }

        // A new size the stage's own frame does not have yet: SwiftUI hands
        // it over before it resizes and moves the stage in this pass. Placed
        // now, the cards stood a resize step off for a frame — during a
        // sidebar edge drag the blades on the right jittered by every step.
        // Place them once the frame is set (`layout`).
        pending = (cards, environment, style)
        if resized && abs(frame.width - size.width) + abs(frame.height - size.height) >= 0.5 {
            needsLayout = true
            return
        }
        placePending()
    }

    /// The cards from the last `apply` not yet placed (`placePending`).
    private var pending: (cards: [PaneStage.Card], environment: EnvironmentValues, style: PaneStage.Style)?

    override func layout() {
        super.layout()
        placePending()
    }

    /// Every card where the layout puts it, its content at its size.
    private func placePending() {
        guard let (cards, environment, style) = pending, glide == nil else { pending = nil; return }
        pending = nil
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
            view.apply(card, environment: environment, style: style)
            order.append(view)
        }
        for (id, view) in self.cards where !live.contains(id) {
            view.removeFromSuperview()
            self.cards[id] = nil
        }
        if subviews != order { subviews = order }
        placedOrigin = originInWindow
    }

    // MARK: Glide

    /// Which cards are on show changed: each card eases from where it is on
    /// screen toward where the layout now puts it, every card re-placed
    /// together on every frame — one unit, the card, its sheet and its
    /// content placed in the same step, the gutters between them holding
    /// their width (the edges move by the same easing). The layout keeps
    /// changing under a drag; each frame eases toward its latest. A card's
    /// content is held at its final size (or the larger of the two, for a
    /// card on show at both ends) meanwhile, clipped by the card, so nothing
    /// reflows mid-glide. A card going into its strip narrows into it, its
    /// content fading out and its title in (`PaneCardView.collapse`); one
    /// coming out widens, the other way round.
    private struct Glide {
        /// Each item as it is drawn: a card's pane, or a strip — what glides.
        var drawn: [UUID: CGRect] = [:]
        /// The item is drawn as a card (its pane shows), not a strip. A card
        /// going into its strip stays a card until it is there.
        var asCard: [UUID: Bool] = [:]
        /// A card that was on show when its glide began: its size then. Its
        /// content is held at the larger of that and its target (cut by the
        /// card), so nothing reflows on the glide's own clock.
        var startSize: [UUID: CGSize] = [:]
        /// A card going into or coming out of its strip: the strip lies on
        /// its leading side. Its content slides behind the strip's edge, its
        /// far edge leading.
        var stripLeads: [UUID: Bool] = [:]
        /// The size a card going into its strip is held at.
        var goingInSize: [UUID: CGSize] = [:]
        /// The size a card coming out of its strip was held at there.
        var comingOutSize: [UUID: CGSize] = [:]
        /// How long a strip was along the stack when the glide found it (or
        /// when it reached its strip): a strip gaining its reach under the
        /// strip in front (`bladeTuck`) takes it only when the glide is over,
        /// once that one has landed over it.
        var stripLength: [UUID: CGFloat] = [:]
        var targets: [UUID: PaneStage.Card] = [:]
        var environment: EnvironmentValues
        var style: PaneStage.Style
        var last: CFTimeInterval
        /// The drag is still under way: a glide that catches up rests until
        /// the next step. Once it is over, catching up ends the glide.
        var isGesturing = true
        /// No drag began it (a strip clicked, a pane split or closed): every
        /// card's content is held at the size it had until the glide is
        /// over, and then they all take their sizes together — one resize
        /// per terminal, after the motion. A drag's follows the hand.
        var holdsSizes = false
        /// How much of the grid's move for the sidebar (`noteColumnShift`)
        /// the stage has yet to make: the targets are already where it will
        /// be, so until it gets there every card holds where it is drawn —
        /// a step toward them sooner eased each card toward a place the
        /// shift away, and a blade's fixed edge pulled in and eased back.
        var awaitingMove: CGFloat = 0
        var awaitingSince: CFTimeInterval = 0
    }

    private var glide: Glide?
    private var glideTimer: Timer?

    /// How quickly a glide closes on its target: about 90% in 0.1s.
    static let glideTime: CFTimeInterval = 0.045

    /// How long a glide holds for the stage's move for the sidebar before it
    /// goes on without it.
    static let moveWait: CFTimeInterval = 0.15

    /// Where the layout puts an item: its strip, or its card.
    private static func target(_ leaf: PaneLayout.Leaf) -> CGRect {
        leaf.isTucked ? (leaf.tab ?? leaf.frame) : leaf.frame
    }

    private func startGlide(
        _ cards: [PaneStage.Card], environment: EnvironmentValues, style: PaneStage.Style, isGesturing: Bool,
        seedOffset: CGFloat = 0, awaitingMove: CGFloat = 0, resized: Bool = false
    ) {
        var glide = self.glide ?? Glide(
            environment: environment, style: style, last: CACurrentMediaTime(), holdsSizes: !isGesturing)
        if abs(awaitingMove) >= 0.5 {
            glide.awaitingMove = awaitingMove
            glide.awaitingSince = CACurrentMediaTime()
        }
        if seedOffset != 0 {
            // The stage moved under its cards: where they are drawn, in its
            // new coordinates, is that far back.
            for (id, rect) in glide.drawn { glide.drawn[id] = rect.offsetBy(dx: seedOffset, dy: 0) }
        }
        glide.environment = environment
        glide.style = style
        glide.isGesturing = isGesturing
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
            order.append(view)
            glide.targets[id] = card
            let to = Self.target(card.leaf)
            if glide.drawn[id] == nil {
                // As it is drawn now: its strip, or its card.
                let wasCard = view.placedFrame != nil && !view.isContentHidden
                glide.drawn[id] = (view.placedTab?.rect ?? view.placedFrame)?.offsetBy(dx: seedOffset, dy: 0) ?? to
                glide.asCard[id] = view.placedFrame == nil ? !card.leaf.isTucked : wasCard
                if let tab = view.placedTab { glide.stripLength[id] = Self.length(tab.rect, tab.axis) }
                if wasCard, let size = view.laidOutSize ?? view.placedFrame?.size { glide.startSize[id] = size }
            }
            let drawn = glide.drawn[id] ?? to
            let asCard = glide.asCard[id] ?? false
            if card.leaf.isTucked {
                if asCard {
                    // Going into its strip: held at the size it is drawn at,
                    // sliding behind the strip's edge.
                    if glide.goingInSize[id] == nil {
                        glide.goingInSize[id] = view.laidOutSize ?? drawn.size
                        glide.stripLeads[id] = Self.leads(to, of: drawn, card.leaf.tabAxis)
                    }
                    view.glideFreeze = glide.goingInSize[id]
                } else {
                    view.glideFreeze = nil
                    view.glideAnchor = nil
                }
            } else {
                glide.goingInSize[id] = nil
                if !asCard {
                    // Coming out of its strip.
                    glide.asCard[id] = true
                    glide.stripLeads[id] = Self.leads(drawn, of: to, card.leaf.tabAxis ?? view.placedTab?.axis)
                    glide.comingOutSize[id] = view.heldSize
                }
                if glide.holdsSizes, let held = glide.comingOutSize[id] ?? glide.startSize[id] {
                    view.glideFreeze = held
                    continue
                }
                // Held at where the layout puts it NOW: the target moves with
                // the hand, and the content with it. Held at the first target,
                // a fast pull left the content short of its growing card.
                let size = card.leaf.frame.size
                view.glideFreeze = glide.startSize[id].map {
                    CGSize(width: max($0.width, size.width), height: max($0.height, size.height))
                } ?? size
            }
        }
        for (id, view) in self.cards where !live.contains(id) {
            view.removeFromSuperview()
            self.cards[id] = nil
            for key in [id] {
                glide.drawn[key] = nil; glide.asCard[key] = nil; glide.startSize[key] = nil
                glide.stripLeads[key] = nil; glide.goingInSize[key] = nil; glide.targets[key] = nil
                glide.comingOutSize[key] = nil; glide.stripLength[key] = nil
            }
        }
        if subviews != order { subviews = order }
        if glideTimer == nil { glide.last = CACurrentMediaTime() }
        self.glide = glide
        if glideTimer == nil { startGlideTimer() }
        // The stage resized: its move, if one comes with it (the sidebar's
        // edge dragged), lands later in this pass, and these targets are
        // already where it will be. Place the cards where they are drawn,
        // and ease from the next step: eased now, every card stepped toward
        // a place the move away and came back once it landed — a blade's
        // edge jittered on every step of the drag.
        stepGlide(ease: !resized)
    }

    /// How long `rect` is along a stack running along `axis`.
    private static func length(_ rect: CGRect, _ axis: PaneLayout.Direction) -> CGFloat {
        axis == .vertical ? rect.height : rect.width
    }

    /// Whether `strip` lies on the leading side of `card`, along the stack.
    private static func leads(_ strip: CGRect, of card: CGRect, _ axis: PaneLayout.Direction?) -> Bool {
        axis == .vertical ? strip.midY < card.midY : strip.midX < card.midX
    }

    private func stepGlide(ease: Bool = true) {
        absorbStageMove()
        guard var glide else { return }
        let now = CACurrentMediaTime()
        // The stage has yet to move for the sidebar: hold (but not forever).
        let waiting = glide.awaitingMove != 0 && now - glide.awaitingSince < Self.moveWait
        if !waiting { glide.awaitingMove = 0 }
        // The targets are for the size the last layout gave (`lastSize`);
        // until the stage's frame has it, it has not been resized — and
        // moved — for them, and a step toward them is a step toward the
        // wrong place (SwiftUI can hand over a size a pass before it lays
        // the stage out at it).
        let laidOut = lastSize.map { abs(frame.width - $0.width) < 0.5 && abs(frame.height - $0.height) < 0.5 } ?? true
        let k = waiting || !ease || !laidOut ? 0 : 1 - exp(-(now - glide.last) / Self.glideTime)
        glide.last = now
        var settled = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, card) in glide.targets {
            guard let view = cards[id], let from = glide.drawn[id] else { continue }
            let to = Self.target(card.leaf)
            func ease(_ a: CGFloat, _ b: CGFloat) -> CGFloat { abs(b - a) < 0.5 ? b : a + (b - a) * k }
            let next = CGRect(
                x: ease(from.minX, to.minX), y: ease(from.minY, to.minY),
                width: ease(from.width, to.width), height: ease(from.height, to.height))
            glide.drawn[id] = next
            if next != to { settled = false }
            // A card that reached its strip is the strip.
            if card.leaf.isTucked, next == to {
                if glide.asCard[id] == true, let axis = card.leaf.tabAxis {
                    glide.stripLength[id] = Self.length(to, axis)
                }
                glide.asCard[id] = false
                glide.startSize[id] = nil
                glide.goingInSize[id] = nil
                glide.comingOutSize[id] = nil
            }
            var leaf = card.leaf
            if glide.asCard[id] == true {
                let horizontal = (card.leaf.tabAxis ?? .horizontal) == .horizontal
                if card.leaf.isTucked || glide.startSize[id] == nil {
                    // In or out of its strip: the card where it is drawn,
                    // its rim and sheet all round it, its content at its
                    // held size pinned to the far edge — sliding behind the
                    // strip's edge — and cut by the card.
                    let leadsStrip = glide.stripLeads[id] ?? true
                    view.glideAnchor = horizontal
                        ? (leadsStrip ? .topTrailing : .topLeading)
                        : (leadsStrip ? .bottomLeading : .topLeading)
                } else {
                    view.glideAnchor = nil
                }
                leaf.frame = next
                leaf.clip = nil
                leaf.isTucked = false
                leaf.tab = nil
                leaf.isSliver = false
            } else {
                // A strip, moved along with the row by its OUTER edge — the
                // one that shows. A strip that gains its reach under the
                // strip in front (a pane collapsing between it and the run)
                // keeps its length until the glide is over: reaching out
                // sooner put its edge in the gutter ahead of the newcomer,
                // and a trailing strip's outer edge jumped out by the reach
                // and eased back — a jiggle in a strip that should not move.
                // Losing the reach is immediate, under the strip in front.
                let axis = card.leaf.tabAxis ?? .horizontal
                let leads = card.leaf.stripLeads ?? true
                let target = Self.length(to, axis)
                let length = Swift.min(glide.stripLength[id] ?? target, target)
                var tab = next
                switch (axis, leads) {
                case (.horizontal, true): tab.size.width = length
                case (.horizontal, false): tab = CGRect(x: next.maxX - length, y: next.minY, width: length, height: next.height)
                case (.vertical, true): tab.size.height = length
                case (.vertical, false): tab = CGRect(x: next.minX, y: next.maxY - length, width: next.width, height: length)
                }
                // Across the stack the strip eases with the glide, as every
                // edge does: set to the target's at once, a strip whose
                // stack narrowed (the sidebar expanding) took its new width
                // in the first frame and only slid after.
                let dx = leads || axis == .vertical ? next.minX - to.minX : next.maxX - to.maxX
                let dy = leads || axis == .horizontal ? next.minY - to.minY : next.maxY - to.maxY
                leaf.frame = leaf.frame.offsetBy(dx: dx, dy: dy)
                leaf.tab = tab
            }
            if glide.asCard[id] != true { view.glideAnchor = nil }
            view.apply(
                PaneStage.Card(pane: card.pane, leaf: leaf, isStacked: card.isStacked, content: card.content),
                environment: glide.environment, style: glide.style)
        }
        CATransaction.commit()
        self.glide = glide
        placedOrigin = originInWindow
        // Caught up: rest until the layout moves again (the next step
        // restarts the clock) — or, the drag over, end.
        if settled {
            glideTimer?.invalidate()
            glideTimer = nil
            if !glide.isGesturing { finishGlide() }
        }
        // The bar of the drag stays over the gutter as it is drawn.
        GutterBar.refreshActive()
        // The pane sidebar's card follows the grid's leading edge.
        NotificationCenter.default.post(name: Self.didStep, object: self)
    }

    /// Posted after every glide step, and when a glide ends.
    static let didStep = Notification.Name("PaneStageViewDidStep")

    /// The glide's clock, stepping it at 120Hz until it settles. A stage
    /// freed mid-glide (its window or tab closed while a split change was
    /// still easing) never settles, so the timer stops itself then: the run
    /// loop retains a repeating timer until it is invalidated, and left alone
    /// it would fire a no-op 120 times a second for the rest of the app's
    /// life, one more for every stage that went this way.
    private func startGlideTimer() {
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.stepGlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    /// How far the grid's leading edge is drawn from where the layout puts
    /// it, ON SCREEN — the stage's own move still to come counted in
    /// (`awaitingMove`) — while it glides; nil when it does not. Negative:
    /// short of it. The pane sidebar's card follows it on a collapse or
    /// expand (`PaneSidebarCardGlide`), so the gutter between them holds
    /// whatever either clock does.
    var leadingLag: CGFloat? {
        guard let glide else { return nil }
        let leading = glide.targets.compactMap { id, card -> (CGRect, CGRect)? in
            glide.drawn[id].map { ($0, Self.target(card.leaf)) }
        }.min { $0.1.minX < $1.1.minX }
        return leading.map { $0.0.minX - $0.1.minX - glide.awaitingMove }
    }

    /// Every card where the layout puts it, its content at its size.
    private func finishGlide() {
        guard let glide else { return }
        glideTimer?.invalidate()
        glideTimer = nil
        self.glide = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, card) in glide.targets {
            guard let view = cards[id] else { continue }
            view.glideAnchor = nil
            // Placed first, so a card that went into its strip keeps its
            // content at the size it was held at.
            view.apply(card, environment: glide.environment, style: glide.style)
            view.glideFreeze = nil
        }
        CATransaction.commit()
        placedOrigin = originInWindow
        NotificationCenter.default.post(name: Self.didStep, object: self)
    }

    /// Where a gutter laid out at `rect` (window coordinates) is drawn while
    /// the cards glide: beside the card whose edge it is, as far along as
    /// that card has got. Nil when no glide is under way, or it is no
    /// card's gutter.
    func shownGutter(_ rect: CGRect, horizontal: Bool) -> CGRect? {
        guard let glide else { return nil }
        let r = convert(rect, from: nil)
        for (id, shown) in glide.drawn {
            guard let leaf = glide.targets[id]?.leaf else { continue }
            let target = Self.target(leaf)
            let offset: CGFloat?
            if horizontal {
                guard target.maxY > r.minY, target.minY < r.maxY else { continue }
                offset = abs(target.maxX - r.minX) <= 1.5 ? shown.maxX - target.maxX
                    : abs(target.minX - r.maxX) <= 1.5 ? shown.minX - target.minX : nil
            } else {
                guard target.maxX > r.minX, target.minX < r.maxX else { continue }
                offset = abs(target.maxY - r.minY) <= 1.5 ? shown.maxY - target.maxY
                    : abs(target.minY - r.maxY) <= 1.5 ? shown.minY - target.minY : nil
            }
            guard let offset else { continue }
            let moved = horizontal ? r.offsetBy(dx: offset, dy: 0) : r.offsetBy(dx: 0, dy: offset)
            return convert(moved, to: nil)
        }
        return nil
    }

    private var gestureEnds: AnyCancellable?
    private weak var observed: PaneStackState?

    /// The drag is over: a glide resting where it caught up ends now; one
    /// still on its way settles first. (Left to the next redraw of the grid,
    /// which the end of a drag does not always bring, a glide could rest
    /// forever, the cards mid-way and cut.)
    func observe(_ state: PaneStackState) {
        guard observed !== state else { return }
        observed = state
        gestureEnds = state.$isGesturing
            .removeDuplicates()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, var glide = self.glide else { return }
                glide.isGesturing = false
                self.glide = glide
                if self.glideTimer == nil {
                    self.glide?.last = CACurrentMediaTime()
                    self.startGlideTimer()
                }
                self.stepGlide()
            }
    }

    // Points over no card fall through to whatever is behind the stage.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// One pane on the stage: its SwiftUI content (the pane and its card chrome)
/// in a hosting view, and — when it is tucked into a stack — the title that
/// names it and brings it forward.
///
/// A tucked pane is its strip: the pane's own card at the strip's size — the
/// same glass, rim and unfocused tint as any card — with its content faded
/// out and its title in. Neither is switched: both follow how far into its
/// strip the card is drawn (`collapse`), so a card gliding into its strip
/// fades its content out and its title in as it narrows, and the reverse
/// coming out, with nothing left to change when it gets there.
///
/// The view is larger than the pane by `outset` all round, room for the
/// card's shadow and focus glow. Inside it, a clip view cuts the card off at
/// its stack's far end when it hangs past it (`PaneLayout.Leaf.clip`); the
/// content view inside the clip view holds everything else, and moves against
/// the clip so the card stays put as the cut moves.
final class PaneCardView: NSView {
    /// Room around the pane for what its card draws outside itself.
    static let outset: CGFloat = 32

    /// How much wider than its strip a card is when its content has faded
    /// all the way in (and its title out).
    static let fadeSpan: CGFloat = 120

    private let clipView = FlippedLayerView()
    private let contentView = FlippedLayerView()
    private let shadowView = FlippedLayerView()
    /// The card itself: the pane and its title.
    private let bodyView = FlippedLayerView()
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let tab = PaneStackTabView()

    private var leaf: PaneLayout.Leaf?
    private var style: PaneStage.Style?
    /// The pane's SwiftUI content, and the environment it inherits (a
    /// hosting view's tree inherits nothing unless it is handed over), as
    /// last handed over.
    private var content: AnyView?
    private var environment: EnvironmentValues?
    /// The size a tucked card's content is held at: the size it last had on
    /// show. Nil: it fills the card.
    private var frozenSize: CGSize?
    /// The size the content was last laid out at.
    private var contentSize: CGSize?
    /// The axis of the stack the card was last a strip of.
    private var axis: PaneLayout.Direction?

    /// The size the content is held at while the stage glides the card
    /// (`PaneStageView.glide`), so nothing reflows mid-glide.
    var glideFreeze: CGSize? {
        didSet { if glideFreeze != oldValue { render() } }
    }

    /// Where held content is pinned in a card gliding into or out of its
    /// strip: its far edge, so the pane slides behind the strip's edge. Nil:
    /// its top leading corner, and the card is not on its way to or from a
    /// strip.
    var glideAnchor: Alignment?

    /// The size a strip's content is held at: what it had last on show.
    var heldSize: CGSize? { frozenSize }
    /// The size its content is laid out at now.
    var laidOutSize: CGSize? { contentSize }
    /// Its content is held at a size of its own, not the card's.
    var isFrozen: Bool { frozenSize != nil }

    /// How far into its strip the card is drawn: 0 on show (its content
    /// shows), 1 a strip (its title does).
    private(set) var collapse: CGFloat = 0

    /// The layer casting the card's shadow, and whether it is a strip's
    /// (a stacked card all the way into its strip). For tests.
    var stripShadowLayer: CALayer? { shadowView.layer }
    var isStripShadowed: Bool { collapse >= 1 && (shadowView.layer?.shadowOpacity ?? 0) > 0 }

    /// The part of the pane that is drawn, in window coordinates: the pane
    /// as cut by its clip. For tests.
    var drawnPaneInWindow: CGRect {
        let o = Self.outset
        let pane = bounds.insetBy(dx: o, dy: o)
        let clip = clipView.frame
        return convert(pane.intersection(clip), to: nil)
    }

    /// The stage is gliding this card (for tests: none should be, once a
    /// drag has settled).
    var isGliding: Bool { glideFreeze != nil }

    /// Where the card was last placed, in the stage's coordinates.
    var placedFrame: CGRect? { leaf?.frame }

    /// The strip it was last placed as, and the axis its stack runs along.
    var placedTab: (rect: CGRect, axis: PaneLayout.Direction)? {
        guard let leaf, leaf.isTucked, let tab = leaf.tab, let axis = leaf.tabAxis else { return nil }
        return (tab, axis)
    }

    /// Something of the card is animating on its own clock, for tests: none
    /// of it should while a drag moves the layout.
    var isAnimating: Bool {
        func busy(_ layer: CALayer?) -> Bool {
            guard let layer else { return false }
            return !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: busy)
        }
        return busy(layer)
    }
    /// The pane's content has faded out all the way, leaving its strip.
    var isContentHidden: Bool { collapse >= 1 }
    /// How opaque the title is (it shows as the content fades), for tests.
    var titleOpacity: CGFloat { tab.isHidden ? 0 : tab.alphaValue }
    /// The pane this card shows.
    private(set) var paneID: UUID?
    /// The cut that keeps a hanging card inside its stack.
    var clipLayer: CALayer? { clipView.layer }

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
        bodyView.addSubview(host)

        tab.alphaValue = 0
        tab.isHidden = true
        bodyView.addSubview(tab)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Where a strip's title goes: the part of it that shows. A strip that
    /// reaches under the strip in front of it (`bladeTuck`, toward the run)
    /// has that much of itself hidden, so its title is centered on the rest.
    private static func titleRect(_ pane: CGRect, _ leaf: PaneLayout.Leaf) -> CGRect {
        guard let leads = leaf.stripLeads, let axis = leaf.tabAxis else { return pane }
        let tuck = PaneLayout.Metrics.bladeTuck
        let along = axis == .horizontal ? pane.width : pane.height
        guard along > PaneLayout.Metrics.peek + tuck / 2 else { return pane }
        // Leading strips reach toward the run past their trailing edge;
        // trailing ones past their leading edge.
        switch (axis, leads) {
        case (.horizontal, true): return CGRect(x: pane.minX, y: pane.minY, width: pane.width - tuck, height: pane.height)
        case (.horizontal, false): return CGRect(x: pane.minX + tuck, y: pane.minY, width: pane.width - tuck, height: pane.height)
        case (.vertical, true): return CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height - tuck)
        case (.vertical, false): return CGRect(x: pane.minX, y: pane.minY + tuck, width: pane.width, height: pane.height - tuck)
        }
    }

    func apply(_ card: PaneStage.Card, environment: EnvironmentValues, style: PaneStage.Style) {
        let o = Self.outset
        // A tucked card is its strip: the pane's own card, the strip's size.
        var shown = card.leaf
        if shown.isTucked, let tab = shown.tab {
            shown.frame = tab
            shown.isSliver = false
        }
        leaf = shown
        paneID = card.pane.id
        self.style = style
        if let axis = shown.tabAxis { self.axis = axis }

        // A tucked card's pane keeps the size it last had on show — a row
        // reflowing around it never resizes a program nobody can see — and
        // takes its slot's size once it is back on show.
        frozenSize = shown.isTucked ? frozenSize ?? glideFreeze ?? contentSize ?? card.leaf.frame.size : nil

        let frame = shown.frame.insetBy(dx: -o, dy: -o)
        let size = frame.size
        let paneRect = CGRect(x: o, y: o, width: shown.frame.width, height: shown.frame.height)
        let clip = Self.visible(shown, clip: shown.clip).offsetBy(dx: -frame.minX, dy: -frame.minY)
        Self.place(self, frame)
        Self.place(clipView, clip)
        Self.place(contentView, CGRect(origin: CGPoint(x: -clip.minX, y: -clip.minY), size: size))
        clipView.layer?.cornerRadius = style.cornerRadius
        clipView.layer?.cornerCurve = .continuous
        Self.place(bodyView, CGRect(origin: .zero, size: size))
        Self.place(host, CGRect(origin: .zero, size: size))
        Self.place(shadowView, CGRect(origin: .zero, size: size))

        // How far into its strip: by how much wider than a strip the card is
        // drawn. Only a strip, or a card on its way to or from one, fades.
        let pane = paneRect.intersection(clip)
        if shown.isTucked || glideAnchor != nil, !pane.isNull {
            let extent = Swift.min(pane.width, pane.height)
            // A strip reaching under the one in front (`bladeTuck`) is still
            // just a strip: fully collapsed up to its peek and its tuck.
            let strip = PaneLayout.Metrics.peek + PaneLayout.Metrics.bladeTuck
            collapse = Swift.min(1, Swift.max(0, 1 - (extent - strip) / Self.fadeSpan))
        } else {
            collapse = 0
        }

        content = card.content
        self.environment = environment
        render()

        // Shadow: only where cards overlap. A strip is a blade tucked behind
        // the panes on show, lying against the next blade out: its shadow is
        // tighter than a card's, light, and leans AWAY from the run (onto
        // the blade behind it). Along the strip it is cast from a shape
        // pulled in from the strip's ends, so it fades out inside its
        // rounded corners — not cut off flat there, nor haloing past them.
        // All of it follows `collapse` — how far the card is into its strip
        // — so it comes on as the card narrows into the strip, not in one
        // step when the glide lands.
        let shape = Self.rounded(paneRect, style.cornerRadius)
        let blade = card.isStacked ? collapse : 0
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * blade }
        let axis = shown.tabAxis ?? self.axis
        let outward: CGFloat = (shown.stripLeads ?? card.leaf.stripLeads).map { $0 ? -1 : 1 } ?? 0
        let lean = mix(0, 3) * outward
        let ends = mix(0, style.cornerRadius)
        let caster = axis == .vertical
            ? paneRect.insetBy(dx: Swift.min(ends, paneRect.width / 4), dy: 0)
            : paneRect.insetBy(dx: 0, dy: Swift.min(ends, paneRect.height / 4))
        shadowView.layer?.shadowPath = Self.rounded(caster, style.cornerRadius)
        shadowView.layer?.shadowRadius = mix(10, 5)
        shadowView.layer?.shadowOffset = axis == .vertical
            ? CGSize(width: 0, height: lean)
            : CGSize(width: lean, height: 0)
        shadowView.layer?.shadowOpacity = card.isStacked
            ? Float(mix(style.isLight ? 0.16 : 0.4, style.isLight ? 0.14 : 0.3)) : 0
        // Cast only outside the card: the whole layer, less its shape.
        let outside = CAShapeLayer()
        let mask = CGMutablePath()
        mask.addRect(CGRect(origin: .zero, size: size))
        mask.addPath(shape)
        outside.path = mask
        outside.fillRule = .evenOdd
        shadowView.layer?.mask = outside

        // The title, over what of the card is drawn, as the content fades.
        if collapse > 0, !pane.isNull {
            tab.pane = card.pane
            tab.update(face: PaneStackTabFace(
                pane: card.pane,
                axis: shown.tabAxis ?? axis ?? (pane.width < pane.height ? .horizontal : .vertical),
                cornerRadius: style.cornerRadius,
                background: style.background,
                isLight: style.isLight,
                isFilled: !style.isCard))
            Self.place(tab, Self.titleRect(pane, shown))
            tab.isHidden = false
            tab.alphaValue = collapse
            tab.isStrip = shown.isTucked
        } else {
            tab.isHidden = true
            tab.alphaValue = 0
            tab.isStrip = false
        }
        setAccessibilityElement(false)
    }

    /// The SwiftUI content, laid out exactly where the grid puts the pane.
    private func render() {
        guard let leaf, let content, var environment else { return }
        let held = glideFreeze ?? frozenSize
        environment.paneContentFreeze = held
        environment.paneContentAnchor = glideAnchor ?? .topLeading
        environment.paneCollapse = collapse
        contentSize = held ?? leaf.frame.size
        host.rootView = AnyView(
            content
                .environment(\.self, environment)
                .frame(width: leaf.frame.width, height: leaf.frame.height)
                .padding(Self.outset)
                .ignoresSafeArea())
    }

    /// Draw the card `offset` from its place, above every other card: it is
    /// being dragged by its strip.
    func lift(by offset: CGSize) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.zPosition = 1000
        layer.transform = CATransform3DMakeTranslation(offset.width, offset.height, 0)
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
        animation.duration = PaneStageView.settleDuration
        animation.timingFunction = PaneStageView.settleTiming
        layer.add(animation, forKey: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + animation.duration) { [weak self] in
            guard let self, let layer = self.layer, CATransform3DIsIdentity(layer.transform) else { return }
            layer.zPosition = 0
        }
    }

    // Only the pane itself, and only the part of it not cut off, takes clicks:
    // the outset is shadow, and overlaps the panes beside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        let pane = bounds.insetBy(dx: Self.outset, dy: Self.outset)
        guard pane.contains(local), clipView.frame.contains(local) else { return nil }
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

    /// Set a frame with no animation.
    private static func place(_ view: NSView, _ frame: CGRect) {
        guard view.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
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

private struct PaneContentFreezeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

private struct PaneContentAnchorKey: EnvironmentKey {
    static let defaultValue: Alignment = .topLeading
}

private struct PaneCollapseKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The size a pane's content is held at while its card glides or is a
    /// strip (`PaneStage`); nil, it fills the card.
    var paneContentFreeze: CGSize? {
        get { self[PaneContentFreezeKey.self] }
        set { self[PaneContentFreezeKey.self] = newValue }
    }

    /// Where held content is pinned in its card (`PaneCardView.glideAnchor`).
    var paneContentAnchor: Alignment {
        get { self[PaneContentAnchorKey.self] }
        set { self[PaneContentAnchorKey.self] = newValue }
    }

    /// How far into its strip a pane's card is (`PaneCardView.collapse`): its
    /// content fades out as it goes in.
    var paneCollapse: CGFloat {
        get { self[PaneCollapseKey.self] }
        set { self[PaneCollapseKey.self] = newValue }
    }
}

