# TODO / work queue

## Distribution / one-line installer

- [x] **Published app archives + checksums are automated.** `.github/workflows/release.yml` builds the
      app (binary + `ifd-macrdp.bundle` + `macrdphud`/`macrdpshield`), `packaging/release-app.sh` tars
      `macrdp.app` with a `.sha256`, and the release carries the `…-app.zip`, the
      `…-aarch64-apple-darwin.tar.gz` and `SHA256SUMS` (checked on v0.9.61).
- [x] **The one-liner installer never builds from source.** `packaging/install-remote.sh` resolves
      `releases/latest` (or `MACRDP_VERSION`), downloads the app archive, verifies against published
      `SHA256SUMS` (or a per-asset `.sha256`), and only then extracts — no `cargo`, no fetched code execution.
- [x] **Published-release install mechanics verified on this Mac (2026-10-15); clean-first-run gates are not applicable to this already-configured account.** Isolated `/tmp` install passed download, SHA256SUMS verification, extraction, signature validation; ad-hoc cdhash behaved as expected. Existing stable app, TCC grants, Keychain entry and LaunchAgent were checked and preserved. Not performed: Gatekeeper click-through/TCC prompts, first LaunchAgent enrollment, or upgrade/rollback of the live app—these require a clean test account/Mac or explicit maintenance approval.
      The download → verify → install mechanics were first fixed on 2026-10-15 after rehearsal exposed that
      the installer chose the bare-binary archive and looked for a checksum file that releases do not ship.
      It now prefers `…-app.zip`, verifies `SHA256SUMS` (or per-asset `.sha256`), refuses unverified installs
      by default, and uses `ditto -x -k` to preserve the signature. The offline regression test is
      `scripts/test-install-remote.sh` (17 checks).
- [x] **One-place user documentation** — `docs/operations.md` (2026-10-15): the three install paths
      and why not to mix them, the TCC grants + `--check-permissions`, the Keychain password
      (set/rotate/remove), upgrade (what the menu verifies and that it updates the SERVER only) and
      rollback, uninstall with what each flag keeps, the security posture, and the black-picture cure.
      Verified against the scripts and the Controller's menu rather than restated from memory; wired
      into the README docs table and CLAUDE.md's map.
- **Published apps are ad-hoc signed by design** — no Developer ID / notarization in CI (documented in
  `release.yml`), so Gatekeeper prompts and the user opens via right-click → Open, and every published
  build has its own code identity (grants re-prompt after an *archive* install). Stability for *local*
  use comes from `packaging/make-app.sh` + the local signing certificate, which is this Mac's path.

## Done — the 2026-10-04 menu-bar controller plan (verified 2026-10-15)

Shipped in v0.9.10 and verified in the tree, so the plan is closed instead of left as a task list:
Quit stops the server AND unloads the login item (`launchctl bootout` in `macrdptray/main.swift`, so
`KeepAlive` cannot respawn it); `Check for updates…` against `releases/latest` with a numeric compare
and SHA-256 verification; `Uninstall…` reusing `packaging/uninstall-launchagent.sh`; the Sleep submenu;
the `Combine` warning fixed in `SettingsWindow.swift`; a Swift test target in `gui/Package.swift`
(`MacRDPUpdateCoreTests`, 18 XCTest cases) plus `swift test` running without SwiftUI; and
`scripts/test-config-keys.sh`, which round-trips the UI's config keys against the running server. The
update path warns when the designated requirement changes — the one moment a TCC re-grant is due.

## In flight — latest live findings (2026-10-14)

### Controlled reset diagnosis (recorded; safe configuration remains active)
- [x] **Confirmed operational fix / controlled same-client A/B (2026-10-15): reliable AAC on TCP; lossy-audio mode off.** Backup: `/tmp/macrdp-config-before-reset-ab-20261015-081151.env`; pre-change SHA-256 `196d89f1a97ae8956d8b36854cf2f387b03d2267f901d576cd975616e4f246dc`. Changed exactly two mutually-exclusive audio-mode keys (`ENABLE_LOSSY_AUDIO=1→0`, `ENABLE_AAC=0→1`); H.264, `BITRATE=10`, adaptive bitrate, `--fps 60`, host/client/network otherwise held. Restarted server PID 96512→99533. Runtime startup log confirms `enable_h264=true enable_aac=true enable_lossy_audio=false bitrate_mbps=10 enable_udp_multitransport=false udp_migrate_egfx=false adaptive_bitrate=true`. PC074FG / Windows 22621 authenticated at `2026-10-15T06:12:02Z`, AAC-LC 128 kbps negotiated and SCK audio started. At `08:42:54` it was still the same TCP connection (source port 56007), **1,852 s (>30 min)** after authentication, with zero disconnect records; telemetry showed 44,875 frames, 63,883 audio waves, queue=0, only 3 audio-buffer drops, 0 resyncs. The same PC previously reset repeatedly after 65.3–65.5 s in loss-only mode. This exceeds the previous >27-minute historic run and constitutes a strong matched A/B: switching off macrdp's lossy-audio/FECL mode fixes the observed reset for the user's session. Leave this safe mode active; original config backup is for rollback only, do NOT restore the lossy setting.

  **Status:** operationally resolved for this deployment; root protocol mechanism still unproven. Source inspection: `--enable-lossy-audio` does more than change audio codec: it enables RDPEMT, changes the server Initiate Multitransport request from reliable `UdpFecR` to lossy `UdpFecL`, and (only after FECL/DTLS tunnel + DVC prerequisites) migrates `AUDIO_PLAYBACK_LOSSY_DVC` Wave2 to UDP. RDPEMT listener comments document mstsc's own ~60 s dead-tunnel timeout can reset a session; observed client resets at ~65.3 s are consistent with—but do NOT prove—that sequence. Old lossy-mode logs used INFO and do not establish whether FECL SYN, DTLS, cookie-bound tunnel, Soft-Sync, or Wave2 occurred. Stable A/B means no risky lossy re-enable: leave reliable AAC ON + lossy OFF. If protocol root cause is pursued, design offline log/parser or test harness around those stages first; a live FECL trial requires explicit user approval. Reconnect-black-screen/QoE blank is separate and persists; don't conflate presentation failure with the transport reset.
- [x] Backup + SHA verified before the controlled restart; effective args verified after boot; restored neither file nor audio mode because the matched reliable-AAC session survived the criterion. Original backup remains available for deliberate rollback.
- [x] **Lossy RDPEMT/DTLS root mechanism remains undiagnosed; safe operational mitigation retained.** Archived reset runs lack listener debug/packet capture and do not prove whether FECL tunnel/DVC ever bound. Do not reproduce by restoring lossy on user configuration. Any future offline fix needs reliable repro/test harness or explicit user approval for controlled lossy session, with per-stage offer→SYN_LOSSY→DTLS→cookie bind→Soft-Sync→Wave2 evidence. Operational incident is solved by reliable AAC/TCP; distinct EGFX reconnect-black-screen remains open.



- [x] **Remote RDP session reset at ~65.4 seconds: operationally resolved with reliable AAC/TCP.** Same-client controlled A/B and the later >30-minute stable run are documented above. Root cause not proven; do not describe this as a diagnosed protocol defect or re-enable lossy audio on the live config without approval. Historical investigation details retained below.

  **Historical record (superseded; values below are NOT current):** earlier PC074FG / Windows 22621 runs showed repeated ~65.4 s resets while lossy audio was enabled; same-client reliable AAC/TCP A/B later ran >30 min without reset and operationally resolved the incident. Root protocol mechanism remains unproven. At the time, config used `ENABLE_LOSSY_AUDIO=1`, `ENABLE_AAC=0`; those values are stale. Retain detailed archived ports/timestamps below only as historical evidence; do not use old proposed experiment or claim current reset reproduction. Live config is reliable AAC with lossy audio off; do not restore lossy mode or restart the live server without explicit approval. The old protocol investigation continues below as archived history. Confirmed configuration flow from code: `ENABLE_LOSSY_AUDIO=1` emits `--enable-lossy-audio`; at startup that sets `MACRDP_UDP_OFFER_FECL=1`, and `MacMultitransport::requested_protocol()` therefore offers `UdpFecL` instead of `UdpFecR`. With H.264 enabled, successful UDP bind, DTLS, cookie bind, and DVC negotiation would Soft-Sync the lossy audio DVC onto that flow. **But those stages are not confirmed for the latest sessions:** reset-window logs show no UDP listener-bound, SYN_LOSSY/DTLS handshake, tunnel-bound, or audio Soft-Sync/Wave2 marker. `macrdp=info` normally hides the listener’s `debug!` datagram/handshake/route evidence; absence in retained INFO tail is NOT proof UDP was unused. Next non-disruptive app-side investigation: check listener bind / DTLS context errors in `macrdp.log`, UDP/TCP socket presence and any logged startup effective args. With permission for a later controlled session, temporarily set only `ironrdp_server::server=debug,ironrdp_server::multitransport=debug` (or targeted listener target), retain logs across one reset; trace each stage (offered FECL → client SYN_LOSSY → DTLS done → cookie-bound tunnel → audio DVC Soft-Sync → first Wave2). If current live default logger cannot provide a stage, add low-cost per-connection audit flags/counters rather than infer from reset timing. Do NOT toggle audio or restart current session without user authorization. If reliable AAC still resets, demote lossy-audio hypothesis and instrument server event scheduling / idle RDPSND channel; capture Windows RDP client and packet logs at reset. TCP peer reset wording alone does not assign blame.
- [ ] **Client/server interoperability residual: mstsc EGFX reconnect-black-screen (fresh repro on updated live app, 2026-10-16; root cause unknown).**

  **Evidence** (`~/Library/Logs/macrdp.log`, client PC074FG build 22621, 1710×1112):
  - Morning (05:58–06:10Z, `ENABLE_LOSSY_AUDIO=1`): 10 connections, each **blank from frame one** (`longest_render_run_before=0`, `window_zeros == window_reports`) *and* each killed by the client at 65.3–65.5 s — the transport reset and the presentation blank overlapped.
  - 06:12Z restart into reliable AAC: session 56007 **presented for 112.8 minutes with no blank warning** and ended cleanly; this client/build can render in a long session, while reconnects were observed blank in later tests.
  - 11:52–13:19Z, reconnecting into the **same mstsc process**: every connection blank. Attempt 1 (bare core reactivation) gave at most a brief paint (`best_render_run` 1–2) that relapsed; attempt 2 (drop + auto-reconnect cookie) did not heal; the storm guard tripped repeatedly. Fully close and reopen the RDP client window was the reliable operator recovery observed; it does not alone prove whether stale client state or a server/client interaction is causal.
  - **Every one of the 16 connections before the experiment logged `surface_id=0`** (the stock auto-allocator restarts at 0 per connection).

  **Surface-ID experiment (13:17–13:19Z, 0.9.62):** with `EGFX_FRESH_SURFACE_ID=1`, three connections used never-before-seen IDs (`37888`, `37889`, `37890`) and all still blanked (zero QoE render windows; reactivation → drop). This falsifies the simple retained-ID no-op as a complete explanation on this client; it does not establish another cause or what a fresh mstsc process will do. The experimental fork, flag, script and docs were reverted (`343fb3a`); stock surface IDs remain.

  **Root cause remains unknown.** The client reports decode without presentation in affected sessions; logs do not establish whether this is client-only or an interaction with server output/state. Tests so far show server recovery interventions did not reliably restore presentation on the affected reconnects.

  **Later evidence the same day — reactivation results were inconsistent (13:28–15:45Z).** After the config was restored and the agent restarted, the reconnect at 13:28:26 blanked twice (`13:28:30`, `13:28:34`) — the reactivation **healed it**, and that session then ran **106.7 minutes** with no further blank warning and ended `transport_error=none` (a silent end: client close or a path drop — no RST). 22 minutes later the client reconnected into the same process and every connection blanked again: `15:37:06` (8.5 s) and `15:37:25` (8.0 s) went reactivate → drop, and the current session (`15:37:44`) blanked at `15:37:48`, reactivated, then the storm guard tripped (`consecutive_blank_drops=3`) and **disarmed the detector for the connection** — so the screen stays black with nothing further attempted server-side. Same binary, same config, same client: recovery differed between reconnects. These observations do not isolate which client/server state or timing factor caused the difference.

  **Repeated-reactivation experiment (2026-10-15 16:08–16:10Z) — also negative.** A temporary knob (`BLANK_RECOVERY_REACTIVATE_ATTEMPTS=3`) made the first three attempts reactivate in place instead of escalating to the drop after one. On four consecutive connections the log shows `Reactivate attempt=1/4`,
  `2/4`, `3/4` at 4 s spacing and then `Drop attempt=4/4` — ~16 s sessions, every one still blank. So the escalation order alone did not account for the repeated failures: none of the tested server levers reliably restored those four sessions; restarting the client was the operational recovery observed. That knob is reverted too (`7e7d567`), so the shipped escalation is unchanged and only the measurements remain.

  **User-facing documentation done (2026-10-15):** README gains *If the RDP picture is black (with a live cursor)*, the storm-guard log line and observed operational recovery. It does not establish a client-only root cause.

  **Operational consequence:** blanks were observed on reconnect, including after server restarts; avoid repeated restarts as an experiment while the client remains open. In the 15:48 sequence three connections (`57712`, `60044`, `61122`) went reactivate → drop; a fourth (`61126`) blanked and the storm guard disarmed the detector. This association does not prove the restart caused the blank. See `docs/known-quirks.md`.

  **Updated live build evidence (2026-10-16):** after installing revision `c552fff` with the stable signing identity, PC074FG / Windows 22621 connected at `05:25:02Z`. It authenticated, advertised AVC support, and macrdp created/mapped surface 0 at 1710×1112; the ship thread sent IDRs (`frame_id=0`, `60`, …). QoE was zero across 10 windows by `05:25:06Z`; reactivation did not heal and drop followed at `05:25:10Z` (session 8.02 s). ARC reconnected at `05:25:20Z`; the second session blanked and dropped at `05:25:28Z`. Third connection at `05:25:38Z` blanked at `05:25:42Z`, then Reactivate→Drop at `05:25:46Z`. Same surface ID 0; config unchanged. **Revision caveat:** installed build was `c552fff`, not current `be3f9f7`; intervening commits are documentation only, while the Ready-state guard was already present. This confirms persistence on the installed code, but does not isolate cause or what wire PDUs the client received.

  **Recovery-dispatch defect found 2026-10-16:** the detector committed attempts/drop counters before capture admission. FPS, pipeline or UDP throttling could return before executing the locally queued recovery action. Thus `action=Reactivate/Drop` alone is not execution evidence; earlier claims of failed recovery must be checked against the action's execution marker. Fixed by leaving the ctx lock scope immediately when recovery is armed, before capture throttles, then executing outside the lock. This fixes lost recovery, not the initial presentation failure. The monitor-count regression fixture was also corrected to include the GFX header and assert the specific `monitor_count` rejection rather than accepting an unrelated decode error.

  **Next discriminating test (requires the Windows client):** confirm whether mstsc itself fully exited between the three 2026-10-16 auto-reconnects. Then fully exit the Windows mstsc process, reopen, and connect once to the still-running updated macrdp; record UTC time/build and whether video paints. If it still blanks, collect a bounded, approved `ironrdp_server::server=debug` trace to verify outbound ResetGraphics/CreateSurface/MapSurface and inbound frame ACK/QoE.

## Historical follow-ups (reviewed; current external gates above)
- [x] *(Folded into the client-dependent reconnect-blank item above.)* The v0.9.18 ask here was "gather evidence before touching the blank detector"; the 2026-10-15 tests found fresh surface IDs, reactivation, repetition and drop did not reliably restore presentation on the tested client. They did not isolate root cause, so no runtime change is justified without fresh-client/wire evidence. The keystroke-staleness half is covered by the flush-burst IDR work (`--flush-frames`) and the key-event IDR; re-open that separately if it recurs.

- [x] **Single adaptive FPS state machine, priority 60→30→bitrate ceiling→10.** The two overlapping gates shared a timestamp and could starve all video captures; replaced by one stage enum + one capture-side cadence gate, before encode, with a single timestamp written only for admitted frames. No VideoToolbox encoder is shared or mutated across threads. Pure policy tests cover stage selection, cadence for each stage, congestion escalation, slow recovery and prevention of early clear-sample recovery. Live test under a measured-over-capacity 6 Mbit ceiling: stayed connected 90 s, 60→30 once, one ceiling step 6→3 Mbit, then 30 fps / 3 Mbit stable; queue 8–45 ms, zero audio drops, no frame starvation. (An earlier run exposed 30↔10 transitions during intermittent congestion; removed the separate 10-FPS limiter, because the user's requirement is a single FPS policy and only one cadence gate.)

- [x] **Diagnostic detail + responsive control for keyboard echo / early disconnects.** Added aggregate input-handler timing from RDP callback entry through macOS event post (`input_events`, total/last/max, p50/p95/max, `input_over_10ms`); never logs keycodes or typed text. Added frame-drop reason counters (FPS, event queue, encoder pipeline, UDP lag), actual capture-submit cadence, adaptive controller effective knobs, INFO logs for congestion-state edges and every bitrate target adjustment, and bounded/sanitized disconnect `transport_error` reason. Lowered H.264 frames-in-flight default to 1 (shorter encode/decode queue). Adaptive controller now ticks at 200 ms, effective ceiling can step down every 200 ms after one congested interval, decrease factor defaults to 0.5, increase step 1/8 ceiling per 200 ms (five-second clear-at-bound ceiling climb remains intentionally conservative); tests updated for responsive half-step convergence. No client-payload/key contents in logs. Validation: 234 Rust + 18 Swift, fmt/clippy clean. Live measure with v0.9.20 and the next visible disconnect; don't raise bitrate target or relax congestion threshold without evidence.

- [x] **The stats endpoint's queue delay is stale (DONE — the payload carries the age).** `queue_delay_ms` is "last measured", so a reading taken while the screen was moving stayed at that value forever once capture stopped, reading like live congestion in the Status pane. `src/stats.rs` now publishes `queue_delay_age_ms` and the Controller labels a reading older than ~2 s ("<n> ms (last measured <k> s ago)", `LiveStats.queueAgeMs`). Deliberately **not** decayed: a client that stopped consuming leaves exactly that standing backlog, and it is the signal the blank-recovery detector reads (docs/release-history.md).


- [x] **Adaptive ceiling — implemented, down-only, floor at half --bitrate** (see the "measure before you change a live behaviour" rule in `docs/conventions.md`). Three versions were built and measured on this host before one was kept, and the two failures are the reason for the final design:
  1. *Symmetric AIMD on the ceiling* — failed: with an unreachable 6 Mbit operator ceiling it oscillated 6000k → 750k → 6000k → 5250k, 50 convergence events in 90 s. The reason is structural: "congestion cleared" cannot be distinguished from "the AIMD dropped the target and drained the pipe", so any climb rule guesses.
  2. *Climb gated on pushing the bound* — failed the same way (6000k ⇄ 750k), because the drain still looks like headroom.
  3. *Down-only, rate-limited, floor at half the operator maximum* — **keeps**: one step (6000k → 3000k), stays there for 120 s, queue delay 13–27 ms against the 101–180 ms of the original limit cycle, one log line instead of 50.

  So the ceiling is a **safety net for a badly-chosen `--bitrate`**, not a replacement for measuring one: `--bitrate 4` remains the measured answer for this link, and the net only engages when the ceiling is far above capacity. It never climbs within a session (the ceiling resets per connection and starts from `--bitrate` again), it never exceeds `--bitrate`, and it never drops below half of it, so a bursty link keeps detail instead of being walked to nothing. `--bitrate` stays what an operator means by it: the maximum.


  **Measured 2026-10-05 (ZeroTier link, ~24 ms RTT, YouTube playing) — this is the design input.** With a ceiling of 6 Mbit the link could not sustain it, and the controller entered a **limit cycle**: bitrate oscillating 6000k→1440k→2359k→3059k every few seconds, standing queue delay spiking to 101-180 ms, **89 IDR-backoff suppressions in one session (and exactly 89 recoveries)** — the backoff firing every control interval — plus `socket_write_stalls` 1237 and `audio_drops` 91 (video and audio share one socket, so the video saturations starved audio). Dropping the ceiling to **4 Mbit**, i.e. *inside* the achievable band, collapsed all of it in one change:

  | video playing | ceiling 6 Mbit | ceiling 4 Mbit |
  |---|---|---|
  | bitrate samples | 6000k, 6000k, 6000k, 6000k, 4200k, **2190k** | 4000k × 6 (stable, at ceiling) |
  | queue delay samples | 18, 13, 42, 17, **154**, 9 ms | 35, 4, 13, 42, 30, 14 ms |
  | IDR backoff (one session) | 89 suppress / 89 recover | **1 / 1** |
  | socket_write_stalls | 1237 | **50** |
  | audio_drops | 91 | **1** |
  | fps / RTT / CPU | 60 / 28 ms / 31 % | 60 / 24 ms / 30 % |

  So the ceiling has to converge toward the *measured* capacity, or the AIMD will keep hunting: a ceiling above capacity is not "more headroom", it is a limit cycle whose side effects (starved keyframes, starved audio) are worse than a lower ceiling. Wanted: a slow, hysteretic adaptation of the ceiling itself from the standing queue delay, seeded from the same baseline numbers used here. **Deliberately not done yet** — the video path destabilised for 40 min from a much smaller change the same day (see the UDP-multitransport entry in docs/known-quirks.md), so this wants its own branch and tests.
- [x] **Client graphics-update PDUs are decoded and ignored — closed with evidence, not implemented.** The vendored acceptor answers Input / Shutdown / SuppressOutput / RefreshRectangle and logs everything else as `warn!("Unexpected share data pdu")`; client graphics updates arrive raw inside `ShareDataPdu::Update(Vec<u8>)` and this ironrdp version does not model them, so a client RefreshRect / Set Keyframe / FutureFrames request gets no answer. **It stays unimplemented, deliberately.** (a) Measured: with `ironrdp_server::server=warn` visible across the sessions that mattered, ZERO such lines and zero unexpected share-control types — no observed client behaviour depends on it, so the "the client asks for a keyframe and we ignore it" theory is dead. (b) The project's own first convention is that ironrdp is the only crate that touches RDP wire format and that parallel parsing is not allowed; hand-writing a graphics-update parser in the vendored acceptor would violate that to serve a case nothing demonstrates. If it ever becomes real evidence, the fix belongs upstream in ironrdp-pdu, not here.

- [x] **White screen after an automatic reconnect — closed as a documented limit.** For clients that cache the EGFX surface across sessions the server creates and maps a fresh `surface_id` every connection and the client re-presents on its stale one; the server's own log says so ("it re-lands on its stale surface every time. Fully close and reopen the RDP client window"). Both server-side levers were measured and both are worse: the bare reactivation cannot invalidate the client's cache (it heals in place but the client stays blank), and forcing a new surface (`BLANK_RECOVERY_REACTIVATE=0`) turns every attempt into an immediate drop — a 4-second accept/drop loop. A third option, DeleteSurface or DVC close, is client-fatal by long-standing evidence. So the operator guidance stands: close the whole RDP window, not just the connection. Exposure is already much lower now that the drops that *triggered* the auto-reconnects are gone (UDP multitransport) and the pipe is no longer starved of keyframes.


## Archived follow-up notes

- [x] **Historical PR review notes from 2026-09-17 — stale; current PR state not inferred from these notes.**
  - **Vendored divergence numbering (revised 2026-09-17):** #182 is held for the pin bump and will never
    land its divergence, so only two claimants remain: **#183 keeps (24)** and the **mic divergence takes
    (25)**. If that changes, take the next free number on `main` at merge time.
  - **#183** `fix(input): held modifiers on mouse events + Ctrl+click→Cmd+click` — round 3 (`01e86a8`,
    verified against head `334cc3c75`, CI green) addressed all three follow-ups: the reset is now raised
    once per SERVED connection via a new vendored handle (**divergence (24)**,
    `RdpServer::set_input_reset_handle`, raised at the top of `run_connection`/`serve_negotiated`, not
    `on_accept`); the latch and `remapped_keys` clear unconditionally on reconnect; held buttons are
    released on reconnect, and the idle gap clears modifiers only. Remaining asks: (1) the synthetic
    button-up is posted at the **pre-disconnect** cursor position on the new connection's first input
    (a keystroke counts), so an interrupted Finder drag completes as a drop there — possibly into a folder
    or onto the Trash. His reason for posting it is sound (otherwise macOS stays mid-drag and the next click
    sends a second press with no release) — document the trade-off and live-test a real file drag;
    (2) `01e86a8` adds no tests for the connection-edge path (suite still 208).
  - **#182** `fix(ironrdp-server): bound accept_finalize` — mechanism sound (the bound is on the inner
    call; verified). Asked (https://github.com/clintcan/macrdp/pull/182#issuecomment-5646629705) for a
    **per-step (no-progress) deadline** instead of a 30 s total budget — cheap, since
    `ironrdp_async::single_sequence_step` and `Acceptor::get_result` are already public — with a
    ship-now fallback (raise the default + `MACRDP_FINALIZE_TIMEOUT_SECS`).
    **DISPOSITION 2026-09-17 — HOLD for the pin bump; don't reshape it, don't land the vendored form**
    (https://github.com/clintcan/macrdp/pull/182#issuecomment-5722493925). The identical 30 s bound is
    already upstream in **Devolutions/IronRDP#1890** (merged 2026-09-04, by @antonmos, same const, same
    inner `accept_finalize` call), so the bump HARVESTS it and the divergence never has to exist. Exposure
    until then is mild: macrdp preempts unconditionally and eviction isn't gated on the incumbent having
    activated, so a finalize-wedged client is displaced by the next authenticated connection — a parked
    slot, not a lockout. His log data also settled the "is 30 s too tight?" worry (the 12.55 s-CredSSP
    cellular link's finalize was 0.53 s; finalize doesn't inherit CredSSP's round-trip cost). **Left OPEN
    on purpose** — the PR holds the regression test and the wedge diagnosis, and doubles as the bump
    reminder. **At the bump:** confirm upstream's bound arrives via the pin, and pick his
    `a_client_that_wedges_during_finalize_is_dropped` test back up.
  - **#184** (Ctrl+, → Cmd+,) is **stacked on #183** — it contains #183's commits plus its own `2f61a34`.
    Review after #183 merges. **#181** (`--lock-on-disconnect`) — not reviewed yet.
  - Related: issue **#186** — `run_connection`'s `accept_begin`/TLS/CredSSP are unbounded pre-auth
    awaits, the serving-path half that #182 doesn't cover.

- [x] **SIEM/SOC audit forwarding — Tier 0 (structured JSON audit stream) — SHIPPED (v0.8.33);
  `event="auth"` (div18) + `event="fingerprint"` which-client (PR #163, 2026-07-18, merged, awaits
  next release) added since.** macrdp's `macrdp::audit`
  events (connection accept/reject/disconnect, source IP+port, reason, outcome) are
  additionally written as **one JSON object per line** to a dedicated self-rotating file
  (`--audit-file` / `AUDIT_FILE` / `MACRDP_AUDIT_JSON=1`) for a log collector (Vector /
  Fluent Bit / rsyslog / Splunk UF) to tail → SIEM. macrdp deliberately does **not** speak
  network syslog (the collector owns TLS/buffering; macOS has no `syslogd` — unified logging
  replaced it). **Opt-in, default OFF, byte-identical when off.** Two tracing layers: the
  audit JSON layer's `Targets` filter is **RUST_LOG-independent** (a quiet operational filter
  can't suppress security events); main layer keeps `EnvFilter`. Schema v1 (`AUDIT_SCHEMA_VERSION`
  const, versioned contract; (src_ip,src_port) correlation, conn_id deferred additive). 170
  tests pass incl. a new RUST_LOG-independence test; clippy/fmt clean; **end-to-end `nc` smoke
  produced a correlated accept+disconnect JSON pair.** Files: Cargo.toml (json feat),
  src/{logging,auth_guard,main}.rs, packaging/config.env.example, docs/{cli,configuration}.md,
  NEW docs/siem-forwarding.md (schema + collector configs). Tiers 1 (collector configs) shipped
  as docs; **Tier 2 (native RFC5424/CEF-over-TLS emitter) deferred** — only if a deployment
  can't run a collector. Follow-on (additive, no schema bump): promote cert-expiry /
  health-bounce / active-redirection-features / session-start onto `macrdp::audit`. Plan:
  `~/.claude/plans/tier0-siem-audit-json.md`; [[project_siem_audit_json_tier0]].

- [x] **Tier 2.4 — historical 31-hour soak; old 48–72 h follow-up superseded by subsequent soak/live evidence.** The last leg of the production-readiness trio (TLS ✓ #104, auth ✓
  #105). Historical tooling: `scripts/soak-monitor.sh monitor` samples a resource CSV; `… analyze`
  summarizes. **2026-07-01 run (31 h / 1861 samples, pre-v0.8.22 / pre-ARC build; data recovered
  on a clean re-copy after a first transfer zero-filled):** CLEAN — **no memory leak** (RSS
  bounded 18–88 MB, tracks activity, ended lower than start), no fd/thread/SCStream/NFS/log
  growth, **single process throughout**, **0 panics** (the 55 `Connection error`s are normal
  per-connection client-drop/probe signatures). **v0.8.21 auth-guard fix FIELD-VALIDATED:** the
  17 lockouts of a legit LAN client (escalating to ~239 s) are all **pre-fix** (06-30 + 07-01
  02:xx, before the 18:39 build swap — the false-lockout that *surfaced* v0.8.21, and the "took
  a few tries while I was out" incident); the **post-fix soak window had ZERO lockouts** + 14
  balanced accept/disconnect pairs. **Historical coverage limitation:** (a) 31 h was below the original 48–72 h target; (b)
  predates v0.8.22 and did not exercise the blank-recovery detector, ARC cookie or health watchdog. A 48–72 h soak was once proposed, but this dated plan is not a current run order; refresh it against the current build before scheduling one. Logging fixes for that proposed run **DONE 2026-07-03 (#124):** the soak logger syncs after every CSV append, and multitransport/audio-DVC status lines are demoted WARN→DEBUG. See `docs/production-readiness-roadmap.md` Tier 2.4.

## Deferred — scoped, not started

- [ ] **Microphone / audio-input redirection (MS-RDPEAI, the `AUDIO_INPUT` DVC) — present the CLIENT's mic as a macOS input device.**
  Scoped 2026-07-27, prompted by the A4Tech FHD webcam (`09da:2692`) having a built-in mic:
  none of the three existing channels can carry it — **USB redirection** can't (USB audio streams over
  **isochronous** endpoints; macrdp's URBDRC path is bulk+interrupt only — the isoch gap; this cam's
  *video* only works because it's an unusual **bulk** UVC device), **camera redirection (MS-RDPECAM)**
  is **video-only**, and macrdp's audio today is **output-only** (RDPSND, Mac→client; `src/audio.rs`).
  The RDP-native answer is **MS-RDPEAI** — a **separate** DVC that captures the client's *default
  recording device at the OS audio layer* (so it sidesteps isoch-USB entirely: the client OS already
  drives the webcam mic and just forwards PCM). Together with camera redirection (video, shipped v0.9.0)
  this gives a **full remote webcam + mic**; they're independent channels. **Goal:** with
  `--enable-microphone-redirection` (opt-in, default OFF, byte-identical when off), the connecting
  client redirects its mic and **"macrdp Microphone"** appears as a real macOS *input* device that
  QuickTime / Zoom / Voice Memos / dictation can record from.
  - **Historical protocol sketch (requires spec verification before implementation).** A server-direction audio-input DVC is proposed over DRDYNVC, with macrdp as receiver of client microphone data. The message names (`MSG_SNDIN_*`) below were copied from xrdp's implementation; confirm against the current MS-RDPEAI specification and client behavior before relying on this handshake or PDU ordering. **Upstream status changed:** IronRDP merged its `ironrdp-audin` protocol crate (#1645, 2026-08-12) and server integration (#1946, 2026-09-22). This local tree remains pinned at a5d1c682, so these APIs are not yet available here. Re-audit the merged upstream API during the planned pin migration; do not create parallel PDU/factory plumbing before then. macOS virtual-input device/feed remains new work. Confirm the actual MS-RDPEAI spec and client direction/order against upstream code before implementing. Start with **PCM** only after that validation.
  - **macOS side (the hard, novel part — a virtual INPUT device).** There is **no self-serviceable CoreMediaIO
    equivalent for audio**, so the camera playbook does NOT copy 1:1. Two routes: **(A) `AudioServerPlugIn`**
    — a userspace Core Audio HAL plug-in (`.driver` bundle in `/Library/Audio/Plug-Ins/HAL/`, loaded by
    `coreaudiod`), **needs NO entitlement** but installs into a system dir (one privileged admin step — the
    same install pattern as the `ifd-handler`); reference impl is **BlackHole (GPL)** → write from scratch
    MIT/Apache like the IFD handler. **(B) `AudioDriverKit` System Extension** — modern, ships in the
    controller `.app` and activates like the camera extension, BUT needs the **restricted DriverKit
    entitlement** (Apple-granted, not self-serviceable — heavier than the camera's CMIO entitlement).
    **Recommend route A** (no entitlement; deployment cost is a privileged install, not an Apple grant).
    macrdp feeds received PCM into the plug-in via a **shared-memory ring** (the audio analogue of the CMIO
    sink stream), with **clock/drift handling** — the client mic clock vs the Mac audio clock will drift, so
    resample like `audio.rs` already does 48→44.1 (`rubato`), plus a small jitter buffer (RDPEAI over TCP).
  - **Phasing (mirror the camera feature):** **P0** — the `AUDIO_INPUT` handshake behind the flag, inert:
    negotiate + log the client streaming its mic, drop the audio (proves mstsc/FreeRDP will hand macrdp a mic;
    the camera Phase-0 gate is the template). **P1** — accept the Data PDUs, produce a PCM stream, dump to
    WAV under `MACRDP_MIC_DUMP=1` (like `MACRDP_CAMERA_DUMP`) to verify content. **P2** — the `AudioServerPlugIn`
    virtual mic + the shared-memory feed → present "macrdp Microphone". **P3** — format/clock robustness,
    disconnect cleanup, silence/mute handling.
  - **Module placement:** new `src/audio_input/` (`mod.rs` = the `AUDIO_INPUT` DVC backend + factory/policy,
    `feed.rs` = the shared-memory producer into the HAL plug-in), mirroring `src/camera/`. The plug-in bundle:
    `gui/Sources/macrdpmic` (an `AudioServerPlugIn` `.driver`) + a `packaging/make-audio-plugin.sh` +
    `install-audio-plugin.sh` (privileged, like `install-ifd-handler.sh`).
  - **Client + verification (unverified plan):** determine current FreeRDP microphone-redirection option/channel direction and current mstsc policy/UI first. Then test whether either client opens the proposed server-side DVC and sends audio; do not assume `/microphone` or the cited mstsc menu path is accurate without a version-specific run.
  - **Effort:** comparable to the camera feature (medium–large: new protocol channel + new macOS virtual
    device + install/signing). The **`AudioServerPlugIn` + shared-memory feed + clock-drift** piece is the
    novel/risky part; do not assume the protocol is merely RDPSND in reverse until checked against the current specification. **Biggest unknowns to resolve
    first:** verify MS-RDPEAI protocol direction, then confirm mstsc/FreeRDP stream microphone data to macrdp (P0 GO/NO-GO),
    and that a from-scratch `AudioServerPlugIn` fed from an external process works without licensing the
    BlackHole source. Natural next capability after the camera work — a full webcam **and** mic remote setup.

- [x] **Camera redirection Phases 1–3 — SHIPPED in v0.9.0 (2026-07-20). The client's webcam IS a macOS camera.**
  Phase 0 protocol gate is LANDED + LIVE-VERIFIED GREEN (v0.8.39-era, f2d54e5: vendored server
  divergence (19) `rdcamera.rs` + `camera_factory` seam + `src/camera/MacCamera` +
  `--enable-camera-redirection`; real mstsc SelectVersion v2 → DEVICE_ADDED over MS-RDPECAM —
  proving a modern mstsc/Win11 hands us the webcam over the RDCamera DVC, the channel USB
  redirection can't reach). **Remaining = the real presentation work, ~multi-week:** (1) open the
  per-device stream channel; (2) media-type negotiation (the client offers H.264/MJPEG/uncompressed
  formats); (3) VideoToolbox H.264 decode of the incoming samples; (4) surface it as a macOS
  camera via a **CoreMediaIO Camera Extension** (self-serviceable entitlement; VT-decoded frames
  → CMIO). This is the standout next capability — gives mstsc webcam support the raw-USB path
  can't (mstsc refuses macrdp's bulk-video reads with 0x8007001f and routes real video over
  MS-RDPECAM instead). **Phase 1 DONE — LIVE-VERIFIED GREEN 2026-07-20** (on branch
  `feat/camera-redirection-phase1`, not yet merged to main): real mstsc streamed a redirected
  A4Tech webcam as **H.264 1080p over plain TCP DRDYNVC** (350+ frames, steady ~20 fps,
  ~18 KB/frame) — the full MS-RDPECAM server state machine (enumerate → open the client-named
  per-device channel → ActivateDevice → StreamList → media-type negotiation picking H.264 →
  StartStreams → the SampleRequest↔SampleResponse pull loop), mirroring FreeRDP's `rdpecam`
  server + the URBDRC per-device model (divergence 16). **GO/NO-GO answered GREEN: samples flow
  over TCP, so UDP (Phase 4) is NOT a prerequisite.** First known OSS RDP *server* to receive a
  webcam over MS-RDPECAM. **Phase 2 DONE — LIVE-VERIFIED GREEN 2026-07-20** (same branch):
  VideoToolbox decodes the webcam end-to-end — 500+ frames, zero errors, real color
  `CVPixelBuffer` at 1080p (the decoded grayscale-Y dump is the user's real camera view;
  color CVPixelBuffer, luma-only PNG). Both technical unknowns now GREEN (protocol over TCP +
  VT decode). **Phase 3 COMPLETE — LIVE-VERIFIED GREEN 2026-07-20**: a client webcam redirected over MS-RDPECAM now
  presents as a **live macOS camera** (Photo Booth, ~30 fps, zero dropped frames) via a hand-assembled
  (no-Xcode) CoreMediaIO Camera system extension — 3a activation + 3b sink feed + 3c 420v format, all green.
  As far as is known the first OSS RDP *server* to present a client-redirected webcam as a native OS camera.
  **Four silent CMIO failure modes were found and are documented in `docs/camera-extension-setup.md` — read
  it before touching this**: bundle filename must == bundle id; `signingID` is literally "unknown" (so sink
  producer auth is impossible and a rejecting hook surfaces as a bogus `-4`); `kCMIOStreamPropertyDirection`
  is INVERTED (pick the sink by NAME — starting the wrong stream returns SUCCESS and silently never drains);
  and macOS won't replace a same-CFBundleVersion extension (monotonic build number now). Extension `os_log`
  needs `sudo` to read. Remaining follow-ups (non-blocking): env-gate the Phase-2 $TMPDIR dumps; a controller
  "disable camera" menu item. **RELEASED as v0.9.0** (tag `efbe3d0`, published latest — the first minor bump since the 0.8 series began). Decode diagnostics are now opt-in behind `MACRDP_CAMERA_DUMP=1`; `--enable-camera-redirection` is documented in `docs/cli.md`. **Release gotcha worth remembering: the first tag failed CI** because a helper used from cross-platform code was `#[cfg(target_os = "macos")]` — a macOS-green clippy/test run cannot catch a Linux-stub break (no local Linux C toolchain). **Phase 4** (UDP migration) still scoped + deferred, low priority. Full plan +
  the live-debugged wire lessons: `~/.claude/plans/camera-redirection-phase1.md` +
  `docs/rdp-camera-redirection-feasibility.md` + [[project_camera_redirection_feasibility]].

- [x] **FreeRDP audio smoothness — server-side render-latency estimator — DROPPED 2026-07-20
  (built + tested, no perceptible benefit).** From the 2026-07-18 audio research: FreeRDP sends
  TWO WaveConfirms per wave and the server can measure the client play-out depth from them (mstsc
  sends one, so it can't). Phase 1 (observe-only harness, vendored `ironrdp-rdpsnd` fork) was GREEN
  — the signal tracked a 6%-loss stress link (depth 0.3ms→380ms, ship→play 4ms→15.5s) and proved
  the send-side drop-stale model MISSES a backlog living in the kernel socket buffer. Phase 2 (act:
  drop a wave when measured depth > threshold) was built + live-tested on Thincast + the shaper and
  **fired once the whole run** (the client's own buffering keeps the smoothed depth under threshold
  for the common PCM/self-managing case) and **sounded identical** to the no-drop run. Only
  FreeRDP-with-AAC has real value (its client overrun-dropper exempts AAC) — narrow, untested, not
  what's run here (mstsc can't use it). Not worth a vendored fork + hot-path divergence for zero
  audible benefit. **Branch + fork DELETED; main untouched (git pin intact).** The RESEARCH is the
  durable win and is retained (docs/known-quirks.md "Why mstsc audio is mostly smooth" +
  [[project_waveconfirm_not_playback_position]] + [[project_av_choppiness_contention]]).
  **Don't re-attempt without a specific "FreeRDP-AAC choppy under loss" complaint; even then
  `/sound:latency:<ms>` (client-side, zero divergence) is the first try.** Plan FINAL OUTCOME:
  `~/.claude/plans/freerdp-render-latency-estimator.md`.

- [~] **Perf: eliminate the per-capture full-frame `last_frame` memcpy — ASSESSED 2026-07-07,
  DEPRIORITIZED (don't re-propose as a win).** From the 2026-07-03 audit's one HIGH finding:
  `capture.rs` copies the whole BGRA frame into the flush-burst stash on every EGFX-accepted
  capture (~8 MB @1080p / ~24 MB @HiDPI × 60 fps ≈ 1.4 GB/s), read only when SCK goes idle.
  Fix shape (retain the SCK `CVPixelBuffer`, release the prior, re-lock during the flush burst)
  is FEASIBLE and refcount-correct — confirmed `CMSampleBuffer.image_buffer()` returns an
  independent retained ref (screencapturekit 2.1 Swift shim `Unmanaged.passRetained`),
  `CVPixelBuffer` is `Send+Sync` with `lock()`/`Drop`. **But the risk/reward doesn't justify it:**
  (1) reward is marginal — 1.4 GB/s is <1% of Apple-Silicon bandwidth; it removes ~200 µs
  (1080p) to ~600 µs (HiDPI) of capture-thread memcpy/frame (~1–4% of the 60 fps budget), and
  the capture thread isn't the bottleneck; (2) its sibling (CVPixelBufferPool for encoder input,
  [[project_cvpixelbufferpool_no_win_reverted]]) A/B'd at PARITY and was reverted — same
  fill-bound path, likely the same result here; (3) real risk — holding the retained buffer pins
  one IOSurface from SCK's recycle pool (macrdp doesn't set `queueDepth`, Apple default 3), the
  "blank after N frames" starvation class, mitigable only by a `queueDepth` bump (+~24 MB/slot);
  (4) it's a video hot-path (`next_update`) change, which project guidance says not to touch
  without a verified payoff. Revisit only if a HiDPI-under-contention smoothness problem is
  actually observed and traced to this copy. **Do NOT re-list as a "clean win."**
- [x] **Rolling latency percentiles + opt-in CPU sampling** — implemented in `stats.rs` and
  vendored diagnostics. CPU sampler runs every 2 s only with `STATS_ENDPOINT=1`; p50/p95/max
  windows cover capture age, encode/ship latency, socket wait, audio queue age, and audio write wait.
  Deployment is validated; values remain zero only when no RDP client is connected.
- [x] **Audio reservation fairness on SharedWriter** — fresh audio now raises a reservation
  flag before waiting; new non-audio writes yield until the audio wave is admitted. Existing
  in-progress writes remain non-preemptible, H.264 ordering is unchanged, and telemetry remains
  opt-in. This bounds new video/control overtaking of queued audio but is not full batching.
- [x] **Adjacent EGFX event coalescing** — consecutive `ServerEvent::Egfx` batches now merge
  their ordered DVC message vectors before socket dispatch. No cross-channel reorder, no
  post-encode frame drop, H.264 frame order preserved. Full write coalescing remains upstream-sensitive.
- [x] **Telemetry-only pre-encode event-queue backpressure** — when `STATS_ENDPOINT=1` and
  `server_event_queue` reaches `MACRDP_EVENT_QUEUE_HIGH` (default 512), captures drop before
  VideoToolbox submission. H.264 reference ordering remains valid; disabled path is unchanged.
- [x] **Bounded unified-event dispatch turns** — dispatch keeps a bounded FIFO batch but emits
  one event per scheduler turn, preserving FIFO/H.264 order while returning to `select!` between
  socket writes. Fresh audio/control tasks get scheduling opportunities even during backlog.
- [x] **VideoToolbox timestamp ownership** — `submitted_at` is reclaimed on pixel-buffer creation
  failure and rejected encode submission; accepted frames transfer ownership to callback.
- [x] **Bounded display write coalescing** — display fragments now coalesce into max 64 KiB
  ordered writes, flushing between chunks so audio fairness remains effective. H.264 EGFX
  event ordering is untouched; oversized fragments bypass coalescing. Full EGFX write batching
  remains upstream-sensitive.
- [x] **Outbound scheduler core** — added/tested owner-friendly typed queues, bounded bytes,
  urgent audio/control priority, weighted data fairness, FIFO EGFX behavior, bounded same-class
  coalescing, pre-framing audio admission/drop telemetry, typed queue snapshots, and local
  enqueue/reject/sent packet+byte counters in `vendor/macrdp-server/src/outbound.rs`. Coalescing
  preserves complete-buffer byte order and caps each owner write at explicit 64 KiB; typed snapshots are
  available for opt-in telemetry, and scheduler is not wired to live socket yet.
- [~] **Live socket-owner adapter** — blocked safely at design boundary: current
  `FramedWrite::write_all` is not cancellation-safe and can duplicate partial frames on retry.
  Added isolated `OutboundOwner` complete-buffer handoff, bounded same-class coalescing,
  shutdown-drain, bounded ingress backpressure, finite ingress-batch fairness, pending-buffer
  drain-state (tested), explicit run-until-drained helper, ingress-batch budget, observable/exhausted/reset urgent budget, writer-error, partial-write, all-class typed ingress, ingress counters/snapshot accessors,
  owner scheduler snapshots with ingress counters, direct queue-depth accessors, and queue-depth test,
  per-class packet/byte occupancy and class snapshots, packet budget/capacity probes, typed audio result helpers and owner alias,
  opt-in outbound queue JSON gauges (reserved fields) and cumulative counter fields, pre-framing upper-bound admission,
  audio-admission debug guard, and fake-writer tests; it awaits each write
  exactly once and never retries a failed/partially
  written buffer. Scheduler remains
  isolated from live `client_loop`;
  wiring still requires a controlled producer handoff and shutdown test before changing the active
  path. Owner now also exposes a typed status snapshot, zero-value status constructor, pure lifecycle transition helper, bounded `pump_ingress` and single-buffer `pump_one_ingress` adapters, spawnable `OutboundOwnerSession` receiver/owner bundle with `from_writer` and `into_parts`, complete-packet `write_packet` boundary, typed producer byte ingress API, explicit `run_until_shutdown` owner loop, opt-in diagnostic owner wrapper with writer boundary, handoff status snapshot, scheduler queue/sent gauge publication, and explicit diagnostic status publication with fake coverage; integration harness covers concurrent all-six typed producer handoff, drain, EGFX FIFO, same-class buffering, oversized admission, typed byte routing/close, explicit shutdown ingress drain, lifecycle reconnect/preemption transitions, single-buffer ingress close boundary, and complete-packet write boundary. Runtime remains `SharedWriter` until adapter migration; next step is one live producer adapter, not owner activation. Next live cutover must own `WriteHalf` outside client-loop `select!`, with explicit ingress-close/error propagation and reconnect rollback. Owner spawn task is now independently cancellable only through explicit shutdown handle.
  SharedWriter labels audio socket-write timing separately without changing ownership; owner now
  exposes writer construction, typed ingress-writer handoff, `with_ingress` setup, and explicit
  shutdown/drain signaling tests for a future controlled handoff, but live wiring remains blocked. The cutover boundary is now a single `client_loop` owner task; no producer may retain a `FramedWrite` or `WriteHalf` after activation.
- [x] **Performance review — stale 2026-06-28/29 opportunities rechecked against current tree.** Bounded SharedWriter batching and adjacent EGFX/display-write coalescing are already implemented (commits `0c83d56`, `c9a5457`, `b97a1cf`; capped writes preserve ordering/fairness). Legacy bitmap scratch-buffer/`spawn_blocking` optimization remains unmeasured legacy-client-only work; do not add without profiling. RDPEUDP allocation, NFS pagination and idle-tick changes remain explicitly not worth pursuing.
- [x] **Adaptive congestion control — implemented baseline; optional research separated below.** Historical rollout notes: **P1 (adaptive bitrate)
  SHIPPED as #94; P2a (IDR backoff + ack-lag signal switch) SHIPPED 2026-06-29;
  P3 (controller runs on the TCP path too) SHIPPED 2026-06-29** (verified on real mstsc:
  with `--bitrate 8` on a pure-TCP session, clean connect via the cold-start guard, gentle
  8M↔5.6M sawtooth backoff/recovery under 5% TCP drop — see the feasibility doc "P3" note;
  ack-lag on TCP is a real but spiky/lower-amplitude signal, tuned via a ¾·max_frame_lag
  threshold). **EWMA smoothing + hysteresis + 3-zone hold SHIPPED 2026-06-29** (verified
  mstsc: per-spike sawtooth → one gentle step-and-recover per episode; A/V more in sync,
  catch-up speed-up cut, "video sometimes stops" gone — see feasibility doc). **P2b
  frame-rate floor SHIPPED 2026-06-29 (#102, verified mstsc):** once bitrate is pinned at
  the floor AND still congested, cap the effective fps (drop captures within `1/floor-fps`,
  default 10 fps, never zero) to shed packet load — on BOTH transports (the only fps lever
  on TCP). Pure `frame_drop_at_floor`; `MACRDP_ADAPTIVE_FLOOR_FPS` tunable. Live log
  confirmed: bitrate AIMD → 750k floor under rising ack-lag → P2b caps to ~10 fps
  (choppy-but-steady, in sync) → recovers to the 6M ceiling + full fps when loss clears.
  **Current architecture:** bitrate, capture-FPS and UDP IDR pacing use per-frame ack-derived standing queue delay, ack lag/no-ack distress and retransmit evidence. The 2026-06-28 queue-depth freeze report predates the current multi-signal controller; raw queue depth was also elevated on healthy links. Do not add a queue-depth threshold without a fresh Windows baseline.

  **Optional future research (not a bug fix):** transport-level RDPEUDP feedback (CN, ACK-vector loss, RTT/window) or SCReAM/Copa/BBR-lite; requires API/wire-signal review and real mstsc loss testing. Do not assume datagram ACKs are exposed to the app or that a controller removes reliable-transport HOL blocking. Keep implementation unchanged unless measurements show AIMD insufficient. See finding #5 in `docs/rdp-udp-multitransport-feasibility.md`; refs SCReAM RFC 8298, NADA RFC 8698.

- [x] **A/V offset EWMA + drift telemetry** — source audio/video PTS feed `av_offset_ewma_ms`,
  `av_offset_ewma_samples`, `av_drift_ppm`, and `av_drift_samples`; playback is untouched. A
  telemetry-only drift hysteresis classifier now uses 80/40 ms and 500/250 ppm enter/exit
  deadbands with a 3-sample hold; it exposes stable/ahead/behind zone state and accepted-sample
  count without correction.
  Unit tests cover offset and ppm holds, deadband exit, and pathological-value clamping.
  Correction policy still waits for scheduler integration and more live drift data. Live session currently shows offset
  around -27 ms; no correction is applied automatically.
- [ ] **A/V desync under packet loss** (user-reported 2026-06-29, after P3). Audio drifts
  from video under drops, most apparent on the TCP path. Root constraint: **RDP has no A/V
  sync primitive** (RDPSND + EGFX are independent channels, no shared clock/PTS) → true
  lip-sync is impossible, only *reduce* drift. The P3 adaptive video catches up (speeds/
  slows) while fixed-rate audio can't, which makes the drift visible. Two partial levers,
  two levers: **A** — EWMA/hysteresis smoothing of the video controller (**DONE
  2026-06-29**, shipped with the rate-control EWMA work above; user confirmed "audio more
  in sync" + less catch-up speed-up); **B** (remaining) — tighten the audio-lag resync
  (vendored `dispatch_audio`, ~300 ms threshold tuned for resize-freezes, not slow drift)
  to keep audio live, at the cost of choppier audio. Lever A substantially improved it;
  B only if the residual drift/skips still bother in daily use. A bounded queue primitive
  `AudioWaveReceiver::drop_oldest_until_below` is now invoked only after projected audio backlog
  crosses 260 ms, trimming toward 200 ms; AAC duration metadata is honored. This is hysteretic
  stale-audio resync, not playback-clock correction; PTS drift EWMA remains telemetry-only and
  AAC priming/packet-loss validation remains open. Opt-in stats now expose current/maximum source
  A/V offset, producer-to-dispatch AudioWave queue wait, and emitted AU/byte counters alongside
  resync action/drop counters plus maximum projected backlog, with JSON serialization tests; current binary shows
  queue wait fields only after the next controlled app update; debug logs include queue
  duration before/after trim.
  Detail:
  `project_av_sync_under_drops` memory.
- [x] **EGFX-over-UDP watchdog follow-up — lag-based no-progress trigger already exists.** The current adaptive controller records ack advancement time and uses shipped-minus-acked lag/no-ack distress for bitrate/FPS backoff; the watchdog's transport migration remains gated on fully silent ACKs. This is intentional fail-safe separation, not an unimplemented promised trigger. Revisit only with a fresh soak showing harmful delay from waiting for ack silence.
- [x] **UDP multitransport — TCP-session-end → listener peer-evict signal** (the deferred half of M3c; the *correct* fix for dead-peer reclaim). **Shipped 2026-10-15.** The shared tunnel-bound flag was already lowered by the server when it retires a connection's tunnel (session teardown) or when tunnel-death detection declares it dead; the peer then sat in `peers`/`bound_addrs` until the 60 s idle GC, i.e. up to a minute of the reliability SM still RTO-retransmitting into a tunnel the server had stopped routing to, with its cookie still reserved. `check_dead_tunnels` now returns the addresses it retired/dead-declared and the new `evict_retired_peers` drops them (peer + cookie mapping, flag re-lowered defensively) on the same retransmit tick; the idle GC stays as the long pure backstop (it covers a peer nothing ever retired). Idempotent + unit-tested (6 tests: retired evicted with its binding, live bound peer untouched, wedge declared dead AND evicted, unbound untouched, GC backstop, eviction idempotent). **Also in this change:** the vendored crate now builds its own tests (`[lib] test = true`, upstream ships `test = false`) and CI runs them standalone (`--features multitransport --lib`, 67 tests) — flipping the flag caught two rotted tests that had never been compiled or run (a `DiagnosticsHandle` initializer missing the four input→output latency windows, and a test that hung because it never dropped the writer half). See `vendor/macrdp-server/CLAUDE.md` "M3c retire-on-session-end".

- [x] **UDP multitransport Phase 2 — lossy `UdpFecL` + DTLS + 1+1 redundancy** (FEC dropped).
  **Lossy AUDIO is DONE + verified.** Phase 1 (reliable EGFX-over-UDP) shipped (v0.8.15,
  clean-link only). Phase 2 loss resilience for *audio* is now shipped and soaked: lossy
  RDPEUDP delivery (deliver-on-arrival, no retransmit) + DTLS-over-lossy + the dual-channel
  topology (MS-RDPEA format handshake on the reliable `AUDIO_PLAYBACK_DVC` over TCP; AAC
  Wave2 data Soft-Synced onto the lossy `AUDIO_PLAYBACK_LOSSY_DVC`) + **1+1 duplicate-send**
  (each datagram sent twice; client DTLS anti-replay dedups → p→p² loss). **Soak-verified on
  real mstsc 2026-06-29:** dup=0 glitches at 5% loss; dup=1 stays smooth at 5/10/15% (trace
  jitter only at 15%). Promoted from the four expert env gates to the single
  **`--enable-lossy-audio`** flag (#101). Back-to-back duplicates were enough — the
  documented staggered-duplicate hardening was NOT needed (deferred unless a future burst
  case defeats 1+1). Remaining Phase-2 piece is *video* over the lossy tunnel (the known
  HOL-block ceiling — separate, lower value); see the lossy-video deferral and the
  watchdog-timeout follow-up above.
- [x] ~~**Reed-Solomon FEC** (RDPEUDP v1 `UDPFECL`)~~ — **CLOSED, structural NO-GO.**
  FEC is a dead/legacy feature across the *whole* RDP ecosystem, not just a macrdp gap
  (2026-06-28 industry survey): the only stack that ever shipped FEC is Microsoft's
  RDP-8.x/RemoteFX-over-UDP server (v1 lossy); **Microsoft removed FEC in RDPEUDP2** and
  modern Windows (RDP 10+, AVD Shortpath) negotiates RDPUDP2 → retransmit-only, **never
  FEC** (confirmed by our own zero-FEC capture). FreeRDP deliberately skipped it
  (RDPUDP2-only). So **no current client would decode macrdp-emitted FEC** — building the
  encoder is pointless. The 1+1 redundancy stand-in (above) is the only loss-resilience
  lever reachable for a modern client. Would only reopen with legacy-Windows-8.x test
  machines, which isn't a realistic target. See the "Industry status" + "P2.3 FEC capture
  RESULT" notes in `docs/rdp-udp-multitransport-feasibility.md` + `vendor/ironrdp-rdpeudp/CLAUDE.md`.

- [x] **Generic USB redirection — current implemented scope verified; remaining items are separate features/client limitation.** FreeRDP mass-storage drive mounts and read/write verified; mstsc enumerates/configures devices and negotiates camera format, but its camera video frames use a separate camera-redirection channel not implemented here. Isochronous/interrupt endpoints and retract/multi-device remain future scope, not a regression blocker.
  **Verified implementation scope:** mstsc enumerates/configures USB devices and negotiates camera format; FreeRDP mass storage mounts and supports read/write. Fixes include per-device channel handshake, interface-0/function-id routing, full configuration descriptors, and Windows-compatible typed URBs. Webcam video requires mstsc's separate "Video capture devices" channel; isochronous/interrupt endpoints and retract/multi-device support remain unimplemented. mstsc RemoteFX excludes mass storage (handled through Drives/RDPDR). Detail: [[project_usb_redirection_feasibility]].
  Path: user-space virtual USB host controller via `IOUSBHostControllerInterface` (a **public,
  headered** IOUSBHost.framework API — NOT private SPI as first assumed; its doc says it
  "create[s] synthetic USB devices"). Entitlement `com.apple.developer.usb.host-controller-
  interface` **GRANTED** to QGLA89KHM7 (FB23363880). All on branch `feat/usb-redirect-spike`.
  - **Phase 1 GO** (2026-07-01, `--usb-spike`): entitled signed+provisioned build creates the
    controller and the kernel begins the command exchange → the route works.
  - **Phase 2 GO** (2026-07-06, commit `ab91a63`): `usb_spike.m` drives the full UserHCI
    command/doorbell loop and a **hardcoded synthetic device enumerates LIVE in `ioreg`**
    (VID 0x1209/PID 0x0001, full EP0 GET_DESCRIPTOR flow, clean teardown) — the whole macOS
    presenting path proven.
  - **Phase 3.0 GO** (2026-07-06, commit `3a435c9`): URBDRC server-direction DVC observe-only
    spike GREEN — `--enable-usb-redirection` advertises URBDRC + runs the MS-RDPEUSB capability
    exchange; **verified locally with a plain `cargo build`** (observe-only never touches the
    UserHCI controller, so no entitled build needed) via `sdl-freerdp /usb:auto` → channel
    opens (Create status 0) + caps exchange completes (S_OK). No `AddDevice` only because this
    Mac has no attachable USB device to redirect. Vendored ironrdp-server **divergence 16**
    (`src/rdpeusb.rs`, `UrbdrcServer` + `UrbdrcServerFactory`); `ironrdp-rdpeusb` added as a
    git dep (PDU-only, pinned rev).
  - **Phase 3.1a GO** (2026-07-06, commit `38a360f`): the server opens a **per-device DVC** on
    the client's `ADD_VIRTUAL_CHANNEL` (via `ServerEvent::Urbdrc(OpenDeviceChannel)` → the
    `client_loop` dispatch arm → `DrdynvcServer::create_channel(UrbdrcDeviceProcessor)`), which
    sends `RIMCALL_RELEASE` on the new channel so the client sends `ADD_DEVICE` with the real
    descriptors. **Verified live** with a USB-3 flash drive (full handshake → per-device channel
    → `ADD_DEVICE` = GO, session stays up). Both `process()` impls now **tolerate decode errors**
    (never tear down the session) — the pinned `ironrdp-rdpeusb` `SupportedUsbVer` enum stops at
    USB 2.0 and rejects the SSD's USB-3.2 `0x320` caps; adversarially code-reviewed clean.
  - **Phase 3.1b(1) GO** (2026-07-06, commit `357624f`): the client's `ADD_DEVICE` now **fully
    parses** (real descriptors, `usb_version=Usb32`), not just header-recognized. **Vendored
    `ironrdp-rdpeusb`** (leaf crate → clean one-sided path-dep; `ironrdp-str` pinned via
    `[patch.crates-io]`) with a **lenient `UsbDeviceCaps` decode**: `SupportedUsbVer`/`UsbdiVer`/
    `UsbBusIfaceVer`/`DeviceSpeed` are data-carrying enums with the named values + an `Other(u32)`
    fallback (named `Usb30/31/32` added), so a modern USB-3 device's `0x320` caps parse instead of
    erroring. Verified live with a USB-3.2 flash drive. New vendored crate divergence. **NOTE: the
    upstream form (#1418) was reshaped to newtype-over-`u32` + consts at CBenoit's request — so at
    pin-bump this vendored `Other(u32)` shape is REPLACED and call sites shift
    `SupportedUsbVer::Usb32`→`::USB_32`; see the Upstreaming-watch #1418 entry.**
  - **Phase 3.1b(2a) GO** (2026-07-06, commit `5ef8e4b`): a server-initiated **`GET_DESCRIPTOR`
    control transfer round-trips REAL device data** — proven observe-only (plain `cargo build`).
    On `ADD_DEVICE` the device processor reactively sends `RegisterRequestCallback` +
    `TransferInRequest(GetDescriptorFromDevice)` and decodes the `URB_COMPLETION`. Verified live:
    `hresult=0x0 descriptor_len=18 vid=0x2174 pid=0x2100` — the flash drive's real VID/PID read
    from the physical device. macOS libusb kernel-detach was not a blocker after unmount. This
    de-risks the whole transfer path.
  - **Phase 3.1b(2b) part 1 GO** (2026-07-06, commit `e79fa85`): the transfer path is now a
    reusable **async `UsbHandle`/`UsbRouter`** seam (the RdpdrHandle pattern: 31-bit req-id router +
    `ServerEvent::Urbdrc(SendMessages)` DVC-framed dispatch + `DeviceDescriptor::parse`), and
    `UrbdrcDeviceProcessor::process()` shrank to decode-and-route. The descriptor fetch is driven
    through the handle. Verified live: `vid=0x2174 pid=0x2100 usb_version=0x0320`. (Elegance
    refactor of the 2a spike.)
  - **Phase 3.1b(2b) part 2-i GO** (2026-07-06, commit `c464df0`): **device-callback seam** — the
    vendored server exposes the `UsbHandle` via `UrbdrcServerFactory::device_callback()`; the
    per-device processor invokes it on `ADD_DEVICE`, and the transfer **driver moved into macrdp**
    (`src/usb_redirect/mod.rs::drive_device`). `UrbdrcDeviceProcessor::process()` is now purely
    decode-and-route. Verified live: macrdp's driver fetched `vid=0x2174 pid=0x2100`. (Elegance +
    the exact hook the UserHCI integration needs.)
  - **Phase 3.1b(2b) part 2-ii GO ✅✅ — the Phase-3.1 milestone: a REAL client device enumerates
    locally** (2026-07-06, commits `c1f27e9` async boundary + `0ffc6ce` presenting side). 2-ii-a
    restructured `usb_spike.m` to async out-of-band EP0 completion (raise via C callback → leave
    outstanding → `macrdp_usb_complete_control_in` `dispatch_async`es onto `self.interface.queue`),
    with a bidirectional C ABI; `--usb-spike` still enumerates the synthetic device through it.
    2-ii-b wired `imp::present_device`: create the controller with a Rust control-IN callback that
    services each EP0 `GET_DESCRIPTOR` by awaiting `handle.get_descriptor()` (client-sourced over
    URBDRC). **Verified entitled + FreeRDP `/usb` (flash drive): ESD310C, idVendor=0x2174 enumerates
    on macrdp's UserHCI controller** (ioreg `@80100000`), device + string descriptors (product
    "ESD310C") sourced live from the client. Non-entitled path degrades gracefully.
  - **Phase 3.2 STARTED — teardown/lifecycle first** (2026-07-06, commit `3c85845`): the UserHCI
    controller is now destroyed on disconnect instead of leaking until process exit.
    `UrbdrcDeviceProcessor` holds a `watch::Sender`; each `UsbHandle` carries a subscriber +
    `closed()`; the server's `static_channels` reset (`server.rs:1244`) drops the processor on
    disconnect → `closed()` resolves → `present_device` breaks + destroys the controller. Verified
    entitled + FreeRDP: the presented ESD310C disappears from `ioreg` on disconnect (server stays up).
  - **Phase 3.2 bulk — SelectConfiguration done + a test-environment blocker found** (2026-07-06,
    commit `ed735d5`): implemented the config-descriptor parse + `SelectConfiguration` URB (opens the
    device's pipe handles — the prerequisite for bulk). **The URB is verified correct** (FreeRDP
    parses + attempts it), **but the macOS-client loopback CANNOT complete bulk**: FreeRDP's libusb
    can't detach the mass-storage kernel driver to claim the interface (`LIBUSB_ERROR_ACCESS`), which
    every bulk transfer needs. EP0 descriptor reads work; bulk needs a **claimable-interface client**
    (a real Windows client, or a **Linux FreeRDP** client where kernel-detach works — i.e. a second
    machine). Degrades to enumerate-only (5s timeout).
  - **Phase 3.2 dedup — done, then hardened** (2026-07-06, commits `e11eed3` then the bulk commit):
    one presenting controller per physical device. Initially keyed on the client's
    `device_instance_id`, but that FAILED live — FreeRDP announces one drive twice with instance ids
    differing by a byte (`…d31`/`…d32`), so both presented and the two virtual drives **dueled over
    the single client device** (10 s SCSI timeouts, failed mount). Re-keyed on the device's **stable
    hardware identity** (`VID:PID:bcdDevice`, fetched before claiming). Unit-tested; verified live
    (one controller, clean mount). (`UsbHandle` still exposes `device_instance_id` for logging.)
  - **Phase 3.2 bulk IN/OUT forwarding GO ✅✅ — the redirected DRIVE MOUNTS** (2026-07-06): 
    `UsbHandle::bulk_transfer_in/out` (`TsUrb::BulkInterruptTransfer` on the SelectConfiguration pipe
    handles, direction-flag matched) + the Obj-C ring walk generalized to the bulk endpoints (async
    out-of-band completion, same pattern as EP0 control-IN). **Verified end-to-end on a real Linux
    FreeRDP client** (UTM-QEMU Ubuntu 24.04 ARM64 + a **USB-2.0 hub** to force high-speed so the
    USB-3.2 SSD enumerates in QEMU; guest `udev MODE=0666` + `xfreerdp /usb:dbg,id:2174:2100`): the
    ESD310C **mounts on the Mac and stays mounted**, 1300+ steady bulk transfers, no resets/timeouts.
    Two load-bearing fixes: (1) the hardware-identity dedup above; (2) an Obj-C **endpoint-object
    identity guard** on completion — a device reset destroys+recreates the endpoint at the same key
    (new Active object, but `p.msg` points into the old freed ring), so the completion is dropped
    unless `endpoints[key]` is still the same object it was raised on (fixes a reset-during-bulk
    SIGSEGV the liveness check alone missed).
  - **Phase 3.2 control-OUT forwarding — done** (2026-07-06): EP0 host→device requests the local
    kernel issues (mass-storage Bulk-Only Reset `bReq=0xff` / Clear-Feature(HALT)) now forward to the
    real device via `UsbHandle::control_transfer_out` (generic `URB_FUNCTION_CONTROL_TRANSFER_EX`,
    pipe 0 = default control EP); the standard requests the host controller / SelectConfiguration own
    (SET_ADDRESS/CONFIGURATION/INTERFACE) stay a local ACK. Obj-C forwards on the control STATUS stage
    (no-data requests are SETUP→STATUS) and stashes any DATA-OUT payload. **Regression-verified live**
    (clean mount + file copy + remove/reattach unaffected; the one SET_CONFIGURATION seen was correctly
    NOT forwarded). The forward path itself only fires under a SCSI error/stall, which didn't occur, so
    it's implemented + regression-safe but not yet observed firing.
  - **Phase 3.2 remaining** (generic control-IN forwarding is DONE — the 2026-07-07 hardening pass
    added `UsbHandle::control_transfer_in`; Get Max LUN verified forwarded+answered live). Left:
    **(a)** explicit `RETRACT_DEVICE` PDU — SMALL but low value, the client channel-close path already
    covers detach/reset live-verified; **(b)** true multi-device — MEDIUM, needs the iSerialNumber
    string descriptor to distinguish identical models + two identical devices to test; **(c)**
    dispatch-priority tier. Test rig proven: UTM-QEMU Linux FreeRDP + USB-2.0 hub. Plan:
    `~/.claude/plans/wobbly-honking-minsky.md` §3.2.
  - **Phase 3.3 ISOCHRONOUS transfer spike — M0 (observe-only) LANDED, live go/no-go DEFERRED**
    (2026-07-10, user away from the USB rig). Isoch is the last missing transfer type
    (control/bulk/interrupt all work); it blocks isoch webcams + **USB audio** (mic/speaker).
    Staged M0 (observe) → M1 (forward isoch-IN), **IN-only**, a USB **mic** as the lowest-bandwidth
    go/no-go device. **Key finding: the vendored `ironrdp-rdpeusb` PDU layer is already isoch-ready**
    (`UrbFunction::IsochTransfer`(10) + `TsUrb::IsochTransfer` encode/decode/size; rides the existing
    TransferIn/Out envelope; `UrbCompletion::decode` auto-synthesizes the per-packet IN result) —
    **NO ironrdp-rdpeusb change needed for an IN spike.** **M0 code is written + compiles
    warning-free + an entitled `.app` is built/installed to `/Applications`** (uncommitted
    working-tree changes on `main`, ALL in `src/usb_redirect/usb_spike.m` only; default path
    byte-identical since USB redir is opt-in): (1) `macrdp_ep_transfer_type()` reads the
    EndpointCreate descriptor ptr (`data1`) → `bmAttributes&0x03`; create log tags `(ISOCHRONOUS)`.
    (2) `walkEndpoint:` catches `IOUSBHostCIMessageTypeIsochronousTransfer` (0x3b) before the
    default "unexpected type" path. (3) `observeIsochTransfer:` logs each TRB's frame#/ASAP/len/buf
    + inter-TRB **gap (ms)** for cadence and completes it **zero-length success** (NOT forwarded);
    throttled first-32-then-every-256th; counters cleaned on EndpointDestroy.
    **PENDING LIVE TEST:** `launchctl bootout gui/$(id -u)/com.clintcan.macrdp`, run foreground
    `/Applications/macrdp.app/Contents/MacOS/macrdp --keychain --enable-usb-redirection 2>&1 |
    grep -E 'usb2|ISOCH'`, FreeRDP `/usb:id,<vid>:<pid>` a mic (release the client's own audio
    driver first), open **Audio MIDI Setup**/QuickTime to open the isoch EP. **GREEN** = steady
    `ISOCH observe … gap≈1.000ms` lines → build **M1** (mirror the bulk path across all 3 layers:
    `isoch_transfer_in` UsbHandle method + `TransferReq::Isoch` arm + isoch endpoint classification
    out of `interrupt_eps`; expect to need DEPTH like the bulk read-ahead engine). **RED** = no
    lines / immediate teardown / sub-ms bursts we can't meet over the network → document the ceiling
    and stop (like the UDP client-support finding). Core risk M0 answers: can isoch meet macOS's
    timing over a network redirect (no retransmit + tight service intervals) at all. OUT/speakers
    would need the full `UsbdIsoPacketDesc` back (out of scope; IN-only). Plan:
    `~/.claude/plans/wobbly-honking-minsky.md`.
  Gates to the official signed+provisioned build for the *presenting* side (entitlement baked
  into the signature). See `docs/usb-redirection-feasibility.md` +
  [[project_usb_redirection_feasibility]].

- [ ] **Multi-monitor (client-side multi-display).**
  Extend `--virtual-display` to N monitors. **Blocker:** the git-pinned `ironrdp-acceptor`
  hardcodes a single-monitor `MonitorLayoutPdu`, so true separate monitors needs an acceptor
  change. Open design question: true-monitors vs one-big-desktop vs phased. (PAUSED, no code.)
  Also listed as Tier 3 in the production-readiness roadmap below.

- [x] **Historical production-readiness roadmap snapshot.** TLS and auth controls shipped; Tier 2.5 health/log operations shipped; multi-user concurrent GUI sessions remain a macOS architectural limit. The dated v0.8.24 soak follow-up is historical and is no longer described as an in-flight gate; see `docs/production-readiness-roadmap.md` for scope and evidence. This checklist snapshot is not a current certification of unattended-production readiness.

## Parked — scoped, low priority

- [x] **Headless-lock arc — LANDED on `main` 2026-07-23 (pending a release tag).** Merged this
  session: **`--shield-primary`** opt-in lockable headless blanking (#170; single-panel engage
  #171, @antonmos), the **`Ctrl+Alt+G` majority-area gather** (mostly-off windows now swept),
  the **`--detach-primary` launchd-restart stopgap for #168** (#169, @antonmos-verified on
  26.5.2), the **blank-recovery established tier** (#172, @antonmos), plus #165 vd
  client-resolution auto-adopt and #166 iOS touch-tap fix. All adversarially security-scanned
  clean. **To run any of it live: signed rebuild+reinstall** (installed v0.9.0 predates them —
  build the shield helper via `gui/make-shield-helper.sh`; Team ID QGLA89KHM7). Two ship
  decisions remain the user's: (a) cut a release for the unreleased pile; (b) whether shield
  should ever become the default over `--capture-primary` (currently opt-in, capture unchanged).

- [x] **#168 — `--detach-primary` panel-reenable root fix: no supported in-process fix identified (2026-10-15).** Historical issue #168 is no longer tracked as an open GitHub issue. The prior macOS 26.x investigation found no viable in-process display-config transaction; process exit reverts the app-scoped disable. `--shield-primary` avoids the disable path. Treat as a documented platform limitation unless a new macOS API/measurement changes the evidence.

- [x] **#167 — smaller headless virtual display can place Dock outside capture bounds: documented limitation (2026-10-15).** Historical issue #167 is no longer tracked as an open GitHub issue. The known trade-off remains: persisting the detach arrangement can sacrifice crash-safe auto-revert; no behavior change is justified without a newly approved opt-in design. See `docs/known-quirks.md`.

- [ ] **Crash-report watch (post NSPasteboard-mutex fix).** The rare churn-time
  NSPasteboard use-after-free SIGSEGV was fixed 2026-07-07 via a process-global
  pasteboard mutex (`clipboard::pasteboard_guard()`, released in v0.8.29) — but it was
  rare, so it's unproven-by-repro. Keep the `.ips` files and watch new crash reports for
  a DIFFERENT signature. The 2026-06-28 `UNKNOWN_0x32` pthread crash is a separate,
  still-open one-off.

- [x] **Auto-sized virtual display — SUPERSEDED/ANSWERED by #155 + v0.8.39.** The open
  question ("does `CGVirtualDisplay applySettings` live-resize cleanly or need recreate?") is
  answered: **it live-resizes cleanly** (`VirtualDisplay::resize` re-applies a single mode via
  the shared `apply_single_mode`; the descriptor's 8192×8192 max is a lifetime cap). The
  feature itself shipped as live client-driven resize (MS-RDPEDISP, #155/v0.8.37, antonmos) —
  the vdisplay re-modes to the client's requested size on connect AND on every window
  drag/maximize — then v0.8.39 (#160 + #162) made it smooth on the headless path (see below).

- [x] **Smooth-resize on the headless path — DONE v0.8.39 (#160 + #162, closes #161,
  2026-07-18).** A live resize needs a core reactivation, which on
  `--capture-primary`/`--detach-primary` cascaded into a visible session re-cycle (gamma
  flicker + audio restart) and stranded windows/Dock. Fixes: **(1)** the overlay watcher polls
  through the reactivation's transient 1→0→1 session flap (2.5 s grace; the gap is variable
  ~0.5–0.9 s — a fixed sleep was proven insufficient) instead of tearing down the headless
  capture (#160); **(2) ROOT CAUSE of the Dock/window churn:** the vd's `(0,0)`/main
  placement was `ConfigureForAppOnly` — process-scoped, never persisted — so **every
  `applySettings` re-mode re-derived the arrangement from the WindowServer's session store**
  ("physical is main") and snapped the vd off `(0,0)`: Dock jumped to the blanked panel, and
  a variable-timing relayout kept re-stranding windows AFTER the post-resize gather placed
  them (both sweeps at +0.7 s/+1.7 s re-finding all 8 — sweep-retry is whack-a-mole, don't
  extend it). Fixed with **`ConfigureForSession`** (the store agrees → nothing to snap back
  to); crash-safety unchanged. Defense-in-depth kept: a **synchronous** `reanchor_as_main`
  after each re-mode (off-thread is too late — the Dock has already settled and won't
  re-follow) + a two-sweep post-resize auto-gather (#162). Live-verified consistent across
  maximize + drag-between-monitors on real mstsc. Full lesson: the vd-arrangement quirk note
  in `docs/known-quirks.md`. `DetachedPrimary` keeps `ForAppOnly` deliberately (its disable
  tx must auto-revert on SIGKILL); revisit only with live evidence of the same bug on detach.

- [ ] **`cycle_apps` lock nesting (`CYCLE_SESSION` → `mru`).** Currently safe by consistent
  acquire order; de-nest as a follow-up to the PR #84 hardening if revisiting that area.

- [x] **On-demand A/V resync hotkey (`Ctrl+Alt+Shift+R`) — DONE v0.8.38 (#159, 2026-07-17).**
  Manual recovery of a session gone stale after a long idle — a blanked screen and/or drifted
  audio (mstsc; the audiodg drift is client-side and un-observable from the server, so
  auto-detection is a dead end — this is a lever the user presses when they *see* it). Video
  forces a clean IDR keyframe (`Gfx::force_keyframe`, repaint the stale presentation); audio
  rebuilds its SCK stream via the existing self-heal `'reconnect` (a brief gap drains the
  client's backlog + re-baselines timing, like a minimize→unminimize). No disconnect;
  always-on like `Ctrl+Alt+G`; Win-key-free so mstsc forwards it. **Load-bearing: video uses a
  forced IDR, NOT the core reactivation** — the reactivation un-blanks too but on the
  `--virtual-display`/`--capture-primary` headless path cascades into a visible ~1–2 s session
  re-cycle (vd re-mod → #155 live-resize surface reset → SessionTracker teardown + headless
  re-capture); the IDR is flicker-free. `Gfx::request_reactivation` kept `#[allow(dead_code)]`
  as the escalation for a surface-retention blank an IDR can't clear. Live-verified on real
  mstsc (un-blanked smoothly, audio resynced, zero flicker). See the quirk note in
  `docs/known-quirks.md`.

- [ ] **Auto-mute on silence (audio-only).** Long-idle YouTube unpause loses audio
  (Windows audiodg suspends after hours of digital silence). Must be audio-only (not the
  shared `display_suppressed` gate, which would freeze the desktop). Note: the
  `Ctrl+Alt+Shift+R` resync hotkey (above, DONE) is the *manual* answer to this idle-audio
  drift; an *automatic* audio-only mute-on-silence is the still-parked hands-free version.

- [ ] **AVC444 (4:4:4 chroma).** YUV-pack module + bench scaffold landed; `--avc444` not
  wired. VT hw-encoder serializes → 1080p-comfortable, 4K doesn't fit. Resume only if
  colored-text quality becomes a pain.

## Not planned

- **Printer redirection (RDPDR printer device).** Not implemented; no current demand.

## Upstreaming watch (no action unless a release lands)

- **▶ UPDATE 2026-10-15 — upstream state rechecked via GitHub:** #1969 closed; #1484 remains open. Multitransport stack #1951/#1953/#1954 merged; RDPEAI #1645/#1946 merged; #194 pin bump remains draft awaiting live gates. Fork-specific notes below are archived history, not a current open-PR inventory.
  - **Divergence (23), second-client preemption, upstream status:** #1476/#1913 merged; preserve explicit `.with_connection_policy(ConnectionPolicy::Preempt)` at migration because upstream default is Queue. Upstream invalidates ARC cookie on eviction. #1969 closed 2026-10-01; verify its fix is present in target revision before removing the local workaround. #1483 closed as resolved by #1476/#1913.
  - **#1969 — CLOSED 2026-10-01.** Its old text describing the hook-loss bug as open/blocking is historical; check the closing fix/release before any de-vendoring decision.
  - **Divergence (18), `on_authenticated`, → #1484 (OPEN issue).** Prior patch was reported stale/conflicting and blocked on #1969; since #1969 closed 2026-10-01, re-check the issue and current API before deciding whether to refresh or close this divergence.
  - **Overlapping upstream work to evaluate at the next bump:** the #1951/#1953/#1954 multitransport stack is CLOSED; #1645 RDPEAI crate and #1946 server integration are MERGED. Review their final merged APIs against this pin at migration time.
  - Historic merged list retained in PR-specific entries below.

- IronRDP vendored forks carry macrdp-specific divergences; the set changes as upstream releases land. Snapshot: #1359, #1397, #1373 and the 2026-07/08 merge wave below are historical. Recompute the remaining list against the target revision before any pin migration.
  **Historical merge wave 2026-07-30/31:** #1453, #1405, #1418 and #1420 merged; #1404 merged and #1508 closed via #1509 on 2026-08-02. Later upstream activity is summarized in the refreshed watch entry above.
  - [x] **#1404** `feat(acceptor)!: clamp honored client desktop size to an operator maximum` (**MERGED 2026-08-02, mamoreau**) — the
    honor-size resource-hardening CBenoit green-lit in his #1373 approval. Replaces the `bool` with
    `Option<DesktopSize>` = operator max; client request clamped per-dimension. Upstreams the
    hardened form of acceptor divergence (1).
  - [x] **#1405** `feat(server): send the Server Auto-Reconnect Cookie during logon` — upstreams
    vendored `ironrdp-server` divergence (13). Additive (default `None`): optional ARC_SC cookie
    (MS-RDPBCGR 2.2.4.2) sent as a Save Session Info PDU once per connection, so a client
    auto-reconnects on an ungraceful drop (mstsc won't without it). API mirrors `credential_validator`
    (builder `with_auto_reconnect_cookie` + setter). **MERGED 2026-07-31 (mamoreau).** The phased
    split was accepted — send-side merged; returning-cookie validation + rotation DEFERRED to
    tracking issue **#1508**. (A doc-push exposed a stale-base build break — #1348 removed
    `encode_share_data_pdu` — fixed by rebase + reintroducing the helper as the PR's own; CI green
    before merge.)
  - [x] **#1418** `feat(rdpeusb)!: tolerate unrecognized device-reported USB capability values` —
    opened 2026-07-08, **MERGED 2026-07-31 (CBenoit "LGTM!").** Upstreams vendored `ironrdp-rdpeusb`
    divergence (1) (the lenient USB-caps decode): fixes a real USB-3.2 device (SupportedUsbVersion
    `0x320`) tearing down the URBDRC channel on decode. **REVIEW ADDRESSED 2026-07-10 (commit `80c7c8b9`):** CBenoit REQUIRED
    dropping the `Other(u32)` fallback (it can alias a named value → breaks round-trip/Eq, a pattern
    they're purging codebase-wide), so the 4 device-reported fields are now **newtype structs over
    `u32` with named associated consts** (the `http::StatusCode` shape; matches the crate's own
    `UrbFunction`) — one representation per wire value, no aliasing. Added his requested
    decode-from-raw-bytes test + rstest round-trip. **Double-checked 2026-07-10: build + `clippy -D`
    + tests + fmt all clean, no external consumers.** **2026-07-15: uchouT (community) CHANGES_REQUESTED
    a `check_device_speed` edge — the constraint compared `== HIGH_SPEED` but per MS-RDPEUSB 2.2.11
    `DeviceIsHighSpeed` MUST be 0 at bus-iface-version 0, so a lenient newtype could wrongly accept a
    non-`0x1` non-zero speed. FIXED 2026-07-16 (`04c76e7a`): compare `!= FULL_SPEED` (any non-zero) +
    a 4-case raw-decode rstest. 2026-07-17: uchouT ENDORSED merge (pinged CBenoit "can we just merge
    this?") — community review done, awaiting only CBenoit's merge click. Do NOT double-nudge.**
    Scoped to (1) only —
    The old follow-up for rdpeusb `UsbDevice=0` (#1513) and call-site migration is historical; check the current upstream PR state before planning any local cherry-pick or pin bump.
  - [x] **#1420** `feat(rdpeusb)!: carry the full configuration descriptor in UsbConfigDesc` —
    FILED 2026-07-09 (was the drafted rdpeusb div (3)). `UsbConfigDesc` gains `trailing: Vec<u8>`
    (bytes 9..wTotalLength) so `TS_URB_SELECT_CONFIGURATION` carries the full configuration
    descriptor (real Windows rejects header-only with `0x80070057`). **REVIEW ADDRESSED 2026-07-10
    (commit `2cde264f`):** added Copilot's asked-for encode-time validation — `bLength`==9-byte
    header AND `wTotalLength`==header+trailing, so a caller can't emit a descriptor whose
    `wTotalLength` disagrees with the payload (+ `inconsistent_header_fails_to_encode` test).
    **CBenoit APPROVED 2026-07-31 ("LGTM and approving; just needs a rebase").** It was stacked on
    #1418; when that merged first #1420 went CONFLICTING → **REBASED** (`git rebase --onto
    upstream/master` dropped the two now-merged #1418 commits, replayed only #1420's own; `mod.rs`
    auto-resolved), force-pushed → **MERGED 2026-07-31 (mamoreau).** The rdpeusb pair (div 1 #1418 +
    div 3 #1420) is now fully upstream.
    (Local clippy false-alarm during verify: `unfulfilled_lint_expectations` in `ironrdp-str` — a
    crate #1420 doesn't touch — from local rustc 1.97 vs CI's pinned 1.89; reproduces on pristine
    master, CI unaffected.)
  - Historical #1513 note: old discussion proposed upstreaming `UsbDevice == 0` handling and then dropping the local rdpeusb fork. The current pin and upstream state must be checked before relying on that proposal.
  - [x] **#1453** `feat(acceptor): expose client multitransport flags on AcceptorResult` — opened
    2026-07-17, **MERGED 2026-07-30 (mamoreau).** Upstreams the READ-side of vendored `ironrdp-acceptor` divergence (3): surfaces
    `pub multitransport_flags: gcc::MultiTransportFlags` (the client's GCC `MultiTransportChannelData`,
    MS-RDPBCGR §2.2.1.3.8, which the acceptor already parses then discards) so a UDP-capable server
    can decide whether to send a Server Initiate Multitransport Request. **Purely additive, zero
    behavior change** — a line-for-line twin of the merged `keyboard_layout` (#1397) / desktop-size
    (#1373) surfacing at all six touch points. No test (matches #1397/#1373 precedent; acceptor lib is
    `test=false`). clippy/fmt clean. The bulky M3c advertise/emit/offer HALF of divergence (3) stays
    vendored as macrdp UDP policy, so even merged+released this does NOT de-vendor the acceptor.
  The July 2026 vendor-removal count and follow-up API list are a historical snapshot of the older pin. Rebuild the exact removable-divergence map against the target revision and current fork CLAUDE.md files before migration; #1404 is now merged.
    <!-- Historical API-fit note (2026-08-02): IronRDP #1394's sans-I/O URBDRC processors do not by themselves replace macrdp's async UsbHandle/router integration. The server factory integration #1417 later merged; compare current upstream code to the local divergence during pin migration. Do not use the old 'open/blocked' PR status here. -->
- [ ] **IronRDP pin migration — upstream draft #194; local tree remains at `a5d1c682`.** Draft proposes `e258f6a0`; GitHub checks pass, but PR remains DRAFT / REVIEW_REQUIRED / BLOCKED; live client/soak gates remain. Local migration needs its own compatibility audit because vendored forks/integration differ. All following dry-run notes are archived, not current guidance.

  **Archived dry-run (2026-08; stale):** `ironrdp-core` 0.1→0.2 was assessed as additive — `Encode`/`Decode`
    traits, `ReadCursor`/`WriteCursor`, `ensure_size!`/`invalid_field_err!`, `EncodeError`/`DecodeError`
    all byte-identical (only a `NonEmpty` export added). So the foundational layer does NOT ripple —
    every custom-PDU impl in the forks + rdpeudp re-compiles near-unchanged; the divergences are
    RE-WIRING work, not rewrites. This caps the whole blast radius.
    **src/ (macrdp own code) edit surface = SMALL-MEDIUM (~half day), only 2 release-path files:**
    (i) `src/audio.rs` — rdpsnd handler rewrite for #1359's `NegotiatedFormat` API (`choose_format` +
    fallible `start(&NegotiatedFormat)`); a NET SIMPLIFICATION — delete `choose_audio_format` + its
    wFormatNo unit tests (the crate now owns that arithmetic; the client-vs-server-index footgun becomes
    *unrepresentable*), return `common.first()` (AAC-ahead-of-PCM falls out). (ii) `src/h264.rs` —
    `GraphicsPipelineHandler::on_frame_ack` gained a 3rd param `total_frames_decoded: u32` (#1345);
    trivial add-and-ignore (resist wiring it into blank-recovery mid-bump). PLUS `src/conn_test.rs`
    (test-only, INVISIBLE to `--release` — don't declare done pre-`cargo test`): `NoAudio` handler sig +
    `Config { connection_type: gcc::ConnectionType::Lan, .. }` new required field. cliprdr
    `ClipboardMessage` gained `SendInitiateFileCopy` — macrdp matches individual arms (no exhaustive
    match) so should compile clean; verify it stays `#[non_exhaustive]`.
    **Vendored forks — retirement map (verified present at `a5d1c682fd`, not just from logs):**
    • **rdpeusb → FULLY RETIRES** (first whole fork to go): all 4 divs upstream (div1 #1418 newtype+
      `USB_32`, div2 #1513 narrowed `usb_device` match, div3 #1420 `trailing`, div4 #1321 guards). BUT
      upstream is `publish=false` → "retire" = convert path-dep to a **git-pin `[patch]` entry** (keep the
      `ironrdp-str` pin), NOT a crates.io version. `SupportedUsbVer::Usb32`→`::USB_32` at call sites.
    • **rdpdr → stays vendored, near-TRIVIAL re-apply** — upstream still strictly client-only (no
      `SvcServerProcessor`, no server-dir MS-RDPESC); the exact files macrdp augments (`pdu/efs.rs`,
      `pdu/esc/`, `pdu/mod.rs`) have ZERO churn between the revs.
    • **rdpeudp → keep-forever, compiles CLEAN** — no upstream twin; depends only on `ironrdp-core`,
      every imported symbol still exported, no sig changes. Just bump its internal `[patch]` rev in lockstep.
    • **dvc → sheds div2 (close-hook, upstream #1302 Drop-based close), keeps Soft-Sync (div1)** —
      `pdu.rs` unchanged so the Soft-Sync structs re-apply trivially; only two small `process()` arms
      re-place onto churned `server.rs`(+181)/`client.rs`(+110). RE-APPLY-easy/medium.
    • **acceptor → RE-APPLY-MEDIUM (highest-effort survivor after server)** — read divs all retire
      (honor-size unified into `set_honor_client_desktop_size(Option<DesktopSize>)` w/ #1404 clamp; KLID
      #1397; MT-flags #1453). Persists for the **M3c UDP-offer machinery + client-fingerprint fields**,
      re-applying onto a **+252-churned `connection.rs`** (`finalization.rs` unchanged → channel-skip clean).
    • **server → 6 delete-free, ~15 re-apply.** DELETE: (5)SuppressOutput #1319, (6)NSCodec #1332,
      (7)QOI #1335/#1341, (9)honor-size #1373/#1404, (13)ARC #1405/#1509, (17)wheel-decode (now fixed in
      ironrdp-pdu `input/mouse.rs` itself). Each of (6)/(9)/(13) still costs a small macrdp-side wiring
      change (enable `nscodec` feature; `bool`+`_max`→`Option<DesktopSize>`; `(logon_id,random_bits)`→
      `Option<ServerAutoReconnect>`). **The 3 HARDEST re-applies (where the effort concentrates):**
      **(23) auth-gated 2nd-client preemption** — restructures `run()` into a race loop + `Box→Rc` for ALL
      factories + hand-duplicates a `run_connection` that **upstream itself just refactored** into
      `run_connection_with(TransportTls{Managed,AlreadyDone})`; **(12) UDP multitransport** module wired
      into that same moved `run_connection`/`run` path; **(2)+(3) audio `dispatch_audio` carve-out** —
      rebuild over the changed rdpsnd `start()` API (upstream may have independently fixed the
      wFormatNo-indexes-client-list bug we documented). Sharp cross-cutting hazards: the
      `run_connection_with`/`TransportTls` refactor (hits div-18 `on_authenticated` + div-23), `run()` now
      TRIPLE-purposed (upstream `GetLocalAddr`/`AutoDetectRttRequest` + div-15 RTT sample + div-23 race),
      the **`ServerEvent` enum union** (upstream added `SetAutoReconnectCookie`/`GetLocalAddr`/
      `AutoDetectRttRequest`; fork added `Rdpdr`/`Urbdrc`/`Camera`/`EvictedByOtherConnection` — merge both,
      reconcile every dispatch arm), and egfx churn (compositor.rs +1217, so the div-14 `on_ready` AVC seam
      may have shifted). Also note **#1501** (session-resume via ARC, `pdu,session,connector,server!`)
      overlaps our div-13/div-18 ARC surface — upstream now owns cookie send+validate+rotate (#1405/#1509),
      so most of the ARC divergence is upstream; re-check what's left. **Graph risk:** `ironrdp-error 0.1→0.2`
      ripples every crate's error type — lockfile-check nothing pins error 0.1.
    **Historical effort estimate (Aug 2026; stale):** refresh after reviewing the current draft diff and rebuilding a migration map. Schedule a maintenance window and real mstsc/FreeRDP validation before deployment; do not treat the old soak plan or estimated duration as current gates.
- Upstream-ability of the remaining divergences was surveyed 2026-07-01 (don't re-survey; ranking
  in `project_upstream_ironrdp_open_prs` memory). The other "quick" items (RDPDR decode halves,
  AudioWave `duration_ms`, keyboard-layout handle) are **held** — no upstream consumer yet, so they
  belong with their larger feature (server-RDPDR processor, audio-lag model), not standalone PRs.
