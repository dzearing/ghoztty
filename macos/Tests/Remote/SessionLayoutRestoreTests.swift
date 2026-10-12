import Foundation
import Testing
@testable import Ghostty

/// The session-layout restore path bakes the window name into each restored
/// pane, as every freshly spawned pane gets it. An agent restart (reboot)
/// RELAUNCHes a pane with the env its restored surface config carries, so a
/// name missing here was a `GHOZTTY_WINDOW_NAME` missing from the respawned
/// shell — and `+close --target=$GHOZTTY_WINDOW_NAME` closing nothing.
struct SessionLayoutRestoreTests {
    @Test func restoredLeafCarriesTheWindowName() {
        let leaf = SessionLayoutManifest.Leaf(sessionID: "s-1", title: nil, ipcName: nil)
        let cfg = AppDelegate.sessionLayoutLeafConfig(leaf: leaf, windowName: "feature-x")
        #expect(cfg.environmentVariables["GHOZTTY_WINDOW_NAME"] == "feature-x")
        #expect(cfg.remoteSessionId == "s-1")
    }

    @Test func restoredLeafKeepsItsSnapshot() {
        var leaf = SessionLayoutManifest.Leaf(sessionID: "s-1", title: nil, ipcName: nil)
        leaf.screenSnapshot = Data([1, 2, 3]).base64EncodedString()
        leaf.screenSnapshotOffset = 42
        let cfg = AppDelegate.sessionLayoutLeafConfig(leaf: leaf, windowName: "w")
        #expect(cfg.remoteRestoreSnapshot == Data([1, 2, 3]))
        #expect(cfg.remoteRestoreByteOffset == 42)
    }

    @Test func localRestoreReadoptsAFreePersistedName() {
        let name = AppDelegate.restoredWindowName(
            persisted: "feature-x", bindLocal: true, isTaken: { _ in false })
        #expect(name == "feature-x")
    }

    /// A taken name must not be baked into the panes: they would carry ANOTHER
    /// window's name, and closing "their" window would close that one.
    @Test func takenPersistedNameIsNotReadopted() {
        let name = AppDelegate.restoredWindowName(
            persisted: "feature-x", bindLocal: true, isTaken: { $0 == "feature-x" })
        #expect(name == nil)
    }

    @Test func crossMachineResumeTakesAFreshName() {
        let name = AppDelegate.restoredWindowName(
            persisted: "feature-x", bindLocal: false, isTaken: { _ in false })
        #expect(name == nil)
    }

    @Test func missingOrEmptyPersistedNameTakesAFreshName() {
        #expect(AppDelegate.restoredWindowName(
            persisted: nil, bindLocal: true, isTaken: { _ in false }) == nil)
        #expect(AppDelegate.restoredWindowName(
            persisted: "", bindLocal: true, isTaken: { _ in false }) == nil)
    }
}
