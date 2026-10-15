import Foundation
import Testing
@testable import Ghostty

// MARK: - The policy

struct MachineHostingVerdictTests {
    private func decide(
        pending: Bool = false,
        account: String? = "owner@example.com",
        _ credential: MachineHostingVerdict.CredentialState
    ) -> MachineHostingVerdict {
        MachineHostingVerdict.decide(
            pendingRevocation: pending, accountEmail: account, credential: credential)
    }

    /// An enrolled Mac whose credential belongs to the signed-in account hosts —
    /// that is the whole feature.
    @Test func theSignedInAccountsEnrollmentIsServed() {
        #expect(decide(.alive(ownerEmail: "Owner@Example.com", relayBase: "https://r.test"))
            == .host(relayBase: "https://r.test"))
    }

    /// A pending revocation outranks a credential the relay still accepts:
    /// that live credential is exactly the one being revoked, and the stopped
    /// agent is what keeps the machine dark until the revocation lands.
    @Test func aPendingRevocationAlwaysStops() {
        #expect(decide(pending: true, .alive(ownerEmail: "owner@example.com", relayBase: "x"))
            == .stop)
        #expect(decide(pending: true, .unprobed) == .stop)
        #expect(decide(pending: true, account: nil, .unknown) == .stop)
    }

    @Test func nothingToServeStops() {
        #expect(decide(.absent) == .stop)
        #expect(decide(.dead) == .stop)
        #expect(decide(account: nil, .absent) == .stop)
        #expect(decide(account: nil, .dead) == .stop)
    }

    /// Someone else's enrollment is not this app's to serve.
    @Test func anotherAccountsEnrollmentIsNotServed() {
        #expect(decide(.alive(ownerEmail: "someone@else.com", relayBase: "x")) == .stop)
    }

    /// The network blinking must neither take a working host down nor start
    /// one on a credential nobody vouched for.
    @Test func anUnreachableRelayChangesNothing() {
        #expect(decide(.unknown) == .unchanged)
        #expect(decide(account: nil, .unknown) == .unchanged)
    }

    /// Signed out at launch with a credential that still works: a Keychain
    /// read that failed after a reboot must not take the host offline (an
    /// explicit sign-out stops it by itself, without asking).
    @Test func noAccountAndALiveCredentialChangesNothing() {
        #expect(decide(account: nil, .alive(ownerEmail: "owner@example.com", relayBase: "x"))
            == .unchanged)
    }
}

// MARK: - The probe, against a stub relay

@MainActor
struct MachineHostingProbeTests {
    @Test func hostsTheRelayTheCredentialAnswersOn() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.whoami(email: "owner@example.com")

        let verdict = await fx.makeSubject().hostingVerdict(accountEmail: "owner@example.com")
        #expect(verdict == .host(relayBase: fx.relayBase))
        // Hosting changes nothing on disk.
        #expect(fx.envFile.load()?.credential?.deviceToken == "dev-token")
    }

    /// A `wss://` spelling in relay.env is handed to the agent normalized —
    /// the base the probe actually reached.
    @Test func aWebsocketBaseIsNormalized() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential(base: "wss://\(fx.host)/")
        fx.whoami(email: "owner@example.com")

        let verdict = await fx.makeSubject().hostingVerdict(accountEmail: "owner@example.com")
        #expect(verdict == .host(relayBase: fx.relayBase))
    }

    /// The device was removed from the account on another machine: the dead
    /// credential is dropped (it can never authenticate again) and nothing
    /// hosts. A recorded suspension survives, as it does for a revocation.
    @Test func aDeadCredentialStopsAndIsDropped() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        let suspended = SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox", ownerEmail: "owner@example.com")
        fx.store.suspended = suspended
        fx.reply("GET", "/v1/agent/whoami", .init(status: 401))

        let verdict = await fx.makeSubject().hostingVerdict(accountEmail: "owner@example.com")
        #expect(verdict == .stop)
        #expect(fx.envFile.load()?.credential == nil)
        #expect(fx.store.suspended == suspended)
    }

    /// Offline: no change, and the credential is certainly not touched.
    @Test func anUnreachableRelayKeepsEverything() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.reply("GET", "/v1/agent/whoami", .init(
            status: 0, failure: URLError(.notConnectedToInternet)))

        let verdict = await fx.makeSubject().hostingVerdict(accountEmail: "owner@example.com")
        #expect(verdict == .unchanged)
        #expect(fx.envFile.load()?.credential?.deviceToken == "dev-token")
    }

    /// A pending revocation stops without a single request — the stop must not
    /// wait on the very relay that couldn't be reached for the revocation.
    @Test func aPendingRevocationStopsWithoutAsking() async throws {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        try fx.seedCredential()
        fx.store.pendingRevocationEmail = "owner@example.com"
        fx.whoami(email: "owner@example.com")

        let verdict = await fx.makeSubject().hostingVerdict(accountEmail: "owner@example.com")
        #expect(verdict == .stop)
        #expect(fx.requests.isEmpty)
        #expect(fx.envFile.load()?.credential != nil)
    }

    /// A client-only Mac: nothing to serve, no requests.
    @Test func noCredentialStopsWithoutAsking() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }

        let verdict = await fx.makeSubject().hostingVerdict(accountEmail: "owner@example.com")
        #expect(verdict == .stop)
        #expect(fx.requests.isEmpty)
    }

    /// Restore then host: the credential a same-account sign-in re-enrolls is
    /// the one the next verdict serves.
    @Test func aRestoredEnrollmentIsServed() async {
        let fx = EnrollmentFixture()
        defer { fx.teardown() }
        fx.store.suspended = SuspendedEnrollment(
            relayBase: fx.relayBase, machineName: "thisbox", ownerEmail: "owner@example.com")
        fx.reply("POST", "/v1/client/devices", .init(
            status: 201, body: #"{"id":"dev-2","name":"thisbox","token":"fresh-tok"}"#))
        fx.whoami(email: "owner@example.com", deviceID: "dev-2")

        let subject = fx.makeSubject()
        #expect(await subject.hostingVerdict(accountEmail: "owner@example.com") == .stop)
        await subject.restoreEnrollment(accountEmail: "owner@example.com", sessionToken: "s")
        #expect(await subject.hostingVerdict(accountEmail: "owner@example.com")
            == .host(relayBase: fx.relayBase))
    }
}

// MARK: - The LaunchAgent

struct RelayHostAgentJobTests {
    let home = URL(fileURLWithPath: "/Users/someone")

    @Test func lineagesGetTheirOwnLabelsAndPointAtEachOther() {
        let release = RelayHostAgent.Paths(bundleID: "com.dzearing.ghoztty", home: home)
        let debug = RelayHostAgent.Paths(bundleID: "com.dzearing.ghoztty.debug", home: home)
        #expect(release.launchAgentLabel == "com.dzearing.ghoztty.relay-agent")
        #expect(debug.launchAgentLabel == "com.dzearing.ghoztty.debug.relay-agent")
        #expect(release.otherLineageLabel == debug.launchAgentLabel)
        #expect(debug.otherLineageLabel == release.launchAgentLabel)
        #expect(release.launchAgentPlistURL.path
            == "/Users/someone/Library/LaunchAgents/com.dzearing.ghoztty.relay-agent.plist")
        #expect(release.logFile.path == "/Users/someone/.config/ghoztty/relay-agent/agent.log")
        #expect(debug.logFile.path == "/Users/someone/.config/ghoztty/relay-agent-debug/agent.log")
        // Never the session agent's label or directory.
        let session = LocalAgentManager.Paths(bundleID: "com.dzearing.ghoztty", home: home)
        #expect(release.launchAgentLabel != session.launchAgentLabel)
        #expect(release.directory != session.directory)
    }

    private func job(appEnv: [String: String] = [:]) -> [String: Any] {
        RelayHostAgent.plistDictionary(
            paths: .init(bundleID: "com.dzearing.ghoztty", home: home),
            binary: URL(fileURLWithPath: "/Applications/Ghoztty.app/Contents/MacOS/ghoztty-agent"),
            relayBase: "https://relay.test",
            relayEnv: URL(fileURLWithPath: "/Users/someone/.config/ghoztty/relay.env"),
            appEnv: appEnv)
    }

    @Test func runsAHeadlessRelayAgentThatExitsOnRevoke() {
        let plist = job()
        #expect(plist["ProgramArguments"] as? [String] == [
            "/Applications/Ghoztty.app/Contents/MacOS/ghoztty-agent",
            "--relay=https://relay.test",
            "--headless",
            "--exit-on-revoke",
        ])
        #expect(plist["RunAtLoad"] as? Bool == true)
        // Restarted after a crash or a 183; left down after the clean exit a
        // revoked credential produces.
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    }

    /// The relay job takes the relay role's DEFAULT lock (so a hand-started
    /// relay agent still excludes it) and none of the session agent's
    /// identity.
    @Test func carriesNoLockOverride() {
        let env = job()["EnvironmentVariables"] as? [String: String] ?? [:]
        #expect(env["GHOSTTY_AGENT_LOCK"] == nil)
        #expect(env["GHOSTTY_AGENT_HEARTBEAT"] == nil)
        #expect(env["GHOSTTY_AGENT_NO_SELFUPDATE"] == "1")
        #expect(env["GHOSTTY_RELAY_ENV"] == "/Users/someone/.config/ghoztty/relay.env")
    }

    /// Env drift between launches (Finder vs a shell) is not a config change —
    /// a change restarts the agent and drops the sessions it hosts.
    @Test func volatileEnvIsNotAConfigChange() throws {
        func data(_ p: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
        }
        let a = try data(job(appEnv: ["PATH": "/usr/bin", "SHELL": "/bin/zsh"]))
        let b = try data(job(appEnv: ["PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "en_US.UTF-8"]))
        #expect(RelayHostAgent.sameJob(a, b))

        var moved = job()
        moved["ProgramArguments"] = ["/elsewhere/ghoztty-agent", "--relay=https://relay.test",
                                     "--headless", "--exit-on-revoke"]
        #expect(!RelayHostAgent.sameJob(a, try data(moved)))
        #expect(!RelayHostAgent.sameJob(nil, a))
    }
}
