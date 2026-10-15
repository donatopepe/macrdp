# Operations runbook: install, permissions, upgrade, rollback, uninstall

Everything an operator has to do to a Mac running macrdp, in one place. It
exists because the pieces were scattered across `README.md`, `docs/cli.md`,
`docs/known-quirks.md` and the scripts, and because two of the steps have a trap
that only shows up later: the **code identity** (which is what macOS keys the
Screen Recording / Accessibility grants to) and the **two auto-start paths**
(which collide on `:3390`).

Paths used throughout (app-bundle install, the recommended one):

| What | Where |
|---|---|
| App bundle | `~/Applications/macrdp.app` (or `/Applications`, `APP_DIR=`) |
| LaunchAgent label | `com.clintcan.macrdp` (`gui/$UID/…`) |
| Feature toggles | `~/Library/Application Support/macrdp/config.env` |
| TLS cert/key | `~/Library/Application Support/macrdp/{cert,key}.pem` |
| Log | `~/Library/Logs/macrdp.log` (rotated, `macrdp.log.1` …) |
| Password | Keychain generic password, service `macrdp`, account `$(id -un)` |
| Loopback stats (opt-in) | `http://127.0.0.1:<port>` — the port is in the log line `stats endpoint listening` |

The bare-binary path (`dist/install.sh`) uses a different label and layout:
`com.user.macrdp`, binary in `~/.local/bin/macrdp`, plist in
`~/Library/LaunchAgents/com.user.macrdp.plist`.

## 1. Install

Three supported paths — pick one.

**a. App bundle, built locally (recommended on the machine you administer).**
This is the path with a stable signing identity, so TCC grants survive rebuilds:

```bash
APP_DIR="$HOME/Applications" packaging/make-app.sh   # build + sign + install the bundle
security add-generic-password -s macrdp -a "$(id -un)" -w 'YOUR_PASSWORD'
APP_DIR="$HOME/Applications" packaging/install-launchagent.sh
```

`make-app.sh` prefers the local self-signed `macrdp Local Code Signing`
certificate (creating it on first run) and falls back to ad-hoc signing with a
warning. **Ad-hoc is the thing to avoid on a machine you will rebuild**: it keys
the grants to the binary's cdhash, so every rebuild drops them and macOS starts
asking again.

**b. Published release (one line, no checkout).**

```bash
curl -fsSL https://raw.githubusercontent.com/donatopepe/macrdp/main/packaging/install-remote.sh | bash
MACRDP_VERSION=v0.9.61 curl -fsSL …/install-remote.sh | bash   # an exact release
```

It downloads the release archive, verifies the published SHA-256, installs
`macrdp.app` into `~/Applications` (atomically: staged, then swapped, old copy
removed) and never builds from source. It loads the LaunchAgent **only when run
from a checkout** (the script sits next to `install-launchagent.sh`); from a pipe
it prints the line to run instead. Published bundles are **ad-hoc signed by design** (no Developer ID
in CI), so Gatekeeper asks the first time: open via right-click → **Open**.

**c. Bare binary + launchd (`dist/install.sh`).** Lighter, no bundle, no
embedded smart-card handler or HUD/shield helpers.

> ⚠️ **Never install both a and c.** They both bind `:3390`; macrdp now refuses
> to start when it detects the conflict, but the loser can still be left
> crash-looping in `launchctl print`.

## 2. Permissions (TCC)

Grant, to `macrdp.app`:

- **Screen Recording** — required; without it the server exits 1 immediately.
- **Accessibility** — required for synthetic input (keystrokes, clicks, the
  `Ctrl+Alt+G` window gather).

Ask the binary instead of guessing:

```bash
~/Applications/macrdp.app/Contents/MacOS/macrdp --check-permissions
```

It prints the executable, the code identifier, the **designated requirement**
with a STABLE / AD-HOC verdict, and both permission states; it exits non-zero
when a permission is missing or the identity is ad-hoc. It opens no port,
captures nothing and raises no dialog, so it is safe to run any time — and it is
the right first answer to "why is macOS asking again?".

macOS keys the grants to the **code identity**, and the System Settings row is
named after that identity — not after the path. A `cdhash H"…"` requirement
means ad-hoc signing and a re-grant on every rebuild. Removing macrdp's rows from
System Settings does **not** revoke the grant on current macOS; use
`--check-permissions` rather than trusting the UI. (A launchd agent denied Screen
Recording crash-loops silently — `KeepAlive` respawns it every few seconds — and
attempting capture is itself what makes macOS notify, so the prompts can repeat
forever. `ensure_screen_recording_access()` runs before any capture and, under
launchd, exits 1 with an actionable message instead.)

## 3. Password / Keychain

The server authenticates clients against the Mac account password, read from the
Keychain when `USE_KEYCHAIN=1` (default) — the password itself never lives in
`config.env`.

```bash
security add-generic-password -s macrdp -a "$(id -un)" -w 'YOUR_PASSWORD'   # set / rotate
security find-generic-password -s macrdp -a "$(id -un)" >/dev/null && echo ok
security delete-generic-password -s macrdp -a "$(id -un)"                   # remove
```

The Controller's Settings window can also set it (and reports whether one
exists). Rotating the password only requires restarting the server
(`launchctl kickstart -k gui/$UID/com.clintcan.macrdp`); it does not change the
code identity, so no re-grant is involved.

## 4. Upgrade

**From the menu bar:** *Check for updates…* queries `releases/latest`, compares
versions numerically (so `0.9.10` > `0.9.9`), downloads the asset, **verifies its
SHA-256**, then replaces `~/Applications/macrdp.app` — **rolling back if the new
bundle does not verify**. It re-signs with the local certificate to keep the
identity stable and warns loudly when that was not possible (the one moment a
TCC re-grant is actually due). It updates the **server only**: the Controller is
not a release asset, so rebuild it from the repository
(`gui/make-tray-app.sh`).

**From a checkout:** build and install in place.

```bash
git pull
APP_DIR="$HOME/Applications" packaging/make-app.sh
launchctl kickstart -k gui/$UID/com.clintcan.macrdp
```

Replacing the bundle does **not** touch a running process: the server keeps
serving the old binary until it is restarted, which is a feature — you can stage
an update and let the next natural restart (reboot, or *Restart* in the menu)
pick it up. Check what is installed vs. running with
`cat ~/Applications/macrdp.app/Contents/Resources/build-revision` and
`pgrep -fl 'macrdp.app/Contents/MacOS/macrdp'`.

`config.env` and the Keychain entry are never modified by an upgrade.

## 5. Rollback

Install an older published release, or rebuild from the older commit:

```bash
MACRDP_VERSION=v0.9.61 curl -fsSL …/packaging/install-remote.sh | bash
git checkout v0.9.61 && APP_DIR="$HOME/Applications" packaging/make-app.sh
launchctl kickstart -k gui/$UID/com.clintcan.macrdp
```

Rollback is a bundle swap, so it is symmetric with upgrade: the same identity
rule applies (a published bundle is ad-hoc, so re-signing locally is what keeps
your grants). Nothing in `config.env` needs reverting unless the newer release
documented a key change — settings are read by name and unknown keys are
ignored.

**Never version-number your way into a downgrade by accident:** the binary's
reported version comes from `Cargo.toml`, so a build from `main` must carry a
version above the latest published tag, or the menu-bar update check will offer
to "update" you to an older artifact.

## 6. Uninstall

**From the menu bar:** *Uninstall…* — three buttons plus two unticked checkboxes
for `config.env` and the Keychain password; it reuses the script below.

**From the command line (app-bundle path):**

```bash
packaging/uninstall-launchagent.sh [--remove-app] [--purge-config] [--purge-keychain] [--yes]
```

It unloads the label, removes the plist (otherwise the agent is back at the next
login), and clears the recorded identity. **The app bundle is opt-out**
(`--remove-app`): it carries the code identity your TCC grants hang off, so
deleting it makes the next install a new identity and a new prompt. `config.env`
and the Keychain entry are kept unless you purge them.

**Bare-binary path:** `dist/uninstall.sh` (add `--keep-binary` to leave the
binary; `--purge-keychain` to remove the password).

To stop the server without uninstalling anything, use *Stop* in the menu or
`launchctl bootout gui/$UID/com.clintcan.macrdp`; *Quit* stops the server **and**
unloads the Controller's own login item (a `KeepAlive` respawn would otherwise
bring it back within a second).

## 7. Security posture

- **Never expose `:3390` on a public IP.** macrdp serves one console session of
  your Mac account; put it on a trusted LAN, a VPN (ZeroTier/WireGuard) or
  behind an RD Gateway. The *binary's* default bind is loopback, but the seeded
  `config.env` example uses `BIND="0.0.0.0:3390"` so LAN/VPN clients can reach
  it — check what your own file says before assuming either.
- TLS terminates in the server with a **self-signed certificate**, persistent per
  install (clients show a trust prompt the first time — that is expected).
  Operators can supply a real certificate with `--cert`/`--key` (or `TLS_CERT` /
  `TLS_KEY`); a missing or bad file is a hard error, never a silent self-sign.
- **Published release bundles are ad-hoc signed and not notarized.** Notarizing
  needs an Apple Developer ID and a notarization step; until then macOS asks for
  a right-click → Open on first launch.
- The audit log (`AUDIT_FILE`, plus the human-readable `macrdp.log` lines) records
  accept / auth / disconnect with source IP and reason; see
  [audit-log.md](audit-log.md) and [siem-forwarding.md](siem-forwarding.md).
  Credential material is never logged.

## 8. Recovering a black picture

If a client shows a black screen with a live cursor after a reconnect, **close
and reopen the whole RDP client window** — that is the only reliable cure, and it
is a measured conclusion, not a shrug: the server's in-place re-activation,
repeated re-activations, a never-before-used EGFX surface id and the
drop/auto-reconnect fallback were all tried against an affected client and none
of them healed it. See the README section of the same name and the H.264
reconnect-blank entry in [known-quirks.md](known-quirks.md). Note that the blank
arrives *on reconnect*, so restarting the server to "try again" is itself a way
to strand an open client.
