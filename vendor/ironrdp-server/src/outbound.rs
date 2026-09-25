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

/// Single-thread-owned scheduler state. Move it into future socket-owner task;
/// no mutex is needed inside that task. `MAX_URGENT_BURST` bounds audio/control
/// priority so a steady stream cannot starve EGFX or display updates.
pub struct OutboundScheduler {
    queues: [VecDeque<OutboundPacket>; 6],
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
}

impl OutboundScheduler {
    pub const MAX_URGENT_BURST: usize = 8;

    pub fn new(max_bytes: usize) -> Self {
        Self {
            queues: std::array::from_fn(|_| VecDeque::new()),
            queued_bytes: 0,
            max_bytes,
            data_cursor: 0,
            urgent_remaining: Self::MAX_URGENT_BURST,
            enqueued_packets: 0,
            rejected_packets: 0,
            sent_packets: 0,
            sent_bytes: 0,
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

    /// Enqueue one complete wire buffer. Full queue returns packet to caller;
    /// this is intentional: audio may be dropped before framing, while EGFX
    /// must apply backpressure rather than silently lose a reference frame.
    pub fn try_push(&mut self, packet: OutboundPacket) -> Result<(), EnqueueError> {
        if packet.len() > self.max_bytes.saturating_sub(self.queued_bytes) {
            self.rejected_packets = self.rejected_packets.saturating_add(1);
            return Err(EnqueueError::QueueFull(packet));
        }
        self.enqueued_packets = self.enqueued_packets.saturating_add(1);
        self.queued_bytes += packet.len();
        self.queues[packet.class.index()].push_back(packet);
        Ok(())
    }

    fn pop_class(&mut self, class: OutboundClass) -> Option<OutboundPacket> {
        let packet = self.queues[class.index()].pop_front()?;
        self.queued_bytes = self.queued_bytes.saturating_sub(packet.len());
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
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(class: OutboundClass, id: u8) -> OutboundPacket {
        OutboundPacket::new(class, vec![id])
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
