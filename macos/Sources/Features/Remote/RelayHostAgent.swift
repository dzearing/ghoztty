import Foundation
import OSLog

/// Runs THIS Mac's relay agent — the `ghoztty-agent --relay` daemon that makes
/// an enrolled Mac reachable from the other machines on its account — whenever
/// the machine's enrollment says it should be served.
///
/// Without it a signed-in Mac was enrolled (listed in every chooser on the
/// account, named after the Mac) and never online: enrollment wrote
/// `relay.env` for a daemon that "polls this file", and on macOS no such
/// daemon was ever started. Design: `docs/design/mac-relay-host.md`.
///
/// ### One decision point
/// `reconcile` asks `LocalMachineEnrollment.hostingVerdict` — the enrollment
/// type stays the only authority on whether this machine's credential belongs
/// to the signed-in account — and applies the answer:
///
/// - `.host(relayBase)` → the LaunchAgent is installed and running.
/// - `.stop` → it is booted out and its plist removed.
/// - `.unchanged` (the relay couldn't say) → nothing is touched.
///
/// It runs at launch, after sign-in, and on every network-came-back
/// transition. Sign-out does not reconcile; it calls `stop` directly, because
/// every sign-out outcome (revoked, already revoked, pending revocation,
/// another account's machine) means "no relay agent", and the stop must be
/// finished before the UI reports "signed out".
///
/// ### Why its own LaunchAgent
/// Not a second mode on the session-persistence agent: one agent serving both
/// `--listen-unix` and `--relay` shares one session store, so a relay client
/// could list and ATTACH to the user's local panes; the session agent must
/// never restart under live panes, and adding `--relay` to its argv would be
/// exactly that; and `session-persistence = false` has no session agent at
/// all. The two daemons have different roles, so their single-instance guards
/// never contend (`single_instance.zig`).
///
/// ### One relay agent per machine
/// The credential (`relay.env`) and the relay role's lock are per MACHINE, not
/// per app lineage. The debug and release lineages get distinct job labels
/// (so neither rewrites the other's plist), but a lineage that starts hosting
/// boots out the other lineage's job first, and `stop` stops both — otherwise
/// the loser of the lock would exit 183 and launchd would respawn it every
/// throttle interval for as long as both were installed.
///
/// ### `GhosttyRelayDisable`
/// A relay-disabled app reads as signed out but knows nothing about the
/// machine's enrollment, so it keeps its hands off entirely: it starts
/// nothing, and it does not stop a relay agent the other lineage runs.
@MainActor
final class RelayHostAgent {
    static let shared = RelayHostAgent()

    nonisolated private static let logger = Logger(
        subsystem: Bundle.loggerSubsystem,
        category: String(describing: RelayHostAgent.self)
    )

    /// Where this lineage's job lives. Pure function of (bundle id, home), as
    /// `LocalAgentManager.Paths` is.
    struct Paths: Equatable {
        let home: URL
        /// Holds only the agent's log; the agent's own state (lock,
        /// heartbeat, `relay.env`) lives where every relay agent keeps it.
        let directory: URL
        let launchAgentLabel: String
        /// The OTHER lineage's label — booted out when this one starts hosting.
        let otherLineageLabel: String

        var logFile: URL { directory.appendingPathComponent("agent.log") }

        var launchAgentPlistURL: URL {
            Self.plistURL(home: home, label: launchAgentLabel)
        }

        static func plistURL(home: URL, label: String) -> URL {
            home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        }

        static let releaseLabel = "com.dzearing.ghoztty.relay-agent"
        static let debugLabel = "com.dzearing.ghoztty.debug.relay-agent"

        init(bundleID: String?, home: URL) {
            let isDebug = bundleID?.hasSuffix(".debug") == true
            self.home = home
            self.directory = home.appendingPathComponent(
                ".config/ghoztty/\(isDebug ? "relay-agent-debug" : "relay-agent")",
                isDirectory: true)
            self.launchAgentLabel = isDebug ? Self.debugLabel : Self.releaseLabel
            self.otherLineageLabel = isDebug ? Self.releaseLabel : Self.debugLabel
        }

        static var current: Paths {
            .init(
                bundleID: Bundle.main.bundleIdentifier,
                home: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    private let paths: Paths
    private let enrollment: LocalMachineEnrollment
    /// Tail of the serialized work, so a launch reconcile, a sign-in and a
    /// network kick can't interleave their launchctl calls.
    private var tail: Task<Void, Never>?
    private var observingNetwork = false

    init(paths: Paths = .current, enrollment: LocalMachineEnrollment = .shared) {
        self.paths = paths
        self.enrollment = enrollment
    }

    /// Whether this process may touch the machine's relay agent at all. The
    /// unit-test host must not (it would stop the user's real host), and a
    /// relay-disabled build keeps its hands off (see the type doc).
    private static var isActive: Bool {
        !AppDelegate.isTestHost && !RelayAccountKeychain.isDisabled
    }

    // MARK: Entry points

    /// Launch: reconcile now, and again on every network-came-back transition
    /// (a verdict of `.unchanged` at launch — offline — must not stick).
    func start() {
        guard Self.isActive else { return }
        if !observingNetwork {
            observingNetwork = true
            NetworkPathMonitor.shared.start()
            NotificationCenter.default.addObserver(
                forName: .ghosttyNetworkPathDidBecomeSatisfied,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.reconcile(reason: "network came back") }
                }
            }
        }
        Task { await reconcile(reason: "launch") }
    }

    /// Ask the enrollment what this machine should be doing, and do it.
    func reconcile(reason: String) async {
        guard Self.isActive else { return }
        await serialized {
            let verdict = await self.enrollment.hostingVerdict(
                accountEmail: RelayAccount.shared.email)
            Self.logger.info(
                "relay host: \(reason, privacy: .public) → \(String(describing: verdict), privacy: .public)")
            switch verdict {
            case .host(let relayBase): await self.install(relayBase: relayBase)
            case .stop: await self.uninstallBothLineages()
            case .unchanged: break
            }
        }
    }

    /// Stop hosting, unconditionally, and return once the agent is gone. For
    /// sign-out: whatever the revocation's outcome, the machine is no longer
    /// served — and for a PENDING revocation the credential is still alive, so
    /// this stop is the only thing keeping the machine dark until it lands.
    func stop(reason: String) async {
        guard Self.isActive else { return }
        await serialized {
            Self.logger.info("relay host: \(reason, privacy: .public) → stop")
            await self.uninstallBothLineages()
        }
    }

    // MARK: launchd

    private func install(relayBase: String) async {
        guard let bin = LocalAgentManager.agentBinaryURL(),
              FileManager.default.isExecutableFile(atPath: bin.path)
        else {
            Self.logger.error(
                "relay host: agent binary missing at \(LocalAgentManager.agentBinaryURL()?.path ?? "<nil>", privacy: .public)")
            return
        }
        let desired = Self.plist(
            paths: paths, binary: bin, relayBase: relayBase,
            relayEnv: RelayEnvFile.defaultURL,
            appEnv: ProcessInfo.processInfo.environment)
        let paths = self.paths
        await Task.detached(priority: .utility) {
            // One relay agent per machine: take over from the other lineage.
            Self.bootout(label: paths.otherLineageLabel, home: paths.home)
            Self.ensureLoaded(paths: paths, desired: desired)
        }.value
    }

    private func uninstallBothLineages() async {
        let home = paths.home
        let labels = [paths.launchAgentLabel, paths.otherLineageLabel]
        await Task.detached(priority: .utility) {
            for label in labels { Self.bootout(label: label, home: home) }
        }.value
    }

    /// The job's plist, as a dictionary (pure; tested).
    ///
    /// - `--headless`: a background job must never open a browser to enroll;
    ///   the app only installs it when a credential exists.
    /// - `--exit-on-revoke`: once the relay rejects the credential the agent
    ///   exits 0 instead of redialing forever with a dead token…
    /// - …and `KeepAlive = {SuccessfulExit: false}` leaves it down after that
    ///   clean exit, while still restarting it after a crash or a 183.
    /// - No `GHOSTTY_AGENT_LOCK`: the relay role's default lock is the one a
    ///   hand-started relay agent takes too, so the two stay exclusive.
    /// - `GHOSTTY_RELAY_ENV`: the exact file the app reads and writes, so an
    ///   override in the app's environment can't split them apart.
    nonisolated static func plistDictionary(
        paths: Paths, binary: URL, relayBase: String,
        relayEnv: URL, appEnv: [String: String]
    ) -> [String: Any] {
        var env: [String: String] = [
            "GHOSTTY_AGENT_NO_SELFUPDATE": "1",
            "GHOSTTY_RELAY_ENV": relayEnv.path,
        ]
        // launchd doesn't inherit the app's environment; the agent needs these
        // to start a login shell for a remote window.
        for key in volatileEnvKeys {
            if let v = appEnv[key], !v.isEmpty { env[key] = v }
        }
        return [
            "Label": paths.launchAgentLabel,
            "ProgramArguments": [
                binary.path,
                "--relay=\(relayBase)",
                "--headless",
                "--exit-on-revoke",
            ],
            "EnvironmentVariables": env,
            "WorkingDirectory": paths.home.path,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": paths.logFile.path,
            "StandardErrorPath": paths.logFile.path,
        ]
    }

    nonisolated private static func plist(
        paths: Paths, binary: URL, relayBase: String,
        relayEnv: URL, appEnv: [String: String]
    ) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: plistDictionary(
                paths: paths, binary: binary, relayBase: relayBase,
                relayEnv: relayEnv, appEnv: appEnv),
            format: .xml, options: 0)
    }

    /// Env keys inherited from whatever launched the app. They drift between
    /// launches (Finder vs a shell), so they never count as a config change —
    /// a restart of the relay agent drops the sessions it hosts for other
    /// machines, and must only happen when something real changed.
    nonisolated static let volatileEnvKeys = ["SHELL", "PATH", "LANG"]

    /// Whether two plists describe the same job, ignoring the volatile env.
    nonisolated static func sameJob(_ a: Data?, _ b: Data?) -> Bool {
        func key(_ data: Data?) -> NSDictionary? {
            guard let data,
                  var plist = (try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil)) as? [String: Any]
            else { return nil }
            if var env = plist["EnvironmentVariables"] as? [String: Any] {
                for k in volatileEnvKeys { env.removeValue(forKey: k) }
                plist["EnvironmentVariables"] = env
            }
            return plist as NSDictionary
        }
        guard let ka = key(a), let kb = key(b) else { return false }
        return ka == kb
    }

    nonisolated private static func ensureLoaded(paths: Paths, desired: Data?) {
        guard let desired else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: paths.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            logger.error("relay host: can't create \(paths.directory.path, privacy: .public): \(error)")
            return
        }

        let plistURL = paths.launchAgentPlistURL
        let changed = !sameJob(try? Data(contentsOf: plistURL), desired)
        if changed {
            do {
                try fm.createDirectory(
                    at: plistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try desired.write(to: plistURL, options: .atomic)
            } catch {
                logger.error("relay host: can't write \(plistURL.path, privacy: .public): \(error)")
                return
            }
        }

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(paths.launchAgentLabel)"
        let loaded = LocalAgentManager.launchctl(["print", service]).status == 0
        if loaded && !changed {
            // Unchanged: make sure it runs (it may have exited 0 on a revoke
            // that a later re-enrollment has since undone).
            LocalAgentManager.launchctl(["kickstart", service])
            return
        }
        // A changed job (new relay, moved binary) restarts the agent. Unlike
        // the session agent this costs nothing local: the sessions it hosts
        // belong to OTHER machines' windows, which reconnect.
        if loaded { LocalAgentManager.launchctl(["bootout", service]) }
        let (rc, out) = LocalAgentManager.launchctl(["bootstrap", domain, plistURL.path])
        if rc != 0 && rc != 5 {
            logger.error("relay host: bootstrap \(service, privacy: .public) failed rc=\(rc): \(out, privacy: .public)")
            return
        }
        LocalAgentManager.launchctl(["kickstart", service])
        logger.info("relay host: \(service, privacy: .public) installed")
    }

    /// Boot the job out and remove its plist so neither launchd nor a reboot
    /// brings it back. `bootout` waits for the process to exit. A job that is
    /// neither installed nor loaded costs one `launchctl print`.
    nonisolated private static func bootout(label: String, home: URL) {
        let plistURL = Paths.plistURL(home: home, label: label)
        let service = "gui/\(getuid())/\(label)"
        let hasPlist = FileManager.default.fileExists(atPath: plistURL.path)
        let loaded = LocalAgentManager.launchctl(["print", service]).status == 0
        guard hasPlist || loaded else { return }
        if loaded { LocalAgentManager.launchctl(["bootout", service]) }
        try? FileManager.default.removeItem(at: plistURL)
        logger.info("relay host: \(service, privacy: .public) stopped")
    }

    // MARK: Plumbing

    private func serialized(_ body: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let work = Task { @MainActor in
            await previous?.value
            await body()
        }
        tail = work
        await work.value
    }
}
