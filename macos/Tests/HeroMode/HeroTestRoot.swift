import AppKit
import SwiftUI
@testable import Ghostty

/// `HeroModeView` as the app mounts it: inside the environment that carries
/// the `Ghostty.App`. `HeroPaneView` reads its configuration from there, and
/// SwiftUI traps on a missing environment object — which, in a test that
/// hosted the bare view, took the whole test host down with it.
struct HeroTestRoot: View {
    let tree: SplitTree<PaneView>
    let state: HeroModeState

    var body: some View {
        if let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty {
            HeroModeView(tree: tree, state: state).environmentObject(ghostty)
        }
    }
}
