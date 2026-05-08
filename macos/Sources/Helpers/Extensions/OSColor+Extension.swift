import Foundation
#if !DOCK_TILE_PLUGIN
import GhosttyKit
#endif

extension OSColor {
    var isLightColor: Bool {
        return self.luminance > 0.5
    }

    var luminance: Double {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolvedSRGB.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r) + (0.587 * g) + (0.114 * b)
    }

    var hexString: String? {
#if canImport(AppKit)
        guard let rgb = usingColorSpace(.deviceRGB) else { return nil }
        let red = Int(rgb.redComponent * 255)
        let green = Int(rgb.greenComponent * 255)
        let blue = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
#elseif canImport(UIKit)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard self.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return nil
        }

        // Convert to 0–255 range
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)

        // Format to hexadecimal
        return String(format: "#%02X%02X%02X", r, g, b)
#endif
    }

    /// Create an OSColor from a hex string.
    convenience init?(hex: String) {
        var cleanedHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove `#` if present
        if cleanedHex.hasPrefix("#") {
            cleanedHex.removeFirst()
        }

        guard cleanedHex.count == 6 || cleanedHex.count == 8 else { return nil }

        let scanner = Scanner(string: cleanedHex)
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber) else { return nil }

        let red, green, blue, alpha: CGFloat
        if cleanedHex.count == 8 {
            alpha = CGFloat((hexNumber & 0xFF000000) >> 24) / 255
            red   = CGFloat((hexNumber & 0x00FF0000) >> 16) / 255
            green = CGFloat((hexNumber & 0x0000FF00) >> 8) / 255
            blue  = CGFloat(hexNumber & 0x000000FF) / 255
        } else { // 6 characters
            alpha = 1.0
            red   = CGFloat((hexNumber & 0xFF0000) >> 16) / 255
            green = CGFloat((hexNumber & 0x00FF00) >> 8) / 255
            blue  = CGFloat(hexNumber & 0x0000FF) / 255
        }

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    func darken(by amount: CGFloat) -> OSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedSRGB.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return OSColor(
            hue: h,
            saturation: s,
            brightness: min(b * (1 - amount), 1),
            alpha: a
        )
    }

    func lighten(by amount: CGFloat) -> OSColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolvedSRGB.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return OSColor(
            hue: h,
            saturation: s,
            brightness: min(b + (1 - b) * amount, 1),
            alpha: a
        )
    }

    /// Resolve to a concrete sRGB NSColor that is safe for getHue/getRed.
    /// Falls back through CGColor decomposition to handle catalog/dynamic colors.
    var resolvedSRGB: OSColor {
        #if canImport(AppKit)
        if let srgb = self.usingColorSpace(.sRGB) { return srgb }
        let cg = self.cgColor
        let comps = cg.components ?? []
        if comps.count >= 3 {
            return OSColor(red: comps[0], green: comps[1], blue: comps[2],
                           alpha: comps.count >= 4 ? comps[3] : 1)
        }
        if comps.count >= 1 {
            return OSColor(white: comps[0],
                           alpha: comps.count >= 2 ? comps[1] : 1)
        }
        return OSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
        #else
        return self
        #endif
    }
}

// MARK: Ghostty Types
#if !DOCK_TILE_PLUGIN
extension OSColor {
    /// Create a color from a Ghostty color.
    convenience init(ghostty: ghostty_config_color_s) {
        let red = Double(ghostty.r) / 255
        let green = Double(ghostty.g) / 255
        let blue = Double(ghostty.b) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
