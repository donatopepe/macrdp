import AppKit
import UniformTypeIdentifiers
import MacRDPUpdateCore

// macrdp Controller: a menu-bar app that controls the macrdp LaunchAgent
// (label com.clintcan.macrdp, installed by packaging/install-launchagent.sh)
// and toggles flags in config.env. It is a *controller* — quitting it leaves
// the server running under launchd. It needs no TCC grants of its own (it only
// runs `launchctl`, opens URLs, and edits files in the user's own Library);
// the Screen Recording / Accessibility grants belong to the macrdp binary.

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // Lazy so the controller can be instantiated for the headless --install-agent
    // path without touching the status bar (which needs a GUI app context).
    lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    /// The server's LaunchAgent label, derived from this controller's own bundle
    /// id by stripping the ".controller" suffix — so whatever BUNDLE_PREFIX the
    /// app was built with, the controller drives the matching agent. Falls back
    /// to the default prefix for unbundled `swift run` during development.
    let label: String = {
        if let bid = Bundle.main.bundleIdentifier, bid.hasSuffix(".controller") {
            return String(bid.dropLast(".controller".count))
        }
        return "com.clintcan.macrdp"
    }()

    var uid: String { String(getuid()) }
    var domain: String { "gui/\(uid)" }
    var service: String { "gui/\(uid)/\(label)" }

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    var configURL: URL { home.appendingPathComponent("Library/Application Support/macrdp/config.env") }
    var logURL: URL { home.appendingPathComponent("Library/Logs/macrdp.log") }
    // The server owns + rotates macrdp.log itself; stderr (panics, pre-logging
    // startup errors) goes to a small separate file.
    var errLogURL: URL { home.appendingPathComponent("Library/Logs/macrdp.err.log") }
    var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }

    var timer: Timer?

    /// The tabbed Settings window (SettingsWindow.swift); nil while closed.
    var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance. The login item (a LaunchAgent) execs the binary
        // directly, which bypasses LaunchServices' own one-instance-per-bundle
        // handling — so opening the app from Finder while the login item is
        // loaded used to leave TWO icons in the menu bar, each with its own
        // state. The newcomer steps aside.
        if let bid = Bundle.main.bundleIdentifier {
            let myPID = getpid()
            let others = NSRunningApplication
                .runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != myPID }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }
        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon
        installMainMenu() // so the Settings window's text fields get edit shortcuts
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: "macrdp")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self          // menuNeedsUpdate rebuilds on every open
        statusItem.menu = menu
        rebuildMenu()
        refreshGlyph()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshGlyph()
        }
    }

    // MARK: - Agent state

    /// (loaded, pid). loaded=false means the agent isn't bootstrapped at all;
    /// pid=nil while loaded means installed but not currently running.
    func agentState() -> (loaded: Bool, pid: Int?) {
        let out = run("/bin/launchctl", ["print", service])
        guard out.code == 0 else { return (false, nil) }
        if let r = out.stdout.range(of: #"pid = (\d+)"#, options: .regularExpression) {
            let pid = out.stdout[r].split(separator: "=").last
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (true, pid)
        }
        return (true, nil)
    }

    func refreshGlyph() {
        let st = agentState()
        let running = st.pid != nil
        // Dim the menu-bar icon when the server isn't running so state is
        // glanceable without opening the menu.
        statusItem.button?.alphaValue = running ? 1.0 : 0.4
        statusItem.button?.toolTip = running
            ? "macrdp: running (pid \(st.pid!))"
            : (st.loaded ? "macrdp: stopped" : "macrdp: not installed")
    }

    // MARK: - Server status (parsed from the log)

    /// Last ~32 KB of the server log split into lines (oldest first).
    func logTail() -> [String] {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let window: UInt64 = 32 * 1024
        try? h.seek(toOffset: size > window ? size - window : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Latest TCC grant state the server logged (nil = not seen in recent log).
    /// The server logs "<X> permission already granted" / "<X> permission NOT
    /// granted" at startup; we can't query another process's TCC directly.
    func permissionStatus() -> (screen: Bool?, accessibility: Bool?) {
        var screen: Bool?
        var ax: Bool?
        for line in logTail() { // later lines win → most recent startup
            if line.contains("Screen Recording permission already granted") { screen = true } else if line
                .contains("Screen Recording permission NOT granted") { screen = false }
            if line.contains("Accessibility permission already granted") { ax = true } else if line
                .contains("Accessibility permission NOT granted") { ax = false }
        }
        return (screen, ax)
    }

    /// Most recent error worth surfacing (auth failure / port in use / panic).
    func lastServerError() -> String? {
        for raw in logTail().reversed() {
            let line = raw.replacingOccurrences(
                of: "\u{1b}\\[[0-9;]*m", with: "", options: .regularExpression)
            if line.contains("authentication failed") { return "Login failed — check the account password" }
            if line.contains("Address already in use") { return "Port in use — another server is bound to :3390" }
            if line.contains("panicked") { return "Server crashed — see Open Logs" }
        }
        return nil
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let st = agentState()
        let header: String
        if !st.loaded { header = "macrdp — not installed" }
        else if let pid = st.pid { header = "macrdp — running (pid \(pid))" }
        else { header = "macrdp — stopped" }
        let h = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        h.isEnabled = false
        menu.addItem(h)
        // Surface a server error (auth/port/crash) right under the header so a
        // silent crash-loop isn't invisible.
        if st.pid == nil, let err = lastServerError() {
            let e = NSMenuItem(title: "⚠️ \(err)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())

        // Show the tabbed Settings window (where all the config options now live).
        menu.addItem(item("Show macrdp…", #selector(showSettings)))
        menu.addItem(.separator())

        let running = st.pid != nil
        if running {
            menu.addItem(item("Stop", #selector(stop)))
            menu.addItem(item("Restart", #selector(restart)))
        } else {
            // Start self-installs the LaunchAgent + onboards the password on
            // first run, so it's always actionable (no Terminal step needed).
            menu.addItem(item(st.loaded ? "Start" : "Start (first run sets up)", #selector(start)))
        }
        // Sleep policy as a submenu: it is a two-state switch, and it is the
        // setting people flip most often (a docked vs. an unplugged laptop).
        // The server holds the display awake ONLY on AC power, so the checkmark
        // means "hold on AC", not "hold always".
        let allowSleep = readConfig()["ALLOW_SLEEP"] == "1"
        let sleepItem = NSMenuItem(title: "Sleep", action: nil, keyEquivalent: "")
        let sleepMenu = NSMenu(title: "Sleep")
        sleepMenu.addItem(checkable("Prevent sleep while on AC power", state: !allowSleep,
                                    #selector(setPreventSleepOnAC(_:)), tag: 0))
        sleepMenu.addItem(checkable("Allow the Mac to sleep normally", state: allowSleep,
                                    #selector(setPreventSleepOnAC(_:)), tag: 1))
        sleepItem.submenu = sleepMenu
        menu.addItem(sleepItem)

        let upd = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates),
                             keyEquivalent: "")
        upd.target = self
        menu.addItem(upd)
        menu.addItem(item("Uninstall…", #selector(uninstall)))
        menu.addItem(.separator())
        // Quit stops the server too, so the label says so: after it nothing is
        // listening until Start or the next login. The icon comes back through
        // "Show Controller", which reloads the login item when it is still there.
        menu.addItem(item("Quit (stops the server)", #selector(quit)))
        // Any live instance counts, not just the login item: opened from Finder
        // the app runs under a LaunchServices `application.*` job, so asking
        // launchd about our own label would offer "Show Controller" while the
        // icon is already on screen.
        if !controllerRunning() {
            menu.addItem(item("Show Controller", #selector(showController)))
        }
    }

    /// Is a launchd job currently loaded? (For the controller's own login item,
    /// so the menu can offer to bring the icon back after a Quit.)
    /// Is a copy of this controller alive? Bundle-id based, so it catches both
    /// the login-item launch and a Finder `open`.
    func controllerRunning() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return true }
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .contains { $0.processIdentifier != me }
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    // MARK: - Actions

    @objc func start() {
        // Self-install on first run: locate the server app, onboard the Keychain
        // password, write + register the LaunchAgent — no Terminal step needed.
        guard let serverApp = locateServerApp() else {
            alert(style: .warning, "Can't find macrdp.app",
                  "Move both macrdp.app and macrdp Controller into /Applications "
                  + "(or ~/Applications), then click Start again.")
            return
        }
        if !hasKeychainPassword() {
            guard promptAndStorePassword() else { return } // user cancelled
        }
        ensureConfigExists()
        let firstInstall = !FileManager.default.fileExists(atPath: plistURL.path)
        if firstInstall { installLaunchAgent(serverApp: serverApp) }
        ensureLoaded()
        _ = run("/bin/launchctl", ["kickstart", "-k", service])
        refreshGlyph()
        if firstInstall { remindPermissions() }
    }

    @objc func stop() {
        _ = run("/bin/launchctl", ["bootout", service])
        refreshGlyph()
    }

    @objc func restart() { start() }

    func ensureLoaded() {
        guard !agentState().loaded, FileManager.default.fileExists(atPath: plistURL.path) else { return }
        // `launchctl bootstrap` intermittently fails with EIO ("Bootstrap
        // failed: 5: Input/output error") right after a bootout; retry a few
        // times until the service registers.
        for _ in 0..<5 {
            _ = run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
            if agentState().loaded { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        _ = run("/bin/launchctl", ["enable", service])
    }

    // MARK: - Headless entry (scripted/MDM deploy + testing)

    /// Runs the install logic without the GUI. `--print-paths` is side-effect
    /// free; `--install-agent` locates the server, writes + loads the agent
    /// (assumes the Keychain password is set separately for unattended deploys).
/// Headless self-test: exercise every path the menu bar and the Settings
    /// window can take EXCEPT the ones that need a human (showing a window,
    /// opening a System Settings pane, the smart-card installer, the camera
    /// system extension). Prints PASS/FAIL per item and exits non-zero if any
    /// fail, so it can be run from a script or as a launchd health probe.
    ///
    /// It is deliberately non-destructive: config.env is snapshotted and put
    /// back, and the Keychain round-trip uses its OWN service name, never the
    /// real `macrdp` entry with the account password in it.
    func selfTest() -> Int32 {
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok {
                print("  ✓ \(name)"); pass += 1
            } else {
                print("  ✗ \(name)\(detail().isEmpty ? "" : " — \(detail())")"); fail += 1
            }
        }

        print("macrdp Controller self-test — \(installedServerVersion() ?? "server app NOT FOUND")")

        // 1. Inventory: the Settings window can write these, and the Rust bridge
        //    is asserted against the same list.
        let missing = ["ALLOW_SLEEP", "ENABLE_LOSSY_AUDIO", "USB_STREAM_STALL_MS",
                       "RESTORE_WINDOWS_ON_DISCONNECT", "ENABLE_USB_REDIRECTION"]
            .filter { ConfigKeys.key($0) == nil }
        check("config key inventory complete", missing.isEmpty, "missing: \(missing)")

        // 2. config.env round-trip, restored afterwards.
        let snapshot = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        do {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: configURL.path) {
                try? "BIND=\"127.0.0.1:3390\"\n".write(to: configURL, atomically: true,
                                                      encoding: .utf8)
            }
            let probe = "SELFTEST_PROBE"
            writeConfig(key: probe, value: "1")
            let back = readConfig()[probe]
            check("config.env write → read round-trip", back == "1", "read back \(back ?? "nil")")
            // Rewrite an existing key rather than appending a second copy.
            writeConfig(key: probe, value: "0")
            check("config.env rewrite in place", readConfig()[probe] == "0")
            let lines = (try? String(contentsOf: configURL, encoding: .utf8))?
                .split(separator: "\n").filter { $0.contains(probe) } ?? []
            check("no duplicate key written", lines.count == 1, "\(lines.count) copies")
            if !snapshot.isEmpty {
                try? snapshot.write(to: configURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: configURL)
            }
        }

        // 3. The inverted key must round-trip to the value the SERVER expects:
        //    "prevent sleep ON" has to write ALLOW_SLEEP=0.
        let sleepKey = ConfigKeys.key("ALLOW_SLEEP")!
        check("sleep toggle writes the inverted key",
              ConfigKeys.value(for: sleepKey, toggleOn: true) == "0"
                  && ConfigKeys.value(for: sleepKey, toggleOn: false) == "1")

        // 4. Keychain, read-only on the real entry + a full round-trip on our own
        //    service so nothing touches the stored account password.
        check("Keychain: real entry detected (read-only)", hasKeychainPassword(),
              "no macrdp entry — the server cannot start headless")
        let probeService = "macrdp-selftest"
        _ = run("/usr/bin/security",
                ["delete-generic-password", "-s", probeService, "-a", NSUserName()])
        let added = run("/usr/bin/security",
                        ["add-generic-password", "-U", "-s", probeService, "-a", NSUserName(),
                         "-w", "selftest-value"]).code == 0
        // `-w` is what actually prints the password; without it the command
        // prints only the attributes, so the comparison below would fail on a
        // perfectly good entry.
        let readRun = run("/usr/bin/security",
                          ["find-generic-password", "-s", probeService, "-a", NSUserName(), "-w"])
        let readBack = readRun.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == "selftest-value"
        let removed = run("/usr/bin/security",
                          ["delete-generic-password", "-s", probeService, "-a", NSUserName()])
            .code == 0
        check("Keychain add → read → delete (own service)",
              added && readBack && removed,
              "add=\(added) read=\(readBack) delete=\(removed) "
                  + "[find rc=\(readRun.code) out=\(readRun.stdout.prefix(120))]")

        // 5. Permissions: read-only queries, so this is safe to run anywhere.
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()
        print("  · Screen Recording \(screenOK ? "granted" : "NOT granted")"
            + " — the server bundle must be granted, not the controller")
        print("  · Accessibility \(axOK ? "granted" : "NOT granted")")
        check("permission probes answerable", true)

        // 6. Install discovery.
        check("server app found", locateServerApp() != nil)
        check("controller bundle found", locateControllerApp() != nil)
        check("server LaunchAgent plist present",
              FileManager.default.fileExists(atPath: plistURL.path), plistURL.path)
        check("controller login item present",
              FileManager.default.fileExists(atPath: selfPlistURL.path), selfPlistURL.path)

        // 7. launchd, read-only.
        let st = agentState()
        check("server agent state readable (loaded=\(st.loaded) pid=\(st.pid.map(String.init) ?? "none"))",
              true)

        // 8. Updater: version compare, asset selection, checksum parsing, and a
        //    REAL fetch of the published SHA256SUMS — without installing
        //    anything. This is the part that silently rots.
        check("version compare rejects an older release",
              !Version.isNewer("0.9.9", than: "0.9.10"))
        check("version compare accepts a newer patch",
              Version.isNewer("0.9.10", than: "0.9.9"))
        switch latestRelease() {
        case .failure(let why):
            check("GitHub release lookup", false, why.message)
        case .success(let rel):
            check("GitHub release lookup (latest \(rel.tag))", true)
            let names = rel.assets.map(\.lastPathComponent)
            guard let zipName = Assets.url(in: names, endingWith: "-app.zip"),
                  let sumsName = Assets.url(in: names, endingWith: "SHA256SUMS")
            else {
                check("release assets present", false, "assets: \(names)")
                break
            }
            check("release assets present (\(names.count))", true)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("macrdp-selftest-\(ProcessInfo.processInfo.processIdentifier)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let sumsURL = tmp.appendingPathComponent(sumsName)
            guard download(assetURL(assets: rel.assets, suffix: "SHA256SUMS") ?? rel.assets[0],
                           to: sumsURL)
            else {
                check("download SHA256SUMS", false)
                break
            }
            // Deliberately do NOT download the 8 MB app here: verify the MANIFEST
            // parses and that a wrong file name yields no expectation (which is
            // what makes a tampered archive fail instead of pass).
            let manifest = (try? String(contentsOf: sumsURL, encoding: .utf8)) ?? ""
            let want = Checksums.expected(inManifest: manifest, for: zipName)
            check("SHA256SUMS parses for \(zipName)", want?.count == 64,
                  "expected 64 hex chars, got \(want?.count ?? -1)")
            check("SHA256SUMS yields nothing for an unknown file",
                  Checksums.expected(inManifest: manifest, for: "not-a-real-file.zip") == nil)
        }

        print("self-test: \(pass) ok, \(fail) failed")
        return fail == 0 ? 0 : 1
    }
    func runHeadless(_ args: [String]) -> Int32 {
        if args.contains("--self-test") { return selfTest() }
        // Quit from a script / MDM: stop the server agent AND unload the
        // controller's login item, so nothing comes back until Start or the next
        // login. Same code path as the menu's Quit, so it cannot drift.
        if args.contains("--stop-all") {
            let r = stopEverything(terminate: false)
            print("server agent: \(r.serverStopped ? "stopped" : "was not running")")
            print("controller:   \(r.selfStopped ? "login item unloaded" : "no login item")")
            print("both return at the next login, or via Start / --install-agent")
            return 0
        }
        if args.contains("--print-paths") {
            print("label:      \(label)")
            print("bind:       \(readConfig()["BIND"] ?? "127.0.0.1:3390")")
            print("server app: \(locateServerApp()?.path ?? "NOT FOUND")")
            print("plist:      \(plistURL.path)")
            print("config:     \(configURL.path)")
            print("log:        \(logURL.path)")
            // The build stamp, so "is the installed copy current?" is one command:
            // compare this with `git rev-parse HEAD` in the repository.
            let revURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/build-revision")
            let rev = (try? String(contentsOf: revURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no stamp)"
            print("revision:   \(rev)  (controller v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"))")
            print("password:   \(hasKeychainPassword() ? "set" : "MISSING")")
            return 0
        }
        guard let serverApp = locateServerApp() else {
            FileHandle.standardError.write(Data(
                "error: macrdp.app not found next to the controller or in /Applications\n".utf8))
            return 1
        }
        ensureConfigExists()
        installLaunchAgent(serverApp: serverApp)
        ensureLoaded()
        _ = run("/bin/launchctl", ["kickstart", "-k", service])
        print("installed: \(plistURL.path) -> \(serverApp.path)")
        if !hasKeychainPassword() {
            print("note: Keychain password not set — store it with:")
            print("  security add-generic-password -U -s macrdp -a \(NSUserName()) -w '<password>'")
        }
        return 0
    }

    // MARK: - Self-install

    /// Locate the server bundle (`macrdp.app`): next to this controller first
    /// (the usual case — both dragged into the same folder), then the standard
    /// install locations.
    func locateServerApp() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("macrdp.app"),
            URL(fileURLWithPath: "/Applications/macrdp.app"),
            home.appendingPathComponent("Applications/macrdp.app"),
        ]
        let fm = FileManager.default
        return candidates.first {
            fm.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/macrdp").path)
        }
    }

    /// Write + register the LaunchAgent plist pointing at the located server's
    /// SIGNED binary, run directly with `--config` (the binary reads config.env
    /// itself). Mirrors packaging/install-launchagent.sh, in-process. Launching
    /// the signed Mach-O — not an unsigned wrapper script — gives macOS
    /// Background Task Management a stable identity to approve once.
    func installLaunchAgent(serverApp: URL) {
        let bin = serverApp.appendingPathComponent("Contents/MacOS/macrdp").path
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [bin, "--config", configURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            // No StandardOutPath: the server writes + rotates macrdp.log itself
            // (a second writer would corrupt it / strand launchd on a rotated
            // inode). StandardErrorPath keeps panics + pre-logging stderr.
            "StandardErrorPath": errLogURL.path,
            "EnvironmentVariables": ["RUST_LOG": "info"],
        ]
        let fm = FileManager.default
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                          format: .xml, options: 0) {
            try? data.write(to: plistURL)
        }
    }

    // MARK: - Keychain password onboarding

    /// The server (run headless by launchd) reads its account password from the
    /// Keychain via the `security` CLI, so we write it the same way — keeping the
    /// item's access context as /usr/bin/security so no read-time prompt appears.
    func hasKeychainPassword() -> Bool {
        run("/usr/bin/security", ["find-generic-password", "-s", "macrdp", "-a", NSUserName()]).code == 0
    }

    @discardableResult
    func promptAndStorePassword() -> Bool {
        let a = NSAlert()
        a.messageText = "Enter your macOS account password"
        a.informativeText = "macrdp authenticates RDP clients against your Mac account and "
            + "starts headless via launchd, so the password is stored in your login Keychain. "
            + "It never leaves this Mac."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Account password for \(NSUserName())"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return false }
        let r = run("/usr/bin/security",
                    ["add-generic-password", "-U", "-s", "macrdp", "-a", NSUserName(),
                     "-w", field.stringValue])
        if r.code != 0 {
            alert(style: .critical, "Couldn't save password", "Keychain returned an error.")
            return false
        }
        return true
    }

    @objc func setPassword() { promptAndStorePassword() }

    func remindPermissions() {
        let a = NSAlert()
        a.messageText = "Grant macrdp two permissions"
        a.informativeText = "macrdp needs Screen Recording (to share the display) and "
            + "Accessibility (to forward keyboard/mouse). Enable macrdp.app in System "
            + "Settings → Privacy & Security, then it'll work."
        a.addButton(withTitle: "Open Privacy Settings")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { openScreenRecording() }
    }

    func alert(style: NSAlert.Style, _ message: String, _ info: String) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        _ = a.runModal()
    }

    /// An attached USB device, for the smart-card trigger picker.
    struct UsbDevice {
        let vid: String // "0x2174" (4-digit lowercase hex)
        let pid: String // "0x2100"
        let label: String // human-readable name
    }

    /// Enumerate attached USB devices via `ioreg -a -r -c IOUSBHostDevice`, which
    /// emits an XML-plist array of device dicts (idVendor/idProduct as decimal
    /// ints, plus name strings). We deliberately use ioreg, NOT
    /// `system_profiler SPUSBDataType`: some USB-C devices (e.g. a Transcend
    /// ESD310C SSD — the dev trigger) are visible in ioreg but never appear in
    /// the SPUSBDataType tree, so a system_profiler-based picker silently misses
    /// them. install-ifd-handler.sh's hint dump already uses ioreg for the same
    /// reason. VID/PID are formatted as the 4-digit lowercase hex the bundle's
    /// Info.plist wants.
    func usbDevices() -> [UsbDevice] {
        let out = run("/usr/sbin/ioreg", ["-a", "-r", "-c", "IOUSBHostDevice"])
        guard out.code == 0, let data = out.stdout.data(using: .utf8),
              let list = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [[String: Any]] else { return [] }
        func hex4(_ any: Any?) -> String? {
            // idVendor/idProduct come as NSNumber; tolerate a string too.
            if let n = any as? Int { return String(format: "0x%04x", n & 0xFFFF) }
            if let s = any as? String, let n = Int(s) { return String(format: "0x%04x", n & 0xFFFF) }
            return nil
        }
        var devices: [UsbDevice] = []
        var seen = Set<String>()
        for it in list {
            guard let vid = hex4(it["idVendor"]), let pid = hex4(it["idProduct"]) else { continue }
            let name = (it["USB Product Name"] as? String)
                ?? (it["IORegistryEntryName"] as? String) ?? "USB device"
            let man = (it["USB Vendor Name"] as? String) ?? ""
            let label = (man.isEmpty || name.contains(man)) ? name : "\(name) (\(man))"
            // De-dupe identical VID/PID (e.g. two of the same stick) by key.
            let key = "\(vid):\(pid):\(label)"
            if seen.insert(key).inserted { devices.append(UsbDevice(vid: vid, pid: pid, label: label)) }
        }
        return devices
    }

    enum TriggerChoice {
        case cancel // abort the install
        case keepDefault // install, leave the bundle's baked-in trigger
        case device(vid: String, pid: String) // install, rebind to this device
    }

    /// Show a native popup of attached USB devices to use as the smart-card load
    /// trigger (macOS loads the IFD driver only on a USB hotplug whose VID/PID
    /// match the bundle). Returns the user's choice; "Keep default" leaves the
    /// trigger unchanged, a device rebinds it via IFD_VID/IFD_PID.
    func pickUsbTrigger() -> TriggerChoice {
        let devices = usbDevices()
        let a = NSAlert()
        a.messageText = "Choose the USB trigger device"
        a.informativeText = "macOS loads the smart-card driver only while a USB device with a "
            + "matching ID is plugged in. Pick the device you'll keep attached as the trigger "
            + "(any USB stick works), or choose \u{201C}Keep default trigger\u{201D} to leave it "
            + "unchanged."
        a.addButton(withTitle: "Install")
        a.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
        popup.addItem(withTitle: "Keep default trigger")
        for d in devices { popup.addItem(withTitle: "\(d.label)  —  \(d.vid):\(d.pid)") }
        a.accessoryView = popup
        a.window.initialFirstResponder = popup
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return .cancel }
        let idx = popup.indexOfSelectedItem
        if idx <= 0 { return .keepDefault }
        let d = devices[idx - 1]
        return .device(vid: d.vid, pid: d.pid)
    }

    /// One-time privileged install of the smart-card IFD handler (the toggle only
    /// flips the server flag; the handler still has to be copied into the system
    /// drivers dir). Lets the user pick the USB trigger device from a popup
    /// (matching the CLI's select-usb-trigger.sh), passes it to the embedded
    /// installer as IFD_VID/IFD_PID, then runs it (it prompts for admin via its
    /// own GUI dialog).
    @objc func installSmartcardHandler() {
        func say(_ msg: String, _ info: String) {
            let a = NSAlert()
            a.messageText = msg
            a.informativeText = info
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            _ = a.runModal()
        }
        guard let app = locateServerApp() else {
            say("macrdp.app not found", "Install macrdp.app first, then run this again.")
            return
        }
        let installer = app.appendingPathComponent("Contents/Resources/install-ifd-handler.sh").path
        guard FileManager.default.fileExists(atPath: installer) else {
            say("Installer not found",
                "This macrdp.app build doesn't bundle the smart-card handler installer.")
            return
        }
        var env: [String: String] = [:]
        var picked: String?
        switch pickUsbTrigger() {
        case .cancel: return
        case .keepDefault: break
        case let .device(vid, pid):
            env["IFD_VID"] = vid
            env["IFD_PID"] = pid
            picked = "\(vid):\(pid)"
        }
        let out = run("/bin/bash", [installer], env: env)
        if out.code == 0 {
            let trigger = picked.map { "the chosen trigger device (\($0))" } ?? "the USB trigger device"
            say("Smart-card handler installed",
                "Unplug/replug \(trigger) so macOS loads the driver, and make sure "
                    + "the connecting client redirects its smart card.")
        } else {
            say("Install failed",
                out.stdout.isEmpty
                    ? "The installer exited with code \(out.code)." : String(out.stdout.suffix(800)))
        }
    }

    // Standard 16:9 virtual-display resolutions, highest 1440p; default 1920×1080.
    static let resolutions: [(Int, Int, String)] = [
        (1280, 720, "1280 × 720"),
        (1600, 900, "1600 × 900"),
        (1920, 1080, "1920 × 1080 (1080p)"),
        (2560, 1440, "2560 × 1440 (1440p)"),
    ]

    /// (bundle id, menu label) curated shortcuts for the Ctrl→Cmd exclude list —
    /// common editors with an embedded terminal that can't be auto-detected.
    /// Anything else is added via "Add an app…" (which reads the bundle id off the
    /// chosen .app, so no need to know it).
    static let remapExcludeApps: [(String, String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code — Insiders"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
    ]

    /// (config value, menu label) for the keyboard-layout picker. The empty
    /// value = no translation (positional keycodes / US ANSI). Values match the
    /// short names `--keyboard-layout` accepts.
    static let keyboardLayouts: [(String, String)] = [
        ("", "US / default (no translation)"),
        ("british", "British"),
        ("french", "French (AZERTY)"),
        ("german", "German (QWERTZ)"),
        ("swissgerman", "Swiss German"),
        ("spanish", "Spanish"),
        ("italian", "Italian"),
        ("portuguese", "Portuguese"),
        ("brazilian", "Portuguese (Brazil)"),
        ("dutch", "Dutch"),
        ("belgian", "Belgian"),
        ("swedish", "Swedish"),
        ("norwegian", "Norwegian"),
        ("danish", "Danish"),
        ("finnish", "Finnish"),
        ("russian", "Russian"),
        ("polish", "Polish"),
        ("czech", "Czech"),
        ("hungarian", "Hungarian"),
    ]

    /// Re-exec the agent so config.env changes take effect, if it's running.
    func applyIfRunning() {
        if agentState().pid != nil {
            _ = run("/bin/launchctl", ["kickstart", "-k", service])
        }
    }

    func checkable(_ title: String, state: Bool, _ sel: Selector, tag: Int) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        i.state = state ? .on : .off
        i.tag = tag
        return i
    }

    /// tag 0 = prevent on AC (default), tag 1 = allow normal sleep. Writes the
    /// INVERTED key and applies with a single kickstart, so one click is one
    /// restart — the old menu wrote + kickstarted per toggle.
    @objc func setPreventSleepOnAC(_ sender: NSMenuItem) {
        // tag 1 = "allow normal sleep", i.e. the toggle is OFF. The inversion
        // itself lives in ConfigKeys so the UI and the tests cannot disagree.
        let prevent = sender.tag == 0
        let key = ConfigKeys.key("ALLOW_SLEEP") ?? ConfigKey("ALLOW_SLEEP", inverted: true)
        writeConfig(key: key.name, value: ConfigKeys.value(for: key, toggleOn: prevent))
        applyIfRunning()
    }

    // MARK: - Update from GitHub

    /// Latest published release. Any failure (offline, rate-limited, malformed
    /// JSON) is reported rather than guessed: an updater that invents a version
    /// is worse than one that says "could not check".
    struct UpdateFailure: Error { let message: String }

    func latestRelease() -> Result<(tag: String, version: String, assets: [URL]), UpdateFailure> {
        // Fixed to this fork's repo — the same one install-remote.sh uses.
        let api = "https://api.github.com/repos/donatopepe/macrdp/releases/latest"
        let r = run("/usr/bin/curl", ["-fsSL", "-H", "Accept: application/vnd.github+json", api])
        guard r.code == 0,
              let data = r.stdout.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String
        else {
            return .failure(UpdateFailure(
                message: "could not read the release list from GitHub (curl exit \(r.code))"))
        }
        let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))
        var assets: [URL] = []
        for a in (json["assets"] as? [[String: Any]]) ?? [] {
            if let b = a["browser_download_url"] as? String, let u = URL(string: b) {
                assets.append(u)
            }
        }
        return .success((tag: tag, version: version, assets: assets))
    }

    /// The installed server app's own version, from its Info.plist.
    func installedServerVersion() -> String? {
        guard let app = locateServerApp(),
              let info = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                      as? String
        else { return nil }
        return info
    }

    /// Thin wrappers over MacRDPUpdateCore so the logic lives in one place and
    /// is unit-tested without a GUI (see Sources/MacRDPUpdateCore).
    func isNewer(_ candidate: String, than current: String) -> Bool {
        Version.isNewer(candidate, than: current)
    }

    func assetURL(assets: [URL], suffix: String) -> URL? {
        guard let name = Assets.url(in: assets.map(\.lastPathComponent), endingWith: suffix)
        else { return nil }
        return assets.first { $0.lastPathComponent == name }
    }

    @objc func checkForUpdates() {
        guard let installed = installedServerVersion() else {
            alert(style: .warning, "Can't tell which version is installed",
                  "macrdp.app was not found next to the Controller or in /Applications.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        switch latestRelease() {
        case .failure(let why):
            alert(style: .warning, "Update check failed",
                  why.message + "\n\nThe installed version is \(installed).")
        case .success(let rel):
            guard isNewer(rel.version, than: installed) else {
                alert(style: .informational, "macrdp is up to date",
                      "Installed \(installed), latest release is \(rel.tag).")
                return
            }
            guard let zip = assetURL(assets: rel.assets, suffix: "-app.zip"),
                  let sums = assetURL(assets: rel.assets, suffix: "SHA256SUMS")
            else {
                alert(style: .warning, "Release \(rel.tag) has no app archive",
                      "Expected an asset ending in -app.zip plus SHA256SUMS.")
                return
            }
            confirmInstall(version: rel.version, tag: rel.tag, installed: installed,
                           zip: zip, sums: sums)
        }
    }

    /// Fetch, verify, replace — with the TCC-identity check this whole session
    /// has been about: the published bundle is ad-hoc signed, so replacing it
    /// changes the code identity and macOS drops the Screen Recording /
    /// Accessibility grants. Re-signing locally with the `macrdp Local Code
    /// Signing` certificate keeps the identity stable; if it still changed, say
    /// so loudly rather than letting the user find a dead input path later.
    func confirmInstall(version: String, tag: String, installed: String,
                        zip: URL, sums: URL) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Update macrdp \(installed) → \(version)?"
        a.informativeText = """
            Downloads \(zip.lastPathComponent) from the \(tag) release, verifies its SHA-256, \
            then replaces ~/Applications/macrdp.app (rolling back if the new bundle does not \
            verify).

            macOS keys your Screen Recording and Accessibility grants to the app's code \
            identity, so replacing it can drop them. The updater re-signs with the local \
            "macrdp Local Code Signing" certificate to keep the identity stable, and warns \
            you if that was not possible.

            This updates the SERVER only. The Controller is not part of the release assets — \
            it is rebuilt from the repository with gui/make-tray-app.sh.
            """
        a.addButton(withTitle: "Download and install")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrdp-update-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let sumsPath = tmp.appendingPathComponent("SHA256SUMS")
        let zipPath = tmp.appendingPathComponent(zip.lastPathComponent)
        guard download(sums, to: sumsPath), download(zip, to: zipPath) else {
            alert(style: .warning, "Download failed", "Could not fetch the release assets.")
            return
        }
        guard verifyChecksum(zipPath, against: sumsPath) else {
            alert(style: .critical, "Checksum mismatch",
                  "\(zip.lastPathComponent) does not match SHA256SUMS. Nothing was changed.")
            return
        }
        let staging = tmp.appendingPathComponent("staged")
        let un = run("/usr/bin/ditto", ["-x", "-k", zipPath.path, staging.path])
        let stagedApp = staging.appendingPathComponent("macrdp.app")
        guard un.code == 0, FileManager.default.fileExists(atPath: stagedApp.path) else {
            alert(style: .warning, "Could not unpack the archive", "ditto exit \(un.code).")
            return
        }
        guard let current = locateServerApp() else {
            alert(style: .warning, "Installed app not found", "Nothing to replace.")
            return
        }
        let drBefore = designatedRequirement(of: current)
        // Keep the old bundle until the new one verifies: a failed install must
        // not leave the user with no server at all.
        let backup = tmp.appendingPathComponent("macrdp.app.old")
        try? FileManager.default.moveItem(at: current, to: backup)
        do {
            try FileManager.default.moveItem(at: stagedApp, to: current)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: current)
            alert(style: .critical, "Install failed", "Rolled back: \(error.localizedDescription)")
            return
        }
        resignInPlace(current)
        guard codesignValid(current) else {
            try? FileManager.default.moveItem(at: current, to: tmp.appendingPathComponent("bad.app"))
            try? FileManager.default.moveItem(at: backup, to: current)
            alert(style: .critical, "The new app does not verify",
                  "Rolled back to the previous version.")
            return
        }
        let drAfter = designatedRequirement(of: current)
        applyIfRunning()
        if let before = drBefore, let after = drAfter, before != after {
            alert(style: .warning, "Installed \(version) — re-grant the permissions",
                  "The code identity changed, so macOS dropped the Screen Recording and "
                  + "Accessibility grants. Re-grant BOTH in System Settings → Privacy & "
                  + "Security, then restart macrdp.\n\nbefore: \(before)\nafter:  \(after)")
        } else {
            alert(style: .informational, "Installed \(version)",
                  "The code identity is unchanged, so your permissions still apply. "
                  + "The server has been restarted.")
        }
    }

    func download(_ url: URL, to path: URL) -> Bool {
        let r = run("/usr/bin/curl", ["-fsSL", "-o", path.path, url.absoluteString])
        return r.code == 0 && FileManager.default.fileExists(atPath: path.path)
    }

    /// Compare the downloaded file against its SHA256SUMS line.
    func verifyChecksum(_ file: URL, against sums: URL) -> Bool {
        guard let text = try? String(contentsOf: sums, encoding: .utf8) else { return false }
        guard let want = Checksums.expected(inManifest: text, for: file.lastPathComponent)
        else { return false }
        return run("/usr/bin/shasum", ["-a", "256", file.path])
            .stdout.split(separator: " ").first.map(String.init) == want
    }

    /// Re-sign in place with the local certificate when it exists, so an update
    /// does not silently change the identity macOS keyed the grants to.
    func resignInPlace(_ app: URL) {
        let kc = home.appendingPathComponent("Library/Keychains/login.keychain-db").path
        let has = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", kc])
            .stdout.contains("macrdp Local Code Signing")
        guard has else { return } // no certificate available: ad-hoc identity stands
        _ = run("/usr/bin/codesign",
                ["--force", "-s", "macrdp Local Code Signing", app.path])
    }

    func codesignValid(_ app: URL) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--strict", app.path]).code == 0
    }

    func designatedRequirement(of app: URL) -> String? {
        // codesign writes this line to stdout with the `# ` prefix when the
        // signature is ad-hoc, so match loosely and trim.
        let r = run("/usr/bin/codesign", ["-d", "-r-", app.path])
        guard let line = r.stdout
            .split(separator: "\n")
            .first(where: { $0.contains("designated") })
        else { return nil }
        let cleaned = line
            .replacingOccurrences(of: "designated => ", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Uninstall

    /// Destructive and partly irreversible, so it is an explicit checklist with
    /// conservative defaults: the server, the agent and the bundles go;
    /// config.env and the Keychain entry (a real account password) stay unless
    /// explicitly ticked.
    @objc func uninstall() {
        // NSAlert carries at most three buttons, so the two genuinely optional
        // and irreversible things (config.env, the Keychain password) are
        // checkboxes in the accessory view, unticked by default. The three
        // buttons are the real choice: stop, uninstall, cancel.
        let purgeConfig = NSButton(checkboxWithTitle: "Also delete config.env", target: nil, action: nil)
        let purgeKeychain = NSButton(checkboxWithTitle: "Also delete the Keychain password",
                                     target: nil, action: nil)
        let accessory = NSStackView(views: [purgeConfig, purgeKeychain])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6

        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Uninstall macrdp?"
        a.informativeText = """
            “Stop” only halts the server — everything stays installed and comes back at the next             login or from Start. “Uninstall” removes the server LaunchAgent, macrdp.app, the             Controller and its login item; config.env and the Keychain password are kept unless             you tick the boxes below.
            """
        a.accessoryView = accessory
        a.addButton(withTitle: "Stop the server")
        let uninstall = a.addButton(withTitle: "Uninstall")
        let cancel = a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        let choice = a.runModal()
        if choice == .alertThirdButtonReturn { return } // Cancel

        var log: [String] = []
        if agentState().pid != nil || agentState().loaded {
            _ = run("/bin/launchctl", ["bootout", service])
        }
        log.append("server agent: \(agentState().loaded ? "still loaded" : "stopped")")

        if choice == .alertSecondButtonReturn {
            // Reuse the shell uninstaller rather than reimplementing it: it
            // encodes the safe order (unload, remove the plist, keep config.env
            // unless asked) and is what the README documents.
            let script = home.appendingPathComponent("macrdp/packaging/uninstall-launchagent.sh")
            var args = [script.path, "--yes"]
            if purgeConfig.state == .on { args.append("--purge-config") }
            if purgeKeychain.state == .on { args.append("--purge-keychain") }
            if FileManager.default.isExecutableFile(atPath: script.path) {
                log.append("uninstall-launchagent.sh: exit \(run("/bin/bash", args).code)")
            } else {
                try? FileManager.default.removeItem(at: plistURL)
                log.append("removed the plist directly (script missing at \(script.path))")
            }
            if let app = locateServerApp() {
                try? FileManager.default.removeItem(at: app)
                log.append("removed \(app.lastPathComponent)")
            }
            if let c = locateControllerApp(), c != locateServerApp() {
                try? FileManager.default.removeItem(at: c)
                log.append("removed \(c.lastPathComponent)")
            }
            _ = run("/bin/launchctl", ["bootout", selfService])
            try? FileManager.default.removeItem(at: selfPlistURL)
            log.append("removed the Controller login item")
        }
        if purgeConfig.state == .on {
            try? FileManager.default.removeItem(at: configURL)
            log.append("deleted config.env")
        }
        if purgeKeychain.state == .on {
            _ = run("/usr/bin/security",
                    ["delete-generic-password", "-s", "macrdp", "-a", NSUserName()])
            log.append("deleted the Keychain entry")
        }
        print("uninstall:\n" + log.map { "  - \($0)" }.joined(separator: "\n"))
        NSApp.terminate(nil)
    }

    @objc func editConfig() { ensureConfigExists(); NSWorkspace.shared.open(configURL) }
    @objc func openLogs() {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        NSWorkspace.shared.open(logURL)
    }
    @objc func openScreenRecording() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }
    @objc func openAccessibility() {
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }
    /// The controller's OWN login item, registered by `gui/make-tray-app.sh`.
    /// Separate from `plistURL`, which is the server agent's plist.
    var selfLabel: String { "\(Bundle.main.bundleIdentifier ?? "com.clintcan.macrdp.controller")" }
    var selfService: String { "gui/\(uid)/\(selfLabel)" }
    var selfPlistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(selfLabel).plist") }

    /// Quit = stop the server AND take the icon away.
    ///
    /// Two subtleties, both learned the hard way:
    /// 1. The login item runs with `KeepAlive`, so `NSApp.terminate` alone is
    ///    undone by launchd within a second — the icon would pop straight back.
    ///    Booting the job *out* is what actually makes it stay gone; the plist
    ///    is deliberately LEFT in place, so the next login brings the icon back
    ///    (that is what a per-user login item is for).
    /// 2. Stopping the server is a `bootout` of its agent, not a kill: the plist
    ///    stays, so "Start" (or the next login) brings it back without
    ///    reinstalling anything.
    /// The one implementation of "stop everything": the server agent and this
    /// controller's own login item. Shared by the menu item and `--stop-all`
    /// (scripted/MDM use, and the only way to exercise the path without a
    /// human clicking the menu).
    @discardableResult
    func stopEverything(terminate: Bool) -> (serverStopped: Bool, selfStopped: Bool) {
        let st = agentState()
        var serverStopped = false
        if st.pid != nil || st.loaded {
            serverStopped = run("/bin/launchctl", ["bootout", service]).code == 0 || st.pid == nil
        }
        var selfStopped = false
        if FileManager.default.fileExists(atPath: selfPlistURL.path) {
            selfStopped = run("/bin/launchctl", ["bootout", selfService]).code == 0
        }
        // Do NOT delete selfPlistURL: keeping it is what makes the icon return at
        // the next login. Removing it would be "uninstall", which has its own
        // menu item and its own confirmation.
        if terminate { NSApp.terminate(nil) }
        return (serverStopped, selfStopped)
    }

    @objc func quit() { _ = stopEverything(terminate: true) }

    /// Bring the icon back after a Quit (the login item is still on disk).
    @objc func showController() {
        if FileManager.default.fileExists(atPath: selfPlistURL.path) {
            _ = run("/bin/launchctl", ["bootstrap", domain, selfPlistURL.path])
            return
        }
        // No login item (removed, or never installed): just open the app.
        if let app = locateControllerApp() {
            NSWorkspace.shared.open(app)
        } else {
            alert(style: .warning, "Can't find macrdp Controller",
                  "Reinstall it with: APP_DIR=$HOME/Applications gui/make-tray-app.sh")
        }
    }

    /// The installed controller bundle, if we can find one.
    func locateControllerApp() -> URL? {
        var candidates: [URL] = []
        if let appPath = Bundle.main.bundlePath as String? {
            candidates.append(URL(fileURLWithPath: appPath))
        }
        for dir in [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            let app = dir.appendingPathComponent("macrdpController.app")
            if FileManager.default.fileExists(atPath: app.path) { candidates.append(app) }
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    // MARK: - config.env IO

    func readConfig() -> [String: String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            d[k] = v
        }
        return d
    }

    func writeConfig(key: String, value: String) {
        ensureConfigExists()
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        var found = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            if k == key { lines[i] = "\(key)=\(value)"; found = true; break }
        }
        if !found { lines.append("\(key)=\(value)") }
        // Always end with exactly one trailing newline — a config file with no
        // final newline makes a downstream append concatenate onto the last
        // key (which silently corrupted VD_HEIGHT + a new key once).
        let body = lines.joined(separator: "\n")
        let out = body.hasSuffix("\n") ? body : body + "\n"
        try? out.write(to: configURL, atomically: true, encoding: .utf8)
    }

    func ensureConfigExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) {
            let defaults = """
            BIND="127.0.0.1:3390"
            USE_KEYCHAIN=1
            ENABLE_H264=0
            ENABLE_AAC=0
            HIDPI=0
            UNMINIMIZE=0
            APP_SWITCHER_HUD=0
            ALT_TAB_SWITCH=0
            ENABLE_DRIVE_REDIRECTION=0
            ENABLE_SMARTCARD_REDIRECTION=0
            VIRTUAL_DISPLAY=0
            PRIMARY_MODE=none
            VD_WIDTH=1920
            VD_HEIGHT=1080
            EXTRA_FLAGS=""

            """
            try? defaults.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Process helper

    func run(_ path: String, _ args: [String], env: [String: String]? = nil)
        -> (code: Int32, stdout: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env = env, !env.isEmpty {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// Headless entry for scripted/MDM deploy + testing (no GUI, no status bar).
let cliArgs = CommandLine.arguments
if cliArgs.contains("--install-agent") || cliArgs.contains("--print-paths")
    || cliArgs.contains("--stop-all") || cliArgs.contains("--self-test") {
    exit(AppController().runHeadless(cliArgs))
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
