//! EGFX (Graphics Pipeline Extension) server integration.
//!
//! Provides the bridge between `ironrdp-egfx`'s `GraphicsPipelineServer` and
//! `ironrdp-server`'s `RdpServer`, enabling H.264 video streaming via DVC.
//!
//! The bridge pattern (`GfxDvcBridge`) wraps an `Arc<Mutex<GraphicsPipelineServer>>`
//! so the display handler can call `send_avc420_frame()` proactively while the
//! DVC infrastructure handles client messages (capability negotiation, frame acks).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use ironrdp_core::impl_as_any;
use ironrdp_dvc::{DvcMessage, DvcProcessor, DvcServerProcessor};
use ironrdp_egfx::server::{GraphicsPipelineHandler, GraphicsPipelineServer};
use ironrdp_pdu::PduResult;
use ironrdp_svc::SvcMessage;

use crate::server::ServerEventSender;

/// Shared handle to a `GraphicsPipelineServer`.
///
/// Uses `std::sync::Mutex` (not tokio) because `DvcProcessor` trait methods
/// are synchronous and cannot hold async locks.
pub type GfxServerHandle = Arc<Mutex<GraphicsPipelineServer>>;

/// Factory for creating EGFX graphics pipeline handlers.
///
/// Implements `ServerEventSender` so the factory can signal the server event loop
/// when EGFX frames are ready to be drained and sent.
pub trait GfxServerFactory: ServerEventSender + Send {
    /// Create a handler for EGFX callbacks (caps negotiation, frame acks).
    fn build_gfx_handler(&self) -> Box<dyn GraphicsPipelineHandler>;

    /// Create a bridge and shared server handle for proactive frame sending.
    ///
    /// When returning `Some`, the bridge is registered with DrdynvcServer for
    /// client messages, and the handle is available for direct frame submission.
    /// Returns `None` by default, falling back to `build_gfx_handler()`.
    fn build_server_with_handle(&self) -> Option<(GfxDvcBridge, GfxServerHandle)> {
        None
    }
}

/// DVC bridge wrapping a shared `GraphicsPipelineServer`.
///
/// Delegates all `DvcProcessor` methods to the inner server through a mutex,
/// enabling shared access from both the DVC layer and the display handler.
pub struct GfxDvcBridge {
    inner: GfxServerHandle,
    /// Optional "decline the graphics pipeline" flag, set by the application's
    /// `GraphicsPipelineHandler` (synchronously during `process` — the inner
    /// server invokes the handler before returning). When true, `process`
    /// discards the inner server's output instead of shipping it — most
    /// importantly the `CapabilitiesConfirm`, so a client whose advertised
    /// capabilities the application can't serve (e.g. EGFX offered but AVC
    /// disabled on every capset) is never told the pipeline is active and
    /// keeps rendering legacy updates. Confirming caps and then sending legacy
    /// updates anyway is a protocol violation some clients (Windows App for
    /// Android) hard-disconnect on. `None` = never decline (default).
    decline_output: Option<Arc<AtomicBool>>,
}

impl GfxDvcBridge {
    pub fn new(server: GfxServerHandle) -> Self {
        Self {
            inner: server,
            decline_output: None,
        }
    }

    /// Like [`Self::new`] but with a shared decline flag (see the field note).
    pub fn with_decline_flag(server: GfxServerHandle, decline: Arc<AtomicBool>) -> Self {
        Self {
            inner: server,
            decline_output: Some(decline),
        }
    }

    pub fn server(&self) -> &GfxServerHandle {
        &self.inner
    }
}

impl_as_any!(GfxDvcBridge);

impl DvcProcessor for GfxDvcBridge {
    fn channel_name(&self) -> &str {
        ironrdp_egfx::CHANNEL_NAME
    }

    fn start(&mut self, channel_id: u32) -> PduResult<Vec<DvcMessage>> {
        self.inner
            .lock()
            .expect("GfxServerHandle mutex poisoned")
            .start(channel_id)
    }

    fn process(&mut self, channel_id: u32, payload: &[u8]) -> PduResult<Vec<DvcMessage>> {
        let out = self
            .inner
            .lock()
            .expect("GfxServerHandle mutex poisoned")
            .process(channel_id, payload)?;
        // The handler ran synchronously inside `process` above, so the decline
        // flag is current for the PDU just handled. Discarding the output here
        // (rather than not processing) keeps the inner server's state machine
        // consistent while the client is never told the pipeline came up.
        if let Some(declined) = &self.decline_output
            && declined.load(Ordering::Relaxed)
        {
            return Ok(Vec::new());
        }
        Ok(out)
    }

    fn close(&mut self, channel_id: u32) {
        self.inner
            .lock()
            .expect("GfxServerHandle mutex poisoned")
            .close(channel_id)
    }
}

impl DvcServerProcessor for GfxDvcBridge {}

#[cfg(test)]
mod egfx_wire_regression_tests {
    use ironrdp_core::{Decode, Encode, ReadCursor, WriteCursor};
    use ironrdp_dvc::{DvcMessage, DvcProcessor};
    use ironrdp_egfx::pdu::{
        CapabilitiesAdvertisePdu, CapabilitiesV107Flags, CapabilitySet, GfxPdu, ResetGraphicsPdu,
    };
    use ironrdp_egfx::server::{GraphicsPipelineHandler, GraphicsPipelineServer};
    use ironrdp_pdu::gcc::{Monitor, MonitorFlags};


    struct NoopHandler;

    impl GraphicsPipelineHandler for NoopHandler {
        fn capabilities_advertise(&mut self, _pdu: &ironrdp_egfx::pdu::CapabilitiesAdvertisePdu) {}
        fn on_ready(&mut self, _negotiated: &ironrdp_egfx::pdu::CapabilitySet) {}
    }

    fn decode_wire(data: &[u8]) -> GfxPdu {
        // GraphicsPipelineServer emits ZGFX uncompressed single-segment framing
        // (0xE0 descriptor, 0x04 flags) around each encoded GFX PDU.
        assert_eq!(data[0], 0xE0);
        assert_eq!(data[1], 0x04);
        let mut cursor = ReadCursor::new(&data[2..]);
        let pdu = GfxPdu::decode(&mut cursor).expect("valid EGFX PDU");
        assert!(cursor.pos() <= data.len() - 2, "EGFX decoder stays within payload");
        pdu
    }

    fn decode_messages(messages: Vec<DvcMessage>) -> Vec<GfxPdu> {
        messages
            .into_iter()
            .map(|message| {
                let mut bytes = vec![0; message.size()];
                let mut cursor = WriteCursor::new(&mut bytes);
                message.encode(&mut cursor).expect("message encodes");
                decode_wire(&bytes)
            })
            .collect()
    }

    #[test]
    fn resize_with_explicit_monitor_precedes_surface_create_on_reconnect() {
        let mut server = GraphicsPipelineServer::new(Box::new(NoopHandler));
        assert!(!server.is_ready(), "pipeline starts before capability negotiation");
        let _ = server.start(7).expect("DVC starts");
        let caps = GfxPdu::CapabilitiesAdvertise(CapabilitiesAdvertisePdu::from_typed(&[
            CapabilitySet::V10_7 { flags: CapabilitiesV107Flags::empty() },
        ]));
        let mut bytes = vec![0; caps.size()];
        let mut cursor = WriteCursor::new(&mut bytes);
        caps.encode(&mut cursor).expect("caps encode");
        let _ = server.process(7, &bytes).expect("caps negotiate");
        assert!(server.is_ready(), "pipeline is Ready after capability negotiation");

        // Same production ordering used on every fresh EGFX connection:
        // RESET_GRAPHICS with an explicit output monitor before Create/MapSurface.
        let monitor = Monitor {
            left: 0,
            top: 0,
            right: 1709,
            bottom: 1111,
            flags: MonitorFlags::PRIMARY,
        };
        server.set_output_dimensions(1710, 1112);
        server.resize_with_monitors(1710, 1112, vec![monitor]);
        let sid = server.create_surface(1710, 1112).expect("ready after resize");
        assert!(server.map_surface_to_output(sid, 0, 0));

        let pdus = decode_messages(server.drain_output());
        assert!(matches!(pdus.first(), Some(GfxPdu::ResetGraphics(ResetGraphicsPdu {
            width: 1710, height: 1112, monitors, ..
        })) if monitors.len() == 1 && monitors[0].flags.contains(MonitorFlags::PRIMARY)));
        assert!(matches!(pdus.get(1), Some(GfxPdu::CreateSurface(_))));
        assert!(matches!(pdus.get(2), Some(GfxPdu::MapSurfaceToOutput(_))));
        assert_eq!(pdus.len(), 3);
    }

    #[test]
    fn reset_graphics_round_trips_exact_primary_bounds() {
        let monitor = Monitor {
            left: 0,
            top: 0,
            right: 1709,
            bottom: 1111,
            flags: MonitorFlags::PRIMARY,
        };
        let expected = ResetGraphicsPdu {
            width: 1710,
            height: 1112,
            monitors: vec![monitor],
        };
        let pdu = GfxPdu::ResetGraphics(expected.clone());
        let mut bytes = vec![0; pdu.size()];
        let mut cursor = WriteCursor::new(&mut bytes);
        pdu.encode(&mut cursor).expect("reset encodes");
        let wrapped = [0xE0, 0x04].into_iter().chain(bytes).collect::<Vec<_>>();
        assert_eq!(decode_wire(&wrapped), GfxPdu::ResetGraphics(expected));
    }

    #[test]
    fn reset_graphics_decoder_rejects_more_than_sixteen_monitors() {
        // ResetGraphics fixed size is 340 bytes. Monitor count follows width/height;
        // 17 is rejected before monitor entries are read.
        let mut pdu = vec![0u8; 340];
        pdu[0..4].copy_from_slice(&1710u32.to_le_bytes());
        pdu[4..8].copy_from_slice(&1112u32.to_le_bytes());
        pdu[8..12].copy_from_slice(&17u32.to_le_bytes());
        let wrapped = [0xE0, 0x04].into_iter().chain(pdu).collect::<Vec<_>>();
        let result = decode_wire_result(&wrapped);
        assert!(result.is_err(), "protocol limit is 16 monitors");
    }

    fn decode_wire_result(data: &[u8]) -> ironrdp_core::DecodeResult<GfxPdu> {
        assert_eq!(data[0], 0xE0);
        assert_eq!(data[1], 0x04);
        GfxPdu::decode(&mut ReadCursor::new(&data[2..]))
    }
}

/// Message for routing EGFX PDUs to the wire via `ServerEvent`.
#[derive(Debug)]
pub enum EgfxServerMessage {
    /// Pre-encoded DVC messages from `GraphicsPipelineServer::drain_output()`.
    SendMessages { messages: Vec<SvcMessage> },
}

impl core::fmt::Display for EgfxServerMessage {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::SendMessages { messages } => {
                write!(f, "SendMessages(count={})", messages.len())
            }
        }
    }
}
