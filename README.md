# macrdp — Donato Pepe distribution

[![License](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue)](#license)

> **Derivative project / attribution**
>
> This repository is a personal derivative distribution of
> [macrdp](https://github.com/clintcan/macrdp), originally created and
> maintained by **Clint Christopher Canada**. It also uses
> [IronRDP](https://github.com/Devolutions/IronRDP), originally created and
> maintained by its upstream authors. Original copyright notices and license
> files are retained. This repository does not claim original ownership of
> upstream code; changes made here are documented below.
>
A native RDP server for macOS, written in Rust on top of [IronRDP]. Connect from `mstsc`, Microsoft Remote Desktop, or FreeRDP to drive your Mac desktop with keyboard, mouse, real-cursor-shape forwarding, text + image clipboard sync, Mac↔Windows file copy, **read-write drive redirection** (mount the client's drives in Finder), **smart-card redirection** (use the client's smart card from macOS apps), system audio forwarding, and optional H.264 video (EGFX/AVC420, hardware-encoded). NLA/CredSSP is supported. Authenticates against your local Mac account via PAM.

This is the macOS equivalent of `xrdp`. Not a client, not a VNC bridge.

## Derivative changes in this repository

This distribution adds or carries the following local changes on top of the
upstream project:

- Italian / Italian-Pro keyboard layout support for RDP clients, including
  server-side non-US layout translation.
- macOS F1–F12 forwarding without requiring the physical `Fn` key. Function
  events use an isolated CoreGraphics source and `SecondaryFn`, preventing F-key
  state from affecting later ordinary remote input.
- Stable local self-signed code-signing workflow for macOS app packaging:
  `packaging/create-local-signing-cert.sh` creates the certificate and private
  key in the user's login Keychain; `packaging/make-app.sh` uses it
  automatically.
- App-based LaunchAgent setup with stable bundle identity, Keychain-backed
  password startup, TCC permission guidance, and detailed input diagnostics.
- Debug logging for RDP keyboard events, scancode/keycode translation,
  modifier state, CoreGraphics flags, event source, and post confirmation.

These changes are local maintenance and integration work. They do not replace
upstream ownership or upstream license terms.

## Status and operational contract

This distribution targets one trusted interactive session on a Mac. It is intended for a LAN or a private VPN, not for public exposure, multi-user hosting, or enterprise workloads. The latest release is [v0.9.61](https://github.com/donatopepe/macrdp/releases/tag/v0.9.61) (upstream [clintcan/macrdp](https://github.com/clintcan/macrdp/releases) is at v0.9.7); local changes and live verification notes are tracked in the [release history](docs/release-history.md).

**Verified workflow:** TLS/NLA (CredSSP) against the Mac account, per-IP authentication throttling and audit logging, display/input including non-US layouts, bidirectional clipboard and file copy, system audio, optional drive and smart-card redirection, headless virtual displays, and optional hardware H.264/EGFX. The project also ships signed-app/LaunchAgent packaging and a health-check watchdog.

**Known limits:** one session and one user; no multi-monitor or printer redirection; macOS policy can black out DRM video and password-manager windows; synthetic input cannot reach login or secure fields; a reconnect into a still-running `mstsc` can leave a **black picture with a live cursor** — the server's in-place RDP re-activation heals that only sometimes (measured 2026-10-15: fresh surface ids, repeated re-activations and the reconnect drop all failed on an affected client); **closing and reopening the RDP client window fixes it every time**. See *If the RDP picture is black* below; opt-in UDP paths are newer than the TCP path; no enterprise SLA. Never expose RDP directly on a public IP—use a VPN or RD Gateway.

See the [production-readiness roadmap](docs/production-readiness-roadmap.md) for remaining gaps and verification evidence.

## Quick start

### One-line installer

Install the latest GitHub Release without cloning the repository:

```bash
curl -fsSL https://raw.githubusercontent.com/donatopepe/macrdp/main/packaging/install-remote.sh | bash
```

Install an exact release:

```bash
MACRDP_VERSION=v0.9.61 curl -fsSL https://raw.githubusercontent.com/donatopepe/macrdp/main/packaging/install-remote.sh | bash
```

The installer downloads the release's **app-bundle** archive, verifies it against
the published `SHA256SUMS` (refusing to install unverified unless you pass
`MACRDP_ALLOW_UNVERIFIED=1`), installs `macrdp.app` atomically into
`~/Applications`, and loads the LaunchAgent when run from a checkout. Grant
Screen Recording and Accessibility after installation. Note that a published
bundle is **ad-hoc signed**, so it is a different code identity from a locally
built one — see [docs/operations.md](docs/operations.md). Maintainers create
release assets with:

```bash
packaging/release-app.sh v0.9.62
```

It emits the same two files the workflow publishes —
`macrdp-<tag>-aarch64-apple-darwin-app.zip` and `SHA256SUMS` — and verifies its
own output by extracting the zip and running `codesign --verify --deep --strict`
plus `shasum -c` on it, so a hand-made artifact is one the installer accepts.

For a persistent macOS installation, use the automated app setup. It builds the
release binary, creates/imports the local signing identity if needed, signs the
app, installs the LaunchAgent, and keeps the private key in Keychain:

```bash
APP_DIR="$HOME/Applications" packaging/make-app.sh
security add-generic-password -s macrdp -a "$(id -un)" -w 'YOUR_PASSWORD'
APP_DIR="$HOME/Applications" packaging/install-launchagent.sh
```

Grant **Screen Recording** and **Accessibility** to `macrdp.app` in System
Settings → Privacy & Security, then restart the agent. The default local setup
listens on `127.0.0.1:3390`; set `BIND="0.0.0.0:3390"` in
`~/Library/Application Support/macrdp/config.env` for LAN/VPN access. The
included example already uses `0.0.0.0:3390`; restrict the bind address or use
a VPN when the Mac is not on a trusted network.

The local certificate is deliberately self-signed. It stabilizes this Mac's
code identity; it is not an Apple Developer ID, is not trusted by other Macs,
and cannot be notarized. For distribution, use an official Apple Developer ID
and notarization. To force ad-hoc signing instead:

```bash
AUTO_CREATE_LOCAL_CERT=0 CODESIGN_IDENTITY=- \
  APP_DIR="$HOME/Applications" packaging/make-app.sh
```

Manual CLI mode remains available:

```bash
cargo build --release
codesign -s - --force target/release/macrdp   # ad-hoc sign; local machine only
./target/release/macrdp
```

First run will prompt for:
1. **Screen Recording permission** (System Settings → Privacy & Security → Screen Recording → enable `macrdp` → restart it).
2. **Accessibility permission** (same path, "Accessibility" — required to forward keyboard and mouse).
3. Your Mac password at the terminal — validated against your local account via PAM `checkpw`, then used as the RDP credential.

Then connect from a client to `<your-mac-ip>:3390` with your Mac username and password. `mstsc` will prompt for credentials in its own NLA dialog — no need to pre-type the username.

Common flags to try next (full reference: [docs/configuration.md](docs/configuration.md)):

```bash
./macrdp --enable-h264                      # H.264 video — crisper AND lighter than the default bitmaps
./macrdp --enable-h264 --adaptive-bitrate   # + congestion-responsive rate control (recommended off-LAN)
./macrdp --bind 0.0.0.0:3390                # accept LAN connections (keep it OFF public IPs)
./macrdp --virtual-display --width 2560 --height 1440   # headless second desktop; local screen untouched
./macrdp --map-ctrl-to-cmd                  # Windows Ctrl+C/V/X muscle memory drives macOS copy/paste
```

## Hotkeys

macrdp reimplements the macOS symbolic hotkeys in user space (WindowServer won't fire them for forwarded events). On a **Windows client the Cmd key is the Windows key**, so press the Win-key equivalent:

| Keys (on the client) | Action |
|---|---|
| **Cmd+Tab** / **Cmd+Shift+Tab** | Cycle apps (forward / back); the app you land on is surfaced |
| **Cmd+\`** / **Cmd+Shift+\`** | Cycle windows of the current app |
| **Cmd+Space** | Spotlight |
| **Cmd+Shift+3 / 4 / 5** | Screenshots (full screen / region / Screenshot.app) |
| **Ctrl+Alt+G** | Gather windows stranded off the virtual display (headless `--capture-primary`/`--detach-primary` modes) |
| **Ctrl+Alt+Shift+R** | On-demand A/V resync — repaint a stale/idle-blanked screen (forced keyframe) and re-sync drifted audio, without disconnecting. Handy for mstsc after hours idle. |

Optional flags: `--alt-tab-switch` / `--alt-backtick-switch` accept **Option+Tab** / **Option+\`** as the same triggers; `--app-switcher-hud` draws a visible switcher overlay; `--map-ctrl-to-cmd` remaps Windows **Ctrl+C/V/X/…** editing shortcuts to their **Cmd** equivalents.

> **mstsc tip:** if **Cmd+Tab** seems ignored, set **Local Resources → Keyboard → "Apply Windows key combinations"** to **"On the remote computer"** (or go full-screen) — the windowed default eats **Win+Tab** locally as Task View.

## Diagnosing macOS permissions

If macOS keeps asking for Screen Recording, or input from RDP clients is silently dropped, ask the binary itself:

```bash
/Users/donato/Applications/macrdp.app/Contents/MacOS/macrdp --check-permissions
```

```
executable:           /Users/donato/Applications/macrdp.app/Contents/MacOS/macrdp
bundle:               yes (.app)
code identifier:      com.clintcan.macrdp
designated requirement: identifier "com.clintcan.macrdp" and certificate leaf = H"da9d…"
  -> STABLE across rebuilds (TCC grants survive)
Screen Recording:     granted
Accessibility:        granted
All good.
```

macOS keys the Screen Recording / Accessibility grants to the **code identity**, not to the project, and the System Settings row is named after that identity — so the useful question is never just "is the permission on?" but "which identity is macOS being asked about, and will it be the same one after the next rebuild?". `cdhash H"…"` in the requirement means ad-hoc signing, which is re-keyed on every build and is the usual cause of a re-prompt. The command exits non-zero when a permission is missing or the identity is ad-hoc, so it also works as a health probe. Both `packaging/make-app.sh` and `packaging/install-launchagent.sh` print the same requirement at build/install time and warn when it changes, since that is exactly when a re-grant becomes due.

### If the RDP picture is black (with a live cursor)

Close and reopen the **whole RDP client window** — not just the connection. That clears the client's retained
EGFX surface cache, which is where the problem lives.

macrdp cannot fix this from the server side, and that is a measured statement, not a shrug. On 2026-10-15, on a
client (Windows build 22621) that blanked from frame one on every reconnect, all of the server's levers were
tried against the same session and none of them healed it:

- creating the surface at a **never-before-used id** (in case the client was no-op'ing a re-used id) — the id
  really was fresh (`37888`, `37889`, `37890`), and every connection still blanked;
- the in-place **RDP re-activation** (the default first action) — it healed once that day (that session then ran
  106 minutes) and did nothing on the next four connections;
- **repeating** that re-activation three times before giving up — same, blank every time;
- the **drop + auto-reconnect** fallback — three drops in a row reconnected straight back into the blank.

The detector gives up after 3 such drops and says so in `~/Library/Logs/macrdp.log`
(`EGFX blank persisted across every auto-reconnect … fully close and reopen the RDP client window`). The blank
is a *reconnect* symptom, so anything that forces one — a network blip, an auto-reconnect, or a macrdp restart
— can land a still-open client in that state; restarting the server to "try again" therefore makes it worse, not
better. Full evidence: the H.264 reconnect-blank entry in [docs/known-quirks.md](docs/known-quirks.md).

## Auto-start at login (launchd)

```bash
dist/install.sh
```

Builds + signs + installs to `~/.local/bin/macrdp`, stores your Mac password in the macOS Keychain under service `macrdp`, drops a launchd plist at `~/Library/LaunchAgents/com.user.macrdp.plist`, and loads it. macrdp will start on every login and restart if it crashes. Re-run the script after `cargo build --release` to refresh the installed binary.

```bash
launchctl print gui/$UID/com.user.macrdp | head    # status
launchctl kickstart -k gui/$UID/com.user.macrdp    # restart
launchctl bootout gui/$UID/com.user.macrdp         # stop
dist/uninstall.sh                                  # remove agent + plist + binary
```

Two things to know about this path:

- **Signing identity matters.** The script signs with the local self-signed `macrdp Local Code Signing` certificate (created on first run) rather than ad-hoc, because macOS keys Screen Recording / Accessibility to the *code identity*: an ad-hoc signature is pinned to the binary's cdhash and is **revoked by every rebuild**. It also pins `--identifier macrdp` and prints the resulting designated requirement — `identifier … and certificate leaf = H"…"` is stable (grants survive rebuilds), `cdhash H"…"` is not. Override with `CODESIGN_IDENTITY=…` / `AUTO_CREATE_LOCAL_CERT=0` / `MACRDP_SIGN_ID=…`; forcing `-` keeps ad-hoc and prints a warning. When the identity changes, macOS drops the existing grants: re-grant both in System Settings → Privacy & Security, then `launchctl kickstart -k`. Until you do, the agent exits 1 and is respawned every few seconds — see [docs/known-quirks.md](docs/known-quirks.md).
- **The template passes no `--bind`, so the agent listens on `127.0.0.1` only** and LAN clients cannot reach it. To expose the server, add `--bind 0.0.0.0:3390` to `ProgramArguments` in the plist and `launchctl kickstart -k`.

> ⚠️ **Pick ONE auto-start path — they collide on `:3390`, and macrdp now refuses to start when it detects the conflict.** `dist/install.sh` (label `com.user.macrdp`, bare binary in `~/.local/bin`) and `packaging/install-launchagent.sh` (label `com.clintcan.macrdp`, signed `macrdp.app` + `--config config.env`) are **mutually exclusive**: whichever loads first takes the port, and the second crash-loops under `KeepAlive` with `Address already in use (os error 48)`. Starting the binary by hand on top of that is worse than a clean failure — macOS lets a flagless instance bind `127.0.0.1:3390` alongside `0.0.0.0:3390`, so it silently serves loopback clients with defaults (password prompt, legacy bitmaps, 15 fps, `config.env` ignored). Since v0.9.8 that case is refused at startup, with an actionable error naming both labels and the commands to fix it. Uninstall cleanly with `dist/uninstall.sh` (bare-binary path) or `packaging/uninstall-launchagent.sh` (signed app). Check with `lsof -nP -iTCP:3390 -sTCP:LISTEN` (expect **one** row) and `pgrep -fl macrdp`. Full symptoms and recovery commands: [docs/known-quirks.md](docs/known-quirks.md).

## Building the full app

> Day-to-day operations — install paths, permissions, password, upgrade, rollback, uninstall — are consolidated in **[docs/operations.md](docs/operations.md)**.

`dist/install.sh` installs a bare binary. For a proper **signed `macrdp.app`** — stable bundle identity (TCC grants survive rebuilds), background-agent behavior, the embedded smart-card IFD handler, optional notarization, the menu-bar controller app, and a distributable DMG:

```bash
packaging/make-app.sh                                 # build + sign + install to /Applications
security add-generic-password -s macrdp -a "$(id -un)" -w 'YOUR_PASSWORD'
packaging/install-launchagent.sh                      # load LaunchAgent (label com.clintcan.macrdp)
```

Feature toggles, bind address, and extra flags live in `~/Library/Application Support/macrdp/config.env` — outside the bundle, so edits never disturb the signature or TCC grants. The file is read **only** when the agent passes `--config <file>`: a bare `macrdp` ignores it and runs pure flag defaults (loopback bind, password prompt, legacy codecs), so run the agent (or pass `--config` yourself) rather than typing `macrdp` in a terminal. The full packaging guide (Developer-ID signing, notarization, the DMG, the controller app, icons, TCC notes): **[packaging/README.md](packaging/README.md)**.

## Release artifacts

Pushing a `v*` tag runs the [release workflow](.github/workflows/release.yml), which builds on an Apple-Silicon runner and attaches these to a draft GitHub Release (Apple Silicon / `aarch64-apple-darwin` only):

| File | What it is |
|------|------------|
| `macrdp-<ver>-aarch64-apple-darwin.tar.gz` | the **bare CLI binary** + `LICENSE`/`README` |
| `macrdp-<ver>-aarch64-apple-darwin-app.zip` | the full **`macrdp.app`**, with the embedded smart-card IFD handler + installer — the only artifact that carries everything `--enable-smartcard-redirection` needs |
| `SHA256SUMS` | checksums for both |

Both are **ad-hoc signed, not notarized** — open the app once via **right-click → Open** (or `xattr -dr com.apple.quarantine macrdp.app`). For a Developer-ID-signed + notarized build, or the menu-bar controller app (neither is produced in CI), build locally with [packaging/make-app.sh](packaging/README.md).

## Documentation

| Guide | What's in it |
|-------|--------------|
| **[Operations runbook](docs/operations.md)** | Install (three paths, and which to avoid mixing), the TCC grants and `--check-permissions`, the Keychain password, upgrade + rollback, uninstall and what each step keeps, the security posture, and what to do when the picture is black. |
| **[Configuration & CLI](docs/configuration.md)** | Every flag, the auth-hardening environment variables (rate-limit/lockout/audit), headless mode (`--virtual-display`, `--detach-primary`/`--capture-primary`), and a full set of example invocations. |
| **[Video](docs/video.md)** | The H.264/EGFX pipeline, Retina capture (`--hidpi`), client-resolution auto-adopt and letterboxing, bitrate/keyframe tuning, the mstsc reconnect-blank quirk and its in-place auto-recovery, and the vImage color-conversion benchmarks. |
| **[Audio](docs/audio.md)** | RDPSND PCM, opt-in AAC compression (`--enable-aac`), the self-healing capture stream, and mute-on-minimize. |
| **[File copy](docs/file-copy.md)** | Mac↔Windows clipboard file copy (files and folder trees), lazy vs eager paste, and the two Windows-side gotchas (Explorer folder-copy, archive shell extensions). |
| **[Drive redirection](docs/drive-redirection.md)** | Mounting the client's drives as read-write Finder volumes (`--enable-drive-redirection`) — how the in-process NFS bridge works and what to expect from permissions. |
| **[Camera redirection](docs/camera-extension-setup.md)** | Presenting the client's **webcam as a real macOS camera** (`--enable-camera-redirection`) — the one-time system-extension setup and activation, how the MS-RDPECAM → VideoToolbox → CoreMediaIO pipeline fits together, and the four CoreMediaIO failure modes that all fail *silently*. **For a webcam use this, not USB redirection** — it's the path mstsc feeds. |
| **[Smart-card redirection](docs/smart-card-redirection.md)** | Using the client's smart card from macOS apps (`--enable-smartcard-redirection`) — one-time IFD-handler install, the USB-trigger caveat, upgrade/reload notes, and why it's a user-space handler rather than USB passthrough. |
| **[Audit log & SIEM](docs/audit-log.md)** | The security audit events (accept / reject / auth / disconnect) — every field and how to interpret them — plus [forwarding the JSON stream](docs/siem-forwarding.md) to a SIEM/SOC collector (Vector / Fluent Bit / rsyslog) and a runnable [OpenSearch SIEM tutorial](docs/siem-tutorial.md) that detects an RDP brute-force end-to-end. |
| **[vs. other OSS RDP servers](docs/oss-rdp-server-comparison.md)** | Two parts. **Part 1** — the evidence behind every "first" claim in these docs, verified adversarially against FreeRDP/xrdp and re-checked in the source, including what macrdp is **not** first at and how to re-verify when upstreams move. **Part 2** — an honest head-to-head against the other native macOS RDP servers (`x6nux/macrdp`, `RDPonMAC`), written steelmanning theirs, including where they beat us. |
| **[Release history](docs/release-history.md)** | Per-release narrative of what shipped and what was live-verified. |
| [CLAUDE.md](CLAUDE.md) | Developer/agent reference — architecture, feature status, macOS gotchas, known quirks. |

## Why this was made

macrdp exists to provide a native macOS RDP server where the practical alternatives are limited. The project grew from a small proof of concept into a maintained daily-driver through protocol investigation, packet captures, and repeated interoperability testing with Windows Remote Desktop and FreeRDP.

It is intentionally focused: one reliable interactive session, clear macOS integration, and honest operational limits rather than enterprise feature breadth. Multi-monitor support remains future work.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at your option. Being permissively licensed, a productized/notarized build may be sold commercially with support — that's selling the product, not a license exemption.

[IronRDP]: https://github.com/Devolutions/IronRDP

## Attribution and licensing

This repository is a derivative work. See `LICENSE-MIT` and `LICENSE-APACHE`
for the retained upstream license terms and copyright notices. Upstream project:
[clintcan/macrdp](https://github.com/clintcan/macrdp). Local changes are
identified in **Derivative changes in this repository** above.

The Git history retains the upstream authors and commits; local commits should
identify Donato Pepe's changes rather than rewriting upstream authorship.
