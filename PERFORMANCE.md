# Performance

`zig build font-bench -Doptimize=ReleaseFast` (dvui-dev/font-bench.zig, text-layout demo).

| target                                      | cold start (total) | cold allocs | steady/frame | steady allocs |
|----------------------------------------------|--------------------:|------------:|--------------:|---------------:|
| baseline (eager Latin-1 glyph prefill)        | 25.24 ms            | 4073        | 0.41 ms        | 0              |
| lazy rasterization                            | 9.53 ms             | 526         | 0.71 ms        | 0              |
| + lazy fallback-family materialization        | 6.0 ms              | 907         | 0.28 ms        | 0              |

- `Font.Cache.Entry.glyphInfoGet` eager-called for 0x20-0xFF per font at `Entry.init`: 15.6ms / 3547 allocs, all avoidable. Removed.
- parse + `Renderer.init` (hinting VM) + `measuredCapHeight` x2 (ppem calibration): not isolated, assumed cheap per earlier profile (<500µs combined per font) — not remeasured.
- remaining cold start, `textures_created: 10`: real rasterization+atlas-upload for glyphs actually on screen, not overhead.
- steady state: 0 allocs/frame, 0 `textures_created` — nothing to fix.
- atlas packer (`placeGlyph`/`repackAll`): no eviction, unbounded growth under glyph churn (`Font.zig:818`) — not measured, not touched here.
- lazy fallback-family materialization (only building a full calibrated `Entry` for a stack family once shaped text actually needs it, not eagerly per `resolveStack`) shipped with a correctness bug that made font-bench segfault on frame 2: `Cache.shapeLineText` inserted into the long-lived font cache using a frame-scoped arena allocator instead of the persistent `gpa`, so the cache's backing storage got freed out from under it at the next frame's arena reset. Fixed by threading `persist_gpa` through those `getOrCreate` calls, and by boxing cache entries (`*Entry` instead of `Entry` by value) so a live entry's address is stable across the cache's hashmap growing — several callers (e.g. `ShapedText.fallback`) already assumed that stability without it being guaranteed. See `zig build test -Dbackend=testing`.
- `grid` scene (100-row table, ~30 rows visible/frame) added to font-bench: 12.6 ms cold (9701 allocs, 1 `textures_created`), 2.1 ms/frame steady (0 allocs, 0 `textures_created`) — no atlas churn, so the steady-state cost is pure per-cell layout/shape; not yet profiled further.
