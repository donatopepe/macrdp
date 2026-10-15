# vendor/ironrdp-egfx — local fork divergence log

`ironrdp-egfx` is the EGFX (MS-RDPEGFX) dynamic virtual channel crate: the
graphics pipeline server/handler, surface management, PDU encode/decode, and the
H.264 (AVC420) frame path macrdp drives from `src/h264.rs`.

Upstream: [Devolutions/IronRDP](https://github.com/Devolutions/IronRDP). This is
a verbatim copy of `crates/ironrdp-egfx` at rev
`a5d1c682fd1f65287f6f5727bdead2aef7a2bea7` — the same rev the root
`Cargo.toml` pins every other `ironrdp-*` crate to — with **one** divergence.
Workspace-inherited fields are inlined in `Cargo.toml` because the copy lives
outside the IronRDP cargo workspace; sibling `ironrdp-*` deps are version-only
and resolve through the root `Cargo.toml`'s `[patch.crates-io]` redirects (the
in-crate `[patch.crates-io]` block is only honored when the crate is built
standalone for isolated validation).

It is vendored rather than dropped because the divergence is a *client
interoperability* lever that upstream has no reason to carry: it exists for one
specific Windows client's cross-session surface cache.

## Divergence 1 — create a surface at an explicit id (`create_surface_with_id`)

- **What:** `GraphicsPipelineServer::create_surface_with_id(surface_id, w, h,
  format)` creates the surface at a caller-chosen id, plus
  `Surfaces::reserve_id(surface_id)` which advances the auto-allocator past it so
  a later auto-allocated surface in the same session can never collide with an
  explicitly created one. The existing `ResetGraphics`-before-`CreateSurface`
  rule was factored into a private `ensure_reset_graphics()` used by both paths,
  so the explicit-id path is wire-for-wire identical to the stock one apart from
  the id.
- **Why:** **mstsc retains EGFX surfaces by id for the whole lifetime of its
  process** and no-ops a `CreateSurface` for an id it already holds. A fresh
  `GraphicsPipelineServer` per connection resets the auto-allocator, so every
  connection creates **id 0**; a reconnect inside a still-running mstsc therefore
  re-creates an id it holds, mstsc composites its stale retained surface, and the
  client shows a **black screen with a live cursor**. Handing it an id it has
  never seen is the only server-side lever that avoids the no-op.
- **Deliberately NOT part of this divergence:** `DeleteSurface`. Deleting an id
  the client does not currently hold (or one mapped to the output) tears its
  graphics channel down instead of repairing it — confirmed repeatedly on mstsc;
  see `docs/known-quirks.md`.
- **Consumer:** `src/h264.rs`, `Gfx::setup_locked`, gated on
  `MACRDP_EGFX_FRESH_SURFACE_ID=1` (config key `EGFX_FRESH_SURFACE_ID`). The
  counter is persisted (`MACRDP_EGFX_SURFACE_ID_FILE`, default a file in the
  per-user temp dir) because the client's surface cache also survives macrdp
  restarts. **Default OFF**: with the flag unset the runtime takes upstream's
  auto-allocated id and behaviour is unchanged.
- **De-vendor when:** upstream exposes an explicit-id (or "never reuse an id")
  surface creation API, or the client quirk stops being real. Until then the fork
  must be kept in step with the pin bump (`git diff` the crate against the new
  rev and re-apply this one hunk — it is ~70 lines in `src/server.rs`).
