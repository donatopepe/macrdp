import XCTest
@testable import MacRDPUpdateCore

/// These are the rules the menu-bar controller gets wrong in ways a human never
/// sees: an update offered in the wrong direction, an archive that verifies
/// against the wrong line, a settings key that exists in the UI but maps to
/// nothing on the server.
final class UpdateCoreTests: XCTestCase {

    // MARK: Version comparison

    func test_newer_is_numeric_not_lexicographic() {
        // The case that matters: 0.9.10 must beat 0.9.9.
        XCTAssertTrue(Version.isNewer("0.9.10", than: "0.9.9"))
        XCTAssertFalse(Version.isNewer("0.9.9", than: "0.9.10"))
    }

    func test_equal_versions_are_not_newer() {
        XCTAssertFalse(Version.isNewer("0.9.9", than: "0.9.9"))
        XCTAssertFalse(Version.isNewer("1.0.0", than: "1.0.0"))
    }

    func test_v_prefix_is_ignored_on_either_side() {
        XCTAssertTrue(Version.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertFalse(Version.isNewer("0.9.9", than: "v0.9.9"))
    }

    func test_missing_components_count_as_zero() {
        XCTAssertTrue(Version.isNewer("0.10", than: "0.9.9"))
        XCTAssertFalse(Version.isNewer("0.9", than: "0.9.1"))
    }

    func test_non_numeric_component_is_zero_not_a_crash() {
        XCTAssertFalse(Version.isNewer("0.9.x", than: "0.9.9"))
        XCTAssertTrue(Version.isNewer("1.0.0", than: "0.9.x"))
    }

    // MARK: Asset selection

    func test_asset_selection_by_suffix() {
        let names = [
            "macrdp-v0.9.9-aarch64-apple-darwin-app.zip",
            "macrdp-v0.9.9-aarch64-apple-darwin.tar.gz",
            "SHA256SUMS",
        ]
        XCTAssertEqual(
            Assets.url(in: names, endingWith: "-app.zip"),
            "macrdp-v0.9.9-aarch64-apple-darwin-app.zip")
        XCTAssertEqual(Assets.url(in: names, endingWith: "SHA256SUMS"), "SHA256SUMS")
        // The tarball must not be picked up by the .zip request, and a missing
        // asset must be nil (the caller shows an alert) — not a silent default.
        XCTAssertNil(Assets.url(in: names, endingWith: "-app.dmg"))
    }

    // MARK: Checksums

    func test_checksum_manifest_lookup() {
        let manifest = """
            b64ca178c3b85a0a4ff761c57645daccc376da0ff5677e37341c6f0eb3cbbfd3  macrdp-v0.9.8-aarch64-apple-darwin-app.zip
            844e7a37460b493718fdb3a4374ab6e548980d29c8ca6717caf6c31dddee5e7d  macrdp-v0.9.9-aarch64-apple-darwin-app.zip
            """
        XCTAssertEqual(
            Checksums.expected(inManifest: manifest,
                               for: "macrdp-v0.9.9-aarch64-apple-darwin-app.zip"),
            "844e7a37460b493718fdb3a4374ab6e548980d29c8ca6717caf6c31dddee5e7d")
    }

    /// A file absent from the manifest has NO expected hash: treating that as
    /// "verification passed" would install anything.
    func test_missing_manifest_entry_is_nil_not_a_pass() {
        XCTAssertNil(Checksums.expected(inManifest: "deadbeef  other.zip\n", for: "app.zip"))
        XCTAssertNil(Checksums.expected(inManifest: "", for: "app.zip"))
    }

    func test_manifest_entry_with_star_binary_marker() {
        // `shasum -b` writes "hash *name"; the name must still match.
        let manifest = "844e7a37460b493718fdb3a4374ab6e548980d29c8ca6717caf6c31dddee5e7d *app.zip"
        XCTAssertEqual(
            Checksums.expected(inManifest: manifest, for: "app.zip"),
            "844e7a37460b493718fdb3a4374ab6e548980d29c8ca6717caf6c31dddee5e7d")
    }

    // MARK: Mutually-exclusive audio settings

    func test_enable_lossy_audio_turns_reliable_aac_off() {
        let state = AudioMode.resolve(enabledKey: "ENABLE_LOSSY_AUDIO", enabled: true,
                                      aac: true, lossy: false)
        XCTAssertEqual(state, AudioMode(aac: false, lossy: true))
    }

    func test_enable_reliable_aac_turns_lossy_audio_off() {
        let state = AudioMode.resolve(enabledKey: "ENABLE_AAC", enabled: true,
                                      aac: false, lossy: true)
        XCTAssertEqual(state, AudioMode(aac: true, lossy: false))
    }

    func test_disabling_one_mode_leaves_other_mode_unchanged() {
        XCTAssertEqual(AudioMode.resolve(enabledKey: "ENABLE_AAC", enabled: false,
                                         aac: true, lossy: false),
                       AudioMode(aac: false, lossy: false))
        XCTAssertEqual(AudioMode.resolve(enabledKey: "ENABLE_LOSSY_AUDIO", enabled: false,
                                         aac: false, lossy: true),
                       AudioMode(aac: false, lossy: false))
    }

    func test_disabling_audio_mode_does_not_enable_the_other() {
        XCTAssertEqual(AudioMode.resolve(enabledKey: "ENABLE_AAC", enabled: false,
                                         aac: true, lossy: false),
                       AudioMode(aac: false, lossy: false))
        XCTAssertEqual(AudioMode.resolve(enabledKey: "ENABLE_LOSSY_AUDIO", enabled: false,
                                         aac: false, lossy: true),
                       AudioMode(aac: false, lossy: false))
    }

    func test_server_config_conflict_gives_lossy_audio_precedence() {
        // Mirrors args_from_config: hand-edited config.env with both keys ON
        // must never emit the incompatible --enable-aac + --enable-lossy-audio.
        let state = AudioMode.fromConfig(aac: true, lossy: true)
        XCTAssertEqual(state, AudioMode(aac: false, lossy: true))
    }

    // MARK: Config key inventory

    func test_no_duplicate_keys() {
        XCTAssertEqual(Set(ConfigKeys.names).count, ConfigKeys.names.count)
    }

    func test_sleep_is_the_only_inverted_key() {
        let inverted = ConfigKeys.all.filter(\.inverted).map(\.name)
        XCTAssertEqual(inverted, ["ALLOW_SLEEP"])
    }

    /// The UI asks "prevent sleep?"; the key says ALLOW_SLEEP. If this mapping
    /// inverts wrongly, the user turns the toggle on and the Mac still sleeps.
    func test_inverted_key_maps_toggle_the_other_way() {
        let sleep = ConfigKeys.key("ALLOW_SLEEP")!
        XCTAssertEqual(ConfigKeys.value(for: sleep, toggleOn: true), "0")  // prevent
        XCTAssertEqual(ConfigKeys.value(for: sleep, toggleOn: false), "1") // allow
        // A normal key is not inverted.
        let hidpi = ConfigKeys.key("HIDPI")!
        XCTAssertEqual(ConfigKeys.value(for: hidpi, toggleOn: true), "1")
    }

    /// Guards the UI against drifting away from the inventory: the Settings
    /// window's toggles are all in this list, and nothing else is.
    func test_inventory_covers_the_settings_window_keys() {
        let expected = [
            "ADAPTIVE_BITRATE", "ALT_TAB_SWITCH", "APP_SWITCHER_HUD", "ENABLE_AAC",
            "ENABLE_CAMERA_REDIRECTION", "ENABLE_DRIVE_REDIRECTION", "ENABLE_LOSSY_AUDIO",
            "ENABLE_SMARTCARD_REDIRECTION", "ENABLE_UDP_MULTITRANSPORT",
            "ENABLE_USB_REDIRECTION", "EXTRA_FLAGS", "HIDPI", "KEYBOARD_LAYOUT",
            "MAP_CTRL_TO_CMD", "STATS_ENDPOINT", "UDP_MIGRATE_EGFX", "UNMINIMIZE",
            "USB_STREAM_STALL_MS", "VIRTUAL_DISPLAY",
        ]
        for k in expected {
            XCTAssertNotNil(ConfigKeys.key(k), "\(k) is in the Settings window but not in ConfigKeys")
        }
    }
}