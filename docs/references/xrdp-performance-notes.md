# xrdp performance reference

Source: `reference/xrdp-linux`, xrdp `v0.10.4` (`4dcc0397`), Apache-2.0.

## Relevant design lessons

- xrdp batches drawing operations inside `server_begin_update` / `server_end_update` and emits dirty regions once per update, rather than copying/encoding every primitive immediately.
- Dirty regions are accumulated and coalesced with pixman. EGFX receives regions directly; legacy clients receive only tightly packed dirty rectangles.
- H.264/RFX work runs on a dedicated encoder worker. The producer submits work to a FIFO and the worker drains available work without blocking the protocol loop.
- EGFX frame flow is explicitly bounded by acknowledged frames. `xrdp_mm_update_module_frame_ack()` only releases frames when `frame_id_client + frames_in_flight > frame_id_server`; default GFX window is 2, configurable 1..16.
- Completed encoded work is drained in batches (`xrdp_mm_process_enc_done()`), and frame markers bracket a complete frame. This preserves ordering while reducing per-fragment scheduling overhead.
- xrdp exposes separate capture intervals for H.264/RFX/normal paths (`h264_frame_interval=16`, `rfx_frame_interval=32`, `normal_frame_interval=40` ms in the sample config).
- Socket readiness uses `poll()` rather than repeated blocking/select paths. Output buffers are sized for the expected workload; NEWS calls out high-bandwidth/high-latency buffer tuning.
- xrdp's GFX path avoids treating an unbounded encoded-output queue as latency control. Backpressure happens before/around encode, while frame ACKs bound client presentation work.

## What this means for macrdp

1. Keep ScreenCaptureKit capture bounded/drop-to-latest.
2. Coalesce pending legacy dirty rectangles before allocating `Bytes` updates.
3. Keep H.264 ordering/reference chain intact; drop/coalesce only before VideoToolbox submission.
4. Bound outbound video work separately from control traffic. Do not let EGFX frames accumulate behind clipboard/input/audio.
5. Instrument capture age, dirty area/rect count, encode latency, ship latency, event depth, write stalls, ACK delay, and CPU before tuning.
6. Compare Windows `mstsc` and macOS clients with same resolution/FPS/bitrate/network and report p50/p95, not anecdotes.
