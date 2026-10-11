import SwiftUI

/// The pane sidebar's own glyphs, drawn from the design mock's icon set
/// (`temp/mocks/pane-sidebar`) rather than approximated with SF Symbols —
/// the mock's thinner, rounder strokes are the look that was chosen, and the
/// nearest symbols (`rectangle.stack`, the SF pushpin) read as a different
/// family. Paths are in the mock's 16×16 SVG space and scale to any size,
/// line width included.
enum PaneSidebarSymbol: Equatable {
    case windows(filled: Bool)
    case trash(filled: Bool)
    case pin(filled: Bool)
    case terminal
    case document
    case globe
    case diff

    /// The stroke, in 16-unit space.
    var lineWidth: CGFloat {
        switch self {
        case .terminal, .document, .globe: 1.3
        case .diff: 1.4
        case .windows, .trash, .pin: 1.25
        }
    }

    /// What is stroked.
    var outline: Path {
        var p = Path()
        switch self {
        case .windows:
            p.addRoundedRect(in: CGRect(x: 4.4, y: 1.8, width: 9.8, height: 8),
                             cornerSize: CGSize(width: 1.8, height: 1.8))
            // The window behind, peeking out below and to the left.
            p.move(to: CGPoint(x: 11.6, y: 11.6))
            p.addLine(to: CGPoint(x: 11.6, y: 12.2))
            p.addArc(tangent1End: CGPoint(x: 11.6, y: 14), tangent2End: CGPoint(x: 9.8, y: 14), radius: 1.8)
            p.addLine(to: CGPoint(x: 3.6, y: 14))
            p.addArc(tangent1End: CGPoint(x: 1.8, y: 14), tangent2End: CGPoint(x: 1.8, y: 12.2), radius: 1.8)
            p.addLine(to: CGPoint(x: 1.8, y: 6.4))
            p.addArc(tangent1End: CGPoint(x: 1.8, y: 4.6), tangent2End: CGPoint(x: 3.6, y: 4.6), radius: 1.8)
            p.addLine(to: CGPoint(x: 4.4, y: 4.6))
        case .trash:
            p.move(to: CGPoint(x: 2.8, y: 4.2)); p.addLine(to: CGPoint(x: 13.2, y: 4.2))
            p.move(to: CGPoint(x: 6.2, y: 4.2)); p.addLine(to: CGPoint(x: 6.2, y: 2.8))
            p.addLine(to: CGPoint(x: 9.8, y: 2.8)); p.addLine(to: CGPoint(x: 9.8, y: 4.2))
            p.addPath(Self.trashCan)
            if self != .trash(filled: true) {
                p.addPath(Self.trashRibs)
            }
        case .pin:
            p.addPath(Self.pinHead)
            p.addPath(Self.pinBody)
            p.move(to: CGPoint(x: 8, y: 9.8)); p.addLine(to: CGPoint(x: 8, y: 14.7))
        case .terminal:
            p.addRoundedRect(in: CGRect(x: 1.5, y: 2.5, width: 13, height: 11),
                             cornerSize: CGSize(width: 2.2, height: 2.2))
            p.move(to: CGPoint(x: 4.5, y: 6.2)); p.addLine(to: CGPoint(x: 6.8, y: 8))
            p.addLine(to: CGPoint(x: 4.5, y: 9.8))
            p.move(to: CGPoint(x: 8.2, y: 10)); p.addLine(to: CGPoint(x: 11.4, y: 10))
        case .document:
            p.move(to: CGPoint(x: 4, y: 1.8)); p.addLine(to: CGPoint(x: 9.2, y: 1.8))
            p.addLine(to: CGPoint(x: 12.5, y: 5)); p.addLine(to: CGPoint(x: 12.5, y: 14.2))
            p.addLine(to: CGPoint(x: 4, y: 14.2)); p.closeSubpath()
            p.move(to: CGPoint(x: 9, y: 1.8)); p.addLine(to: CGPoint(x: 9, y: 5.3))
            p.addLine(to: CGPoint(x: 12.5, y: 5.3))
            for (y, length) in [(8.0, 4.5), (10.3, 4.5), (12.5, 3.0)] {
                p.move(to: CGPoint(x: 6, y: y)); p.addLine(to: CGPoint(x: 6 + length, y: y))
            }
        case .globe:
            p.addEllipse(in: CGRect(x: 1.7, y: 1.7, width: 12.6, height: 12.6))
            p.addEllipse(in: CGRect(x: 5.3, y: 1.7, width: 5.4, height: 12.6))
            p.move(to: CGPoint(x: 1.9, y: 6)); p.addLine(to: CGPoint(x: 14.1, y: 6))
            p.move(to: CGPoint(x: 1.9, y: 10)); p.addLine(to: CGPoint(x: 14.1, y: 10))
        case .diff:
            p.move(to: CGPoint(x: 5, y: 2.5)); p.addLine(to: CGPoint(x: 5, y: 7.5))
            p.move(to: CGPoint(x: 2.5, y: 5)); p.addLine(to: CGPoint(x: 7.5, y: 5))
            p.move(to: CGPoint(x: 2.5, y: 12.5)); p.addLine(to: CGPoint(x: 7.5, y: 12.5))
            p.move(to: CGPoint(x: 10, y: 3)); p.addLine(to: CGPoint(x: 13.5, y: 13))
        }
        return p
    }

    /// What is filled (the "on" state of a toggle).
    var fill: Path? {
        switch self {
        case .windows(filled: true):
            Path(roundedRect: CGRect(x: 4.4, y: 1.8, width: 9.8, height: 8),
                 cornerSize: CGSize(width: 1.8, height: 1.8))
        case .trash(filled: true):
            Self.trashCan
        case .pin(filled: true):
            {
                var p = Self.pinHead
                p.addPath(Self.pinBody)
                return p
            }()
        default:
            nil
        }
    }

    /// Drawn knocked out of the fill (the filled trash can's ribs).
    var knockout: Path? {
        self == .trash(filled: true) ? Self.trashRibs : nil
    }

    private static var trashCan: Path {
        var p = Path()
        p.move(to: CGPoint(x: 4.2, y: 4.2)); p.addLine(to: CGPoint(x: 4.9, y: 13.2))
        p.addLine(to: CGPoint(x: 11.1, y: 13.2)); p.addLine(to: CGPoint(x: 11.8, y: 4.2))
        p.closeSubpath()
        return p
    }

    private static var trashRibs: Path {
        var p = Path()
        p.move(to: CGPoint(x: 6.8, y: 6.5)); p.addLine(to: CGPoint(x: 6.8, y: 11.1))
        p.move(to: CGPoint(x: 9.2, y: 6.5)); p.addLine(to: CGPoint(x: 9.2, y: 11.1))
        return p
    }

    private static var pinHead: Path {
        Path(roundedRect: CGRect(x: 5.1, y: 1.4, width: 5.8, height: 2),
             cornerSize: CGSize(width: 1, height: 1))
    }

    private static var pinBody: Path {
        var p = Path()
        p.move(to: CGPoint(x: 6.3, y: 3.4))
        p.addLine(to: CGPoint(x: 9.7, y: 3.4))
        p.addLine(to: CGPoint(x: 10.3, y: 7.5))
        p.addCurve(to: CGPoint(x: 12.4, y: 9.8),
                   control1: CGPoint(x: 11.5, y: 8), control2: CGPoint(x: 12.3, y: 8.8))
        p.addLine(to: CGPoint(x: 3.6, y: 9.8))
        p.addCurve(to: CGPoint(x: 5.7, y: 7.5),
                   control1: CGPoint(x: 3.7, y: 8.8), control2: CGPoint(x: 4.5, y: 8))
        p.closeSubpath()
        return p
    }
}

/// A `PaneSidebarSymbol`, `size` points square, in the current foreground style.
struct PaneSidebarSymbolView: View {
    let symbol: PaneSidebarSymbol
    var size: CGFloat = 15

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 16
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            let shading = GraphicsContext.Shading.foreground
            let stroke = StrokeStyle(
                lineWidth: symbol.lineWidth * scale, lineCap: .round, lineJoin: .round)
            if let fill = symbol.fill {
                let filled = fill.applying(transform)
                context.fill(filled, with: shading)
                context.stroke(filled, with: shading, style: stroke)
            }
            context.stroke(symbol.outline.applying(transform), with: shading, style: stroke)
            if let knockout = symbol.knockout {
                var inner = context
                inner.blendMode = .destinationOut
                inner.opacity = 0.45
                inner.stroke(knockout.applying(transform), with: .color(.black), style: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
