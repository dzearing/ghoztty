import AppKit
import SwiftUI

/// The small card that follows the pointer during a pane drag.
///
/// It is a card rather than a scaled snapshot because a snapshot alone is
/// nearly nothing. A pane's background is drawn by the card behind it, not by
/// the surface, so a terminal's snapshot holds only its glyphs: a fresh pane
/// measured 97% transparent, and at drag size that is one faint line. The
/// ghost supplies what the snapshot lacks — the pane's background, its title,
/// a rim and a shadow — so it reads as a pane whatever is in it, and a pane
/// whose content can't be captured (a web view) still gets a card.
enum PaneDragGhost {
    /// The card never outgrows this: it marks the drag, and must not hide the
    /// targets under it.
    static let maxSize = CGSize(width: 220, height: 150)

    /// A sliver of a pane still gets a card big enough to read.
    static let minSize = CGSize(width: 120, height: 72)

    static let titleHeight: CGFloat = 18
    static let cornerRadius: CGFloat = 8

    /// Room around the card in the image, for its shadow.
    static let margin: CGFloat = 10

    /// The pane's shape, scaled to fit `maxSize` and held to `minSize`.
    static func cardSize(for paneSize: CGSize) -> CGSize {
        guard paneSize.width > 0, paneSize.height > 0 else { return minSize }
        let scale = Swift.min(maxSize.width / paneSize.width, maxSize.height / paneSize.height, 1)
        return CGSize(
            width: Swift.max(minSize.width, paneSize.width * scale),
            height: Swift.max(minSize.height, paneSize.height * scale))
    }

    /// Where the image goes for a pointer at `pointer`, in a non-flipped
    /// view: the pointer holds the card by its title strip, as a window is
    /// held by its titlebar, so the card hangs below the pointer and the
    /// target under the pointer stays in view.
    static func frame(imageSize: CGSize, pointer: CGPoint) -> CGRect {
        CGRect(
            x: pointer.x - imageSize.width / 2,
            y: pointer.y - imageSize.height + margin + titleHeight / 2,
            width: imageSize.width,
            height: imageSize.height)
    }

    /// The card for a pane, or nil when the pane is not mounted and there is
    /// nothing to say what it looks like.
    @MainActor
    static func image(for pane: PaneView) -> NSImage? {
        guard pane.contentView.window != nil else { return nil }
        return image(
            paneSize: pane.contentView.bounds.size,
            title: pane.displayLabel,
            content: pane.dragSnapshot,
            background: background(of: pane))
    }

    @MainActor
    private static func background(of pane: PaneView) -> NSColor {
        guard let surface = pane.surfaceView else { return .windowBackgroundColor }
        return NSColor(surface.backgroundColor ?? surface.derivedConfig.backgroundColor)
    }

    static func image(paneSize: CGSize, title: String, content: NSImage?, background: NSColor) -> NSImage {
        let card = cardSize(for: paneSize)
        let size = CGSize(width: card.width + margin * 2, height: card.height + margin * 2)
        let fill = background.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? background
        return NSImage(size: size, flipped: false) { _ in
            let rect = CGRect(origin: CGPoint(x: margin, y: margin), size: card)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            fill.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - titleHeight)
            if let content { drawContent(content, in: body) }
            drawTitle(title, in: CGRect(x: rect.minX, y: body.maxY, width: rect.width, height: titleHeight), over: fill)
            NSGraphicsContext.restoreGraphicsState()

            (fill.isLightColor ? NSColor.black : NSColor.white).withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    /// The pane's content as it sits in the pane: from the top left, where a
    /// fresh terminal's prompt is, covering the body.
    private static func drawContent(_ content: NSImage, in body: CGRect) {
        guard content.size.width > 0, content.size.height > 0 else { return }
        let scale = Swift.max(body.width / content.size.width, body.height / content.size.height)
        let size = CGSize(width: content.size.width * scale, height: content.size.height * scale)
        NSGraphicsContext.current?.imageInterpolation = .high
        content.draw(
            in: CGRect(x: body.minX, y: body.maxY - size.height, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1)
    }

    private static func drawTitle(_ title: String, in strip: CGRect, over fill: NSColor) {
        let light = fill.isLightColor
        (light ? NSColor.black : NSColor.white).withAlphaComponent(0.1).setFill()
        strip.fill()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: (light ? NSColor.black : NSColor.white).withAlphaComponent(0.85),
            .paragraphStyle: style,
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let height = text.size().height
        text.draw(in: CGRect(
            x: strip.minX + 8,
            y: strip.midY - height / 2,
            width: strip.width - 16,
            height: height))
    }
}
