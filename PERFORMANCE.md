# Performance

`zig build font-bench -Doptimize=ReleaseFast` (dvui-dev/font-bench.zig, text-layout demo).

| target                                 | cold start (total) | cold allocs | steady/frame | steady allocs |
| -------------------------------------- | -----------------: | ----------: | -----------: | ------------: |
| baseline (eager Latin-1 glyph prefill) |           25.24 ms |        4073 |      0.41 ms |             0 |
| lazy rasterization                     |            9.53 ms |         526 |      0.71 ms |             0 |
| + lazy fallback-family materialization |             6.0 ms |         907 |      0.28 ms |             0 |

- `Font.Cache.Entry.glyphInfoGet` eager-called for 0x20-0xFF per font at `Entry.init`: 15.6ms / 3547 allocs, all avoidable. Removed.
- parse + `Renderer.init` (hinting VM) + `measuredCapHeight` x2 (ppem calibration): not isolated, assumed cheap per earlier profile (<500µs combined per font) — not remeasured.
- remaining cold start, `textures_created: 10`: real rasterization+atlas-upload for glyphs actually on screen, not overhead.
- steady state: 0 allocs/frame, 0 `textures_created` — nothing to fix.
- atlas packer (`placeGlyph`/`repackAll`): no eviction, unbounded growth under glyph churn (`Font.zig:818`) — not measured, not touched here.
- lazy fallback-family materialization (only building a full calibrated `Entry` for a stack family once shaped text actually needs it, not eagerly per `resolveStack`) shipped with a correctness bug that made font-bench segfault on frame 2: `Cache.shapeLineText` inserted into the long-lived font cache using a frame-scoped arena allocator instead of the persistent `gpa`, so the cache's backing storage got freed out from under it at the next frame's arena reset. Fixed by threading `persist_gpa` through those `getOrCreate` calls, and by boxing cache entries (`*Entry` instead of `Entry` by value) so a live entry's address is stable across the cache's hashmap growing — several callers (e.g. `ShapedText.fallback`) already assumed that stability without it being guaranteed. See `zig build test -Dbackend=testing`.
- `grid` scene (100-row table, ~30 rows visible/frame) added to font-bench: 12.6 ms cold (9701 allocs, 1 `textures_created`), 2.1 ms/frame steady (0 allocs, 0 `textures_created`) — no atlas churn, so the steady-state cost is pure per-cell layout/shape; not yet profiled further.
- Profiled the 2.1ms/frame `grid` steady-state cost with macOS `sample` (20000-frame loop, ReleaseFast, `sample <pid> 10`). `0 allocs/frame` was hiding real work: `shapeLineText`'s cache hit path (`materializeShapedLine`) still does 6 arena copies (buffer info/pos, codepoints, byte_offsets, cluster_starts/ends, segments array) per call — arena bump allocations don't call the backing allocator (so the alloc counter reads 0), but the memcpys and `std.ArrayList` growth are real CPU time. `Font.sizeM` alone was ~25% of sampled frames: `TextLayoutWidget.addTextEx` (per fragment, i.e. per grid cell) called `font.sizeM(1, 1)` for word-wrap width, then `font.lineHeight()` right after — `lineHeight()` is `textHeight() * factor` and `textHeight()` is `sizeM(1,1).h`, so the exact same "M"-glyph shape+measure round trip ran twice back-to-back for every cell, every frame. Fixed by reusing the already-computed `msize.h` instead of a second `font.lineHeight()` call (`TextLayoutWidget.zig` `addTextEx`) — no behavior change (same computation, same scale context), ~8% steady-state win (1.99ms → 1.84ms/frame, grid-only 20000-frame run).
- Remaining cost in the same area: `sizeM`/`textHeight` are called pervasively across the widget set (labels, sliders, grid min-size, text entry, ...) and each call still pays the full `shapeLineText`/`materializeShapedLine` round trip just to measure one "M" glyph, even though `Entry` already precomputes `em_height` at calibration and per-glyph metrics are cached separately on `Entry.glyphs`. A real fix would bypass the general shaped-line machinery for this specific single-ASCII-glyph query (read `Entry.glyphInfoGet('M')` directly instead of going through `Buffer`/segments/materialize) — bigger, correctness-sensitive diff (bidi/fallback plumbing), not attempted here.
- Fixed: `sizeM` now memoizes its `textSizeRawShaped(..., "M", .{})` result on `Cache.ResolvedStack` (`m_size` field) instead of reshaping/rematerializing on every call — first call per resolved font stack pays the normal pipeline once, every later call (the overwhelming majority) is a struct-field read, so `Buffer`/segments/`materializeShapedLine` are skipped entirely. Simpler and safer than a hand-rolled cmap+hmtx bypass (no risk of diverging from GPOS/HVAR-adjusted shaping output — the cached value _is_ the shaped-pipeline output). `grid` steady-state: 1.84 ms → ~1.63 ms/frame (~11%, 3-run average, `zig build font-bench -Doptimize=ReleaseFast`).

next session:
rofile the `grid` scene in `zig build font-bench -Doptimize=ReleaseFast`
(dvui-dev/font-bench.zig) before changing anything — use macOS `sample <pid>
  10` on a long steady-state loop like last time, don't assume. Confirm whether
`Cache.materializeShapedLine` (dvui/src/Font.zig:1099, runs every frame on a
`shaped_line_cache` hit — 6 arena copies: buffer info/pos, codepoints,
byte_offsets, cluster_starts/ends, segments) is really the dominant remaining
cost, per PERFORMANCE.md's last entry. If the profile shows something else
on top, chase that instead.

Also run font-bench against `dvui-main/` (unmodified upstream checkout at
/Users/nat3/programming/zig/lib-opentype-renderer/dvui-main) for the same
scenes — the bench already prints a "dvui-main/ (upstream baseline)"
comparison alongside "dvui/ (opentype-renderer integration)", so just capture
both cleanly instead of only reading our own numbers. We want to know how
the opentype-renderer integration compares to stock dvui, not just to our own
prior commits.

If `materializeShapedLine` is confirmed hot, the real fix is
`ShapedText`/rendering reading glyph data directly off `CachedShapedLine`
(re-resolving `*Entry` per read) instead of eagerly copying into owned arrays
every frame — bigger, correctness-sensitive (bidi/RTL cluster math,
`ShapedLine` lifetime assumptions). Don't start editing until the profile
justifies it.
