//! Deterministic outbound scheduling primitives.
//!
//! This module is the first step toward a single-owner RDP socket writer. It
//! deliberately does not touch the live `client_loop` yet: callers can test
//! queue ordering and fairness before wiring any cancellation-sensitive
//! `FramedWrite::write_all` path to it.
//!
//! Invariants:
//! - each traffic class is FIFO;
//! - EGFX packets are never dropped or reordered by scheduler;
//! - audio/control get urgent service, but a bounded burst yields to data;
//! - queue capacity rejects packets instead of silently dropping wire data.

use std::collections::VecDeque;
use std::io;

use ironrdp_async::FramedWrite;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::mpsc;

/// Outbound traffic class. Ordering is FIFO within each class; scheduler policy
/// only decides which class gets next service.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutboundClass {
    Control,
    Audio,
    Clipboard,
    Egfx,
    Display,
    Bulk,
}

impl OutboundClass {
    pub const ALL: [Self; 6] = [
        Self::Control,
        Self::Audio,
        Self::Clipboard,
        Self::Egfx,
        Self::Display,
        Self::Bulk,
    ];

    const DATA_SLOTS: [Self; 8] = [
        Self::Clipboard,
        Self::Egfx,
        Self::Egfx,
        Self::Egfx,
        Self::Display,
        Self::Display,
        Self::Bulk,
        Self::Bulk,
    ];

    const fn index(self) -> usize {
        match self {
            Self::Control => 0,
            Self::Audio => 1,
            Self::Clipboard => 2,
            Self::Egfx => 3,
            Self::Display => 4,
            Self::Bulk => 5,
        }
    }
}

/// One complete wire buffer. Scheduler never splits or mutates `bytes`.
#[derive(Debug, PartialEq, Eq)]
pub struct OutboundPacket {
    pub class: OutboundClass,
    pub bytes: Vec<u8>,
}

impl OutboundPacket {
    pub fn new(class: OutboundClass, bytes: Vec<u8>) -> Self {
        Self { class, bytes }
    }

    pub fn len(&self) -> usize {
        self.bytes.len()
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum EnqueueError {
    QueueFull(OutboundPacket),
}

/// Current queue occupancy for one typed outbound class.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OutboundClassStats {
    pub packets: usize,
    pub bytes: usize,
}

/// Snapshot suitable for opt-in scheduler telemetry.
///
/// Counters are cumulative since the scheduler was created; queue occupancy is
/// instantaneous. The snapshot contains no socket or framing state and can be
/// collected without changing packet selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutboundSchedulerSnapshot {
    pub queued_packets: usize,
    pub queued_bytes: usize,
    pub classes: [OutboundClassStats; 6],
    pub enqueued_packets: u64,
    pub rejected_packets: u64,
    pub sent_packets: u64,
    pub sent_bytes: u64,
    pub audio_dropped_packets: u64,
    pub audio_dropped_bytes: u64,
}

/// Result of an audio admission check performed before the caller frames the
/// audio wave. `DroppedBeforeFraming` is an intentional stale-audio drop, not
/// a wire-buffer rejection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AudioEnqueue {
    Enqueued,
    DroppedBeforeFraming { estimated_bytes: usize },
}

impl AudioEnqueue {
    pub const fn was_dropped(self) -> bool {
        matches!(self, Self::DroppedBeforeFraming { .. })
    }

    pub const fn estimated_bytes(self) -> Option<usize> {
        match self {
            Self::Enqueued => None,
            Self::DroppedBeforeFraming { estimated_bytes } => Some(estimated_bytes),
        }
    }
}

/// Single-thread-owned scheduler state. Move it into future socket-owner task;
/// no mutex is needed inside that task. `MAX_URGENT_BURST` bounds audio/control
/// priority so a steady stream cannot starve EGFX or display updates.
pub struct OutboundScheduler {
    queues: [VecDeque<OutboundPacket>; 6],
    class_bytes: [usize; 6],
    queued_bytes: usize,
    max_bytes: usize,
    data_cursor: usize,
    urgent_remaining: usize,
    /// Rolling queue metrics for the future socket owner. Counters stay local
    /// to scheduler state so live wiring can publish atomics without changing
    /// packet selection semantics.
    enqueued_packets: u64,
    rejected_packets: u64,
    sent_packets: u64,
    sent_bytes: u64,
    audio_dropped_packets: u64,
    audio_dropped_bytes: u64,
}

impl OutboundScheduler {
    pub const MAX_URGENT_BURST: usize = 8;
    /// Bound one same-class write so coalescing cannot monopolize the socket.
    pub const MAX_COALESCED_BYTES: usize = 64 * 1024;

    pub fn new(max_bytes: usize) -> Self {
        Self {
            queues: std::array::from_fn(|_| VecDeque::new()),
            class_bytes: [0; 6],
            queued_bytes: 0,
            max_bytes,
            data_cursor: 0,
            urgent_remaining: Self::MAX_URGENT_BURST,
            enqueued_packets: 0,
            rejected_packets: 0,
            sent_packets: 0,
            sent_bytes: 0,
            audio_dropped_packets: 0,
            audio_dropped_bytes: 0,
        }
    }

    pub fn max_bytes(&self) -> usize {
        self.max_bytes
    }

    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes
    }

    pub fn len(&self) -> usize {
        self.queues.iter().map(VecDeque::len).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.queued_bytes == 0
    }

    pub fn class_len(&self, class: OutboundClass) -> usize {
        self.queues[class.index()].len()
    }

    pub fn class_stats(&self, class: OutboundClass) -> OutboundClassStats {
        OutboundClassStats {
            packets: self.class_len(class),
            bytes: self.class_bytes[class.index()],
        }
    }

    pub fn snapshot(&self) -> OutboundSchedulerSnapshot {
        OutboundSchedulerSnapshot {
            queued_packets: self.len(),
            queued_bytes: self.queued_bytes,
            classes: std::array::from_fn(|index| self.class_stats(OutboundClass::ALL[index])),
            enqueued_packets: self.enqueued_packets,
            rejected_packets: self.rejected_packets,
            sent_packets: self.sent_packets,
            sent_bytes: self.sent_bytes,
            audio_dropped_packets: self.audio_dropped_packets,
            audio_dropped_bytes: self.audio_dropped_bytes,
        }
    }

    pub fn enqueued_packets(&self) -> u64 {
        self.enqueued_packets
    }

    pub fn rejected_packets(&self) -> u64 {
        self.rejected_packets
    }

    pub fn sent_packets(&self) -> u64 {
        self.sent_packets
    }

    pub fn sent_bytes(&self) -> u64 {
        self.sent_bytes
    }

    pub fn audio_dropped_packets(&self) -> u64 {
        self.audio_dropped_packets
    }

    pub fn audio_dropped_bytes(&self) -> u64 {
        self.audio_dropped_bytes
    }

    pub fn queued_bytes_for_class(&self, class: OutboundClass) -> usize {
        self.class_bytes[class.index()]
    }

    pub fn queued_packets_for_class(&self, class: OutboundClass) -> usize {
        self.class_len(class)
    }

    pub fn class_snapshot(&self, class: OutboundClass) -> OutboundClassStats {
        self.class_stats(class)
    }

    pub fn is_packet_within_budget(&self, packet: &OutboundPacket) -> bool {
        packet.len() <= self.max_bytes && self.has_capacity_for(packet.len())
    }

    pub fn has_capacity_for_class(&self, bytes: usize) -> bool {
        self.has_capacity_for(bytes)
    }

    fn has_capacity_for(&self, bytes: usize) -> bool {
        bytes <= self.max_bytes.saturating_sub(self.queued_bytes)
    }

    fn record_audio_drop(&mut self, estimated_bytes: usize) {
        self.audio_dropped_packets = self.audio_dropped_packets.saturating_add(1);
        self.audio_dropped_bytes = self.audio_dropped_bytes.saturating_add(estimated_bytes as u64);
    }

    /// Enqueue one complete wire buffer. Full queue returns packet to caller;
    /// this is intentional: audio may be dropped before framing, while EGFX
    /// must apply backpressure rather than silently lose a reference frame.
    pub fn try_push(&mut self, packet: OutboundPacket) -> Result<(), EnqueueError> {
        if packet.class == OutboundClass::Audio {
            debug_assert!(
                packet.len() <= self.max_bytes,
                "audio should be admitted with try_push_audio before framing"
            );
        }
        if !self.has_capacity_for(packet.len()) {
            self.rejected_packets = self.rejected_packets.saturating_add(1);
            return Err(EnqueueError::QueueFull(packet));
        }
        self.enqueued_packets = self.enqueued_packets.saturating_add(1);
        self.queued_bytes += packet.len();
        self.class_bytes[packet.class.index()] += packet.len();
        self.queues[packet.class.index()].push_back(packet);
        Ok(())
    }

    /// Admit audio before framing it.
    ///
    /// `upper_bound_bytes` must conservatively cover the complete wire buffer
    /// produced by `build`. If the current byte budget cannot accommodate that
    /// upper bound, `build` is not called and the wave is dropped before any
    /// RDP framing/encoding work. If the bound is wrong, the normal
    /// `QueueFull` error returns the built packet so the caller can handle the
    /// programming error explicitly rather than silently losing it.
    pub fn try_push_audio<F>(&mut self, upper_bound_bytes: usize, build: F) -> Result<AudioEnqueue, EnqueueError>
    where
        F: FnOnce() -> Vec<u8>,
    {
        if !self.has_capacity_for(upper_bound_bytes) {
            self.record_audio_drop(upper_bound_bytes);
            return Ok(AudioEnqueue::DroppedBeforeFraming {
                estimated_bytes: upper_bound_bytes,
            });
        }

        let packet = OutboundPacket::new(OutboundClass::Audio, build());
        self.try_push(packet)?;
        Ok(AudioEnqueue::Enqueued)
    }

    fn pop_class(&mut self, class: OutboundClass) -> Option<OutboundPacket> {
        let packet = self.queues[class.index()].pop_front()?;
        self.queued_bytes = self.queued_bytes.saturating_sub(packet.len());
        self.class_bytes[class.index()] = self.class_bytes[class.index()].saturating_sub(packet.len());
        self.sent_packets = self.sent_packets.saturating_add(1);
        self.sent_bytes = self.sent_bytes.saturating_add(packet.len() as u64);
        Some(packet)
    }

    fn has_data(&self) -> bool {
        OutboundClass::DATA_SLOTS
            .iter()
            .any(|class| !self.queues[class.index()].is_empty())
    }

    fn pop_data(&mut self) -> Option<OutboundPacket> {
        for _ in 0..OutboundClass::DATA_SLOTS.len() {
            let class = OutboundClass::DATA_SLOTS[self.data_cursor];
            self.data_cursor = (self.data_cursor + 1) % OutboundClass::DATA_SLOTS.len();
            if let Some(packet) = self.pop_class(class) {
                return Some(packet);
            }
        }
        None
    }

    /// Select next packet. Control/audio receive bounded urgent priority;
    /// data classes use weighted round-robin slots (EGFX gets 3/8 slots).
    pub fn pop_next(&mut self) -> Option<OutboundPacket> {
        let urgent_available = !self.queues[OutboundClass::Control.index()].is_empty()
            || !self.queues[OutboundClass::Audio.index()].is_empty();
        if urgent_available && (self.urgent_remaining > 0 || !self.has_data()) {
            if let Some(packet) = self.pop_class(OutboundClass::Control) {
                self.urgent_remaining -= 1;
                return Some(packet);
            }
            if let Some(packet) = self.pop_class(OutboundClass::Audio) {
                self.urgent_remaining -= 1;
                return Some(packet);
            }
        }

        if let Some(packet) = self.pop_data() {
            self.urgent_remaining = Self::MAX_URGENT_BURST;
            return Some(packet);
        }

        // No data is waiting, so urgent traffic must not wait for a fairness
        // slot. Reset budget for the next mixed burst.
        self.urgent_remaining = Self::MAX_URGENT_BURST;
        self.pop_class(OutboundClass::Control)
            .or_else(|| self.pop_class(OutboundClass::Audio))
    }

    fn coalesce_same_class(&mut self, mut packet: OutboundPacket) -> OutboundPacket {
        while packet.len() < Self::MAX_COALESCED_BYTES {
            let Some(next) = self.queues[packet.class.index()].front() else {
                break;
            };
            if packet.len().saturating_add(next.len()) > Self::MAX_COALESCED_BYTES {
                break;
            }
            let next = self
                .pop_class(packet.class)
                .expect("same-class queue front disappeared");
            packet.bytes.extend(next.bytes);
        }
        packet
    }

    /// Select and coalesce consecutive output buffers of the selected class.
    ///
    /// Coalescing happens only after the normal scheduler decision, so it
    /// cannot change class fairness. It concatenates complete buffers without
    /// changing their byte order; in particular, EGFX reference ordering is
    /// preserved. The 64 KiB bound keeps a busy class from monopolizing the
    /// socket owner.
    pub fn pop_next_coalesced(&mut self) -> Option<OutboundPacket> {
        self.pop_next().map(|packet| self.coalesce_same_class(packet))
    }
}

/// Single-owner adapter for complete outbound wire buffers.
///
/// This type is intentionally not wired into `client_loop` yet. It provides
/// the handoff boundary needed for that migration: one owner selects a packet,
/// keeps its complete buffer alive, and awaits exactly one `write_all` call.
/// On write failure the connection owner must stop; this adapter never retries
/// or requeues a partially written buffer.
pub struct OutboundOwner<W> {
    scheduler: OutboundScheduler,
    writer: W,
}

/// Producer-side handoff for the single socket owner.
///
/// The channel is bounded by packet count. The owner applies the stricter
/// complete-buffer byte budget before a packet reaches the writer; non-audio
/// callers must retain/backpressure a `TrySendError::Full` packet rather than
/// silently dropping it.
#[derive(Debug)]
enum AdmissionError {
    TooLarge(OutboundPacket),
    QueueFull(OutboundPacket),
}

#[derive(Clone)]
pub struct OutboundOwnerIngress {
    sender: mpsc::Sender<OutboundPacket>,
    enqueued_packets: std::sync::Arc<AtomicU64>,
    rejected_packets: std::sync::Arc<AtomicU64>,
}

impl OutboundOwnerIngress {
    pub async fn send(&self, packet: OutboundPacket) -> Result<(), mpsc::error::SendError<OutboundPacket>> {
        match self.sender.send(packet).await {
            Ok(()) => {
                self.enqueued_packets.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(error) => {
                self.rejected_packets.fetch_add(1, Ordering::Relaxed);
                Err(error)
            }
        }
    }

    pub fn try_send(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        match self.sender.try_send(packet) {
            Ok(()) => {
                self.enqueued_packets.fetch_add(1, Ordering::Relaxed);
                Ok(())
            }
            Err(error) => {
                self.rejected_packets.fetch_add(1, Ordering::Relaxed);
                Err(error)
            }
        }
    }

    pub fn enqueued_packets(&self) -> u64 {
        self.enqueued_packets.load(Ordering::Relaxed)
    }

    pub fn rejected_packets(&self) -> u64 {
        self.rejected_packets.load(Ordering::Relaxed)
    }

    /// Audio admission performed before wire framing. This sends only an
    /// already-built complete packet; callers needing pre-framing drops should
    /// use the owner scheduler's `try_push_audio` while the owner is local.
    pub fn try_send_audio(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Audio);
        self.try_send(packet)
    }

    pub async fn send_control(&self, packet: OutboundPacket) -> Result<(), mpsc::error::SendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Control);
        self.send(packet).await
    }

    pub fn try_send_control(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Control);
        self.try_send(packet)
    }

    pub async fn send_clipboard(&self, packet: OutboundPacket) -> Result<(), mpsc::error::SendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Clipboard);
        self.send(packet).await
    }

    pub fn try_send_clipboard(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Clipboard);
        self.try_send(packet)
    }

    pub async fn send_egfx(&self, packet: OutboundPacket) -> Result<(), mpsc::error::SendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Egfx);
        self.send(packet).await
    }

    pub fn try_send_egfx(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Egfx);
        self.try_send(packet)
    }

    pub async fn send_display(&self, packet: OutboundPacket) -> Result<(), mpsc::error::SendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Display);
        self.send(packet).await
    }

    pub fn try_send_display(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Display);
        self.try_send(packet)
    }

    pub async fn send_bulk(&self, packet: OutboundPacket) -> Result<(), mpsc::error::SendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Bulk);
        self.send(packet).await
    }

    pub fn try_send_bulk(&self, packet: OutboundPacket) -> Result<(), mpsc::error::TrySendError<OutboundPacket>> {
        debug_assert_eq!(packet.class, OutboundClass::Bulk);
        self.try_send(packet)
    }
}

impl<W> OutboundOwner<W> {
    pub fn ingress_snapshot(&self, ingress: &OutboundOwnerIngress) -> (u64, u64) {
        (ingress.enqueued_packets(), ingress.rejected_packets())
    }

    pub fn ingress_enqueued_packets(&self, ingress: &OutboundOwnerIngress) -> u64 {
        ingress.enqueued_packets()
    }

    pub fn ingress_rejected_packets(&self, ingress: &OutboundOwnerIngress) -> u64 {
        ingress.rejected_packets()
    }

    pub fn new(writer: W, max_bytes: usize) -> Self {
        Self {
            scheduler: OutboundScheduler::new(max_bytes),
            writer,
        }
    }

    /// Create an owner and a bounded producer handoff channel. The receiver
    /// must be moved into [`Self::run`] on the task that exclusively owns the
    /// socket writer.
    pub fn channel(
        writer: W,
        max_bytes: usize,
        channel_capacity: usize,
    ) -> (Self, OutboundOwnerIngress, mpsc::Receiver<OutboundPacket>) {
        let (sender, receiver) = mpsc::channel(channel_capacity);
        let ingress = OutboundOwnerIngress {
            sender,
            enqueued_packets: std::sync::Arc::new(AtomicU64::new(0)),
            rejected_packets: std::sync::Arc::new(AtomicU64::new(0)),
        };
        (Self::new(writer, max_bytes), ingress, receiver)
    }

    pub fn scheduler(&self) -> &OutboundScheduler {
        &self.scheduler
    }

    pub fn scheduler_mut(&mut self) -> &mut OutboundScheduler {
        &mut self.scheduler
    }

    pub fn try_push(&mut self, packet: OutboundPacket) -> Result<(), EnqueueError> {
        self.scheduler.try_push(packet)
    }

    pub fn try_push_audio<F>(&mut self, upper_bound_bytes: usize, build: F) -> Result<AudioEnqueue, EnqueueError>
    where
        F: FnOnce() -> Vec<u8>,
    {
        self.scheduler.try_push_audio(upper_bound_bytes, build)
    }

    /// Reserve owner byte budget before framing an audio packet. This is the
    /// producer-side pre-framing admission boundary for a future live adapter.
    pub fn try_push_audio_upper_bound<F>(
        &mut self,
        upper_bound_bytes: usize,
        build: F,
    ) -> Result<AudioEnqueue, EnqueueError>
    where
        F: FnOnce() -> Vec<u8>,
    {
        self.try_push_audio(upper_bound_bytes, build)
    }

    pub fn into_inner(self) -> W {
        self.writer
    }
}

impl<W: FramedWrite> OutboundOwner<W> {
    /// Maximum number of producer packets admitted between socket writes.
    ///
    /// A continuously-ready ingress must not keep the owner in `try_recv`
    /// forever; this bound returns control to the scheduler and writer after a
    /// finite batch.
    pub const MAX_INGRESS_BATCH: usize = 64;

    pub const fn max_ingress_batch() -> usize {
        Self::MAX_INGRESS_BATCH
    }

    /// Run the single socket owner until all producers close the handoff.
    ///
    /// The receive side may use `try_recv` while no write is in progress to
    /// fill the typed scheduler, but every `write_next` call is awaited
    /// directly. It is never placed in `select!`, timed out, aborted, or
    /// retried, preserving `FramedWrite::write_all`'s cancellation contract.
    /// A packet too large for the byte budget is returned as an I/O error;
    /// callers must reject/drop audio before framing instead of sending it.
    pub async fn run(mut self, mut receiver: mpsc::Receiver<OutboundPacket>) -> io::Result<W> {
        let max_bytes = self.scheduler.max_bytes();
        let mut closed = false;
        let mut pending = None;

        loop {
            // Wait for one packet only when there is no work already admitted.
            // Once a packet arrives, drain immediately available producers into
            // the typed scheduler before selecting the next write. This keeps
            // the owner in control of class priority without ever receiving
            // while `write_all` is in flight.
            if pending.is_none() && self.scheduler.is_empty() && !closed {
                match receiver.recv().await {
                    Some(packet) => pending = Some(packet),
                    None => closed = true,
                }
            }

            let mut admitted_this_turn = 0;
            if let Some(packet) = pending.take() {
                match Self::admit_packet(&mut self.scheduler, packet, max_bytes) {
                    Ok(()) => {
                        admitted_this_turn += 1;
                    }
                    Err(AdmissionError::TooLarge(packet)) => {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidInput,
                            format!("outbound packet exceeds owner byte budget: {}", packet.len()),
                        ));
                    }
                    Err(AdmissionError::QueueFull(packet)) => {
                        pending = Some(packet);
                    }
                }
            }

            while !closed && pending.is_none() && admitted_this_turn < Self::MAX_INGRESS_BATCH {
                match receiver.try_recv() {
                    Ok(packet) => match Self::admit_packet(&mut self.scheduler, packet, max_bytes) {
                        Ok(()) => {
                            admitted_this_turn += 1;
                        }
                        Err(AdmissionError::TooLarge(packet)) => {
                            return Err(io::Error::new(
                                io::ErrorKind::InvalidInput,
                                format!("outbound packet exceeds owner byte budget: {}", packet.len()),
                            ));
                        }
                        Err(AdmissionError::QueueFull(packet)) => {
                            pending = Some(packet);
                            break;
                        }
                    },
                    Err(mpsc::error::TryRecvError::Empty) => break,
                    Err(mpsc::error::TryRecvError::Disconnected) => {
                        closed = true;
                        break;
                    }
                }
            }

            if !self.scheduler.is_empty() {
                self.write_next().await?;
                continue;
            }

            if pending.is_some() {
                // A packet that fits an empty scheduler must be admitted. This
                // guard protects the owner if admission invariants change.
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "outbound packet cannot be admitted",
                ));
            }
            if closed {
                return Ok(self.writer);
            }
        }
    }

    fn admit_packet(
        scheduler: &mut OutboundScheduler,
        packet: OutboundPacket,
        max_bytes: usize,
    ) -> Result<(), AdmissionError> {
        if packet.len() > max_bytes {
            return Err(AdmissionError::TooLarge(packet));
        }
        scheduler.try_push(packet).map_err(|error| match error {
            EnqueueError::QueueFull(packet) => AdmissionError::QueueFull(packet),
        })
    }

    pub fn scheduler_snapshot(&self) -> OutboundSchedulerSnapshot {
        self.scheduler.snapshot()
    }

    pub fn scheduler_snapshot_with_ingress(
        &self,
        ingress: &OutboundOwnerIngress,
    ) -> (OutboundSchedulerSnapshot, u64, u64) {
        (
            self.scheduler.snapshot(),
            ingress.enqueued_packets(),
            ingress.rejected_packets(),
        )
    }

    /// Write one queued complete buffer.
    ///
    /// `FramedWrite::write_all` is not cancellation-safe. The caller must
    /// await this future to completion and must not place it in `select!`, a
    /// timeout, or an abortable task. An error ends ownership of this socket;
    /// the selected packet is never retried because it may have been partially
    /// written already.
    pub async fn write_next(&mut self) -> io::Result<bool> {
        let Some(packet) = self.scheduler.pop_next_coalesced() else {
            return Ok(false);
        };
        self.writer.write_all(&packet.bytes).await?;
        Ok(true)
    }

    /// Drain packets after producers have stopped and before socket shutdown.
    ///
    /// Like `write_next`, this must run to completion without cancellation.
    pub async fn drain(&mut self) -> io::Result<()> {
        while !self.scheduler.is_empty() {
            self.write_next().await?;
        }
        Ok(())
    }

    pub fn is_drained(&self) -> bool {
        self.scheduler.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(class: OutboundClass, id: u8) -> OutboundPacket {
        OutboundPacket::new(class, vec![id])
    }

    #[derive(Debug, Default)]
    struct FakeWriter {
        writes: Vec<Vec<u8>>,
    }

    impl FramedWrite for FakeWriter {
        type WriteAllFut<'write>
            = std::future::Ready<io::Result<()>>
        where
            Self: 'write;

        fn write_all<'a>(&'a mut self, buf: &'a [u8]) -> Self::WriteAllFut<'a> {
            self.writes.push(buf.to_vec());
            std::future::ready(Ok(()))
        }
    }

    #[test]
    fn ingress_batch_budget_is_explicit_and_bounded() {
        assert_eq!(OutboundOwner::<FakeWriter>::max_ingress_batch(), 64);
        assert!(OutboundOwner::<FakeWriter>::max_ingress_batch() > 0);
    }

    #[test]
    fn owner_snapshot_combines_scheduler_and_ingress_counters() {
        let (mut owner, ingress, _receiver) = OutboundOwner::channel(FakeWriter::default(), 32, 1);
        owner.try_push(packet(OutboundClass::Control, 1)).unwrap();
        ingress.try_send(packet(OutboundClass::Egfx, 2)).unwrap();
        assert!(matches!(
            ingress.try_send(packet(OutboundClass::Display, 3)),
            Err(mpsc::error::TrySendError::Full(_))
        ));

        let (snapshot, enqueued, rejected) = owner.scheduler_snapshot_with_ingress(&ingress);
        assert_eq!(snapshot.queued_packets, 1);
        assert_eq!(snapshot.queued_bytes, 1);
        assert_eq!(
            snapshot.classes[OutboundClass::Control.index()],
            OutboundClassStats { packets: 1, bytes: 1 }
        );
        assert_eq!(enqueued, 1);
        assert_eq!(rejected, 1);
    }

    #[test]
    fn snapshot_reports_typed_queue_occupancy_and_counters() {
        let mut q = OutboundScheduler::new(32);
        q.try_push(packet(OutboundClass::Control, 1)).unwrap();
        q.try_push(OutboundPacket::new(OutboundClass::Egfx, vec![2, 3]))
            .unwrap();
        let snapshot = q.snapshot();

        assert_eq!(snapshot.queued_packets, 2);
        assert_eq!(snapshot.queued_bytes, 3);
        assert_eq!(snapshot.classes[OutboundClass::Control.index()].packets, 1);
        assert_eq!(snapshot.classes[OutboundClass::Egfx.index()].bytes, 2);
        assert_eq!(snapshot.enqueued_packets, 2);
        assert_eq!(snapshot.sent_packets, 0);

        let _ = q.pop_next_coalesced();
        let snapshot = q.snapshot();
        assert_eq!(snapshot.queued_packets, 1);
        assert_eq!(snapshot.sent_packets, 1);
        assert_eq!(snapshot.sent_bytes, 1);
    }

    #[test]
    fn audio_drop_happens_before_builder_and_is_telemetried() {
        let mut q = OutboundScheduler::new(4);
        let mut built = false;
        let result = q
            .try_push_audio(8, || {
                built = true;
                vec![1, 2, 3, 4]
            })
            .unwrap();

        assert_eq!(result, AudioEnqueue::DroppedBeforeFraming { estimated_bytes: 8 });
        assert!(result.was_dropped());
        assert_eq!(result.estimated_bytes(), Some(8));
        assert!(!built);
        assert_eq!(q.audio_dropped_packets(), 1);
        assert_eq!(q.audio_dropped_bytes(), 8);
        assert!(q.is_empty());
    }

    #[test]
    fn audio_admission_builds_only_when_budget_allows() {
        let mut q = OutboundScheduler::new(8);
        let mut built = false;
        let result = q
            .try_push_audio(4, || {
                built = true;
                vec![1, 2, 3]
            })
            .unwrap();

        assert_eq!(result, AudioEnqueue::Enqueued);
        assert!(!result.was_dropped());
        assert_eq!(result.estimated_bytes(), None);
        assert!(built);
        assert_eq!(q.class_len(OutboundClass::Audio), 1);
        assert_eq!(q.audio_dropped_packets(), 0);
    }

    #[test]
    fn coalesces_only_same_class_with_a_byte_bound() {
        let mut q = OutboundScheduler::new(OutboundScheduler::MAX_COALESCED_BYTES + 8);
        q.try_push(OutboundPacket::new(OutboundClass::Egfx, vec![1, 2]))
            .unwrap();
        q.try_push(OutboundPacket::new(OutboundClass::Egfx, vec![3, 4]))
            .unwrap();
        q.try_push(packet(OutboundClass::Display, 5)).unwrap();

        let merged = q.pop_next_coalesced().unwrap();
        assert_eq!(merged.class, OutboundClass::Egfx);
        assert_eq!(merged.bytes, vec![1, 2, 3, 4]);
        assert_eq!(q.pop_next_coalesced().unwrap().class, OutboundClass::Display);
    }

    #[test]
    fn coalescing_keeps_large_next_buffer_separate() {
        let mut q = OutboundScheduler::new(OutboundScheduler::MAX_COALESCED_BYTES + 1);
        q.try_push(OutboundPacket::new(
            OutboundClass::Egfx,
            vec![1; OutboundScheduler::MAX_COALESCED_BYTES],
        ))
        .unwrap();
        q.try_push(packet(OutboundClass::Egfx, 2)).unwrap();

        let first = q.pop_next_coalesced().unwrap();
        assert_eq!(first.bytes.len(), OutboundScheduler::MAX_COALESCED_BYTES);
        assert_eq!(q.pop_next_coalesced().unwrap().bytes, vec![2]);
    }

    #[tokio::test]
    async fn owner_writes_complete_buffers_in_scheduler_order_and_drains() {
        let mut owner = OutboundOwner::new(FakeWriter::default(), 32);
        owner.try_push(packet(OutboundClass::Egfx, 1)).unwrap();
        owner.try_push(packet(OutboundClass::Egfx, 2)).unwrap();
        owner.try_push(packet(OutboundClass::Audio, 3)).unwrap();
        owner.try_push(packet(OutboundClass::Display, 4)).unwrap();

        assert!(owner.write_next().await.unwrap());
        assert!(owner.write_next().await.unwrap());
        assert!(!owner.is_drained());
        owner.drain().await.unwrap();
        assert!(owner.is_drained());
        assert!(!owner.write_next().await.unwrap());

        let writer = owner.into_inner();
        assert_eq!(writer.writes, vec![vec![3], vec![1, 2], vec![4]]);
    }

    #[tokio::test]
    async fn typed_ingress_routes_all_non_audio_classes() {
        let (_owner, ingress, mut receiver) = OutboundOwner::channel(FakeWriter::default(), 32, 8);
        ingress.try_send_control(packet(OutboundClass::Control, 1)).unwrap();
        ingress.try_send_clipboard(packet(OutboundClass::Clipboard, 2)).unwrap();
        ingress.try_send_egfx(packet(OutboundClass::Egfx, 3)).unwrap();
        ingress.try_send_display(packet(OutboundClass::Display, 4)).unwrap();
        ingress.try_send_bulk(packet(OutboundClass::Bulk, 5)).unwrap();

        for expected in 1..=5 {
            assert_eq!(receiver.recv().await.unwrap().bytes, vec![expected]);
        }
    }

    #[tokio::test]
    async fn owner_ingress_try_send_preserves_packet_when_channel_is_full() {
        let (_owner, ingress, _receiver) = OutboundOwner::channel(FakeWriter::default(), 32, 1);
        ingress.try_send(packet(OutboundClass::Control, 1)).unwrap();

        let rejected = ingress.try_send(packet(OutboundClass::Egfx, 2)).unwrap_err();
        match rejected {
            mpsc::error::TrySendError::Full(packet) => {
                assert_eq!(packet.class, OutboundClass::Egfx);
                assert_eq!(packet.bytes, vec![2]);
            }
            mpsc::error::TrySendError::Closed(_) => panic!("owner ingress unexpectedly closed"),
        }
        assert_eq!(ingress.enqueued_packets(), 1);
        assert_eq!(ingress.rejected_packets(), 1);
    }

    #[tokio::test]
    async fn owner_channel_runs_single_writer_and_drains_on_ingress_close() {
        let (owner, ingress, receiver) = OutboundOwner::channel(FakeWriter::default(), 32, 4);
        ingress.send(packet(OutboundClass::Egfx, 1)).await.unwrap();
        ingress.send(packet(OutboundClass::Egfx, 2)).await.unwrap();
        ingress.send(packet(OutboundClass::Audio, 3)).await.unwrap();
        drop(ingress);

        let writer = owner.run(receiver).await.unwrap();
        assert_eq!(writer.writes, vec![vec![3], vec![1, 2]]);
    }

    #[tokio::test]
    async fn owner_drains_pending_packet_after_scheduler_byte_budget_frees_space() {
        let (owner, ingress, receiver) = OutboundOwner::channel(FakeWriter::default(), 2, 4);
        ingress.send(packet(OutboundClass::Control, 1)).await.unwrap();
        ingress.send(packet(OutboundClass::Egfx, 2)).await.unwrap();
        drop(ingress);

        let writer = owner.run(receiver).await.unwrap();
        assert_eq!(writer.writes, vec![vec![1], vec![2]]);
    }

    #[tokio::test]
    async fn owner_run_stops_after_writer_error_without_requeue() {
        #[derive(Debug, Clone)]
        struct FailingWriter {
            writes: std::sync::Arc<std::sync::Mutex<Vec<Vec<u8>>>>,
        }

        impl FramedWrite for FailingWriter {
            type WriteAllFut<'write>
                = std::future::Ready<io::Result<()>>
            where
                Self: 'write;

            fn write_all<'a>(&'a mut self, buf: &'a [u8]) -> Self::WriteAllFut<'a> {
                self.writes.lock().unwrap().push(buf.to_vec());
                std::future::ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "fake")))
            }
        }

        let writes = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let (owner, ingress, receiver) = OutboundOwner::channel(
            FailingWriter {
                writes: std::sync::Arc::clone(&writes),
            },
            32,
            4,
        );
        ingress.send(packet(OutboundClass::Egfx, 1)).await.unwrap();
        ingress.send(packet(OutboundClass::Display, 2)).await.unwrap();
        drop(ingress);

        let error = owner.run(receiver).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        assert_eq!(*writes.lock().unwrap(), vec![vec![1]]);
    }

    #[tokio::test]
    async fn owner_channel_rejects_packet_larger_than_byte_budget() {
        let (owner, ingress, receiver) = OutboundOwner::channel(FakeWriter::default(), 2, 1);
        ingress
            .send(OutboundPacket::new(OutboundClass::Egfx, vec![1, 2, 3]))
            .await
            .unwrap();
        drop(ingress);

        let error = owner.run(receiver).await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
    }

    #[tokio::test]
    async fn owner_retains_unsent_packets_after_writer_error_without_retrying_failed_one() {
        struct FailingWriter {
            writes: Vec<Vec<u8>>,
        }

        impl FramedWrite for FailingWriter {
            type WriteAllFut<'write>
                = std::future::Ready<io::Result<()>>
            where
                Self: 'write;

            fn write_all<'a>(&'a mut self, buf: &'a [u8]) -> Self::WriteAllFut<'a> {
                self.writes.push(buf.to_vec());
                std::future::ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "fake")))
            }
        }

        let mut owner = OutboundOwner::new(FailingWriter { writes: Vec::new() }, 32);
        owner.try_push(packet(OutboundClass::Egfx, 1)).unwrap();
        owner.try_push(packet(OutboundClass::Display, 2)).unwrap();

        assert_eq!(owner.write_next().await.unwrap_err().kind(), io::ErrorKind::BrokenPipe);
        assert_eq!(owner.scheduler().len(), 1);

        let writer = owner.into_inner();
        assert_eq!(writer.writes, vec![vec![1]]);
    }

    #[tokio::test]
    async fn owner_does_not_retry_after_simulated_partial_write() {
        struct PartialWriter {
            writes: Vec<Vec<u8>>,
            partial_bytes: usize,
        }

        impl FramedWrite for PartialWriter {
            type WriteAllFut<'write>
                = std::future::Ready<io::Result<()>>
            where
                Self: 'write;

            fn write_all<'a>(&'a mut self, buf: &'a [u8]) -> Self::WriteAllFut<'a> {
                let written = self.partial_bytes.min(buf.len());
                self.writes.push(buf[..written].to_vec());
                std::future::ready(Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "simulated partial write",
                )))
            }
        }

        let mut owner = OutboundOwner::new(
            PartialWriter {
                writes: Vec::new(),
                partial_bytes: 2,
            },
            32,
        );
        owner
            .try_push(OutboundPacket::new(OutboundClass::Egfx, vec![1, 2, 3, 4]))
            .unwrap();
        owner.try_push(packet(OutboundClass::Display, 5)).unwrap();

        assert_eq!(
            owner.write_next().await.unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
        // First buffer was partially observed exactly once. It is not in the
        // scheduler anymore, and the following display buffer remains queued;
        // reconnect/retry policy belongs to the connection owner.
        assert_eq!(owner.scheduler().len(), 1);
        let writer = owner.into_inner();
        assert_eq!(writer.writes, vec![vec![1, 2]]);
    }

    #[test]
    fn preserves_fifo_within_egfx() {
        let mut q = OutboundScheduler::new(100);
        q.try_push(packet(OutboundClass::Egfx, 1)).unwrap();
        q.try_push(packet(OutboundClass::Egfx, 2)).unwrap();
        q.try_push(packet(OutboundClass::Egfx, 3)).unwrap();
        assert_eq!(q.pop_next().unwrap().bytes, vec![1]);
        assert_eq!(q.pop_next().unwrap().bytes, vec![2]);
        assert_eq!(q.pop_next().unwrap().bytes, vec![3]);
    }

    #[test]
    fn urgent_audio_precedes_data_but_yields_after_burst() {
        let mut q = OutboundScheduler::new(1000);
        for id in 0..16 {
            q.try_push(packet(OutboundClass::Audio, id)).unwrap();
        }
        q.try_push(packet(OutboundClass::Egfx, 99)).unwrap();
        for _ in 0..OutboundScheduler::MAX_URGENT_BURST {
            assert_eq!(q.pop_next().unwrap().class, OutboundClass::Audio);
        }
        assert_eq!(q.pop_next().unwrap().class, OutboundClass::Egfx);
    }

    #[test]
    fn weighted_data_service_keeps_bulk_from_starving() {
        let mut q = OutboundScheduler::new(1000);
        for id in 0..8 {
            q.try_push(packet(OutboundClass::Egfx, id)).unwrap();
            q.try_push(packet(OutboundClass::Bulk, id)).unwrap();
        }
        let mut classes = Vec::new();
        for _ in 0..16 {
            classes.push(q.pop_next().unwrap().class);
        }
        assert!(classes.contains(&OutboundClass::Egfx));
        assert!(classes.contains(&OutboundClass::Bulk));
    }

    #[test]
    fn full_queue_returns_packet_without_dropping_it() {
        let mut q = OutboundScheduler::new(1);
        q.try_push(packet(OutboundClass::Egfx, 1)).unwrap();
        let err = q.try_push(packet(OutboundClass::Egfx, 2)).unwrap_err();
        assert_eq!(err, EnqueueError::QueueFull(packet(OutboundClass::Egfx, 2)));
        assert_eq!(q.pop_next().unwrap().bytes, vec![1]);
    }

    #[test]
    fn urgent_budget_does_not_drop_data_packet() {
        let mut q = OutboundScheduler::new(1000);
        for id in 0..OutboundScheduler::MAX_URGENT_BURST as u8 {
            q.try_push(packet(OutboundClass::Audio, id)).unwrap();
        }
        q.try_push(packet(OutboundClass::Egfx, 99)).unwrap();
        for _ in 0..OutboundScheduler::MAX_URGENT_BURST {
            assert_eq!(q.pop_next().unwrap().class, OutboundClass::Audio);
        }
        assert_eq!(q.pop_next().unwrap().bytes, vec![99]);
        assert!(q.is_empty());
    }
}
