// MacRDPUpdateCore — the parts of the menu-bar controller that can be reasoned
// about without a GUI: version comparison, release-asset selection, checksum
// verification, and the inventory of config.env keys the UI is allowed to write.
//
// It exists as a separate library target for two reasons:
//
// 1. Testability. An *executable* target cannot be imported by a test target, so
//    anything living in `macrdptray` could only be tested by launching the app.
//    Foundation-only code in a library target is importable, and `swift test`
//    runs it here — with the Command Line Tools too, because there is no
//    SwiftUI or AppKit in this file.
// 2. One inventory. The list of keys the Settings window can write is exactly
//    the list the config-bridge tests on the Rust side must cover; keeping it
//    here (instead of as string literals scattered through SwiftUI views) is
//    what makes "every visible setting has a test" checkable rather than a
//    promise.
//
// Deliberately Foundation-only: no AppKit, no SwiftUI, no shelling out. I/O
// stays in the controller; this file only decides.
import Foundation

/// One key the Settings UI may write to config.env.
public struct ConfigKey: Hashable, Sendable {
    public let name: String
    /// Config keys whose user-facing meaning is the INVERSE of the flag they set.
    /// `ALLOW_SLEEP=1` means "do not hold the Mac awake" — the only one today,
    /// but the UI must not scatter that knowledge, so it is declared here.
    public let inverted: Bool

    public init(_ name: String, inverted: Bool = false) {
        self.name = name
        self.inverted = inverted
    }
}

/// Every config.env key the Settings window exposes, plus the ones the menu bar
/// writes outside the window (the sleep switch).
///
/// Keep in sync with:
///  - `docs/configuration.md` (the flag reference), and
///  - `config_tests` in `src/main.rs`, which asserts each one actually reaches
///    the server (a visible toggle that maps to nothing is the ALLOW_SLEEP
///    failure mode: it reads as configured and does nothing).
public enum ConfigKeys {
    public static let all: [ConfigKey] = [
        // Connection / network
        .init("BIND"),
        .init("USE_KEYCHAIN"),
        .init("VIRTUAL_DISPLAY"),
        .init("ENABLE_UDP_MULTITRANSPORT"),
        .init("UDP_MIGRATE_EGFX"),
        .init("STATS_ENDPOINT"),
        .init("KEYBOARD_LAYOUT"),
        // Video / audio
        .init("HIDPI"),
        .init("ENABLE_AAC"),
        .init("ENABLE_LOSSY_AUDIO"),
        .init("ADAPTIVE_BITRATE"),
        // Input
        .init("ALT_TAB_SWITCH"),
        .init("ALT_BACKTICK_SWITCH"),
        .init("APP_SWITCHER_HUD"),
        .init("MAP_CTRL_TO_CMD"),
        .init("UNMINIMIZE"),
        // Redirection
        .init("ENABLE_DRIVE_REDIRECTION"),
        .init("ENABLE_SMARTCARD_REDIRECTION"),
        .init("ENABLE_CAMERA_REDIRECTION"),
        .init("ENABLE_USB_REDIRECTION"),
        .init("USB_STREAM_STALL_MS"),
        .init("RESTORE_WINDOWS_ON_DISCONNECT"),
        // Host power — inverted: the UI shows "prevent sleep", the key says "allow".
        .init("ALLOW_SLEEP", inverted: true),
        // Escape hatch
        .init("EXTRA_FLAGS"),
    ]

    public static func key(_ name: String) -> ConfigKey? {
        all.first { $0.name == name }
    }

    public static var names: [String] { all.map(\.name) }

    /// The value to write for a user-facing choice. `true` is always "the user
    /// turned the toggle ON" as the UI presents it; inversion happens here and
    /// only here.
    public static func value(for key: ConfigKey, toggleOn: Bool) -> String {
        let on = key.inverted ? !toggleOn : toggleOn
        return on ? "1" : "0"
    }
}

/// Resolution of mutually-exclusive reliable RDPSND AAC and lossy-DVC audio modes.
/// Both carry AAC for mstsc, but advertise it on different transports: enabling
/// one disables the other; if a hand-edited config enables both, lossy wins.
public struct AudioMode: Equatable, Sendable {
    public let aac: Bool
    public let lossy: Bool

    public init(aac: Bool, lossy: Bool) {
        self.aac = aac
        self.lossy = lossy
    }

    public static func resolve(enabledKey: String, enabled: Bool,
                               aac: Bool, lossy: Bool) -> AudioMode {
        if enabled && enabledKey == "ENABLE_AAC" {
            return AudioMode(aac: true, lossy: false)
        }
        if enabled && enabledKey == "ENABLE_LOSSY_AUDIO" {
            return AudioMode(aac: false, lossy: true)
        }
        if !enabled && enabledKey == "ENABLE_AAC" {
            return AudioMode(aac: false, lossy: lossy)
        }
        if !enabled && enabledKey == "ENABLE_LOSSY_AUDIO" {
            return AudioMode(aac: aac, lossy: false)
        }
        return fromConfig(aac: aac, lossy: lossy)
    }

    /// Canonicalize persisted / hand-edited config: reliable RDPSND AAC is the
    /// safe fallback for a contradictory legacy config because the lossy UDP
    /// mode correlates with the repeated ~65s reset on this deployment's mstsc.
    public static func fromConfig(aac: Bool, lossy: Bool) -> AudioMode {
        aac ? AudioMode(aac: true, lossy: false) : AudioMode(aac: false, lossy: lossy)
    }
}

/// Version comparison for the updater. Numeric per component, so 0.9.10 beats
/// 0.9.9 — a plain string compare gets that backwards, and an updater that
/// offers a downgrade is how people learn to dismiss updaters.
public enum Version {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts: (String) -> [Int] = {
            $0.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(stripTagPrefix(candidate))
        let b = parts(stripTagPrefix(current))
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func stripTagPrefix(_ v: String) -> String {
        var s = Substring(v)
        while s.first == "v" || s.first == "V" { s = s.dropFirst() }
        return String(s)
    }
}

/// Pick one asset out of a release by suffix (e.g. "-app.zip", "SHA256SUMS").
public enum Assets {
    public static func url(in names: [String], endingWith suffix: String) -> String? {
        names.first { $0.hasSuffix(suffix) }
    }
}

/// Parse a `SHA256SUMS` line for a given file name. Returns nil when absent —
/// a missing entry is a failure, not a pass: silently skipping verification is
/// exactly how a tampered archive gets installed.
public enum Checksums {
    public static func expected(inManifest manifest: String, for fileName: String) -> String? {
        for line in manifest.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            // `shasum -b` writes "<hash> *<name>" with the asterisk glued to the
            // name; plain `shasum -a 256` uses two spaces. Accept both — a
            // manifest this parser cannot match reads as "no checksum", and a
            // missing checksum must never be mistaken for a passing one.
            let rawName = parts.last.map(String.init) ?? ""
            let name = rawName.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let hash = parts.first.map(String.init)
            if name == fileName { return hash }
        }
        return nil
    }
}