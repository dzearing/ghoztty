import SwiftUI
import WebKit
import GhosttyKit

struct HeroCarouselView: View {
    let leaves: [PaneView]
    @ObservedObject var state: HeroModeState
    let heroAspectRatio: CGFloat

    var body: some View {
        HeroCarouselRepresentable(
            leaves: leaves,
            state: state,
            heroAspectRatio: heroAspectRatio
        )
    }
}

struct HeroCarouselRepresentable: NSViewRepresentable {
    let leaves: [PaneView]
    @ObservedObject var state: HeroModeState
    let heroAspectRatio: CGFloat

    func makeNSView(context: Context) -> HeroCarouselContainer {
        HeroCarouselContainer()
    }

    func updateNSView(_ container: HeroCarouselContainer, context: Context) {
        container.update(
            leaves: leaves,
            state: state,
            heroAspectRatio: heroAspectRatio
        )
    }
}

class HeroCarouselContainer: NSView {
    override var isFlipped: Bool { true }

    private let strip = CarouselStrip()
    private var tiles: [CarouselTile] = []
    private var currentIndex: Int = -1
    private var scrollOffset: CGFloat = 0
    private let gap: CGFloat = 8
    private var heroAspectRatio: CGFloat = 1.5
    private weak var state: HeroModeState?
    private var currentLeaves: [PaneView] = []
    private var snapshotTimer: Timer?
    private var needsInitialSnapshot = false

    /// Decides which tiles may capture on each heartbeat. See
    /// `HeroSnapshotScheduler` for the measurements behind the schedule.
    /// Internal rather than private so tests can assert that events reaching
    /// the window actually reach the pacing.
    let scheduler = HeroSnapshotScheduler()

    /// Watches the window's event stream so that interaction *anywhere in the
    /// window* — above all scrolling the web page in the hero pane — pauses
    /// thumbnail capture. The carousel's own `scrollWheel` is not enough: the
    /// hero pane's WKWebView consumes its own scroll events and the carousel
    /// never sees them.
    private var eventMonitor: Any?

    /// How many thumbnail captures this carousel has started. Read by tests, to
    /// prove from outside that a fresh carousel fills its tiles rather than
    /// waiting for an interaction that may never come.
    private(set) var captureCount: Int = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        strip.wantsLayer = true
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        relayout(animated: false)
        if needsInitialSnapshot {
            needsInitialSnapshot = false
            DispatchQueue.main.async { [weak self] in
                self?.refreshSnapshots()
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTimers()
            removeEventMonitor()
        } else {
            installEventMonitor()
            startSnapshotTimer()
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: HeroSnapshotScheduler.interactionEventMask
        ) { [weak self] event in
            guard let self else { return event }
            if HeroSnapshotScheduler.isInteraction(event, in: self.window) {
                self.scheduler.noteInteraction()
            }
            return event
        }
    }

    private func removeEventMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    func update(leaves: [PaneView], state: HeroModeState, heroAspectRatio: CGFloat) {
        self.state = state
        self.heroAspectRatio = heroAspectRatio

        let tilesChanged = rebuildTiles(leaves: leaves)
        self.currentLeaves = leaves
        if tilesChanged {
            needsInitialSnapshot = true
        }

        // Defer bounds-driven layout to layout(), which always runs with the
        // final frame. Relaying out here too is redundant and can position the
        // strip from stale bounds: during a divider drag SwiftUI hasn't applied
        // the new frame yet, so our bounds are still the previous tick's value.
        // layout() runs on every drag tick (the carousel width changes each
        // tick), so a single relayout there is sufficient.
        needsLayout = true

        if state.selectedIndex != currentIndex {
            scrollOffset = 0
            state.scrollOffset = 0
            animateToIndex(state.selectedIndex)
        }

        startSnapshotTimer()
    }

    private var thumbSize: CGSize {
        // Thumbnails mirror the hero pane's aspect ratio. Width is driven by the
        // carousel width, but we must cap the resulting height to the carousel's
        // visible height — otherwise dragging the divider to widen the carousel
        // (which shrinks heroAspectRatio) makes the selected tile grow taller and
        // taller, spilling out of the viewport. When the height would exceed the
        // cap we shrink the width instead, preserving the aspect ratio.
        let ar = max(heroAspectRatio, 0.1)
        let maxW = bounds.width * 0.88
        let maxH = bounds.height * 0.7
        var w = maxW
        var h = w / ar
        if h > maxH {
            h = maxH
            w = h * ar
        }
        return CGSize(width: w, height: h)
    }

    @discardableResult
    private func rebuildTiles(leaves: [PaneView]) -> Bool {
        let oldPanes = currentLeaves
        guard oldPanes != leaves else {
            for (i, tile) in tiles.enumerated() {
                tile.isSelected = i == (state?.selectedIndex ?? 0)
            }
            return false
        }

        var tilesByPane: [ObjectIdentifier: CarouselTile] = [:]
        for tile in tiles {
            tilesByPane[ObjectIdentifier(tile.pane)] = tile
        }

        var newTiles: [CarouselTile] = []
        for pane in leaves {
            let id = ObjectIdentifier(pane)
            if let existing = tilesByPane.removeValue(forKey: id) {
                newTiles.append(existing)
            } else {
                let tile = CarouselTile(pane: pane)
                strip.addSubview(tile)
                newTiles.append(tile)
            }
        }

        for (_, tile) in tilesByPane {
            tile.removeFromSuperview()
        }

        tiles = newTiles

        for (i, tile) in tiles.enumerated() {
            tile.isSelected = i == (state?.selectedIndex ?? 0)
            tile.onTap = { [weak self, weak tile] in
                guard let self = self, let tile = tile else { return }
                guard let idx = self.tiles.firstIndex(where: { $0 === tile }) else { return }
                self.state?.select(idx, leafCount: self.currentLeaves.count)
            }
        }

        return true
    }

    private func relayout(animated: Bool) {
        let ts = thumbSize
        guard ts.width > 0, ts.height > 0 else { return }
        let padding = bounds.width * 0.06

        for (i, tile) in tiles.enumerated() {
            let y = CGFloat(i) * (ts.height + gap)
            tile.frame = NSRect(x: padding, y: y, width: ts.width, height: ts.height)
        }

        let totalHeight = CGFloat(tiles.count) * (ts.height + gap)
        strip.frame = NSRect(x: 0, y: strip.frame.origin.y, width: bounds.width, height: totalHeight)

        repositionStrip(animated: animated)
    }

    private func repositionStrip(animated: Bool) {
        let ts = thumbSize
        guard ts.height > 0 else { return }
        let stride = ts.height + gap
        let idx = currentIndex >= 0 ? currentIndex : 0
        let centeredY = bounds.height / 2 - (CGFloat(idx) * stride + ts.height / 2)
        let targetY = centeredY + scrollOffset

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                strip.animator().frame.origin.y = targetY
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            strip.frame.origin.y = targetY
            CATransaction.commit()
        }
    }

    private func animateToIndex(_ index: Int) {
        let wasFirst = currentIndex < 0
        currentIndex = index

        for (i, tile) in tiles.enumerated() {
            tile.isSelected = i == index
        }

        repositionStrip(animated: !wasFirst)
    }

    override func scrollWheel(with event: NSEvent) {
        let ts = thumbSize
        guard ts.height > 0 else { return }

        // The event monitor already noted this as interaction, which pauses
        // captures; the heartbeat resumes them once the strip settles.
        scrollOffset += event.scrollingDeltaY

        let stride = ts.height + gap
        let totalContentHeight = CGFloat(tiles.count) * stride - gap
        let maxScrollDown = max(0, (totalContentHeight - ts.height) / 2)
        let maxScrollUp = -maxScrollDown
        scrollOffset = max(maxScrollUp, min(maxScrollDown, scrollOffset))

        state?.scrollOffset = scrollOffset
        repositionStrip(animated: false)
    }

    /// The heartbeat that drives thumbnail capture. It ticks at the *fastest*
    /// cadence any pane kind wants and then asks the scheduler per tile, rather
    /// than trying to schedule each tile's next capture: a tick is a few time
    /// comparisons, and running it unconditionally is what guarantees the
    /// trailing refresh after a gesture can never be missed or cancelled.
    private func startSnapshotTimer() {
        guard snapshotTimer == nil, window != nil else { return }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshVisibleSnapshots()
        }
    }

    private func stopTimers() {
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    /// Capture every tile right now, bypassing the idle cadence and the quiet
    /// period. Used only for tiles that have no picture yet (a fresh or rebuilt
    /// carousel), where the alternative is showing blanks.
    private func refreshSnapshots() {
        for tile in tiles where tile.refreshSnapshot(scheduler: scheduler, force: true) {
            captureCount += 1
        }
    }

    private func refreshVisibleSnapshots() {
        let visibleRect = bounds
        for tile in tiles {
            let tileFrameInSelf = strip.convert(tile.frame, to: self)
            if tileFrameInSelf.intersects(visibleRect),
               tile.refreshSnapshot(scheduler: scheduler, force: false) {
                captureCount += 1
            }
        }
    }

    deinit {
        stopTimers()
        removeEventMonitor()
    }
}

private class CarouselStrip: NSView {
    override var isFlipped: Bool { true }
}

private class CarouselTile: NSView {
    let pane: PaneView
    var onTap: (() -> Void)?
    private let imageView = NSImageView()
    private let borderLayer = CAShapeLayer()

    /// When an async WKWebView snapshot (viewer panes) started, so the repeating
    /// snapshot timer doesn't pile up overlapping captures — and so one that
    /// never calls back cannot freeze this thumbnail forever. See
    /// `HeroSnapshotScheduler.staleCaptureTimeout`.
    private var snapshotInFlightSince: TimeInterval?

    /// Bumped for every capture started, so a completion that arrives after its
    /// capture was presumed lost cannot overwrite a newer picture.
    private var snapshotGeneration = 0

    /// When this tile last captured, so the scheduler can hold it to its pane
    /// kind's idle cadence.
    private var lastCapture: TimeInterval?

    private var paneKind: HeroSnapshotScheduler.PaneKind {
        switch pane.content {
        case .terminal: return .terminal
        case .viewer: return .viewer
        }
    }

    /// Tiles are small cards in the panes' look (`PaneCard`, `PaneFocusGlow`):
    /// raised on a soft drop shadow with a hairline rim, and the selected one
    /// backlit, its light spilling past its edges onto the desk. Only the
    /// radius is the tile's own — a pane's 11pt is too round for a rect this
    /// small. (Tiles used to fade to 35% whole, rim and all, which left their
    /// edges barely visible.)
    static let cornerRadius: CGFloat = 5

    /// The window's terminal background is light (the panes' `isLight`).
    private var isLight: Bool {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config else { return false }
        return OSColor(config.backgroundColor).isLightColor
    }

    private var rimColor: NSColor {
        switch (isSelected || isHovered, isLight) {
        case (true, false): return NSColor(white: 1, alpha: isSelected ? 0.6 : 0.4)
        case (false, false): return NSColor(white: 1, alpha: 0.2)
        case (true, true): return NSColor(white: 0, alpha: isSelected ? 0.35 : 0.25)
        case (false, true): return NSColor(white: 0, alpha: 0.14)
        }
    }

    /// The selected tile's backlight: a blurred ring of light around the
    /// card, masked to outside it so the picture is never lightened.
    private let glowLayer = CALayer()
    private let glowMask = CAShapeLayer()

    var isSelected: Bool = false {
        didSet { updateAppearance() }
    }

    private var isHovered = false

    init(pane: PaneView) {
        self.pane = pane
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false

        glowLayer.shadowColor = NSColor.white.cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = 4
        glowLayer.shadowOpacity = 0
        glowMask.fillRule = .evenOdd
        glowLayer.mask = glowMask
        layer?.addSublayer(glowLayer)

        // The card: a drop shadow under it, like a pane's.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -3)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = Self.cornerRadius
        imageView.layer?.masksToBounds = true
        addSubview(imageView)

        borderLayer.fillColor = nil
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let r = Self.cornerRadius
        let card = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: r - 0.5, cornerHeight: r - 0.5, transform: nil
        )
        layer?.shadowPath = card
        glowLayer.frame = bounds
        glowLayer.shadowPath = card
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -30, dy: -30))
        outside.addPath(card)
        glowMask.path = outside
    }

    /// Capture this tile's thumbnail if the scheduler allows it.
    ///
    /// `force` skips the quiet period and the idle cadence — but never the
    /// in-flight guard, which exists to stop overlapping captures rather than to
    /// pace them. It is for tiles that have nothing to show yet.
    ///
    /// - Returns: whether a capture was actually started.
    @discardableResult
    func refreshSnapshot(scheduler: HeroSnapshotScheduler, force: Bool) -> Bool {
        if !force {
            guard scheduler.shouldCapture(
                kind: paneKind,
                lastCapture: lastCapture,
                inFlightSince: snapshotInFlightSince
            ) else { return false }
        } else if let snapshotInFlightSince,
                  scheduler.now() - snapshotInFlightSince < HeroSnapshotScheduler.staleCaptureTimeout {
            return false
        }

        let captured: Bool
        switch pane.content {
        case .terminal(let surfaceView):
            captured = refreshTerminalSnapshot(surfaceView)
        case .viewer(let viewerView):
            captured = refreshViewerSnapshot(viewerView, scheduler: scheduler)
        }

        // A pane with no size yet captured nothing, so it must not start its
        // idle interval — otherwise a tile that failed once would sit blank for
        // a whole interval before trying again.
        if captured { lastCapture = scheduler.now() }
        return captured
    }

    /// Terminal thumbnails render the surface's CALayer directly (an
    /// `IOSurfaceLayer`, so this is a blit: ~1.2ms at full pane resolution).
    ///
    /// Captured at the tile's resolution rather than the pane's: a 1200×900pt
    /// pane on a 2× display is a 16.5MB bitmap per capture, versus 0.7MB and
    /// ~0.05ms for the ~240pt tile it is about to be squeezed into.
    private func refreshTerminalSnapshot(_ surfaceView: Ghostty.SurfaceView) -> Bool {
        guard let surfaceLayer = surfaceView.layer else { return false }
        let size = surfaceView.bounds.size
        guard size.width > 0, size.height > 0 else { return false }

        let backingScale = surfaceView.window?.backingScaleFactor ?? 2.0
        let ratio = HeroSnapshotScheduler.captureRatio(paneSize: size, tileSize: bounds.size)
        let scale = backingScale * ratio
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return false }

        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }

        let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)
        guard let cgCtx = ctx?.cgContext else { return false }

        cgCtx.scaleBy(x: scale, y: scale)
        surfaceLayer.render(in: cgCtx)

        let image = NSImage(size: size)
        image.addRepresentation(bitmapRep)
        imageView.image = image
        return true
    }

    /// Viewer thumbnails must go through WKWebView.takeSnapshot: web content
    /// renders out-of-process, so rendering the view's layer (the terminal
    /// path above) would capture a blank rectangle. The call is async, so the
    /// previous image stays up until the new one lands; `refreshSnapshot` is
    /// what keeps the repeating timer from stacking captures.
    ///
    /// The snapshot is requested at the tile's width. WebKit's cost here is a
    /// full out-of-band paint in the web process — ~30ms at a 1200pt pane
    /// versus ~3ms at a 240pt tile — and it comes out of the very frame budget
    /// the user is scrolling with, so asking for pixels we immediately throw
    /// away is the expensive kind of waste. The returned image is at the
    /// display's backing scale, so it is no less sharp.
    private func refreshViewerSnapshot(_ viewerView: ViewerView, scheduler: HeroSnapshotScheduler) -> Bool {
        let webView = viewerView.webView!
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return false }

        let config = WKSnapshotConfiguration()
        if let width = HeroSnapshotScheduler.snapshotWidth(
            paneSize: webView.bounds.size,
            tileSize: bounds.size
        ) {
            config.snapshotWidth = NSNumber(value: Double(width))
        }

        snapshotInFlightSince = scheduler.now()
        snapshotGeneration += 1
        let generation = snapshotGeneration
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self, generation == self.snapshotGeneration else { return }
            self.snapshotInFlightSince = nil
            if let image {
                self.imageView.image = image
            }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onTap?()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateAppearance()
    }

    private func updateAppearance() {
        let light = isLight
        borderLayer.strokeColor = rimColor.cgColor
        layer?.shadowRadius = 6
        layer?.shadowOpacity = light ? 0.14 : 0.32
        glowLayer.shadowOpacity = isSelected ? (light ? 0.9 : 0.55) : 0
        imageView.alphaValue = isSelected ? 1.0 : (isHovered ? 0.85 : 0.7)
    }
}
