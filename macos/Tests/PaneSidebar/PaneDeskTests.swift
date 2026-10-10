import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// A window's own gradient (`--color=random` in the elevated pane style):
/// random tones from the ocean family, falling off darker on a dark theme and
/// lighter on a light one, derived deterministically from a persisted seed.
struct PaneDeskTests {
    private let seeds: [UInt64] = (1...200).map { UInt64($0) &* 0x9E37_79B9_7F4A_7C15 }

    @Test func tonesStayInTheOceanFamily() {
        for seed in seeds {
            for isLight in [false, true] {
                let p = PaneDeskVariant(seed: seed).palette(isLight: isLight)
                #expect(PaneDeskVariant.leadHues.contains(p.lead.hue * 360), "lead is a blue")
                #expect(PaneDeskVariant.trailHues.contains(p.trail.hue * 360), "trail is a teal")
            }
        }
    }

    @Test func aDarkDeskGetsDarkerAndALightOneLighter() {
        for seed in seeds {
            let dark = PaneDeskVariant(seed: seed).palette(isLight: false)
            #expect(dark.baseEnd.brightness < dark.baseStart.brightness)
            #expect(dark.baseStart.brightness < 0.2, "a dark desk stays dark")
            let light = PaneDeskVariant(seed: seed).palette(isLight: true)
            #expect(light.baseEnd.brightness > light.baseStart.brightness)
            #expect(light.baseStart.brightness > 0.9, "a light desk stays light")
        }
    }

    @Test func aSeedAlwaysGivesTheSamePalette() {
        let v = PaneDeskVariant(seed: 42)
        #expect(v.palette(isLight: false) == v.palette(isLight: false))
        #expect(PaneDeskVariant(seed: 42).palette(isLight: true) == v.palette(isLight: true))
    }

    @Test func differentSeedsGiveDifferentDesks() {
        let palettes = Set(seeds.map { "\(PaneDeskVariant(seed: $0).palette(isLight: false))" })
        #expect(palettes.count == seeds.count)
    }

    // MARK: Cmd-N

    @Test func aWindowOpenedByHandGetsARandomDeskWhenElevated() {
        let first = PaneDeskVariant.forNewWindow(nil, style: .elevated)?.deskVariant
        let second = PaneDeskVariant.forNewWindow(nil, style: .elevated)?.deskVariant
        #expect(first != nil)
        #expect(first != second, "each new window gets its own")
    }

    @Test func aRequestedVariantIsKept() {
        var base = Ghostty.SurfaceConfiguration()
        base.deskVariant = PaneDeskVariant(seed: 7)
        #expect(PaneDeskVariant.forNewWindow(base, style: .elevated)?.deskVariant == PaneDeskVariant(seed: 7))
    }

    @Test func theFlatStyleHasNoDeskToVary() {
        #expect(PaneDeskVariant.forNewWindow(nil, style: .flat)?.deskVariant == nil)
    }

    @Test func theVariantRoundTripsThroughCoding() throws {
        let v = PaneDeskVariant(seed: 0xDEAD_BEEF)
        let back = try JSONDecoder().decode(PaneDeskVariant.self, from: JSONEncoder().encode(v))
        #expect(back == v)
    }

    /// A contact sheet of desks, for a person to look at. Written only when
    /// /tmp/pane-sidebar-snapshots exists.
    @MainActor
    @Test func contactSheet() {
        guard FileManager.default.fileExists(atPath: "/tmp/pane-sidebar-snapshots") else { return }
        for isLight in [false, true] {
            let sheet = VStack(spacing: 6) {
                ForEach(0..<3) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<3) { col in
                            let palette = row == 0 && col == 0
                                ? PaneDeskPalette.ocean(isLight: isLight)
                                : PaneDeskVariant(seed: UInt64(row * 3 + col) &* 0x2545_F491_4F6C_DD1D)
                                    .palette(isLight: isLight)
                            PaneDesk(palette: palette, opacity: 1).frame(width: 300, height: 190)
                        }
                    }
                }
            }
            .padding(6)
            .background(Color.black)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: "/tmp/pane-sidebar-snapshots/desks-\(isLight ? "light" : "dark").png"))
            }
        }
    }
}
