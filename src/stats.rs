//! Opt-in live-telemetry endpoint (`--stats-endpoint`, default OFF).
//!
//! A tiny **loopback-only, read-only** TCP listener that serves a JSON snapshot
//! of the current H.264 session — live bitrate, link RTT, standing queue delay,
//! frame rate, frames sent, and the session dimensions — on each connection. It
//! exists so the menu-bar controller's Status pane can show live "connection
//! health" without the server writing anything to disk.
//!
//! **No disk writes.** The snapshot lives entirely in memory ([`SessionStats`],
//! a handful of atomics updated at low-frequency points in the encode path) and
//! is serialized *only when a client connects* — which the controller does every
//! ~2 s, and only while its Status pane is open. So there is zero periodic I/O
//! (and therefore no SSD wear), unlike a periodically-rewritten stats file.
//!
//! **Default runtime path unchanged when off.** The endpoint is created only
//! when enabled; when it isn't, [`global`] returns `None`, so every update site
//! in the hot path is a single `Option` check that compiles to a no-op. The
//! listener binds `127.0.0.1` only (never routable) and never reads request
//! bytes — it just writes one JSON line and closes. It carries only the local
//! session's own metrics; the trust boundary is the same single-user, loopback
//! model as the other helper channels (see docs/macos-gotchas.md).

use std::net::Ipv4Addr;
use std::sync::atomic::{AtomicBool, AtomicI8, AtomicI64, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// The live snapshot. Every field is an atomic so the encode path can update it
/// lock-free; the listener reads it under no lock either. Values are best-effort
/// and eventually-consistent — a slightly stale read between updates is fine for
/// a status display. "Connected" is deliberately NOT authoritative here (there
/// is no reliable EGFX teardown hook — see the h264 reconnect-blank note); the
/// controller determines connected/disconnected from `lsof` and uses these
/// numbers only while it independently sees a live client.
#[derive(Default)]
pub struct SessionStats {
    /// Best-effort: set true at connection setup. Not cleared reliably (no
    /// teardown hook) — the controller gates on its own `lsof` check instead.
    pub connected: AtomicBool,
    pub width: AtomicU32,
    pub height: AtomicU32,
    /// Live encoder bitrate: the adaptive value when `--adaptive-bitrate` is on,
    /// otherwise the configured ceiling (static for the session).
    pub bitrate_bps: AtomicU32,
    /// The `--bitrate` ceiling (adaptive never exceeds it).
    pub ceiling_bps: AtomicU32,
    /// Kernel-measured link RTT (ms) sampled at accept; 0 = unknown.
    pub rtt_ms: AtomicU32,
    /// Standing queue delay (ms above the windowed-min RTT) — the adaptive
    /// controller's congestion signal. Meaningful only with acks flowing.
    pub queue_delay_ms: AtomicU32,
    /// Effective frame rate (capped by the adaptive floor under congestion).
    pub fps: AtomicU32,
    pub frames_sent: AtomicU64,
    /// Number of captures dropped before VideoToolbox submission.
    pub capture_drops: AtomicU64,
    /// Number of ScreenCaptureKit samples discarded before processing.
    pub capture_sample_drops: AtomicU64,
    /// Number of screen samples superseded by a newer sample before conversion.
    pub capture_superseded: AtomicU64,
    /// Current SCK sample queue depth, when telemetry is enabled.
    pub capture_buffered: AtomicU32,
    /// Current pending legacy bitmap-update queue depth.
    pub display_pending: AtomicU32,
    /// Future live outbound scheduler queue depth, when wired.
    pub outbound_queued_packets: AtomicU64,
    pub outbound_queued_bytes: AtomicU64,
    pub outbound_enqueued_packets: AtomicU64,
    pub outbound_rejected_packets: AtomicU64,
    pub outbound_sent_packets: AtomicU64,
    pub outbound_sent_bytes: AtomicU64,
    /// Number of legacy display queue overflows followed by full-frame resync.
    pub display_overflow_resyncs: AtomicU64,
    /// Last measured age from SCK display timestamp to processing, in ms.
    pub capture_age_ms: AtomicU32,
    /// Last VideoToolbox output age from encode submission to callback, in ms.
    pub encode_latency_ms: AtomicU32,
    /// Last ship duration from encoded callback to event enqueue, in ms.
    pub ship_latency_ms: AtomicU32,
    /// Number of encoded frames waiting for ship processing.
    pub encoded_pending: AtomicU32,
    /// Number of outbound ServerEvent items waiting for dispatch.
    pub server_event_queue: Arc<AtomicU32>,
    /// Number of socket writes that exceeded the diagnostic stall threshold.
    pub socket_write_stalls: Arc<AtomicU64>,
    /// Most recent socket write duration, in ms.
    pub socket_write_ms: Arc<AtomicU32>,
    /// Current queued audio waves in newest-first jitter buffer.
    pub audio_queue: Arc<AtomicU32>,
    /// Queued audio duration, in ms.
    pub audio_queue_ms: Arc<AtomicU32>,
    /// Waves evicted from audio queue because producer outran socket dispatch.
    pub audio_drops: Arc<AtomicU64>,
    /// Audio socket-write waits exceeding 10 ms.
    pub audio_write_stalls: Arc<AtomicU64>,
    /// Most recent audio socket-write duration, in ms.
    pub audio_write_ms: Arc<AtomicU32>,
    /// Number of hysteretic stale-audio resync actions.
    pub audio_resyncs: Arc<AtomicU64>,
    /// Waves removed by hysteretic stale-audio resync.
    pub audio_resync_dropped: Arc<AtomicU64>,
    /// Maximum projected audio backlog observed since session start, in ms.
    pub audio_backlog_max_ms: Arc<AtomicU32>,
    /// Rolling p50/p95/max capture age in ms.
    pub capture_age_p50_ms: AtomicU32,
    pub capture_age_p95_ms: AtomicU32,
    pub capture_age_max_ms: AtomicU32,
    /// Rolling p50/p95/max encode latency in ms.
    pub encode_latency_p50_ms: AtomicU32,
    pub encode_latency_p95_ms: AtomicU32,
    pub encode_latency_max_ms: AtomicU32,
    /// Rolling p50/p95/max ship latency in ms.
    pub ship_latency_p50_ms: AtomicU32,
    pub ship_latency_p95_ms: AtomicU32,
    pub ship_latency_max_ms: AtomicU32,
    /// Rolling p50/p95/max socket wait in ms.
    pub socket_write_p50_ms: AtomicU32,
    pub socket_write_p95_ms: AtomicU32,
    pub socket_write_max_ms: AtomicU32,
    /// Rolling p50/p95/max audio queue depth in ms.
    pub audio_queue_p50_ms: AtomicU32,
    pub audio_queue_p95_ms: AtomicU32,
    pub audio_queue_max_ms: AtomicU32,
    /// Rolling p50/p95/max audio socket wait in ms.
    pub audio_write_p50_ms: AtomicU32,
    pub audio_write_p95_ms: AtomicU32,
    pub audio_write_max_ms: AtomicU32,
    /// Best-effort process CPU percentage sampled by the diagnostics loop.
    pub cpu_percent: AtomicU32,
    pub adaptive: AtomicBool,
    /// Latest ScreenCaptureKit audio presentation timestamp, normalized to ms.
    pub audio_pts_ms: AtomicI64,
    /// Latest ScreenCaptureKit video presentation timestamp, normalized to ms.
    pub video_pts_ms: AtomicI64,
    /// Latest audio PTS minus video PTS. Positive means audio source is ahead.
    pub av_offset_ms: AtomicI64,
    /// Number of valid audio/video PTS pairs observed.
    pub av_samples: AtomicU64,
    /// EWMA of audio-minus-video source PTS offset, in milliseconds.
    pub av_offset_ewma_ms: AtomicI64,
    /// Number of offset samples folded into EWMA.
    pub av_offset_ewma_samples: AtomicU64,
    /// EWMA source-clock drift in parts per million (audio relative to video).
    pub av_drift_ppm: AtomicI64,
    /// Number of source-clock samples folded into the ppm estimator.
    pub av_drift_samples: AtomicU64,
    /// Hysteretic telemetry-only drift zone: -1 behind, 0 stable, 1 ahead.
    pub av_drift_zone: AtomicI8,
    pub aac: AtomicBool,
    av_clock: AvClockTracker,
}

#[derive(Default)]
struct AvClockTracker {
    state: Mutex<AvClockState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AvDriftZone {
    AudioBehind = -1,
    Stable = 0,
    AudioAhead = 1,
}

impl AvDriftZone {
    const fn as_i8(self) -> i8 {
        self as i8
    }
}

/// Pure hysteresis classifier for source-clock drift telemetry.
///
/// The policy intentionally returns a zone only; it does not alter audio,
/// video, pacing, or playback. A future scheduler-owned correction policy can
/// consume the stable zone transitions without reimplementing deadbands.
#[derive(Debug, Clone, Copy)]
pub struct AvDriftHysteresis {
    zone: AvDriftZone,
    pending_zone: Option<AvDriftZone>,
    pending_samples: u8,
    hold_samples: u8,
}

impl Default for AvDriftHysteresis {
    fn default() -> Self {
        Self::new(3)
    }
}

impl AvDriftHysteresis {
    pub const ENTER_OFFSET_MS: i64 = 80;
    pub const EXIT_OFFSET_MS: i64 = 40;
    pub const ENTER_DRIFT_PPM: i64 = 500;
    pub const EXIT_DRIFT_PPM: i64 = 250;
    pub const MAX_ABS_OFFSET_MS: i64 = 10_000;
    pub const MAX_ABS_DRIFT_PPM: i64 = 100_000;
    #[allow(dead_code)]
    pub const DEFAULT_HOLD_SAMPLES: u8 = 3;

    pub const fn new(hold_samples: u8) -> Self {
        Self {
            zone: AvDriftZone::Stable,
            pending_zone: None,
            pending_samples: 0,
            hold_samples: if hold_samples == 0 { 1 } else { hold_samples },
        }
    }

    #[allow(dead_code)]
    pub const fn zone(&self) -> AvDriftZone {
        self.zone
    }

    fn within(value: i64, limit: i64) -> bool {
        value >= -limit && value <= limit
    }

    fn entering_zone(offset_ms: i64, drift_ppm: i64) -> AvDriftZone {
        if offset_ms >= Self::ENTER_OFFSET_MS || drift_ppm >= Self::ENTER_DRIFT_PPM {
            AvDriftZone::AudioAhead
        } else if offset_ms <= -Self::ENTER_OFFSET_MS || drift_ppm <= -Self::ENTER_DRIFT_PPM {
            AvDriftZone::AudioBehind
        } else {
            AvDriftZone::Stable
        }
    }

    fn desired_zone(&self, offset_ms: i64, drift_ppm: i64) -> AvDriftZone {
        match self.zone {
            AvDriftZone::Stable => Self::entering_zone(offset_ms, drift_ppm),
            AvDriftZone::AudioAhead => {
                if offset_ms <= -Self::ENTER_OFFSET_MS || drift_ppm <= -Self::ENTER_DRIFT_PPM {
                    AvDriftZone::AudioBehind
                } else if Self::within(offset_ms, Self::EXIT_OFFSET_MS)
                    && Self::within(drift_ppm, Self::EXIT_DRIFT_PPM)
                {
                    AvDriftZone::Stable
                } else {
                    AvDriftZone::AudioAhead
                }
            }
            AvDriftZone::AudioBehind => {
                if offset_ms >= Self::ENTER_OFFSET_MS || drift_ppm >= Self::ENTER_DRIFT_PPM {
                    AvDriftZone::AudioAhead
                } else if Self::within(offset_ms, Self::EXIT_OFFSET_MS)
                    && Self::within(drift_ppm, Self::EXIT_DRIFT_PPM)
                {
                    AvDriftZone::Stable
                } else {
                    AvDriftZone::AudioBehind
                }
            }
        }
    }

    pub fn update(&mut self, offset_ms: i64, drift_ppm: i64) -> AvDriftZone {
        let offset_ms = offset_ms.clamp(-Self::MAX_ABS_OFFSET_MS, Self::MAX_ABS_OFFSET_MS);
        let drift_ppm = drift_ppm.clamp(-Self::MAX_ABS_DRIFT_PPM, Self::MAX_ABS_DRIFT_PPM);
        let desired = self.desired_zone(offset_ms, drift_ppm);
        if desired == self.zone {
            self.pending_zone = None;
            self.pending_samples = 0;
            return self.zone;
        }

        if self.pending_zone == Some(desired) {
            self.pending_samples = self.pending_samples.saturating_add(1);
        } else {
            self.pending_zone = Some(desired);
            self.pending_samples = 1;
        }

        if self.pending_samples >= self.hold_samples {
            self.zone = desired;
            self.pending_zone = None;
            self.pending_samples = 0;
        }
        self.zone
    }
}

#[derive(Default)]
struct AvClockState {
    anchor_pts_ms: Option<i64>,
    anchor_offset_ms: i64,
    drift_ppm: i64,
    hysteresis: AvDriftHysteresis,
}

impl SessionStats {
    fn to_json(&self) -> String {
        format!(
            concat!(
                "{{\"connected\":{},\"width\":{},\"height\":{},\"bitrate_bps\":{},",
                "\"ceiling_bps\":{},\"rtt_ms\":{},\"queue_delay_ms\":{},\"fps\":{},",
                "\"frames_sent\":{},\"capture_drops\":{},\"capture_sample_drops\":{},",
                "\"capture_superseded\":{},\"capture_buffered\":{},\"display_pending\":{},\"outbound_queued_packets\":{},\"outbound_queued_bytes\":{},\"outbound_enqueued_packets\":{},\"outbound_rejected_packets\":{},\"outbound_sent_packets\":{},\"outbound_sent_bytes\":{},\"display_overflow_resyncs\":{},\"capture_age_ms\":{},",
                "\"encode_latency_ms\":{},\"ship_latency_ms\":{},\"encoded_pending\":{},",
                "\"server_event_queue\":{},\"socket_write_stalls\":{},\"socket_write_ms\":{},",
                "\"audio_queue\":{},\"audio_queue_ms\":{},\"audio_drops\":{},",
                "\"audio_write_stalls\":{},\"audio_write_ms\":{},\"audio_resyncs\":{},\"audio_resync_dropped\":{},\"audio_backlog_max_ms\":{},",
                "\"capture_age_p50_ms\":{},\"capture_age_p95_ms\":{},\"capture_age_max_ms\":{},",
                "\"encode_latency_p50_ms\":{},\"encode_latency_p95_ms\":{},\"encode_latency_max_ms\":{},",
                "\"ship_latency_p50_ms\":{},\"ship_latency_p95_ms\":{},\"ship_latency_max_ms\":{},",
                "\"socket_write_p50_ms\":{},\"socket_write_p95_ms\":{},\"socket_write_max_ms\":{},",
                "\"audio_queue_p50_ms\":{},\"audio_queue_p95_ms\":{},\"audio_queue_max_ms\":{},",
                "\"audio_write_p50_ms\":{},\"audio_write_p95_ms\":{},\"audio_write_max_ms\":{},",
                "\"audio_pts_ms\":{},\"video_pts_ms\":{},\"av_offset_ms\":{},\"av_samples\":{},",
                "\"av_offset_ewma_ms\":{},\"av_offset_ewma_samples\":{},",
                "\"av_drift_ppm\":{},\"av_drift_samples\":{},\"av_drift_zone\":{},",
                "\"cpu_percent\":{},\"adaptive\":{},\"aac\":{}}}"
            ),
            self.connected.load(Ordering::Relaxed),
            self.width.load(Ordering::Relaxed),
            self.height.load(Ordering::Relaxed),
            self.bitrate_bps.load(Ordering::Relaxed),
            self.ceiling_bps.load(Ordering::Relaxed),
            self.rtt_ms.load(Ordering::Relaxed),
            self.queue_delay_ms.load(Ordering::Relaxed),
            self.fps.load(Ordering::Relaxed),
            self.frames_sent.load(Ordering::Relaxed),
            self.capture_drops.load(Ordering::Relaxed),
            self.capture_sample_drops.load(Ordering::Relaxed),
            self.capture_superseded.load(Ordering::Relaxed),
            self.capture_buffered.load(Ordering::Relaxed),
            self.display_pending.load(Ordering::Relaxed),
            self.outbound_queued_packets.load(Ordering::Relaxed),
            self.outbound_queued_bytes.load(Ordering::Relaxed),
            self.outbound_enqueued_packets.load(Ordering::Relaxed),
            self.outbound_rejected_packets.load(Ordering::Relaxed),
            self.outbound_sent_packets.load(Ordering::Relaxed),
            self.outbound_sent_bytes.load(Ordering::Relaxed),
            self.display_overflow_resyncs.load(Ordering::Relaxed),
            self.capture_age_ms.load(Ordering::Relaxed),
            self.encode_latency_ms.load(Ordering::Relaxed),
            self.ship_latency_ms.load(Ordering::Relaxed),
            self.encoded_pending.load(Ordering::Relaxed),
            self.server_event_queue.load(Ordering::Relaxed),
            self.socket_write_stalls.load(Ordering::Relaxed),
            self.socket_write_ms.load(Ordering::Relaxed),
            self.audio_queue.load(Ordering::Relaxed),
            self.audio_queue_ms.load(Ordering::Relaxed),
            self.audio_drops.load(Ordering::Relaxed),
            self.audio_write_stalls.load(Ordering::Relaxed),
            self.audio_write_ms.load(Ordering::Relaxed),
            self.audio_resyncs.load(Ordering::Relaxed),
            self.audio_resync_dropped.load(Ordering::Relaxed),
            self.audio_backlog_max_ms.load(Ordering::Relaxed),
            self.capture_age_p50_ms.load(Ordering::Relaxed),
            self.capture_age_p95_ms.load(Ordering::Relaxed),
            self.capture_age_max_ms.load(Ordering::Relaxed),
            self.encode_latency_p50_ms.load(Ordering::Relaxed),
            self.encode_latency_p95_ms.load(Ordering::Relaxed),
            self.encode_latency_max_ms.load(Ordering::Relaxed),
            self.ship_latency_p50_ms.load(Ordering::Relaxed),
            self.ship_latency_p95_ms.load(Ordering::Relaxed),
            self.ship_latency_max_ms.load(Ordering::Relaxed),
            self.socket_write_p50_ms.load(Ordering::Relaxed),
            self.socket_write_p95_ms.load(Ordering::Relaxed),
            self.socket_write_max_ms.load(Ordering::Relaxed),
            self.audio_queue_p50_ms.load(Ordering::Relaxed),
            self.audio_queue_p95_ms.load(Ordering::Relaxed),
            self.audio_queue_max_ms.load(Ordering::Relaxed),
            self.audio_write_p50_ms.load(Ordering::Relaxed),
            self.audio_write_p95_ms.load(Ordering::Relaxed),
            self.audio_write_max_ms.load(Ordering::Relaxed),
            self.audio_pts_ms.load(Ordering::Relaxed),
            self.video_pts_ms.load(Ordering::Relaxed),
            self.av_offset_ms.load(Ordering::Relaxed),
            self.av_samples.load(Ordering::Relaxed),
            self.av_offset_ewma_ms.load(Ordering::Relaxed),
            self.av_offset_ewma_samples.load(Ordering::Relaxed),
            self.av_drift_ppm.load(Ordering::Relaxed),
            self.av_drift_samples.load(Ordering::Relaxed),
            self.av_drift_zone.load(Ordering::Relaxed),
            self.cpu_percent.load(Ordering::Relaxed),
            self.adaptive.load(Ordering::Relaxed),
            self.aac.load(Ordering::Relaxed),
        )
    }
}

static GLOBAL: OnceLock<Arc<SessionStats>> = OnceLock::new();
static DIAGNOSTICS: OnceLock<ironrdp_server::DiagnosticsHandle> = OnceLock::new();

/// Turn telemetry on: create (idempotently) the shared snapshot and return it.
/// Called once from `main.rs` when the endpoint is enabled.
pub fn enable() -> Arc<SessionStats> {
    GLOBAL
        .get_or_init(|| Arc::new(SessionStats::default()))
        .clone()
}

/// The shared snapshot iff telemetry is enabled, else `None`. Hot-path update
/// sites do `if let Some(s) = stats::global() { … }`, a no-op when off.
#[inline]
pub fn global() -> Option<&'static Arc<SessionStats>> {
    GLOBAL.get()
}

pub fn set_diagnostics(handle: ironrdp_server::DiagnosticsHandle) {
    let _ = DIAGNOSTICS.set(handle);
}

pub fn diagnostics() -> Option<&'static ironrdp_server::DiagnosticsHandle> {
    DIAGNOSTICS.get()
}

/// Fold one source-clock offset into an EWMA. This pure update keeps initial
/// offset and ongoing jitter visible without changing playback.
pub fn record_av_offset(offset_ms: i64) {
    let Some(stats) = global() else { return };
    let old = stats.av_offset_ewma_ms.load(Ordering::Relaxed);
    let samples = stats.av_offset_ewma_samples.load(Ordering::Relaxed);
    let next = if samples == 0 {
        offset_ms
    } else {
        // alpha = 1/8: stable enough for a 60/43 Hz pair, responsive to drift.
        old.saturating_add((offset_ms.saturating_sub(old)) / 8)
    };
    stats.av_offset_ewma_ms.store(next, Ordering::Relaxed);
    stats.av_offset_ewma_samples.fetch_add(1, Ordering::Relaxed);
}

/// Record synchronized source PTS pair and estimate long-term clock drift.
/// This is telemetry-only: no resampling or playback correction occurs here.
pub fn record_av_clock_pair(audio_pts_ms: i64, video_pts_ms: i64) {
    let Some(stats) = global() else { return };
    let offset_ms = audio_pts_ms.saturating_sub(video_pts_ms);
    let Ok(mut clock) = stats.av_clock.state.lock() else {
        return;
    };
    if let Some(anchor) = clock.anchor_pts_ms {
        let elapsed = video_pts_ms.saturating_sub(anchor);
        if elapsed >= 1_000 {
            let offset_delta = offset_ms.saturating_sub(clock.anchor_offset_ms);
            // offset_delta / elapsed is fractional clock error; ppm = ×1e6.
            let instant_ppm = offset_delta.saturating_mul(1_000_000) / elapsed;
            clock.drift_ppm = clock
                .drift_ppm
                .saturating_add((instant_ppm.saturating_sub(clock.drift_ppm)) / 8);
            stats.av_drift_ppm.store(clock.drift_ppm, Ordering::Relaxed);
            let drift_ppm = clock.drift_ppm;
            let zone = clock.hysteresis.update(offset_ms, drift_ppm);
            stats.av_drift_zone.store(zone.as_i8(), Ordering::Relaxed);
            stats.av_drift_samples.fetch_add(1, Ordering::Relaxed);
            clock.anchor_pts_ms = Some(video_pts_ms);
            clock.anchor_offset_ms = offset_ms;
        }
    } else {
        clock.anchor_pts_ms = Some(video_pts_ms);
        clock.anchor_offset_ms = offset_ms;
    }
}

fn publish_window(
    window: &ironrdp_server::LatencyWindow,
    p50: &AtomicU32,
    p95: &AtomicU32,
    max: &AtomicU32,
) {
    let (a, b, c) = window.percentiles();
    p50.store(a, Ordering::Relaxed);
    p95.store(b, Ordering::Relaxed);
    max.store(c, Ordering::Relaxed);
}

pub fn publish_latency_windows() {
    let Some(diag) = diagnostics() else { return };
    let Some(stats) = global() else { return };
    publish_window(
        &diag.capture_age_window,
        &stats.capture_age_p50_ms,
        &stats.capture_age_p95_ms,
        &stats.capture_age_max_ms,
    );
    publish_window(
        &diag.encode_latency_window,
        &stats.encode_latency_p50_ms,
        &stats.encode_latency_p95_ms,
        &stats.encode_latency_max_ms,
    );
    publish_window(
        &diag.ship_latency_window,
        &stats.ship_latency_p50_ms,
        &stats.ship_latency_p95_ms,
        &stats.ship_latency_max_ms,
    );
    publish_window(
        &diag.socket_write_window,
        &stats.socket_write_p50_ms,
        &stats.socket_write_p95_ms,
        &stats.socket_write_max_ms,
    );
    publish_window(
        &diag.audio_queue_window,
        &stats.audio_queue_p50_ms,
        &stats.audio_queue_p95_ms,
        &stats.audio_queue_max_ms,
    );
    publish_window(
        &diag.audio_write_window,
        &stats.audio_write_p50_ms,
        &stats.audio_write_p95_ms,
        &stats.audio_write_max_ms,
    );
}

/// Sample macOS process CPU without adding work to capture, encode, or socket
/// paths. Value is aggregate CPU percentage (100 = one fully busy core).
#[cfg(target_os = "macos")]
pub fn spawn_cpu_sampler() {
    let Some(stats) = global().cloned() else {
        return;
    };
    tokio::spawn(async move {
        let mut previous = process_cpu_snapshot();
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(2));
        ticker.tick().await;
        loop {
            ticker.tick().await;
            publish_latency_windows();
            let current = process_cpu_snapshot();
            let wall_ns = current.wall_ns.saturating_sub(previous.wall_ns);
            let cpu_ns = current.cpu_ns.saturating_sub(previous.cpu_ns);
            if wall_ns > 0 {
                let percent = cpu_ns
                    .saturating_mul(100)
                    .checked_div(wall_ns)
                    .unwrap_or(0)
                    .min(u64::from(u32::MAX));
                stats.cpu_percent.store(percent as u32, Ordering::Relaxed);
            }
            previous = current;
        }
    });
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy)]
struct CpuSnapshot {
    cpu_ns: u64,
    wall_ns: u64,
}

#[cfg(target_os = "macos")]
fn process_cpu_snapshot() -> CpuSnapshot {
    use std::mem::MaybeUninit;
    use std::time::Instant;

    let mut usage = MaybeUninit::<libc::rusage>::zeroed();
    let rc = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    let cpu_ns = if rc == 0 {
        let usage = unsafe { usage.assume_init() };
        let timeval_ns = |time: libc::timeval| -> u64 {
            time.tv_sec.max(0) as u64 * 1_000_000_000 + time.tv_usec.max(0) as u64 * 1_000
        };
        timeval_ns(usage.ru_utime).saturating_add(timeval_ns(usage.ru_stime))
    } else {
        0
    };
    static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let start = START.get_or_init(Instant::now);
    CpuSnapshot {
        cpu_ns,
        wall_ns: start.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64,
    }
}

/// Endpoint port (`MACRDP_STATS_PORT`, default 40245 — next after the shield
/// helper's 40244).
pub fn default_port() -> u16 {
    std::env::var("MACRDP_STATS_PORT")
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(40245)
}

/// Serve the snapshot on `127.0.0.1:port`, one JSON line per connection, until
/// the process exits. Read-only; the request body (if any) is ignored.
pub async fn serve(port: u16, stats: Arc<SessionStats>) {
    use tokio::io::AsyncWriteExt;
    let listener = match tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await {
        Ok(l) => l,
        Err(e) => {
            tracing::warn!(port, error = %e, "stats endpoint: bind failed — live telemetry unavailable");
            return;
        }
    };
    tracing::info!(port, "stats endpoint listening (loopback, read-only)");
    loop {
        match listener.accept().await {
            Ok((mut sock, _)) => {
                let body = stats.to_json();
                // Handle inline (no per-connection task spawn) so a local process
                // that hammers the port can't spawn unbounded tasks; the response
                // is a couple hundred bytes to a loopback socket, so serializing
                // one poll every ~2 s is fine. A short timeout keeps a client that
                // connects but never reads from wedging the accept loop.
                let _ = tokio::time::timeout(std::time::Duration::from_secs(2), async {
                    let _ = sock.write_all(body.as_bytes()).await;
                    let _ = sock.write_all(b"\n").await;
                    let _ = sock.shutdown().await;
                })
                .await;
            }
            Err(e) => tracing::debug!(error = %e, "stats endpoint: accept error"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_shape_is_stable_and_parseable() {
        let s = SessionStats::default();
        s.connected.store(true, Ordering::Relaxed);
        s.width.store(1920, Ordering::Relaxed);
        s.height.store(1080, Ordering::Relaxed);
        s.bitrate_bps.store(4_000_000, Ordering::Relaxed);
        s.fps.store(60, Ordering::Relaxed);
        let j = s.to_json();
        // Spot-check a few fields + that it's a single line with the expected keys.
        assert!(j.starts_with('{') && j.ends_with('}'));
        assert!(!j.contains('\n'));
        assert!(j.contains("\"connected\":true"));
        assert!(j.contains("\"width\":1920"));
        assert!(j.contains("\"bitrate_bps\":4000000"));
        assert!(j.contains("\"fps\":60"));
        assert!(j.contains("\"audio_resyncs\":0"));
        assert!(j.contains("\"outbound_queued_packets\":0"));
        assert!(j.contains("\"outbound_queued_bytes\":0"));
        assert!(j.contains("\"outbound_enqueued_packets\":0"));
        assert!(j.contains("\"outbound_rejected_packets\":0"));
        assert!(j.contains("\"outbound_sent_packets\":0"));
        assert!(j.contains("\"outbound_sent_bytes\":0"));
        assert!(j.contains("\"audio_resync_dropped\":0"));
        assert!(j.contains("\"audio_backlog_max_ms\":0"));
        assert!(j.contains("\"av_drift_samples\":0"));
        assert!(j.contains("\"av_drift_zone\":0"));
    }

    #[test]
    fn audio_resync_stats_are_serialized() {
        let s = SessionStats::default();
        s.audio_resyncs.store(3, Ordering::Relaxed);
        s.audio_resync_dropped.store(7, Ordering::Relaxed);
        s.audio_backlog_max_ms.store(281, Ordering::Relaxed);
        let j = s.to_json();
        assert!(j.contains("\"audio_resyncs\":3"));
        assert!(j.contains("\"audio_resync_dropped\":7"));
        assert!(j.contains("\"audio_backlog_max_ms\":281"));
    }

    #[test]
    fn drift_hysteresis_requires_hold_samples_and_deadband_exit() {
        let mut h = AvDriftHysteresis::new(2);
        assert_eq!(h.update(90, 0), AvDriftZone::Stable);
        assert_eq!(h.update(90, 0), AvDriftZone::AudioAhead);
        assert_eq!(h.update(45, 0), AvDriftZone::AudioAhead);
        assert_eq!(h.update(39, 0), AvDriftZone::AudioAhead);
        assert_eq!(h.update(39, 0), AvDriftZone::Stable);
    }

    #[test]
    fn drift_hysteresis_requires_ppm_hold() {
        let mut h = AvDriftHysteresis::default();
        assert_eq!(h.update(0, 600), AvDriftZone::Stable);
        assert_eq!(h.update(0, 600), AvDriftZone::Stable);
        assert_eq!(h.update(0, 600), AvDriftZone::AudioAhead);
    }

    #[test]
    fn drift_hysteresis_clamps_pathological_values() {
        let mut h = AvDriftHysteresis::new(1);
        assert_eq!(h.update(i64::MAX, i64::MAX), AvDriftZone::AudioAhead);
        assert_eq!(h.update(i64::MIN, i64::MIN), AvDriftZone::AudioBehind);
    }

    #[test]
    fn global_is_none_until_enabled() {
        // NB: process-global; if another test enables it this may already be Some.
        // We only assert the accessor doesn't panic and the enabled snapshot is shared.
        let a = enable();
        let b = global().expect("enabled");
        assert!(Arc::ptr_eq(&a, b));
    }

    #[test]
    fn latency_window_reports_expected_percentiles() {
        let window = ironrdp_server::LatencyWindow::default();
        for value in 1..=100 {
            window.record(value);
        }
        assert_eq!(window.percentiles(), (50, 95, 100));
    }

    #[test]
    fn av_clock_drift_estimator_tracks_positive_slope() {
        let stats = Arc::new(SessionStats::default());
        let _ = GLOBAL.set(Arc::clone(&stats));
        stats.av_samples.store(1, Ordering::Relaxed);
        record_av_clock_pair(1000, 1000);
        record_av_clock_pair(2010, 2000);
        assert!(stats.av_drift_ppm.load(Ordering::Relaxed) > 0);
    }
}
