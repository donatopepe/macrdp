pub use ironrdp_rdpsnd::server::{RdpsndServerHandler, RdpsndServerMessage};

use std::collections::VecDeque;
use std::fmt;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tokio::sync::Notify;

use crate::ServerEventSender;

/// One captured audio chunk en route to the client: encoded audio bytes
/// in the negotiated format (16-bit stereo interleaved PCM at 44.1 kHz,
/// or a single AAC-LC access unit) plus the source-side timestamp in ms,
/// plus the chunk's playback duration in ms. Carried on a dedicated
/// bounded channel separate from the unified `ServerEvent` stream so the
/// server's audio dispatch can run independently of inbound-PDU and
/// outbound-event dispatch, avoiding the multi-second audio starvation
/// that happens when inbound cliprdr chunks monopolize the per-connection
/// `Mutex<Self>` (e.g., during a large `--lazy-paste` Windows→Mac transfer).
///
/// The third element is the chunk's duration in ms, or `None` to have the
/// dispatcher derive it from the byte length assuming uncompressed PCM
/// (`BYTES_PER_MS`). A compressed codec (AAC) MUST set it explicitly: its
/// byte length bears no fixed relationship to playback time, so the
/// PCM-bytes-to-ms assumption in the audio-lag model would collapse.
pub type AudioWave = (Vec<u8>, u32, Option<f64>);

/// Result of inserting one wave into bounded audio jitter buffer.
#[derive(Debug)]
pub enum AudioWaveSendError {
    Closed(AudioWave),
}

struct AudioWaveQueueInner {
    queue: Mutex<VecDeque<AudioWave>>,
    capacity: usize,
    notify: Notify,
    sender_count: AtomicUsize,
    receiver_alive: AtomicBool,
    dropped: AtomicU64,
}

/// Producer handle for audio jitter buffer. Synchronous by design: capture
/// thread never awaits full queue. Full queue drops oldest wave, keeps newest.
pub struct AudioWaveSender {
    inner: Arc<AudioWaveQueueInner>,
}

impl fmt::Debug for AudioWaveSender {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AudioWaveSender")
            .field("len", &self.len())
            .field("capacity", &self.capacity())
            .finish()
    }
}

impl AudioWaveSender {
    pub fn try_send(&self, wave: AudioWave) -> Result<bool, AudioWaveSendError> {
        if !self.inner.receiver_alive.load(Ordering::Acquire) {
            return Err(AudioWaveSendError::Closed(wave));
        }
        let mut queue = self.inner.queue.lock().expect("audio queue mutex poisoned");
        if !self.inner.receiver_alive.load(Ordering::Acquire) {
            return Err(AudioWaveSendError::Closed(wave));
        }
        let dropped = if queue.len() >= self.inner.capacity {
            queue.pop_front();
            self.inner.dropped.fetch_add(1, Ordering::Relaxed);
            true
        } else {
            false
        };
        queue.push_back(wave);
        drop(queue);
        self.inner.notify.notify_one();
        Ok(dropped)
    }

    pub fn len(&self) -> usize {
        self.inner.queue.lock().expect("audio queue mutex poisoned").len()
    }

    pub fn capacity(&self) -> usize {
        self.inner.capacity
    }

    pub fn dropped(&self) -> u64 {
        self.inner.dropped.load(Ordering::Relaxed)
    }
}

impl Clone for AudioWaveSender {
    fn clone(&self) -> Self {
        self.inner.sender_count.fetch_add(1, Ordering::Relaxed);
        Self {
            inner: Arc::clone(&self.inner),
        }
    }
}

impl Drop for AudioWaveSender {
    fn drop(&mut self) {
        if self.inner.sender_count.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.inner.notify.notify_waiters();
        }
    }
}

pub struct AudioWaveReceiver {
    inner: Arc<AudioWaveQueueInner>,
}

impl AudioWaveReceiver {
    pub async fn recv(&mut self) -> Option<AudioWave> {
        loop {
            let notified = self.inner.notify.notified();
            if let Some(wave) = self.inner.queue.lock().expect("audio queue mutex poisoned").pop_front() {
                return Some(wave);
            }
            if self.inner.sender_count.load(Ordering::Acquire) == 0 {
                return None;
            }
            notified.await;
        }
    }

    pub fn clear(&mut self) {
        self.inner.queue.lock().expect("audio queue mutex poisoned").clear();
    }

    pub fn queued_snapshot(&self) -> Vec<AudioWave> {
        self.inner
            .queue
            .lock()
            .expect("audio queue mutex poisoned")
            .iter()
            .cloned()
            .collect()
    }

    pub fn len(&self) -> usize {
        self.inner.queue.lock().expect("audio queue mutex poisoned").len()
    }

    pub fn queued_duration_ms(&self) -> f64 {
        self.inner
            .queue
            .lock()
            .expect("audio queue mutex poisoned")
            .iter()
            .map(|(data, _, duration)| duration.unwrap_or_else(|| data.len() as f64 / 176.4))
            .sum()
    }

    pub fn dropped(&self) -> u64 {
        self.inner.dropped.load(Ordering::Relaxed)
    }

    /// Remove oldest waves until queued duration is below `max_ms`.
    ///
    /// Used only by an explicit audio resync policy. Normal playback path
    /// remains unchanged when caller does not invoke it.
    pub fn drop_oldest_until_below(&mut self, max_ms: f64) -> usize {
        let mut queue = self.inner.queue.lock().expect("audio queue mutex poisoned");
        let mut dropped = 0;
        let mut queued_ms: f64 = queue
            .iter()
            .map(|(data, _, duration)| duration.unwrap_or_else(|| data.len() as f64 / 176.4))
            .sum();
        while queued_ms > max_ms {
            let Some((data, _, duration)) = queue.pop_front() else {
                break;
            };
            queued_ms -= duration.unwrap_or_else(|| data.len() as f64 / 176.4);
            dropped += 1;
        }
        if dropped > 0 {
            self.inner.dropped.fetch_add(dropped as u64, Ordering::Relaxed);
        }
        dropped
    }
}

impl Drop for AudioWaveReceiver {
    fn drop(&mut self) {
        self.inner.receiver_alive.store(false, Ordering::Release);
        self.inner.notify.notify_waiters();
    }
}

/// Capacity 16 is roughly 350 ms at 44.1-kHz AAC waves. It absorbs short
/// socket bursts without permitting multi-second stale audio.
pub fn audio_wave_channel(capacity: usize) -> (AudioWaveSender, AudioWaveReceiver) {
    assert!(capacity > 0, "audio queue capacity must be non-zero");
    let inner = Arc::new(AudioWaveQueueInner {
        queue: Mutex::new(VecDeque::with_capacity(capacity)),
        capacity,
        notify: Notify::new(),
        sender_count: AtomicUsize::new(1),
        receiver_alive: AtomicBool::new(true),
        dropped: AtomicU64::new(0),
    });
    (
        AudioWaveSender {
            inner: Arc::clone(&inner),
        },
        AudioWaveReceiver { inner },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn receiver_drops_oldest_until_duration_bound() {
        let (sender, mut receiver) = audio_wave_channel(8);
        for id in 0..3 {
            sender.try_send((vec![id], u32::from(id), Some(100.0))).unwrap();
        }

        assert_eq!(receiver.drop_oldest_until_below(150.0), 2);
        assert_eq!(receiver.queued_duration_ms(), 100.0);
        assert_eq!(receiver.dropped(), 2);
        assert_eq!(receiver.recv().await.unwrap().0, vec![2]);
    }

    #[tokio::test]
    async fn receiver_keeps_queue_when_already_below_bound() {
        let (sender, mut receiver) = audio_wave_channel(4);
        sender.try_send((vec![1], 0, Some(40.0))).unwrap();
        assert_eq!(receiver.drop_oldest_until_below(40.0), 0);
        assert_eq!(receiver.dropped(), 0);
        assert_eq!(receiver.recv().await.unwrap().0, vec![1]);
    }
}

pub trait SoundServerFactory: ServerEventSender {
    fn build_backend(&self) -> Box<dyn RdpsndServerHandler>;

    /// Dedicated bounded newest-first audio jitter buffer. Full queue drops
    /// oldest wave instead of blocking ScreenCaptureKit.
    fn set_audio_sender(&mut self, _audio_sender: AudioWaveSender) {}
}
