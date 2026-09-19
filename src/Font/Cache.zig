const std = @import("std");
const dvui = @import("../dvui.zig");
const opentype = @import("opentype");
const Font = @import("../Font.zig");

const Size = dvui.Size;
const Texture = dvui.Texture;
const Backend = dvui.Backend;

const UserCoord = opentype.UserCoord;
const Buffer = opentype.Buffer;
const BidiFallbackResult = opentype.BidiFallbackResult;
const DiscoveryHandle = opentype.DiscoveryHandle;
const DiscoveryProperties = opentype.DiscoveryProperties;
const OtFont = opentype.Font;
const Renderer = opentype.Renderer;
const Cmap = opentype.Cmap;
const shaping = opentype.shaping;
const shapeBidiParagraphWithFallback = opentype.shapeBidiParagraphWithFallback;
const PlanCache = opentype.PlanCache;
const firstHardBreak = opentype.firstHardBreak;

const Source = Font.Source;
const FamilyEntry = Font.FamilyEntry;
const ShapedText = Font.ShapedText;
const WebFallback = Font.WebFallback;
const WebFallbackOptions = Font.WebFallbackOptions;
const web_fallback_enabled = Font.web_fallback_enabled;
const system_font_backend = Font.system_font_backend;
const mapFaceFile = Font.mapFaceFile;
const discoverSystemFont = Font.discoverSystemFont;
const array = Font.array;
const NAME_MAX_LEN = Font.NAME_MAX_LEN;
const max_variations = Font.max_variations;
const Error = Font.Error;

const Cache = @This();

database: std.ArrayList(Source) = .empty,
/// Values are `*Entry`, not `Entry`, so a `*Entry` handed out by
/// `getOrCreate`/`stackEntry` stays valid across later inserts into this
/// map: `std.HashMapUnmanaged` relocates its value storage on any
/// insert-triggered growth, not only when `reset()` evicts something, and
/// several callers (e.g. `ShapedText.fallback`, `ShapedLine` segments)
/// hold a `*Entry` across other fonts being resolved later in the same
/// frame.
cache: dvui.TrackingAutoHashMap(Font.CacheKey, *Entry, .get_and_put, void) = .empty,
/// Stack-level coverage cache, keyed per size like `cache`, so `reset()`
/// evicts stacks unused for a frame the same way.
/// Boxed for the same reason as `cache`: a `*ResolvedStack` stays valid
/// across later inserts (e.g. resolving a nested alias mid-build).
resolved_stacks: dvui.TrackingAutoHashMap(Font.CacheKey, *ResolvedStack, .get_and_put, void) = .empty,
/// Merged cmap coverage per family stack, keyed size-independently
/// (`coverageCacheKey`): `FallbackStack.build` sorts every cmap range of
/// every family in the stack, which is the same answer at every size.
/// Owns the `FallbackStack` each `ResolvedStack` borrows, and outlives
/// `reset()` -- the same stacks recur every frame.
coverage_cache: std.AutoHashMapUnmanaged(u64, Cmap.FallbackStack) = .empty,
/// Compiled GSUB/GPOS plans, reused across shape calls (and frames) for
/// the same font + script + features. Holds slices into font bytes, so
/// `evictUnreferencedFontBytes` clears it before freeing any.
shaping_plans: PlanCache = .{},
/// Full-pipeline shape results, so an unchanged widget (grid cells, static
/// labels) doesn't rerun bidi + GSUB/GPOS every frame. Lines unused for a
/// frame go at `reset()`; within a frame `max_shaped_line_bytes` caps it.
shaped_line_cache: dvui.TrackingAutoHashMap(ShapedLineKey, CachedShapedLine, .get_and_put, void) = .empty,
shaped_line_bytes: usize = 0,
/// Per-codepoint memo for `discoverDynamicFallback` -- caches a system
/// discovery lookup (or its failure, stored as `null`) so a codepoint
/// missing from every registered family only ever triggers one OS query,
/// not one per shaped line/frame that contains it.
dynamic_fallback: std.AutoHashMapUnmanaged(u21, ?Font) = .empty,
/// BCP 47 language (e.g. "ja", "zh-Hant") handed to the OS when
/// `discoverDynamicFallback` picks a font for a codepoint -- it decides
/// whether Han characters get Japanese, Korean, Simplified or
/// Traditional Chinese glyph shapes. `null` leaves it to the OS locale
/// (Android: the first CJK family in fonts.xml, Simplified Chinese). Set
/// it before text is shaped: codepoints already looked up stay memoized
/// in `dynamic_fallback`. Not copied; must outlive the `Cache`.
fallback_language: ?[]const u8 = null,
/// Set by the web backend at init. A codepoint no font covers renders as
/// tofu while its font downloads; arrival clears `shaped_line_cache`.
web_fallback: if (web_fallback_enabled) ?WebFallback else void = if (web_fallback_enabled) null else {},
/// Family aliases from `dvui.addFontFamily`: alias -> ordered family
/// names, most-preferred first. Unbounded in length, unlike the family
/// name a `Font` itself carries.
family_aliases: std.StringHashMapUnmanaged([]const FamilyEntry) = .empty,

pub fn deinit(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
    defer self.* = undefined;
    var it = self.cache.iterator();
    while (it.next()) |item| {
        item.value_ptr.*.deinit(gpa, backend);
        gpa.destroy(item.value_ptr.*);
    }
    self.cache.deinit(gpa);

    var sit = self.resolved_stacks.iterator();
    while (sit.next()) |item| {
        item.value_ptr.*.deinit(gpa);
        gpa.destroy(item.value_ptr.*);
    }
    self.resolved_stacks.deinit(gpa);

    var cit = self.coverage_cache.valueIterator();
    while (cit.next()) |fb| fb.deinit(gpa);
    self.coverage_cache.deinit(gpa);

    self.shaping_plans.deinit(gpa);

    self.clearShapedLineCache(gpa);
    self.shaped_line_cache.deinit(gpa);

    for (self.database.items) |*source| source.deinit();
    self.database.deinit(gpa);
    self.dynamic_fallback.deinit(gpa);
    if (web_fallback_enabled) {
        if (self.web_fallback) |*service| service.deinit(gpa);
    }

    var ait = self.family_aliases.iterator();
    while (ait.next()) |kv| {
        gpa.free(kv.key_ptr.*);
        gpa.free(kv.value_ptr.*);
    }
    self.family_aliases.deinit(gpa);
}

/// Register `alias` as an ordered fallback stack of family names.
/// A name in the list may itself be an alias; nesting is expanded when a
/// stack is resolved, so registration order doesn't matter. Nesting
/// deeper than `max_alias_depth`, or past `max_alias_expansions`, is cut
/// off with a warning (so cycles terminate), and a family reached twice
/// keeps its first position. Re-registering an alias replaces its list.
pub fn addFamily(self: *Cache, gpa: std.mem.Allocator, alias: []const u8, names: []const []const u8) std.mem.Allocator.Error!void {
    const list = try gpa.alloc(FamilyEntry, names.len);
    defer gpa.free(list);
    for (names, list) |n, *dst| dst.* = .{ .family = array(n) };
    return self.addFamilyEntries(gpa, alias, list);
}

/// `addFamily` with per-family size/weight/style/stretch overrides.
pub fn addFamilyEntries(self: *Cache, gpa: std.mem.Allocator, alias: []const u8, entries: []const FamilyEntry) std.mem.Allocator.Error!void {
    std.debug.assert(entries.len >= 1);
    const list = try gpa.dupe(FamilyEntry, entries);
    errdefer gpa.free(list);

    // A Font's family key is truncated to NAME_MAX_LEN, so a longer
    // alias could never be looked up under its full name.
    const alias_key = alias[0..@min(alias.len, NAME_MAX_LEN)];
    if (self.family_aliases.getEntry(alias_key)) |e| {
        gpa.free(e.value_ptr.*);
        e.value_ptr.* = list;
    } else {
        const owned_key = try gpa.dupe(u8, alias_key);
        errdefer gpa.free(owned_key);
        try self.family_aliases.put(gpa, owned_key, list);
    }
    // Stacks and their shaped lines flattened the old alias lists.
    var sit = self.resolved_stacks.iterator();
    while (sit.next()) |item| {
        item.value_ptr.*.deinit(gpa);
        gpa.destroy(item.value_ptr.*);
    }
    self.resolved_stacks.map.clearRetainingCapacity();
    self.clearShapedLineCache(gpa);
}

/// Past this, an entry's atlas is dropped at the next `reset()` and the
/// glyphs still in use re-rasterize.
/// ponytail: whole-atlas clear, not per-glyph LRU; add used flags and
/// compaction if steady-state churn keeps hitting the cap.
pub const max_atlas_height = 4096;

pub fn reset(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
    var it = self.cache.iterator();
    while (it.next_resetting()) |kv| {
        var fce = kv.value;
        fce.deinit(gpa, backend);
        gpa.destroy(fce);
    }
    var sit = self.resolved_stacks.iterator();
    while (sit.next_resetting()) |kv| {
        var stack = kv.value;
        stack.deinit(gpa);
        gpa.destroy(stack);
    }
    var lit = self.shaped_line_cache.iterator();
    while (lit.next_resetting()) |kv| {
        var line = kv.value;
        self.shaped_line_bytes -= line.byteSize();
        line.deinit(gpa);
    }
    // Draw commands from the last frame are submitted by now, so atlas
    // positions they captured can be dropped.
    var eit = self.cache.iterator();
    while (eit.next_peek()) |kv| kv.value.clearAtlasIfOversized(gpa);
    self.evictUnreferencedFontBytes(gpa);
}

/// Entries die after one unused frame, so a font shown every other frame
/// (scrolling, hover) would otherwise be freed and re-read from disk in a loop.
const evict_after_unreferenced_resets = 600;

/// `findSource` reads freed bytes back from `path` on next use.
fn evictUnreferencedFontBytes(self: *Cache, gpa: std.mem.Allocator) void {
    for (self.database.items) |*source| {
        if (source.path == null or source.bytes.len == 0) continue;
        if (self.bytesReferenced(source.bytes)) {
            source.unreferenced_resets = 0;
            continue;
        }
        source.unreferenced_resets += 1;
        if (source.unreferenced_resets < evict_after_unreferenced_resets) continue;
        source.unreferenced_resets = 0;
        // Cached shaping plans hold slices into these bytes.
        self.shaping_plans.clear(gpa);
        source.releaseBytes();
    }
}

/// Whether a live `Entry` or `ResolvedStack` still parses from `bytes`;
/// those are the only holders that outlive a frame.
fn bytesReferenced(self: *Cache, bytes: []const u8) bool {
    const start = @intFromPtr(bytes.ptr);
    const end = start + bytes.len;
    var eit = self.cache.iterator();
    while (eit.next_peek()) |kv| {
        const p = @intFromPtr(kv.value.parsed_font.data.ptr);
        if (p >= start and p < end) return true;
    }
    var sit = self.resolved_stacks.iterator();
    while (sit.next_peek()) |kv| {
        for (kv.value.raw_fonts) |raw_font| {
            const p = @intFromPtr(raw_font.data.ptr);
            if (p >= start and p < end) return true;
        }
    }
    return false;
}

/// Budget for `shaped_line_cache` before it is dropped wholesale. Counted
/// in bytes, not lines: line length is caller-controlled and unbounded.
const max_shaped_line_bytes = 16 * 1024 * 1024;

// ponytail: bulk clear rather than LRU -- eviction order only matters if
// the budget is hit routinely. Swap in an LRU if a real workload starts
// thrashing this.
fn clearShapedLineCache(self: *Cache, gpa: std.mem.Allocator) void {
    var it = self.shaped_line_cache.iterator();
    while (it.next()) |kv| kv.value_ptr.deinit(gpa);
    self.shaped_line_cache.map.clearRetainingCapacity();
    self.shaped_line_bytes = 0;
}

/// Keeps `line` for later `shapeLineText` calls with an equal `key`.
/// Failing to allocate just leaves the line uncached.
fn cacheShapedLine(self: *Cache, gpa: std.mem.Allocator, key: ShapedLineKey, line: *const Entry.ShapedLine, segments: []const CachedShapedLine.Segment) void {
    const owned_key, var value = CachedShapedLine.init(gpa, key, line, segments) catch return;
    const bytes = value.byteSize();
    if (bytes <= max_shaped_line_bytes) {
        if (self.shaped_line_bytes + bytes > max_shaped_line_bytes) self.clearShapedLineCache(gpa);
        // Only reached after a miss or after dropping the stale entry.
        if (self.shaped_line_cache.putNoClobber(gpa, owned_key, value)) {
            self.shaped_line_bytes += bytes;
            return;
        } else |_| {}
    }
    value.deinit(gpa);
}

const max_family_variants = 64;

/// CSS Fonts Level 3 closest-match (`opentype.discovery.findBestMatch`)
/// over every registered source sharing `font`'s family name.
pub fn findSource(self: *Cache, font: Font) struct { ?Source, ?Source } {
    var indices: [max_family_variants]usize = undefined;
    var properties: [max_family_variants]DiscoveryProperties = undefined;
    var count: usize = 0;
    for (self.database.items, 0..) |*source, i| {
        if (count >= indices.len) break;
        if (std.mem.eql(u8, font.familyName(), source.familyName())) {
            indices[count] = i;
            properties[count] = .{ .weight = source.weight, .style = source.style, .stretch = source.stretch };
            count += 1;
        }
    }
    if (count == 0) return .{ null, null };

    var index_buf: [max_family_variants]usize = undefined;
    const query: DiscoveryProperties = .{ .weight = font.weight, .style = font.style, .stretch = font.stretch };
    const chosen = opentype.discovery.findBestMatch(properties[0..count], query, index_buf[0..count]) catch return .{ null, null };
    const source = &self.database.items[indices[chosen]];
    if (source.bytes.len == 0) {
        // Dropped by `reset()` while unused; only sources with a path are.
        const path = source.path orelse return .{ null, null };
        if (system_font_backend == null) return .{ null, null };
        const mm = mapFaceFile(path) orelse return .{ null, null };
        source.memory_map = mm;
        source.bytes = mm.memory;
    }

    if (source.weight.value == font.weight.value and source.style == font.style and source.stretch.value == font.stretch.value) {
        return .{ source.*, null }; // exact match
    }
    return .{ null, source.* };
}

/// Resolves `font` to a concrete `Source`: exact match, closest CSS
/// variant match, OS discovery, or the embedded fallback -- in that
/// order. Shared by `getOrCreate` (full calibrated `Entry`) and
/// `resolveStack` (cheap parse-only probe for fallback-stack coverage).
fn resolveSource(self: *Cache, state_gpa: std.mem.Allocator, raw_font: Font) std.mem.Allocator.Error!Source {
    // An alias names no font of its own; on its own (outside resolveStack)
    // it resolves to its first family.
    var font = raw_font;
    var depth: u8 = 0;
    while (depth < max_alias_depth) : (depth += 1) {
        const list = self.family_aliases.get(font.familyName()) orelse break;
        font = list[0].apply(font);
    }
    const exact, const second = self.findSource(font);
    if (exact) |s| return s;

    const fname = font.name(state_gpa);
    defer state_gpa.free(fname);

    if (second) |s| {
        const sname = s.name(state_gpa);
        defer state_gpa.free(sname);
        dvui.log.warn("Font {s} not loaded in dvui, using second best {s}", .{ fname, sname });
        return s;
    } else if (discoverSystemFont(state_gpa, font)) |sys_source| {
        dvui.log.debug("Font {s} resolved via OS font discovery", .{fname});
        self.database.append(state_gpa, sys_source) catch |err| {
            var owned = sys_source;
            owned.deinit();
            return err;
        };
        return sys_source;
    } else {
        dvui.log.warn("Font {s} not loaded in dvui, using fallback", .{fname});
        return Source.fallbackFor(font.familyName());
    }
}

pub fn getOrCreate(self: *Cache, state_gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*Entry {
    const entry = try self.cache.getOrPut(state_gpa, font.cacheKey());
    if (entry.found_existing) return entry.value_ptr.*;
    errdefer self.cache.map.removeByPtr(entry.key_ptr);

    const fname = font.name(state_gpa);
    defer state_gpa.free(fname);

    const source = try self.resolveSource(state_gpa, font);

    //log.debug("FontCacheGet creating font hash {x} ptr {*} size {d} name \"{s}\"", .{ fontHash, bytes.ptr, font.size, font.name });

    const boxed = try state_gpa.create(Entry);
    errdefer state_gpa.destroy(boxed);
    boxed.* = Entry.init(state_gpa, &source, font) catch |err| blk: {
        dvui.log.err("Font {s} init got {any}, using fallback", .{ fname, err });
        // Fallback bytes under the *requested* hash, not the fallback
        // font's: callers (resolveStack/stackEntry) look this entry up by
        // the hash they asked for, and would find nothing otherwise.
        break :blk Entry.init(state_gpa, &Source.fallback, font) catch return error.OutOfMemory;
    };
    entry.value_ptr.* = boxed;
    //log.debug("- size {d} ascent {d} height {d}", .{ font.size, entry.ascent, entry.height });
    return boxed;
}

pub const ResolvedStack = struct {
    /// Font.cacheKey() this stack was resolved from; used as a shaped_line_cache key.
    font_key: Font.CacheKey = .{ .bytes = @splat(0) },
    /// Entry keys; entries themselves live in Cache.cache.
    entry_keys: []Font.CacheKey = &.{},
    /// Single-family Font per stack slot, used to lazily materialize a
    /// full calibrated Entry via `Cache.getOrCreate` the first time a
    /// shaped line actually assigns it a glyph -- see `shapeLineText`.
    family_fonts: []Font = &.{},
    /// Parse-only (no renderer/calibration) font per stack slot, owned
    /// by this struct and independent of `Cache.cache` -- cheap to build
    /// up front for coverage purposes without paying for a fallback
    /// family's Renderer init + ppem calibration until it's actually used.
    raw_fonts: []OtFont = &.{},
    /// Merged codepoint coverage across all entries. Borrowed from
    /// `Cache.coverage_cache`, which owns it -- do not free here.
    fallback: Cmap.FallbackStack = .{},
    /// Warned codepoint blocks (cp >> 8) to suppress duplicate warnings.
    logged_missing: std.AutoHashMapUnmanaged(u21, void) = .empty,
    /// Memoized `textSizeRawShaped(..., "M", .{})` result (screen pixels,
    /// pre-`ss`-descale) -- `sizeM`/`textHeight` are called pervasively
    /// (every label/slider/grid cell), so skip Buffer/segments/
    /// materializeShapedLine on every call past the first for this stack.
    m_size: ?Size = null,

    pub fn deinit(self: *ResolvedStack, gpa: std.mem.Allocator) void {
        for (self.raw_fonts) |*rf| rf.deinit(gpa);
        gpa.free(self.raw_fonts);
        gpa.free(self.entry_keys);
        gpa.free(self.family_fonts);
        self.logged_missing.deinit(gpa);
    }

    /// Stack index of the highest-priority entry covering `codepoint`,
    /// or null if nothing in the stack does (caller should fall back
    /// to entry 0 and expect `.notdef`).
    pub fn entryIndexFor(self: *const ResolvedStack, codepoint: u21) ?u8 {
        return self.fallback.entryIndexFor(codepoint);
    }
};

pub const max_alias_depth = 128;
/// Depth alone doesn't bound the flatten: `A -> [A, A]` fans out
/// 2^depth calls. This caps alias expansions per stack instead.
pub const max_alias_expansions = 256;
/// `Cmap.FallbackStack` indexes stack entries with a u8.
pub const max_stack_families = 64;

const FlattenedAliasStack = struct {
    fonts: [max_stack_families]Font = undefined,
    len: u8 = 0,
    expansions: u16 = 0,
    hit_limit: bool = false,

    fn slice(self: *const FlattenedAliasStack) []const Font {
        return self.fonts[0..self.len];
    }
};

fn flattenAliasStack(self: *const Cache, flattened: *FlattenedAliasStack, font: Font, depth: u8) void {
    const list = self.family_aliases.get(font.familyName()) orelse {
        if (flattened.len == max_stack_families) return;
        const font_key = font.cacheKey();
        for (flattened.slice()) |existing| if (std.mem.eql(u8, &existing.cacheKey().bytes, &font_key.bytes)) return;
        flattened.fonts[flattened.len] = font;
        flattened.len += 1;
        return;
    };
    if (depth == max_alias_depth or flattened.expansions == max_alias_expansions) {
        if (!flattened.hit_limit) dvui.log.warn("Font family alias {s} nests deeper than {d} or expands more than {d} times (cycle?), ignoring the rest", .{ font.familyName(), max_alias_depth, max_alias_expansions });
        flattened.hit_limit = true;
        return;
    }
    flattened.expansions += 1;
    for (list) |entry| self.flattenAliasStack(flattened, entry.apply(font), depth + 1);
}

/// Size-independent identity of a family stack: the same families at a
/// different size cover exactly the same codepoints, so they share one
/// `coverage_cache` entry.
fn coverageCacheKey(names: []const Font) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (names) |family_font| {
        var k = family_font.cacheKey();
        @memset(k.bytes[NAME_MAX_LEN..][0..4], 0); // size
        hasher.update(&k.bytes);
    }
    return hasher.final();
}

/// Load families and cache merged coverage per stack. No family gets a
/// full calibrated `Entry` here -- every family is parsed just enough to
/// read its cmap coverage; a full `Entry` (Renderer + ppem calibration)
/// is built lazily, in `shapeLineText` the first time shaped text needs
/// glyphs from that family, or via `primaryEntry` for the callers that
/// need stack metrics. Coverage-only callers (`ellipsis`, `sizeM` past
/// its first call) then never build one at all.
pub fn resolveStack(self: *Cache, state_gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*ResolvedStack {
    const font_key = font.cacheKey();
    if (self.resolved_stacks.get(font_key)) |existing| return existing;

    var flattened: FlattenedAliasStack = .{};
    self.flattenAliasStack(&flattened, font, 0);
    // A pure cycle yields no concrete family; resolveSource then falls back.
    if (flattened.len == 0) {
        flattened.fonts[0] = font;
        flattened.len = 1;
    }
    const names = flattened.slice();

    const entry_keys = try state_gpa.alloc(Font.CacheKey, names.len);
    errdefer state_gpa.free(entry_keys);
    const family_fonts = try state_gpa.alloc(Font, names.len);
    errdefer state_gpa.free(family_fonts);
    const raw_fonts = try state_gpa.alloc(OtFont, names.len);
    errdefer state_gpa.free(raw_fonts);
    const coverage_key = coverageCacheKey(names);
    const cached_coverage = self.coverage_cache.get(coverage_key);

    const per_entry_ranges = try state_gpa.alloc([]Cmap.Range, names.len);
    defer state_gpa.free(per_entry_ranges);

    var ranges_count: usize = 0;
    defer for (per_entry_ranges[0..ranges_count]) |r| state_gpa.free(r);
    var count: usize = 0;
    errdefer for (raw_fonts[0..count]) |*rf| rf.deinit(state_gpa);

    for (names) |family_font| {
        family_fonts[count] = family_font;
        entry_keys[count] = family_font.cacheKey();

        const source = try self.resolveSource(state_gpa, family_font);
        raw_fonts[count] = Entry.parseFontOrCollection(state_gpa, source.bytes, source.collection_index) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => Entry.parseFontOrCollection(state_gpa, Source.fallback.bytes, Source.fallback.collection_index) catch |e2| switch (e2) {
                error.OutOfMemory => |e| return e,
                else => unreachable, // embedded Vera.ttf is a known-good sfnt
            },
        };

        count += 1;

        if (cached_coverage != null) continue;
        const cmap_data = raw_fonts[count - 1].tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
        per_entry_ranges[ranges_count] = try Cmap.coverageRanges(cmap_data, state_gpa);
        ranges_count += 1;
    }

    const fallback = cached_coverage orelse blk: {
        var built = try Cmap.FallbackStack.build(state_gpa, per_entry_ranges[0..ranges_count]);
        errdefer built.deinit(state_gpa);
        try self.coverage_cache.put(state_gpa, coverage_key, built);
        break :blk built;
    };
    const boxed = try state_gpa.create(ResolvedStack);
    errdefer state_gpa.destroy(boxed);
    boxed.* = .{ .font_key = font_key, .entry_keys = entry_keys, .family_fonts = family_fonts, .raw_fonts = raw_fonts, .fallback = fallback };
    // Inserted only now, so a nested resolveStack during the build above
    // can't leave a half-built or stale slot behind.
    try self.resolved_stacks.put(state_gpa, font_key, boxed);
    return boxed;
}

/// The stack's primary (index 0) `Entry`, built on demand. Every caller
/// needing stack metrics (ascent, line height) goes through this rather
/// than `resolveStack` building one up front, so a stack that is only
/// ever asked about coverage never pays for a Renderer + calibration.
pub fn primaryEntry(self: *Cache, state_gpa: std.mem.Allocator, resolved: *const ResolvedStack) std.mem.Allocator.Error!*Entry {
    if (self.stackEntry(resolved, 0)) |existing| return existing;
    return self.getOrCreate(state_gpa, resolved.family_fonts[0]);
}

/// Entry at stack index; null if evicted by reset or not yet built.
pub fn stackEntry(self: *Cache, resolved: *const ResolvedStack, index: u8) ?*Entry {
    if (index >= resolved.entry_keys.len) return null;
    return if (self.cache.getPtr(resolved.entry_keys[index])) |p| p.* else null;
}

/// Codepoint-keyed counterpart to `discoverSystemFont`: instead of an
/// app-requested family name, asks the OS discovery backend which
/// installed font covers `codepoint` at all (CoreText's cascade list /
/// fontconfig's charset match) -- the "OS should pick some CJK/emoji
/// font for me" case `discoverSystemFont` can't handle, since it only
/// ever looks at family names the caller already named. Memoized in
/// `dynamic_fallback` (including failures, as `null`) so a codepoint
/// missing from every registered family costs one OS query total, not
/// one per shaped line that contains it.
///
/// Backends without a `selectFallbackForCodepoint` (e.g. the manifest
/// source) just return null here, same as "OS discovery found nothing".
///
/// `state_gpa` (not a frame arena): both `dynamic_fallback` (this
/// function's own memo) and `database`/the loaded font bytes (inside
/// `loadDynamicFallback`) live in `Cache`, which outlives the frame --
/// growing them with an arena that resets after this frame leaves their
/// backing storage dangling, corrupting the heap the next time anything
/// touches them (a later frame's `dynamic_fallback.get`, or the byte
/// buffer's owning-allocator free in `Cache.deinit`).
pub fn discoverDynamicFallback(self: *Cache, state_gpa: std.mem.Allocator, codepoint: u21) ?Font {
    if (system_font_backend == null) return null;
    if (self.dynamic_fallback.get(codepoint)) |cached| return cached;
    const found = self.loadDynamicFallback(state_gpa, codepoint);
    self.dynamic_fallback.put(state_gpa, codepoint, found) catch {};
    return found;
}

/// Reads the human-readable family name out of `bytes`' `name` table, for
/// `Source.display_family` -- best-effort, run once per newly-discovered
/// fallback font (memoized by `discoverDynamicFallback`).
fn readDisplayFamilyName(gpa: std.mem.Allocator, bytes: []const u8, collection_index: u32) [NAME_MAX_LEN:0]u8 {
    const parsed = Entry.parseFontOrCollection(gpa, bytes, collection_index) catch return @splat(0);
    defer parsed.deinit(gpa);
    const name_table = parsed.tableData(.{ 'n', 'a', 'm', 'e' }) orelse return @splat(0);
    var buf: [NAME_MAX_LEN]u8 = undefined;
    const found = opentype.parsing.Table.name.familyName(name_table, &buf) orelse return @splat(0);
    return array(found);
}

fn loadDynamicFallback(self: *Cache, state_gpa: std.mem.Allocator, codepoint: u21) ?Font {
    const SysBackend = system_font_backend orelse return null;
    if (!@hasDecl(SysBackend, "selectFallbackForCodepoint")) return null;

    var backend = SysBackend.init() catch return null;
    defer backend.deinit();
    if (@hasField(SysBackend, "language")) backend.language = self.fallback_language;

    var path_storage: [4096]u8 = undefined;
    const needs_allocator = @typeInfo(@TypeOf(SysBackend.selectFallbackForCodepoint)).@"fn".params.len == 4;
    const handle: DiscoveryHandle = if (needs_allocator)
        backend.selectFallbackForCodepoint(codepoint, &path_storage, state_gpa) catch return null
    else
        backend.selectFallbackForCodepoint(codepoint, &path_storage) catch return null;

    const p = switch (handle) {
        .path => |p| p,
        .memory, .url => return null, // fallback backends only ever return .path
    };

    // Dedupe by file identity, not codepoint: many codepoints resolve to
    // the same system font (e.g. every CJK char to one CJK font) -- key
    // the synthetic family on path+index so a second codepoint hitting
    // the same file reuses the already-loaded Source instead of
    // reloading a multi-MB font file.
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(p.path);
    hasher.update(std.mem.asBytes(&p.font_index));
    var family_buf: [32]u8 = undefined;
    const family_name = std.fmt.bufPrint(&family_buf, "fb:{x}", .{hasher.final()}) catch return null;
    const synthetic = Font.init(family_name);

    if (self.findSource(synthetic).@"0" != null) return synthetic; // already loaded

    const path = state_gpa.dupe(u8, p.path) catch return null;
    var mm = mapFaceFile(p.path) orelse {
        state_gpa.free(path);
        return null;
    };
    const bytes = mm.memory;
    self.database.append(state_gpa, .{
        .family = array(family_name),
        .bytes = bytes,
        .memory_map = mm,
        .allocator = state_gpa,
        .collection_index = p.font_index,
        .display_family = readDisplayFamilyName(state_gpa, bytes, p.font_index),
        .path = path,
    }) catch {
        mm.destroy(dvui.io);
        state_gpa.free(path);
        return null;
    };
    return synthetic;
}

/// Web counterpart to `discoverDynamicFallback`: a registered web fallback
/// font covering `codepoint`, else queues it for `processWebFallback` and
/// returns null (tofu until the font arrives).
fn webFallbackFont(self: *Cache, state_gpa: std.mem.Allocator, codepoint: u21) ?Font {
    if (!web_fallback_enabled) return null;
    const service = if (self.web_fallback) |*s| s else return null;
    if (service.registeredFontFor(codepoint)) |font| return webFallbackFamily(font);
    service.addMissingCodepoint(state_gpa, codepoint) catch {};
    return null;
}

fn webFallbackFamily(font: u16) Font {
    var buf: [16]u8 = undefined;
    return Font.init(std.fmt.bufPrint(&buf, "wf:{d}", .{font}) catch unreachable);
}

/// Hands the fonts `web_fallback` picked for the frame's missing
/// codepoints to the backend's `fetchFallbackFont`. Called from `Window.end`.
pub fn processWebFallback(self: *Cache, gpa: std.mem.Allocator, scratch: std.mem.Allocator) void {
    if (!web_fallback_enabled) return;
    const service = if (self.web_fallback) |*s| s else return;
    if (!service.needs_process) return;
    service.language = self.fallback_language;
    var fonts: std.ArrayList(u16) = .empty;
    defer fonts.deinit(scratch);
    service.process(gpa, scratch, &fonts) catch return;
    if (!@hasDecl(dvui.backend, "fetchFallbackFont")) return;
    var url_buf: [512]u8 = undefined;
    for (fonts.items) |font| {
        const url = service.url(font, &url_buf) catch {
            service.fontFailed(gpa, font);
            continue;
        };
        dvui.backend.fetchFallbackFont(font, url);
    }
}

/// `bytes` (allocated with `gpa`, owned by the cache from here on) arrived
/// for web fallback `font`.
pub fn webFallbackLoaded(self: *Cache, gpa: std.mem.Allocator, font: u16, bytes: []u8) void {
    if (!web_fallback_enabled) return gpa.free(bytes);
    const service = if (self.web_fallback) |*s| s else return gpa.free(bytes);
    if (!isKnownWebFallbackFont(service, font)) return gpa.free(bytes);
    const parsed = Entry.parseFontOrCollection(gpa, bytes, 0) catch {
        gpa.free(bytes);
        return service.fontFailed(gpa, font);
    };
    gpa.free(parsed.table_records);
    // Keep the decompressed sfnt, not the wOF2 bytes: every later
    // Entry.init reparses the source, and reset evicts entries after a
    // frame unused, so storing the compressed form pays Brotli again on
    // each reopen.
    const source_bytes = if (parsed.owned_data) blk: {
        gpa.free(bytes);
        break :blk parsed.data;
    } else bytes;
    self.database.append(gpa, .{
        .family = webFallbackFamily(font).family,
        .bytes = source_bytes,
        .allocator = gpa,
        .display_family = array(service.set.fonts[font].name),
    }) catch {
        gpa.free(source_bytes);
        return service.fontFailed(gpa, font);
    };
    service.fontLoaded(font);
    self.clearShapedLineCache(gpa);
}

/// Replaces the web fallback service. Fonts fetched so far stay loaded
/// but go unused.
pub fn setWebFallback(self: *Cache, gpa: std.mem.Allocator, options: WebFallbackOptions) void {
    if (!web_fallback_enabled) return;
    if (self.web_fallback) |*service| service.deinit(gpa);
    self.web_fallback = if (options.enabled) .{ .base_url = options.base_url } else null;
    self.clearShapedLineCache(gpa);
}

pub fn webFallbackFailed(self: *Cache, gpa: std.mem.Allocator, font: u16) void {
    if (!web_fallback_enabled) return;
    const service = if (self.web_fallback) |*s| s else return;
    if (isKnownWebFallbackFont(service, font)) service.fontFailed(gpa, font);
}

// The index round-trips through JS; a stray reply must not index out of bounds.
fn isKnownWebFallbackFont(service: *const WebFallback, font: u16) bool {
    return service.tables != null and font < service.set.fonts.len;
}

/// Shape text up to first newline, splitting runs by font stack coverage.
/// The returned line (and per-call temporaries) come from `output`;
/// `state_gpa` backs everything the cache keeps, so it must be the
/// allocator later passed to `Cache.deinit`, never a frame arena.
pub fn shapeLineText(self: *Cache, output: std.mem.Allocator, state_gpa: std.mem.Allocator, resolved: *ResolvedStack, text: []const u8, item: ?Font.ShapeItem, base_direction: opentype.unicode.Bidi.ParagraphDirection, style: Font.ShapeStyle) std.mem.Allocator.Error!Entry.ShapedLine {
    const has_tab = std.mem.indexOfScalar(u8, text, '\t') != null;
    const cache_key: ShapedLineKey = .{
        .font_key = resolved.font_key,
        .text = text,
        .item = item,
        .base_direction = base_direction,
        .features = style.features,
        // Tab-free text shapes the same wherever it starts, so it keeps one key.
        .tab = if (has_tab) .{ .size = style.tab_size, .origin_bits = @bitCast(style.tab_origin) } else null,
    };
    if (self.shaped_line_cache.getPtr(cache_key)) |cached| {
        if (try self.materializeShapedLine(output, cached)) |line| return line;
        // A segment's font was evicted from `cache` (unused since the
        // last reset -- e.g. scrolled out of view) since this line was
        // cached: the cached line is now unrenderable as-is, so drop it
        // and fall through to reshape from scratch instead of silently
        // rendering with missing segments.
        if (self.shaped_line_cache.fetchRemove(cache_key)) |kv| {
            var stale = kv.value;
            self.shaped_line_bytes -= stale.byteSize();
            stale.deinit(state_gpa);
        }
    }

    const decoded = try Entry.decodeLine(output, text);
    var line_codepoints = decoded.codepoints;
    var line_byte_offsets = decoded.byte_offsets;
    errdefer output.free(line_codepoints);
    errdefer output.free(line_byte_offsets);

    // Codepoint range matching `item`'s byte range; the shaper works in
    // codepoint indices. Clamped to what decodeLine produced, which stops
    // at a hard break.
    var item_cp: ?opentype.shaping.Item = null;
    if (item) |it| {
        var cp_start: usize = 0;
        while (cp_start < decoded.codepoints.len and decoded.byte_offsets[cp_start] < it.start) cp_start += 1;
        var cp_end: usize = cp_start;
        while (cp_end < decoded.codepoints.len and decoded.byte_offsets[cp_end] < it.end) cp_end += 1;
        item_cp = .{ .start = cp_start, .end = cp_end };
    }

    // Fallback font stack in priority order, from the cheap parse-only
    // fonts `resolveStack` built -- no `cache` lookup/eviction concerns
    // since `raw_fonts` is owned by `resolved` itself, followed by
    // dynamically discovered fonts (see below) for codepoints no
    // registered family covers.
    const static_fonts = resolved.entry_keys.len;
    var fonts_list: std.ArrayList(OtFont) = .empty;
    defer fonts_list.deinit(output);
    var keys_list: std.ArrayList(Font.CacheKey) = .empty;
    defer keys_list.deinit(output);
    var family_fonts_list: std.ArrayList(Font) = .empty;
    defer family_fonts_list.deinit(output);
    try fonts_list.appendSlice(output, resolved.raw_fonts[0..static_fonts]);
    try keys_list.appendSlice(output, resolved.entry_keys);
    try family_fonts_list.appendSlice(output, resolved.family_fonts[0..static_fonts]);

    // Query the OS (or the web fallback service) for each newly-uncovered
    // codepoint, skipping any already covered by a font discovered
    // earlier in this same line. Uncapped: a CJK web fallback font is
    // split into ~100 slices, so a long CJK line can need dozens, and
    // every missing codepoint must reach `webFallbackFont` to be fetched.
    var dynamic_cmaps: std.ArrayList([]const u8) = .empty;
    defer dynamic_cmaps.deinit(output);
    if (static_fonts > 0) {
        for (decoded.codepoints) |cp| {
            if (resolved.entryIndexFor(cp) != null) continue;
            var covered = false;
            for (dynamic_cmaps.items) |cm| {
                if (Cmap.lookup(cm, cp) != null) {
                    covered = true;
                    break;
                }
            }
            if (covered) continue;
            // discoverDynamicFallback's memo is keyed on codepoint only
            // (which family covers it, independent of size), so its
            // result carries Font.DefaultSize -- rescale to the size the
            // primary font was actually requested at.
            if (self.discoverDynamicFallback(state_gpa, cp) orelse self.webFallbackFont(state_gpa, cp)) |raw_dyn_font| {
                const dyn_font = raw_dyn_font.withSize(resolved.family_fonts[0].size);
                const dyn_key = dyn_font.cacheKey();
                var already_added = false;
                for (keys_list.items[static_fonts..]) |k| {
                    if (std.mem.eql(u8, &k.bytes, &dyn_key.bytes)) {
                        already_added = true;
                        break;
                    }
                }
                if (already_added) continue;
                // state_gpa: getOrCreate inserts into self.cache, which
                // outlives this frame -- output here may be a frame-scoped
                // arena that resets right after this call returns.
                const dyn_entry = try self.getOrCreate(state_gpa, dyn_font);
                try fonts_list.append(output, dyn_entry.parsed_font);
                try keys_list.append(output, dyn_key);
                try family_fonts_list.append(output, dyn_font);
                const cmap = dyn_entry.parsed_font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
                if (cmap.len > 0) try dynamic_cmaps.append(output, cmap);
            } else logMissingCoverage(resolved, state_gpa, cp);
        }
    }

    var result = Buffer.init(output);
    errdefer result.deinit();
    var segments: std.ArrayList(Entry.ShapedLine.EntrySegment) = .empty;
    errdefer segments.deinit(output);
    // Entry-hash twin of `segments`, cached in place of raw `*Entry`
    // pointers -- `cache`'s backing array can grow/rehash across frames
    // (loading a new bold/italic/mono variant), which would otherwise
    // leave a persisted segment's pointer dangling.
    var cache_segments: std.ArrayList(CachedShapedLine.Segment) = .empty;
    errdefer cache_segments.deinit(output);

    if (decoded.codepoints.len > 0 and fonts_list.items.len > 0) {
        // Bidi outer, font fallback inner, so visual reordering crosses font boundaries.
        // state_gpa backs the plan cache: `output` may be a frame arena,
        // and a cached plan has to outlive the call that built it.
        const shaped = shapeBidiParagraphWithFallback(output, fonts_list.items, decoded.codepoints, base_direction, &.{}, &.{}, style.features, item_cp, .{ .cache = &self.shaping_plans, .state_allocator = state_gpa }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => BidiFallbackResult{ .buffer = Buffer.init(output), .font_indices = &.{} },
        };
        defer output.free(shaped.font_indices);
        result.deinit();
        result = shaped.buffer;

        // Coalesce consecutive same-font glyphs into segments, in two
        // passes. `getOrCreate` lazily materializes the full calibrated
        // Entry (Renderer + ppem calibration) the first time a family is
        // actually assigned a glyph -- a stack fallback family that no
        // shaped text ever needs never pays that cost -- but it inserts
        // into `self.cache`, which can grow/rehash and invalidate every
        // `*Entry` handed out earlier in the same line. So pass 1 only
        // materializes (no pointers kept); pass 2 captures pointers only
        // once every insertion for this line is done.
        var g: usize = 0;
        while (g < shaped.font_indices.len) {
            const fi = shaped.font_indices[g];
            var h = g + 1;
            while (h < shaped.font_indices.len and shaped.font_indices[h] == fi) h += 1;
            // state_gpa: see note on the dynamic-fallback getOrCreate above.
            _ = try self.getOrCreate(state_gpa, family_fonts_list.items[fi]);
            g = h;
        }
        g = 0;
        while (g < shaped.font_indices.len) {
            const fi = shaped.font_indices[g];
            var h = g + 1;
            while (h < shaped.font_indices.len and shaped.font_indices[h] == fi) h += 1;
            const fce = try self.getOrCreate(state_gpa, family_fonts_list.items[fi]);
            try segments.append(output, .{ .entry = fce, .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
            try cache_segments.append(output, .{ .entry_key = keys_list.items[fi], .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
            g = h;
        }
        if (has_tab) applyTabStops(&result, segments.items, decoded.codepoints, style);
    }
    result.have_positions = true;

    // Rebase onto the item: from here on the line reads exactly like a
    // shape of `text[item.start..item.end]` alone -- clusters and byte
    // offsets relative to the item -- so every caller's byte-offset math
    // (prefix measurement, hit testing, selection) is unchanged by the
    // context having been there.
    if (item_cp) |it_cp| {
        const it = item.?;
        const new_codepoints = try output.dupe(u21, line_codepoints[it_cp.start..it_cp.end]);
        errdefer output.free(new_codepoints);
        const new_offsets = try output.alloc(u32, it_cp.end - it_cp.start + 1);
        for (new_offsets[0 .. it_cp.end - it_cp.start], line_byte_offsets[it_cp.start..it_cp.end]) |*dst, off| {
            dst.* = off -| @as(u32, @intCast(it.start));
        }
        new_offsets[it_cp.end - it_cp.start] = line_byte_offsets[it_cp.end] -| @as(u32, @intCast(it.start));
        for (result.info.items) |*info| info.cluster -= @intCast(it_cp.start);
        output.free(line_codepoints);
        output.free(line_byte_offsets);
        line_codepoints = new_codepoints;
        line_byte_offsets = new_offsets;
    }

    const cluster_tables = try result.buildClusterTables(output, line_byte_offsets);
    errdefer output.free(cluster_tables.starts);
    errdefer output.free(cluster_tables.ends);

    const line: Entry.ShapedLine = .{
        .allocator = output,
        .codepoints = line_codepoints,
        .byte_offsets = line_byte_offsets,
        .buffer = result,
        .cluster_starts = cluster_tables.starts,
        .cluster_ends = cluster_tables.ends,
        .segments = try segments.toOwnedSlice(output),
    };

    self.cacheShapedLine(state_gpa, cache_key, &line, cache_segments.items);
    cache_segments.deinit(output);

    return line;
}

/// Fonts have no real tab glyph (U+0009 is .notdef or a zero-width
/// control), so each tab becomes the space glyph with whatever advance
/// reaches the next stop, `tab_size` space advances apart from the line
/// start. Stops follow the pen in reading order: an RTL line counts
/// them from its right edge.
/// ponytail: pen positions in a mixed-direction line are visual, so a
/// tab inside its embedded opposite-direction run snaps off the
/// visual pen rather than a per-run one.
fn applyTabStops(buffer: *Buffer, segments: []const Entry.ShapedLine.EntrySegment, codepoints: []const u21, style: Font.ShapeStyle) void {
    const rtl = buffer.isRtl();
    var pen = style.tab_origin;
    for (0..segments.len) |si| {
        const seg = segments[if (rtl) segments.len - 1 - si else si];
        const font = seg.entry.parsed_font;
        const space_glyph = Cmap.lookup(font.tableData("cmap".*) orelse &.{}, ' ') orelse 0;
        const space_units: i32 = blk: {
            const hhea = opentype.parsing.Table.hhea.parse(font.tableData("hhea".*) orelse &.{}) catch break :blk 0;
            const hmtx = font.tableData("hmtx".*) orelse break :blk 0;
            break :blk opentype.parsing.Table.hmtx.metricForGlyph(hmtx, space_glyph, hhea.number_of_h_metrics).advance_width;
        };
        const space_px = seg.entry.toPixels(space_units);
        for (seg.glyph_start..seg.glyph_end) |k| {
            const g = if (rtl) seg.glyph_end - 1 - (k - seg.glyph_start) else k;
            const info = &buffer.info.items[g];
            const pos = &buffer.pos.items[g];
            if (codepoints[info.cluster] == '\t' and space_px > 0) {
                const stop = space_px * @as(f32, @floatFromInt(style.tab_size));
                var next = if (stop > 0) (@floor(pen / stop) + 1) * stop else pen;
                // CSS: a stop closer than half a space is skipped.
                if (stop > 0 and next - pen < space_px * 0.5) next += stop;
                info.codepoint = space_glyph;
                pos.x_offset = 0;
                pos.x_advance = @intFromFloat(@round((next - pen) * @as(f32, @floatFromInt(space_units)) / space_px));
            }
            pen += seg.entry.toPixels(pos.x_advance);
        }
    }
}

/// Everything that changes a `shapeLineText` result. Keys stored in
/// `shaped_line_cache` point `text` and `features` into their value's
/// `CachedShapedLine.buffer`; lookups borrow the caller's.
pub const ShapedLineKey = struct {
    font_key: Font.CacheKey,
    text: []const u8,
    item: ?Font.ShapeItem,
    base_direction: opentype.unicode.Bidi.ParagraphDirection,
    features: []const Font.Feature,
    tab: ?Tab,

    const Tab = struct { size: u8, origin_bits: u32 };

    // Equality over the full key, not the hash, decides a hit: crafted
    // text can collide any unkeyed hash, and a line shaped from other
    // bytes carries byte offsets that index past this `text`.
    pub const Context = struct {
        pub fn hash(_: Context, key: ShapedLineKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&key.font_key.bytes);
            hasher.update(key.text);
            if (key.item) |item| {
                hasher.update(std.mem.asBytes(&item.start));
                hasher.update(std.mem.asBytes(&item.end));
            }
            hasher.update(std.mem.asBytes(&key.base_direction));
            for (key.features) |feature| {
                hasher.update(&feature.tag);
                hasher.update(std.mem.asBytes(&feature.value));
            }
            if (key.tab) |tab| {
                hasher.update(std.mem.asBytes(&tab.size));
                hasher.update(std.mem.asBytes(&tab.origin_bits));
            }
            return hasher.final();
        }

        pub fn eql(_: Context, a: ShapedLineKey, b: ShapedLineKey) bool {
            // Scalar fields first: the two byte-slice compares below are
            // the expensive half, and most probes already differ here.
            if (a.text.len != b.text.len or a.base_direction != b.base_direction) return false;
            if (!std.meta.eql(a.item, b.item) or !std.meta.eql(a.tab, b.tab)) return false;
            if (a.features.len != b.features.len) return false;
            for (a.features, b.features) |fa, fb| {
                if (!std.meta.eql(fa, fb)) return false;
            }
            if (!std.mem.eql(u8, &a.font_key.bytes, &b.font_key.bytes)) return false;
            return std.mem.eql(u8, a.text, b.text);
        }
    };
};

/// Owned copy of a shape result kept in `shaped_line_cache`. Segments
/// reference fonts by `entry_hash` (stable across `cache` rehashes)
/// rather than `*Entry` (see `shapeLineText`'s cache_segments comment);
/// `materializeShapedLine` resolves them back to live pointers per hit.
const CachedShapedLine = struct {
    /// One allocation per cached line: backs every slice below plus the
    /// owning key's `text` and `features`.
    buffer: []align(buffer_alignment.toByteUnits()) u8,
    glyphs: []Glyph,
    codepoints: []u21,
    byte_offsets: []u32,
    cluster_starts: []u32,
    cluster_ends: []u32,
    segments: []Segment,

    const Segment = struct { entry_key: Font.CacheKey, glyph_start: u32, glyph_end: u32 };

    /// The `GlyphInfo`/`GlyphPosition` fields a shaped line is read
    /// through; the rest is shaper scratch, zeroed on a hit.
    const Glyph = struct { glyph_id: u32, cluster: u32, x_advance: i32, x_offset: i32, y_offset: i32 };

    const buffer_alignment: std.mem.Alignment = .fromByteUnits(@max(
        @alignOf(Glyph),
        @alignOf(u21),
        @alignOf(u32),
        @alignOf(Segment),
        @alignOf(Font.Feature),
    ));

    /// Returns the stored copy of `key` alongside the value; both are
    /// freed together by the value's `deinit`.
    fn init(gpa: std.mem.Allocator, key: ShapedLineKey, line: *const Entry.ShapedLine, segments: []const Segment) std.mem.Allocator.Error!struct { ShapedLineKey, CachedShapedLine } {
        const glyph_count = line.buffer.info.items.len;
        var size: usize = 0;
        try reserve(&size, Glyph, glyph_count);
        try reserve(&size, u21, line.codepoints.len);
        try reserve(&size, u32, line.byte_offsets.len);
        try reserve(&size, u32, line.cluster_starts.len);
        try reserve(&size, u32, line.cluster_ends.len);
        try reserve(&size, Segment, segments.len);
        try reserve(&size, Font.Feature, key.features.len);
        try reserve(&size, u8, key.text.len);
        const buffer = try gpa.alignedAlloc(u8, buffer_alignment, size);

        // Carve in the same order as `reserve` above so offsets match.
        var offset: usize = 0;
        const glyphs = carve(buffer, &offset, Glyph, glyph_count);
        for (glyphs, line.buffer.info.items, line.buffer.pos.items) |*glyph, info, pos| {
            glyph.* = .{ .glyph_id = info.codepoint, .cluster = info.cluster, .x_advance = pos.x_advance, .x_offset = pos.x_offset, .y_offset = pos.y_offset };
        }
        const codepoints = carve(buffer, &offset, u21, line.codepoints.len);
        @memcpy(codepoints, line.codepoints);
        const byte_offsets = carve(buffer, &offset, u32, line.byte_offsets.len);
        @memcpy(byte_offsets, line.byte_offsets);
        const cluster_starts = carve(buffer, &offset, u32, line.cluster_starts.len);
        @memcpy(cluster_starts, line.cluster_starts);
        const cluster_ends = carve(buffer, &offset, u32, line.cluster_ends.len);
        @memcpy(cluster_ends, line.cluster_ends);
        const owned_segments = carve(buffer, &offset, Segment, segments.len);
        @memcpy(owned_segments, segments);
        const features = carve(buffer, &offset, Font.Feature, key.features.len);
        @memcpy(features, key.features);
        const text = carve(buffer, &offset, u8, key.text.len);
        @memcpy(text, key.text);
        std.debug.assert(offset == size);

        var owned_key = key;
        owned_key.text = text;
        owned_key.features = features;
        return .{ owned_key, .{
            .buffer = buffer,
            .glyphs = glyphs,
            .codepoints = codepoints,
            .byte_offsets = byte_offsets,
            .cluster_starts = cluster_starts,
            .cluster_ends = cluster_ends,
            .segments = owned_segments,
        } };
    }

    fn reserve(size: *usize, comptime T: type, count: usize) std.mem.Allocator.Error!void {
        const bytes = std.math.mul(usize, @sizeOf(T), count) catch return error.OutOfMemory;
        const start = std.mem.alignForward(usize, size.*, @alignOf(T));
        size.* = std.math.add(usize, start, bytes) catch return error.OutOfMemory;
    }

    fn carve(buffer: []align(buffer_alignment.toByteUnits()) u8, offset: *usize, comptime T: type, count: usize) []T {
        const start = std.mem.alignForward(usize, offset.*, @alignOf(T));
        offset.* = start + @sizeOf(T) * count;
        return @as([*]T, @ptrCast(@alignCast(buffer[start..offset.*].ptr)))[0..count];
    }

    fn byteSize(self: CachedShapedLine) usize {
        return @sizeOf(ShapedLineKey) + @sizeOf(CachedShapedLine) + self.buffer.len;
    }

    fn deinit(self: *CachedShapedLine, gpa: std.mem.Allocator) void {
        gpa.free(self.buffer);
    }
};

/// Turns a `shaped_line_cache` hit into a caller-owned `Entry.ShapedLine`,
/// re-resolving each segment's `*Entry` from its stable hash -- `null` if
/// any segment's font was evicted from `cache` since the line was cached
/// (the caller reshapes from scratch rather than rendering with segments
/// silently missing).
fn materializeShapedLine(self: *Cache, gpa: std.mem.Allocator, cached: *const CachedShapedLine) std.mem.Allocator.Error!?Entry.ShapedLine {
    const segments = try gpa.alloc(Entry.ShapedLine.EntrySegment, cached.segments.len);
    errdefer gpa.free(segments);
    for (segments, cached.segments) |*dst, seg| {
        const entry = self.cache.getPtr(seg.entry_key) orelse {
            gpa.free(segments);
            return null;
        };
        dst.* = .{ .entry = entry.*, .glyph_start = seg.glyph_start, .glyph_end = seg.glyph_end };
    }

    var buffer = Buffer.init(gpa);
    errdefer buffer.deinit();
    try buffer.info.resize(gpa, cached.glyphs.len);
    try buffer.pos.resize(gpa, cached.glyphs.len);
    for (cached.glyphs, buffer.info.items, buffer.pos.items) |glyph, *info, *pos| {
        info.* = .{ .codepoint = glyph.glyph_id, .cluster = glyph.cluster };
        pos.* = .{ .x_advance = glyph.x_advance, .x_offset = glyph.x_offset, .y_offset = glyph.y_offset };
    }
    buffer.have_positions = true;

    const codepoints = try gpa.dupe(u21, cached.codepoints);
    errdefer gpa.free(codepoints);
    const byte_offsets = try gpa.dupe(u32, cached.byte_offsets);
    errdefer gpa.free(byte_offsets);
    const cluster_starts = try gpa.dupe(u32, cached.cluster_starts);
    errdefer gpa.free(cluster_starts);
    const cluster_ends = try gpa.dupe(u32, cached.cluster_ends);

    return .{
        .allocator = gpa,
        .codepoints = codepoints,
        .byte_offsets = byte_offsets,
        .buffer = buffer,
        .cluster_starts = cluster_starts,
        .cluster_ends = cluster_ends,
        .segments = segments,
    };
}

/// Warns once per uncovered codepoint block (`codepoint >> 8`).
fn logMissingCoverage(resolved: *ResolvedStack, gpa: std.mem.Allocator, codepoint: u21) void {
    const block: u21 = codepoint >> 8;
    if (resolved.logged_missing.get(block) != null) return;
    resolved.logged_missing.put(gpa, block, {}) catch {};
    // debug, not warn: this runs inside shaping, and on the web backend
    // every emitted log line costs a console flush in the hot path.
    dvui.log.debug("Font: no entry covers codepoint block U+{X:0>4}xx (e.g. U+{X:0>4}), falling back to entry 0 (.notdef)", .{ block, codepoint });
}

/// Seeds the growing measurement window from the memoized "M" advance
/// rather than a fixed 64 bytes: every grow re-shapes the whole window
/// from scratch, so a first guess far below the real break point costs
/// full extra bidi+GSUB+GPOS passes. "M" is near the widest glyph, so
/// mixed text fits well past the raw estimate -- over-seeding only costs
/// shaped bytes, under-seeding costs another shape.
fn initialMeasureWindow(resolved: *const ResolvedStack, mwidth: f32, newline_idx: usize) usize {
    const m_advance = if (resolved.m_size) |m| m.w else 0;
    if (!(m_advance > 0) or !std.math.isFinite(mwidth)) return @min(newline_idx, 64);
    const estimate = @min(@as(f32, @floatFromInt(newline_idx)), @max(0, mwidth / m_advance * 2 + 8));
    return @min(newline_idx, @max(16, @as(usize, @intFromFloat(estimate))));
}

pub fn textSizeRawShaped(
    self: *Cache,
    output: std.mem.Allocator,
    state_gpa: std.mem.Allocator,
    resolved: *ResolvedStack,
    text: []const u8,
    opts: Font.TextSizeOptions,
    style: Font.ShapeStyle,
) std.mem.Allocator.Error!Entry.MeasureResult {
    const mwidth = opts.max_width orelse dvui.max_float_safe;
    const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
    // Materialized before shaping: every line's height starts from the
    // primary's, whether or not any glyph ends up assigned to it.
    const default_height: f32 = if (self.primaryEntry(state_gpa, resolved)) |fe| fe.height else |_| 0;

    const hard_break = firstHardBreak(text);
    const newline_idx = if (hard_break) |hb| hb.start else text.len;
    // An item measures a known range of already-broken text, so the
    // growing measurement window (and its max_width break search) is
    // both unnecessary and wrong -- the context beyond the window is
    // exactly what it was asked to shape against.
    var window: usize = if (opts.max_width != null and opts.item == null) initialMeasureWindow(resolved, mwidth, newline_idx) else newline_idx;

    while (true) {
        var line = try self.shapeLineText(output, state_gpa, resolved, text[0..window], opts.item, opts.base_direction, style);
        errdefer line.deinit();

        // Refetched after shapeLineText, not hoisted above the loop:
        // shapeLineText can insert into self.cache while lazily
        // materializing fallback-family entries, which can grow/rehash
        // the map and invalidate any *Entry captured beforehand.
        const fallback_entry = self.stackEntry(resolved, 0);

        var x: f32 = 0;
        var minx: f32 = 0;
        var maxx: f32 = 0;
        var miny: f32 = 0;
        var maxy: f32 = default_height;
        var tw: f32 = 0;
        var th: f32 = default_height;
        var glyphs_used: usize = 0;
        var nearest_break = false;

        for (line.buffer.info.items, line.buffer.pos.items, 0..) |info, pos, gidx| {
            const fce = line.entryForGlyph(fallback_entry orelse break, gidx);
            const gi = try fce.glyphInfoGet(state_gpa, info.codepoint);
            const off_x = fce.toPixels(pos.x_offset);
            const adv = fce.toPixels(pos.x_advance);
            const adv_used = if (snap) @round(adv) else adv;

            minx = @min(minx, x + off_x + gi.leftBearing);
            maxx = @max(maxx, x + off_x + gi.leftBearing + gi.w);
            maxx = @max(maxx, x + adv_used);

            miny = @min(miny, fce.ascent - gi.topBearing);
            maxy = @max(maxy, fce.ascent - gi.topBearing + gi.h);

            if ((maxx - minx) > mwidth) {
                switch (opts.end_metric) {
                    .before => break,
                    .nearest => {
                        if ((maxx - minx) - mwidth >= mwidth - tw) {
                            break;
                        } else {
                            nearest_break = true;
                        }
                    },
                }
            }

            glyphs_used = gidx + 1;
            tw = maxx - minx;
            th = maxy - miny;
            x += adv_used;

            if (nearest_break) break;
        }

        const found_break = glyphs_used < line.buffer.info.items.len;
        if (found_break or window >= newline_idx) {
            // A break inside an RTL run cuts its logical prefix, which is
            // the buffer's trailing glyphs -- the walk above measured in
            // from the other end of the run.
            if (found_break and line.buffer.isRtl()) {
                if (fallback_entry) |fe| {
                    const fit = try fe.logicalPrefixForWidth(state_gpa, &line, mwidth, opts.end_metric, snap);
                    if (opts.end_idx) |endout| endout.* = fit.byte;
                    return .{ .size = .{ .w = fit.w, .h = th }, .line = line };
                }
            }
            if (opts.end_idx) |endout| {
                endout.* = line.byteOffsetForGlyph(glyphs_used);
                // consume the whole hard-break sequence (CRLF, LS, ...)
                if (!found_break) {
                    if (hard_break) |hb| endout.* += hb.len;
                }
            }
            return .{ .size = .{ .w = tw, .h = th }, .line = line };
        }

        line.deinit();
        window = @min(newline_idx, window * 4);
    }
}

pub const Entry = struct {
    name: []const u8, // gpa
    parsed_font: OtFont,
    renderer: Renderer,
    /// The one `sbix` strike this size needs, read from the source file
    /// for a face whose own bytes carry no `sbix` table. Owned here;
    /// `renderer.sbix_data` points into it. Null for a font that has no
    /// `sbix`, whose bytes didn't come from a file we can re-read, or --
    /// the usual case now -- that is mapped and so already has the table.
    sbix_strike: ?[]const u8,
    height: f32, // ascender - descender
    ascent: f32, // ascender
    em_height: f32, // measured M height
    /// Glyphs keyed by ID (post-shaping), not Unicode codepoint.
    /// Bounded by `Cache.max_atlas_height` across `reset()`s.
    glyphs: std.AutoHashMapUnmanaged(u32, GlyphInfo) = .empty,
    texture_atlas_cache: ?Texture = null,
    /// Allocated height (may exceed pack_y due to geometric growth).
    atlas_alloc_height: u32 = 0,
    /// Shelf-packer state; decoupled from GPU upload.
    atlas_width: u32 = 0,
    pack_x: u32 = pad,
    pack_y: u32 = pad,
    pack_row_height: u32 = 0,

    /// Padding (px) kept on every side of a packed glyph.
    const pad: u32 = 1;
    /// Shelf width chosen the first time any glyph is placed; wide
    /// enough that a typical page rarely needs more than a few rows.
    const initial_atlas_width: u32 = 512;

    const GlyphInfo = struct {
        leftBearing: f32, // pen x to glyph left
        topBearing: f32, // pen y to glyph top
        w: f32, // bounding box width
        h: f32, // bounding box height
        /// Raw pixel origin (top-left) in atlas; append-only, never moves.
        origin: @Vector(2, f32),
        /// True for color glyphs (COLR/sbix/CBDT); rendered as-is.
        is_color: bool,
        /// Rasterized bytes, gpa-owned: straight RGBA (w*h*4) when
        /// `is_color`, coverage (w*h) otherwise. Freed once uploaded
        /// when the backend has partial uploads (`drops_uploaded_pixels`);
        /// a rebuild re-rasterizes.
        pixels: []u8,
        /// Uploaded to current texture_atlas_cache yet.
        uploaded: bool,
    };

    pub fn toPixels(self: *const Entry, font_units: i32) f32 {
        return self.renderer.unitsToPixels(font_units);
    }

    /// Parses a plain sfnt, or -- for .ttc files, which several macOS
    /// system fonts ship as (e.g. PingFang SC, Kohinoor Devanagari,
    /// Apple Color Emoji) -- the first face of a font collection.
    fn parseFontOrCollection(gpa: std.mem.Allocator, ttf_bytes: []const u8, collection_index: u32) (OtFont.ParseError || error{OutOfMemory})!OtFont {
        if (ttf_bytes.len < 4 or !std.mem.eql(u8, ttf_bytes[0..4], "ttcf")) {
            return OtFont.parse(gpa, ttf_bytes);
        }
        const collection = try opentype.parsing.Collection.parse(gpa, ttf_bytes);
        defer gpa.free(collection.fonts);
        if (collection_index >= collection.fonts.len) {
            for (collection.fonts) |f| f.deinit(gpa);
            return error.InvalidCollection;
        }
        for (collection.fonts, 0..) |f, i| {
            if (i != collection_index) f.deinit(gpa);
        }
        return collection.fonts[collection_index];
    }

    const max_user_coords = max_variations + DiscoveryProperties.max_pinned_axes + 3;

    /// Axis coordinates in precedence order: `withVariation` pins, then
    /// the face's own named-instance pins (`face_pinned`), then synthetic
    /// `wght`/`wdth`/`ital`/`slnt` from `font.weight`/`stretch`/`style`
    /// -- so a variable font instances at the requested CSS weight, width
    /// and style (CSS Fonts 4 §7.1) instead of its default instance.
    /// Axes the font lacks are ignored.
    fn effectiveUserCoords(font: Font, face_pinned: []const UserCoord, buf: *[max_user_coords]UserCoord) []const UserCoord {
        const pinned = font.variations[0..font.variation_count];
        @memcpy(buf[0..pinned.len], pinned);
        var n = pinned.len;
        const style_coord: UserCoord = switch (font.style) {
            .normal => .{ .tag = "ital".*, .value = 0 },
            .italic => .{ .tag = "ital".*, .value = 1 },
            .oblique => .{ .tag = "slnt".*, .value = -14 },
        };
        const synthetic = [_]UserCoord{
            .{ .tag = "wght".*, .value = font.weight.value },
            .{ .tag = "wdth".*, .value = font.stretch.value * 100 },
            style_coord,
        };
        for ([_][]const UserCoord{ face_pinned, &synthetic }) |layer| {
            for (layer) |coord| {
                const already_set = for (buf[0..n]) |v| {
                    if (std.mem.eql(u8, &v.tag, &coord.tag)) break true;
                } else false;
                if (already_set) continue;
                buf[n] = coord;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Measures, rather than rasterizes: the calibration below only ever
    /// looked at the bitmap's row count, which is the grid-fit box the
    /// rasterizer computes before any scan conversion.
    fn measuredCapHeight(renderer: *Renderer, glyph_id: u16) ?f32 {
        const bounds = renderer.glyphBounds(glyph_id, .{}, dvui.currentWindow().lifo()) catch return null;
        if (bounds.rows == 0) return null;
        return @floatFromInt(bounds.rows);
    }

    /// The `sbix` strike for `ppem`, re-read from the file `source` came
    /// from. Null unless the source has a path -- an embedded or
    /// app-supplied font keeps whatever `sbix` its own bytes carry.
    fn loadSbixStrike(gpa: std.mem.Allocator, source: *const Source, ppem: f32) ?[]const u8 {
        // Only discovery sets `path`, and only a target with a discovery
        // backend has a filesystem to re-read it from (not wasm).
        if (system_font_backend == null) return null;
        const path = source.path orelse return null;
        const file = std.Io.Dir.cwd().openFile(dvui.io, path, .{}) catch return null;
        defer file.close(dvui.io);
        const rounded: u16 = @intFromFloat(std.math.clamp(@round(ppem), 1, std.math.maxInt(u16)));
        return opentype.parsing.Font.readSbixStrike(gpa, dvui.io, file, source.collection_index, rounded) catch null;
    }

    /// Load font, calibrating ppem so rendered M height matches font.size.
    pub fn init(gpa: std.mem.Allocator, source: *const Source, font: Font) Error!Entry {
        const min_pixel_size: f32 = 1;

        const fname = font.name(gpa);
        errdefer gpa.free(fname);

        const parsed_font = parseFontOrCollection(gpa, source.bytes, source.collection_index) catch |err| {
            dvui.log.warn("Font.Cache.Entry.init() opentype parse error {any} font {s}\n", .{ err, fname });
            return Error.FontError;
        };
        errdefer parsed_font.deinit(gpa);

        var ppem = @max(min_pixel_size, font.size);
        var coords_buf: [max_user_coords]UserCoord = undefined;
        const user_coords = effectiveUserCoords(font, source.pinnedAxes(), &coords_buf);
        var renderer = Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = user_coords }) catch |err| {
            dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
            return Error.FontError;
        };
        errdefer renderer.deinit(gpa);

        // Before the cap-height probe below: `glyphBounds` takes a
        // different path for a font with colour bitmaps, so the strike has
        // to be in place for the probe to measure what rendering will do.
        // The probe may then correct ppem; one strike is scaled to
        // whatever ppem ends up being, the same as a full strike list
        // would be, so the pick does not need revisiting.
        // A mapped face carries its whole `sbix` table already, and only
        // the strike actually rasterized faults in -- re-reading one
        // strike would copy megabytes to replace what's already there.
        const sbix_strike = if (parsed_font.tableData(.{ 's', 'b', 'i', 'x' }) != null)
            null
        else
            loadSbixStrike(gpa, source, ppem);
        errdefer if (sbix_strike) |strike| gpa.free(strike);
        if (sbix_strike) |strike| renderer.sbix_data = strike;

        const units_per_em_f: f32 = @floatFromInt(renderer.head.units_per_em);

        // Read hhea ascender/descender directly (not exposed in Table.hhea).
        const hhea_data = parsed_font.tableData(.{ 'h', 'h', 'e', 'a' });
        const raw_ascender: f32 = if (hhea_data != null and hhea_data.?.len >= 6)
            @floatFromInt(std.mem.readInt(i16, hhea_data.?[4..][0..2], .big))
        else
            units_per_em_f * 0.8;
        const raw_descender: f32 = if (hhea_data != null and hhea_data.?.len >= 6)
            @floatFromInt(std.mem.readInt(i16, hhea_data.?[6..][0..2], .big))
        else
            -units_per_em_f * 0.2;

        const cmap_data = parsed_font.tableData(.{ 'c', 'm', 'a', 'p' });
        const m_glyph_id: u16 = if (cmap_data) |cd| (Cmap.lookup(cd, 'M') orelse 0) else 0;

        var em_height = ppem;
        if (m_glyph_id != 0) probe: {
            // Measure M height, correct ppem if it overshoots font.size.
            const probe_h = measuredCapHeight(&renderer, m_glyph_id) orelse break :probe;
            if (probe_h <= 0) break :probe;
            const ratio = probe_h / ppem;
            const corrected = @max(min_pixel_size, font.size / ratio);
            renderer.setPpem(gpa, dvui.currentWindow().lifo(), corrected, .{ .hint_glyf = true, .user_coords = user_coords }) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            ppem = corrected;
            em_height = measuredCapHeight(&renderer, m_glyph_id) orelse ppem;
        }

        const scale_f = ppem / units_per_em_f;
        const entry: Entry = .{
            .name = fname,
            .parsed_font = parsed_font,
            .renderer = renderer,
            .sbix_strike = sbix_strike,
            .ascent = @trunc(raw_ascender * scale_f),
            .height = (raw_ascender - raw_descender) * scale_f,
            .em_height = em_height,
        };

        return entry;
    }

    pub fn deinit(self: *Entry, gpa: std.mem.Allocator, backend: Backend) void {
        defer self.* = undefined;
        gpa.free(self.name);
        var it = self.glyphs.valueIterator();
        while (it.next()) |gi| gpa.free(gi.pixels);
        self.glyphs.deinit(gpa);
        self.renderer.deinit(gpa);
        self.parsed_font.deinit(gpa);
        if (self.sbix_strike) |strike| gpa.free(strike);
        if (self.texture_atlas_cache) |tex| backend.textureDestroy(tex);
    }

    /// Without partial uploads every new glyph rebuilds the whole atlas,
    /// so re-rasterizing all of them each time would cost more than the
    /// memory saved.
    const drops_uploaded_pixels = Backend.has_texture_update_sub_rect;

    fn dropUploadedPixels(gpa: std.mem.Allocator, gi: *GlyphInfo) void {
        if (!drops_uploaded_pixels) return;
        gpa.free(gi.pixels);
        gi.pixels = &.{};
    }

    /// Refills `gi.pixels` dropped by `dropUploadedPixels`; false if the
    /// glyph no longer renders to its recorded size.
    fn restorePixels(self: *Entry, gpa: std.mem.Allocator, glyph_id: u32, gi: *GlyphInfo) std.mem.Allocator.Error!bool {
        if (gi.pixels.len > 0 or gi.w == 0 or gi.h == 0) return true;
        const rendered = self.renderer.renderGlyph(@intCast(glyph_id), .{}, dvui.currentWindow().lifo(), gpa) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return false,
        };
        if (@as(f32, @floatFromInt(rendered.bitmap.width)) != gi.w or @as(f32, @floatFromInt(rendered.bitmap.rows)) != gi.h) {
            rendered.deinit(gpa);
            return false;
        }
        std.debug.assert(rendered.bitmap.pixels_row_major.len == @as(usize, rendered.bitmap.width) * rendered.bitmap.rows * @as(usize, if (rendered.is_color) 4 else 1));
        gi.pixels = rendered.bitmap.pixels_row_major;
        return true;
    }

    pub fn clearAtlasIfOversized(self: *Entry, gpa: std.mem.Allocator) void {
        if (self.pack_y + self.pack_row_height + pad <= max_atlas_height) return;
        var it = self.glyphs.valueIterator();
        while (it.next()) |gi| gpa.free(gi.pixels);
        self.glyphs.clearAndFree(gpa);
        self.invalidateTextureAtlas();
        self.atlas_width = 0;
        self.pack_x = pad;
        self.pack_y = pad;
        self.pack_row_height = 0;
    }

    /// Destroy GPU texture and mark glyphs for re-upload on growth.
    fn invalidateTextureAtlas(self: *Entry) void {
        if (self.texture_atlas_cache) |tex| {
            dvui.textureDestroyLater(tex);
        }
        self.texture_atlas_cache = null;
        self.atlas_alloc_height = 0;
        var it = self.glyphs.valueIterator();
        while (it.next()) |gi| gi.uploaded = false;
    }

    /// Place glyph in atlas via shelf packing; append-only except on width grow.
    fn placeGlyph(self: *Entry, w: u32, h: u32) @Vector(2, f32) {
        if (self.atlas_width == 0) {
            self.atlas_width = @max(initial_atlas_width, w + 2 * pad);
        } else if (w + 2 * pad > self.atlas_width) {
            // Grow geometrically to avoid repack per wide glyph.
            self.atlas_width = @max(w + 2 * pad, self.atlas_width * 2);
            self.repackAll();
        }
        if (self.pack_x + w + pad > self.atlas_width) {
            self.pack_x = pad;
            self.pack_y += self.pack_row_height + pad;
            self.pack_row_height = 0;
        }
        const origin: @Vector(2, f32) = .{ @floatFromInt(self.pack_x), @floatFromInt(self.pack_y) };
        self.pack_x += w + pad;
        self.pack_row_height = @max(self.pack_row_height, h);
        return origin;
    }

    /// Repack all glyphs on atlas_width growth; forces texture rebuild.
    fn repackAll(self: *Entry) void {
        self.pack_x = pad;
        self.pack_y = pad;
        self.pack_row_height = 0;
        var it = self.glyphs.valueIterator();
        while (it.next()) |gi| {
            gi.origin = self.placeGlyphNoWidthCheck(@intFromFloat(gi.w), @intFromFloat(gi.h));
        }
        self.invalidateTextureAtlas();
    }

    fn placeGlyphNoWidthCheck(self: *Entry, w: u32, h: u32) @Vector(2, f32) {
        if (self.pack_x + w + pad > self.atlas_width) {
            self.pack_x = pad;
            self.pack_y += self.pack_row_height + pad;
            self.pack_row_height = 0;
        }
        const origin: @Vector(2, f32) = .{ @floatFromInt(self.pack_x), @floatFromInt(self.pack_y) };
        self.pack_x += w + pad;
        self.pack_row_height = @max(self.pack_row_height, h);
        return origin;
    }

    /// Blit glyph pixels to atlas; used by full rebuild and incremental upload.
    fn blitGlyph(gi: *const GlyphInfo, dst: []dvui.Color.PMA, dst_stride: u32, ox: u32, oy: u32) void {
        const out_w: u32 = @intFromFloat(gi.w);
        const out_h: u32 = @intFromFloat(gi.h);
        if (out_w == 0 or out_h == 0) return;
        var row: u32 = 0;
        while (row < out_h) : (row += 1) {
            var col: u32 = 0;
            while (col < out_w) : (col += 1) {
                const src_index = row * out_w + col;
                const dest = (oy + row) * dst_stride + (ox + col);
                dst[dest] = if (gi.is_color) blk: {
                    // Renderer output is straight (non-premultiplied) alpha; PMA
                    // needs it premultiplied or edge pixels over-brighten on dark
                    // backgrounds (RGB doesn't fall off with alpha near the edge).
                    const src = gi.pixels[src_index * 4 ..][0..4];
                    break :blk .fromColor(.{ .r = src[0], .g = src[1], .b = src[2], .a = src[3] });
                } else blk: {
                    // Coverage-only: broadcast coverage as premultiplied white.
                    const coverage = gi.pixels[src_index];
                    break :blk .{ .r = coverage, .g = coverage, .b = coverage, .a = coverage };
                };
            }
        }
    }

    /// Rebuild whole GPU texture from cached bitmaps at new_height.
    fn rebuildAtlasTexture(self: *Entry, gpa: std.mem.Allocator, new_height: u32) Backend.TextureError!void {
        const pixel_count = @as(usize, self.atlas_width) * new_height;
        const pixels = try gpa.alloc(dvui.Color.PMA, pixel_count);
        defer gpa.free(pixels);
        @memset(pixels, .transparent);

        var it = self.glyphs.iterator();
        while (it.next()) |kv| {
            const gi = kv.value_ptr;
            if (try self.restorePixels(gpa, kv.key_ptr.*, gi)) {
                blitGlyph(gi, pixels, self.atlas_width, @intFromFloat(gi.origin[0]), @intFromFloat(gi.origin[1]));
            }
            gi.uploaded = true;
            dropUploadedPixels(gpa, gi);
        }

        const new_tex = try dvui.textureCreate(pixels, .{ .width = self.atlas_width, .height = new_height });
        if (self.texture_atlas_cache) |old| dvui.textureDestroyLater(old);
        self.texture_atlas_cache = new_tex;
        self.atlas_alloc_height = new_height;
    }

    /// Ensure all placed glyphs have reached GPU texture (full build or incremental upload).
    pub fn getTextureAtlas(self: *Entry, gpa: std.mem.Allocator, backend: Backend) Backend.TextureError!Texture {
        if (self.atlas_width == 0) {
            if (self.texture_atlas_cache) |tex| return tex;
            const blank = [1]dvui.Color.PMA{.transparent};
            self.texture_atlas_cache = try dvui.textureCreate(&blank, .{ .width = 1, .height = 1 });
            return self.texture_atlas_cache.?;
        }

        const needed_height = self.pack_y + self.pack_row_height + pad;
        if (self.texture_atlas_cache == null or needed_height > self.atlas_alloc_height) {
            // Grow geometrically so most new glyphs don't force a resize.
            const new_height = @max(needed_height, self.atlas_alloc_height * 2);
            try self.rebuildAtlasTexture(gpa, new_height);
            return self.texture_atlas_cache.?;
        }

        const tex = self.texture_atlas_cache.?;

        // Steady state: every glyph already on the GPU texture, nothing
        // to blit -- skip the full-atlas-sized scratch allocation below.
        var any_pending = false;
        var scan_it = self.glyphs.valueIterator();
        while (scan_it.next()) |gi| {
            if (!gi.uploaded) {
                any_pending = true;
                break;
            }
        }
        if (!any_pending) return tex;

        if (comptime !drops_uploaded_pixels) {
            try self.rebuildAtlasTexture(gpa, self.atlas_alloc_height);
            return self.texture_atlas_cache.?;
        }

        // textureUpdateSubRect requires atlas-width stride; share buffer across glyphs.
        // Left unset: each upload reads only the rect its glyph was just blitted into.
        const row_pixels = try gpa.alloc(dvui.Color.PMA, @as(usize, self.atlas_width) * needed_height);
        defer gpa.free(row_pixels);

        var it = self.glyphs.iterator();
        while (it.next()) |kv| {
            const gi = kv.value_ptr;
            if (gi.uploaded) continue;
            const out_w: u32 = @intFromFloat(gi.w);
            const out_h: u32 = @intFromFloat(gi.h);
            if (out_w == 0 or out_h == 0) {
                gi.uploaded = true;
                continue;
            }
            // `glyphInfoGet` only measured the glyph; rasterize it now.
            if (!try self.restorePixels(gpa, kv.key_ptr.*, gi)) {
                gi.uploaded = true;
                continue;
            }
            const ox: u32 = @intFromFloat(gi.origin[0]);
            const oy: u32 = @intFromFloat(gi.origin[1]);
            blitGlyph(gi, row_pixels, self.atlas_width, ox, oy);
            try backend.textureUpdateSubRect(tex, @ptrCast(row_pixels.ptr), ox, oy, out_w, out_h);
            gi.uploaded = true;
            dropUploadedPixels(gpa, gi);
        }
        return tex;
    }

    /// Rasterize glyph and place in atlas; getTextureAtlas uploads later.
    pub fn glyphInfoGet(self: *Entry, gpa: std.mem.Allocator, glyph_id: u32) std.mem.Allocator.Error!GlyphInfo {
        if (self.glyphs.get(glyph_id)) |gi| return gi;

        // Measure only: layout and atlas placement need the box, not the
        // coverage. `restorePixels` rasterizes on the way to the GPU, so a
        // glyph that is measured but never drawn is never scan-converted.
        var gi: GlyphInfo = blk: {
            const bounds = self.renderer.glyphBounds(@intCast(glyph_id), .{}, dvui.currentWindow().lifo()) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    dvui.log.warn("Font.Cache.Entry.glyphInfoGet() opentype render error {any} font {s} glyph {d}\n", .{ err, self.name, glyph_id });
                    break :blk .{ .leftBearing = 0, .topBearing = 0, .w = 0, .h = 0, .origin = .{ 0, 0 }, .is_color = false, .pixels = &.{}, .uploaded = false };
                },
            };
            break :blk .{
                .leftBearing = @floatFromInt(bounds.left),
                .topBearing = @floatFromInt(bounds.top),
                .w = @floatFromInt(bounds.width),
                .h = @floatFromInt(bounds.rows),
                .origin = .{ 0, 0 },
                .is_color = bounds.is_color,
                .pixels = &.{},
                .uploaded = false,
            };
        };

        if (gi.w > 0 and gi.h > 0) {
            gi.origin = self.placeGlyph(@intFromFloat(gi.w), @intFromFloat(gi.h));
        }

        try self.glyphs.put(gpa, glyph_id, gi);
        return gi;
    }

    pub const ShapedLine = struct {
        allocator: std.mem.Allocator,
        codepoints: []u21,
        /// Byte offset of each codepoint, plus trailing end offset.
        byte_offsets: []u32,
        buffer: Buffer,
        /// Used cluster starts/ends (byte offset ranges).
        cluster_starts: []u32,
        cluster_ends: []u32,
        /// Glyph ranges per Entry; built by shapeLineText.
        segments: []EntrySegment = &.{},

        pub const EntrySegment = struct { entry: *Entry, glyph_start: u32, glyph_end: u32 };

        pub fn deinit(self: *ShapedLine) void {
            self.buffer.deinit();
            self.allocator.free(self.codepoints);
            self.allocator.free(self.byte_offsets);
            self.allocator.free(self.cluster_starts);
            self.allocator.free(self.cluster_ends);
            self.allocator.free(self.segments);
        }

        /// Entry that shaped glyph at index; fallback for non-stack lines.
        pub fn entryForGlyph(self: ShapedLine, fallback: *Entry, glyph_idx: usize) *Entry {
            for (self.segments) |seg| {
                if (glyph_idx >= seg.glyph_start and glyph_idx < seg.glyph_end) return seg.entry;
            }
            return fallback;
        }

        /// Byte range of cluster at glyph_idx; correct in RTL runs.
        pub fn clusterByteRange(self: ShapedLine, glyph_idx: usize) Buffer.ByteRange {
            return self.buffer.clusterByteRange(self.cluster_starts, self.cluster_ends, self.byte_offsets, glyph_idx);
        }

        /// Byte offset after first glyph_count glyphs; visual order, not logical.
        pub fn byteOffsetForGlyph(self: ShapedLine, glyph_count: usize) usize {
            return self.buffer.byteOffsetForGlyph(self.byte_offsets, glyph_count);
        }

        /// Inverse of byteOffsetForGlyph; slice shape at byte boundary without reshaping.
        pub fn glyphLimitForByteOffset(self: ShapedLine, byte_offset: usize) usize {
            return self.buffer.glyphLimitForByteOffset(self.byte_offsets, byte_offset);
        }

        /// Glyphs of the logical byte prefix [0, byte_offset); RTL-correct.
        pub fn logicalPrefixGlyphs(self: ShapedLine, byte_offset: usize) Buffer.GlyphRange {
            return self.buffer.logicalPrefixGlyphs(self.byte_offsets, byte_offset);
        }

        /// Reads right to left, so a logical prefix sits at its right edge.
        pub fn isRtl(self: ShapedLine) bool {
            return self.buffer.isRtl();
        }

        /// Both directions in one shape: no logical prefix of it covers a
        /// contiguous stretch of the line, so measuring or slicing one by
        /// byte offset is meaningless whichever end you count from.
        pub fn isMixedDirection(self: ShapedLine) bool {
            var saw_forward = false;
            var saw_back = false;
            var prev: ?u32 = null;
            for (self.buffer.info.items) |info| {
                if (prev) |p| {
                    if (info.cluster > p) saw_forward = true;
                    if (info.cluster < p) saw_back = true;
                }
                prev = info.cluster;
            }
            return saw_forward and saw_back;
        }
    };

    /// Decode text to first newline into codepoints + byte offsets.
    fn decodeLine(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!struct { codepoints: []u21, byte_offsets: []u32 } {
        var codepoints: std.ArrayList(u21) = .empty;
        errdefer codepoints.deinit(gpa);
        var byte_offsets: std.ArrayList(u32) = .empty;
        errdefer byte_offsets.deinit(gpa);
        // Upper-bound presize (codepoints/offsets <= byte count) avoids
        // per-append growth reallocations for every shaped line.
        try codepoints.ensureTotalCapacityPrecise(gpa, text.len);
        try byte_offsets.ensureTotalCapacityPrecise(gpa, text.len + 1);

        const hard_break_at = if (firstHardBreak(text)) |hb| hb.start else text.len;
        var i: usize = 0;
        while (i < text.len) {
            if (i >= hard_break_at) break;
            const cplen = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + cplen > text.len) break;
            const cp = std.unicode.utf8Decode(text[i..][0..cplen]) catch break;
            try byte_offsets.append(gpa, @intCast(i));
            try codepoints.append(gpa, cp);
            i += cplen;
        }
        try byte_offsets.append(gpa, @intCast(i));

        const cp_slice = try codepoints.toOwnedSlice(gpa);
        errdefer gpa.free(cp_slice);
        const off_slice = try byte_offsets.toOwnedSlice(gpa);
        errdefer gpa.free(off_slice);
        return .{ .codepoints = cp_slice, .byte_offsets = off_slice };
    }

    pub const MeasureResult = struct {
        size: Size,
        line: ShapedLine,
    };

    /// Size of the logical byte prefix [0, byte_offset) of an already
    /// shaped line; no reshaping. In an RTL run that prefix is the
    /// buffer's trailing glyphs, not its leading ones.
    pub fn measureLogicalPrefix(self: *Entry, state_gpa: std.mem.Allocator, line: *const ShapedLine, byte_offset: usize, snap: bool) std.mem.Allocator.Error!Size {
        const r = line.logicalPrefixGlyphs(byte_offset);
        // Per-glyph entry, not opentype.measureGlyphRange: an RTL run
        // from a fallback font must measure against that font's metrics.
        var x: f32 = 0;
        var minx: f32 = 0;
        var maxx: f32 = 0;
        var miny: f32 = 0;
        var maxy: f32 = self.height;
        for (line.buffer.info.items[r.start..r.end], line.buffer.pos.items[r.start..r.end], r.start..) |info, pos, gidx| {
            const entry = line.entryForGlyph(self, gidx);
            const gi = try entry.glyphInfoGet(state_gpa, info.codepoint);
            const off_x = entry.toPixels(pos.x_offset);
            const adv = entry.toPixels(pos.x_advance);
            const adv_used = if (snap) @round(adv) else adv;
            minx = @min(minx, x + off_x + gi.leftBearing);
            maxx = @max(maxx, x + off_x + gi.leftBearing + gi.w);
            maxx = @max(maxx, x + adv_used);
            miny = @min(miny, entry.ascent - gi.topBearing);
            maxy = @max(maxy, entry.ascent - gi.topBearing + gi.h);
            x += adv_used;
        }
        return .{ .w = maxx - minx, .h = maxy - miny };
    }

    pub const PrefixFit = struct { byte: usize, w: f32 };

    /// Longest logical byte prefix of `line` that fits `mwidth` (device
    /// pixels), and its width: the inverse of `measureLogicalPrefix`, and
    /// exact in both directions because it is found by measuring through
    /// that same call at each cluster boundary.
    pub fn logicalPrefixForWidth(self: *Entry, state_gpa: std.mem.Allocator, line: *const ShapedLine, mwidth: f32, end_metric: Font.EndMetric, snap: bool) std.mem.Allocator.Error!PrefixFit {
        var best: PrefixFit = .{ .byte = 0, .w = 0 };
        // ponytail: re-measures from the run's logical start per candidate
        // (quadratic in glyphs), which a fragment-sized run never notices;
        // make it incremental if whole-paragraph lines ever come through.
        for (line.cluster_ends) |boundary| {
            const w = (try self.measureLogicalPrefix(state_gpa, line, boundary, snap)).w;
            if (w > mwidth) {
                if (end_metric == .nearest and w - mwidth < mwidth - best.w) return .{ .byte = boundary, .w = w };
                return best;
            }
            best = .{ .byte = boundary, .w = w };
        }
        return best;
    }

    /// Pen x, in device pixels from the run's left edge, of a caret
    /// sitting after `byte_offset` logical bytes -- advances only.
    /// `measureLogicalPrefix` answers an ink bounding box, whose
    /// per-glyph side bearings and overhang make it non-additive: a
    /// caret placed from it drifts off the pen positions `renderText`
    /// actually draws the glyphs at, by a different amount per prefix.
    pub fn caretPenOffset(self: *Entry, line: *const ShapedLine, byte_offset: usize, snap: bool) f32 {
        const spot = line.buffer.caretSpot(line.byte_offsets, line.codepoints, byte_offset);
        var x: f32 = 0;
        var cluster_w: f32 = 0;
        for (line.buffer.pos.items[0..spot.glyph_end], 0..) |pos, gidx| {
            const adv = line.entryForGlyph(self, gidx).toPixels(pos.x_advance);
            const used = if (snap) @round(adv) else adv;
            if (gidx < spot.glyph_start) x += used else cluster_w += used;
        }
        if (spot.glyph_end == spot.glyph_start) return x;
        const gdef = line.entryForGlyph(self, spot.glyph_start).parsed_font.tableData("GDEF".*);
        return x + cluster_w * line.buffer.caretFraction(spot, gdef);
    }

    /// Inverse of `caretPenOffset`: the caret stop nearest pen x, one
    /// per grapheme. Pen offsets run backwards through an RTL run's
    /// text, so this picks by distance rather than walking until a
    /// width is exceeded.
    /// ponytail: quadratic in glyphs, same as `logicalPrefixForWidth`;
    /// one click, one fragment-sized run.
    pub fn byteAtPenOffset(self: *Entry, line: *const ShapedLine, x: f32, snap: bool) usize {
        var best: usize = 0;
        var best_d: f32 = @abs(self.caretPenOffset(line, 0, snap) - x);
        var graphemes = opentype.unicode.GraphemeBreakIterator.init(line.codepoints);
        while (graphemes.next()) |_| {
            const boundary = line.byte_offsets[graphemes.pos];
            const d = @abs(self.caretPenOffset(line, boundary, snap) - x);
            if (d < best_d) {
                best_d = d;
                best = boundary;
            }
        }
        return best;
    }
};
test "Cache.buildCoverage: earlier stack entries win overlapping coverage" {
    const gpa = std.testing.allocator;
    const Range = Cmap.Range;

    // entry 0 (highest priority): covers Latin-1 and a slice of CJK
    const entry0 = [_]Range{ .{ .start = 0x20, .end = 0xFF }, .{ .start = 0x4E00, .end = 0x4E10 } };
    // entry 1: overlaps entry 0's CJK slice, also covers Cyrillic (ranges
    // must stay ascending -- FallbackStack.build's binary search assumes
    // it, same invariant `coverageRanges` guarantees for a real font's cmap)
    const entry1 = [_]Range{ .{ .start = 0x400, .end = 0x4FF }, .{ .start = 0x4E00, .end = 0x9FFF } };

    var fallback = try Cmap.FallbackStack.build(gpa, &.{ &entry0, &entry1 });
    defer fallback.deinit(gpa);

    var resolved: Cache.ResolvedStack = .{ .fallback = fallback };

    // Covered only by entry 0.
    try std.testing.expectEqual(@as(?u8, 0), resolved.entryIndexFor('A'));
    // Covered only by entry 1.
    try std.testing.expectEqual(@as(?u8, 1), resolved.entryIndexFor(0x410));
    // Overlap: entry 0 must win even though entry 1 also covers it.
    try std.testing.expectEqual(@as(?u8, 0), resolved.entryIndexFor(0x4E05));
    // Only entry 1 covers past entry 0's CJK slice.
    try std.testing.expectEqual(@as(?u8, 1), resolved.entryIndexFor(0x5000));
    // Covered by nothing in the stack.
    try std.testing.expectEqual(@as(?u8, null), resolved.entryIndexFor(0x1F600));
}

test "Cache.shapeLineText: mixed-script text splits glyphs by stack entry" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    // Registered as a database source, not via addFont: addFont eagerly
    // materializes a full Entry, which would defeat this test's point (that
    // a fallback family stays unmaterialized until shaped text needs it).
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const stack: Font = .init("TestStack");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    // Fallback family (index 1) isn't materialized into a full Entry until
    // some shaped text actually needs it.
    try std.testing.expectEqual(@as(?*Cache.Entry, null), cw.fonts.stackEntry(resolved, 1));

    // "AB" (Latin) + two Hangul syllables (Korean) + "CD" (Latin) -- Vera
    // has no Hangul glyphs and NotoSansKR-Regular has no use registering it
    // as the primary family, so coverage is naturally disjoint here.
    var line = try cw.fonts.shapeLineText(std.testing.allocator, std.testing.allocator, resolved, "AB\u{AC00}\u{AC01}CD", null, .auto, .{});
    defer line.deinit();

    // TestKorean is a fallback family (stack index 1), materialized lazily
    // by the shapeLineText call above rather than eagerly by resolveStack.
    const latin_entry = cw.fonts.stackEntry(resolved, 0).?;
    const korean_entry = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expect(latin_entry != korean_entry);

    try std.testing.expectEqual(@as(usize, 3), line.segments.len);
    try std.testing.expectEqual(latin_entry, line.segments[0].entry);
    try std.testing.expectEqual(korean_entry, line.segments[1].entry);
    try std.testing.expectEqual(latin_entry, line.segments[2].entry);

    try std.testing.expectEqual(@as(u32, 0), line.segments[0].glyph_start);
    try std.testing.expectEqual(line.segments[1].glyph_start, line.segments[0].glyph_end);
    try std.testing.expectEqual(line.segments[2].glyph_start, line.segments[1].glyph_end);
    try std.testing.expectEqual(@as(u32, @intCast(line.buffer.info.items.len)), line.segments[2].glyph_end);

    for (0..line.buffer.info.items.len) |gidx| {
        const expected = line.entryForGlyph(latin_entry, gidx);
        if (gidx < line.segments[0].glyph_end) {
            try std.testing.expectEqual(latin_entry, expected);
        } else if (gidx < line.segments[1].glyph_end) {
            try std.testing.expectEqual(korean_entry, expected);
        } else {
            try std.testing.expectEqual(latin_entry, expected);
        }
    }
}

test "Cache.resolveStack: per-family entry overrides apply to the stack fonts" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamilyEntries("TestStack", &.{
        .{ .family = array("TestLatin") },
        .{ .family = array("TestKorean"), .size_scale = 0.5, .weight = .bold },
    });
    const stack: Font = .init("TestStack");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    try std.testing.expectEqual(stack.size, resolved.family_fonts[0].size);
    try std.testing.expectEqual(Font.Weight.normal, resolved.family_fonts[0].weight);
    try std.testing.expectEqual(stack.size * 0.5, resolved.family_fonts[1].size);
    try std.testing.expectEqual(Font.Weight.bold, resolved.family_fonts[1].weight);

    // Metrics come from stack entry 0, so they track the (unscaled) primary.
    const primary = try cw.fonts.getOrCreate(cw.gpa, resolved.family_fonts[0]);
    try std.testing.expectEqual(primary, cw.fonts.stackEntry(resolved, 0).?);

    var line = try cw.fonts.shapeLineText(std.testing.allocator, std.testing.allocator, resolved, "A\u{AC00}", null, .auto, .{});
    defer line.deinit();
    const korean_entry = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expect(korean_entry.height < primary.height);
}

test "Cache.resolveStack: a nested alias covers the scripts of its inner aliases" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });

    // Outer registered before its inner aliases exist.
    try dvui.addFontFamily("TestOuter", &.{ "TestLatinAlias", "TestKoreanAlias" });
    try dvui.addFontFamily("TestLatinAlias", &.{"TestLatin"});
    try dvui.addFontFamily("TestKoreanAlias", &.{"TestKorean"});

    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestOuter"));
    try std.testing.expectEqual(@as(usize, 2), resolved.family_fonts.len);
    try std.testing.expectEqualStrings("TestLatin", resolved.family_fonts[0].familyName());
    try std.testing.expectEqualStrings("TestKorean", resolved.family_fonts[1].familyName());
    try std.testing.expectEqual(@as(?u8, 0), resolved.entryIndexFor('A'));
    try std.testing.expectEqual(@as(?u8, 1), resolved.entryIndexFor(0xAC00));

    const source = try cw.fonts.resolveSource(cw.gpa, Font.init("TestOuter"));
    try std.testing.expectEqualStrings("TestLatin", source.familyName());
}

test "Cache.resolveStack: an alias cycle terminates at the alias limit" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try dvui.addFontFamily("TestCycleA", &.{"TestCycleB"});
    try dvui.addFontFamily("TestCycleB", &.{ "TestCycleA", "TestLatin" });

    var flattened: Cache.FlattenedAliasStack = .{};
    cw.fonts.flattenAliasStack(&flattened, Font.init("TestCycleA"), 0);
    try std.testing.expect(flattened.hit_limit);
    try std.testing.expectEqual(@as(u8, 1), flattened.len);
    try std.testing.expectEqualStrings("TestLatin", flattened.fonts[0].familyName());

    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestCycleA"));
    try std.testing.expectEqual(@as(usize, 1), resolved.family_fonts.len);
    _ = try cw.fonts.resolveSource(cw.gpa, Font.init("TestCycleA"));
}

test "Cache.resolveStack: an outer alias override reaches inner entries" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamilyEntries("TestOuter", &.{.{ .family = array("TestInner"), .weight = .bold }});
    try dvui.addFontFamilyEntries("TestInner", &.{
        .{ .family = array("TestLatin") },
        .{ .family = array("TestKorean"), .size_scale = 0.5, .weight = .light },
    });

    const stack: Font = .init("TestOuter");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);
    try std.testing.expectEqual(@as(usize, 2), resolved.family_fonts.len);
    try std.testing.expectEqual(Font.Weight.bold, resolved.family_fonts[0].weight);
    try std.testing.expectEqual(stack.size, resolved.family_fonts[0].size);
    try std.testing.expectEqual(Font.Weight.light, resolved.family_fonts[1].weight);
    try std.testing.expectEqual(stack.size * 0.5, resolved.family_fonts[1].size);
}

test "Cache.resolveStack: a diamond of aliases keeps each family once, first position wins" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestTop", &.{ "TestLeft", "TestRight" });
    try dvui.addFontFamily("TestLeft", &.{ "TestLatin", "TestKorean" });
    try dvui.addFontFamily("TestRight", &.{ "TestKorean", "TestLatin" });

    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestTop"));
    try std.testing.expectEqual(@as(usize, 2), resolved.family_fonts.len);
    try std.testing.expectEqualStrings("TestLatin", resolved.family_fonts[0].familyName());
    try std.testing.expectEqualStrings("TestKorean", resolved.family_fonts[1].familyName());
}

test "Cache.shapeLineText: shaped_line_cache stays within its byte budget under distinct-slice churn" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestLatin"));

    // Every slice is a distinct cache key, the way a reflowing TextLayout or
    // the bidi retreat loop mints one per candidate prefix.
    const text = try std.testing.allocator.alloc(u8, 32 * 1024);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    const lines_to_overflow = Cache.max_shaped_line_bytes / (text.len * @sizeOf(Cache.CachedShapedLine.Glyph)) + 4;
    var peak_count: usize = 0;
    for (0..lines_to_overflow) |i| {
        _ = try std.fmt.bufPrint(text, "slice-{d}-", .{i});
        var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto, .{});
        line.deinit();
        try std.testing.expect(cw.fonts.shaped_line_bytes <= Cache.max_shaped_line_bytes);
        peak_count = @max(peak_count, cw.fonts.shaped_line_cache.count());
    }
    try std.testing.expect(cw.fonts.shaped_line_cache.count() < peak_count);
}

fn expectSameShapedLine(expected: Cache.Entry.ShapedLine, actual: Cache.Entry.ShapedLine) !void {
    try std.testing.expectEqualSlices(u21, expected.codepoints, actual.codepoints);
    try std.testing.expectEqualSlices(u32, expected.byte_offsets, actual.byte_offsets);
    try std.testing.expectEqualSlices(u32, expected.cluster_starts, actual.cluster_starts);
    try std.testing.expectEqualSlices(u32, expected.cluster_ends, actual.cluster_ends);
    try std.testing.expectEqualSlices(Cache.Entry.ShapedLine.EntrySegment, expected.segments, actual.segments);
    try std.testing.expectEqual(expected.buffer.have_positions, actual.buffer.have_positions);
    try std.testing.expectEqual(expected.buffer.info.items.len, actual.buffer.info.items.len);
    for (expected.buffer.info.items, actual.buffer.info.items, expected.buffer.pos.items, actual.buffer.pos.items) |ei, ai, ep, ap| {
        try std.testing.expectEqual(ei.codepoint, ai.codepoint);
        try std.testing.expectEqual(ei.cluster, ai.cluster);
        try std.testing.expectEqual(ep.x_advance, ap.x_advance);
        try std.testing.expectEqual(ep.x_offset, ap.x_offset);
        try std.testing.expectEqual(ep.y_offset, ap.y_offset);
    }
}

test "Cache.shapeLineText: a shaped_line_cache hit matches the fresh shape" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });
    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestStack"));

    const no_liga = [_]Font.Feature{.{ .tag = "liga".*, .value = 0 }};
    const Case = struct { text: []const u8, item: ?Font.ShapeItem = null, direction: opentype.unicode.Bidi.ParagraphDirection = .auto, style: Font.ShapeStyle = .{} };
    const cases = [_]Case{
        .{ .text = "AB\u{AC00}\u{AC01}CD" },
        .{ .text = "a\tbc\td", .style = .{ .tab_size = 4, .tab_origin = 13 } },
        .{ .text = "abc \u{05D0}\u{05D1}\u{05D2} def", .direction = .rtl },
        .{ .text = "Hello world", .item = .{ .start = 6, .end = 11 } },
        .{ .text = "office fifty", .style = .{ .features = &no_liga } },
    };
    for (cases) |case| {
        var fresh = try cw.fonts.shapeLineText(gpa, cw.gpa, resolved, case.text, case.item, case.direction, case.style);
        defer fresh.deinit();
        const count = cw.fonts.shaped_line_cache.count();
        var hit = try cw.fonts.shapeLineText(gpa, cw.gpa, resolved, case.text, case.item, case.direction, case.style);
        defer hit.deinit();
        try std.testing.expectEqual(count, cw.fonts.shaped_line_cache.count());
        try expectSameShapedLine(fresh, hit);
    }
}

test "Cache.shapeLineText: a cached key owns its text and features" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestLatin"));

    const text = try gpa.dupe(u8, "office fifty");
    defer gpa.free(text);
    const features = try gpa.dupe(Font.Feature, &.{.{ .tag = "liga".*, .value = 0 }});
    defer gpa.free(features);
    var fresh = try cw.fonts.shapeLineText(gpa, cw.gpa, resolved, text, null, .auto, .{ .features = features });
    defer fresh.deinit();
    const count = cw.fonts.shaped_line_cache.count();

    @memset(text, 'x');
    features[0] = .{ .tag = "kern".*, .value = 1 };
    const no_liga = [_]Font.Feature{.{ .tag = "liga".*, .value = 0 }};
    var hit = try cw.fonts.shapeLineText(gpa, cw.gpa, resolved, "office fifty", null, .auto, .{ .features = &no_liga });
    defer hit.deinit();
    try std.testing.expectEqual(count, cw.fonts.shaped_line_cache.count());
    try expectSameShapedLine(fresh, hit);
}

test "Cache.ShapedLineKey: every field takes part in equality" {
    const Key = Cache.ShapedLineKey;
    const ctx: Key.Context = .{};
    const liga = [_]Font.Feature{.{ .tag = "liga".*, .value = 0 }};
    const base: Key = .{ .font_key = .{ .bytes = @splat(1) }, .text = "text", .item = null, .base_direction = .auto, .features = &.{}, .tab = null };
    try std.testing.expect(ctx.eql(base, base));
    const variants = [_]Key{
        blk: {
            var k = base;
            k.font_key.bytes[0] = 2;
            break :blk k;
        },
        blk: {
            var k = base;
            k.text = "texu";
            break :blk k;
        },
        blk: {
            var k = base;
            k.item = .{ .start = 0, .end = 4 };
            break :blk k;
        },
        blk: {
            var k = base;
            k.base_direction = .rtl;
            break :blk k;
        },
        blk: {
            var k = base;
            k.features = &liga;
            break :blk k;
        },
        blk: {
            var k = base;
            k.tab = .{ .size = 8, .origin_bits = 0 };
            break :blk k;
        },
    };
    for (variants) |variant| try std.testing.expect(!ctx.eql(base, variant));
}

test "Cache.shapeLineText: a shaped_line_cache hit reshapes instead of dropping segments when a fallback font was evicted by reset()" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("../fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const stack: Font = .init("TestStack");
    var resolved = try cw.fonts.resolveStack(cw.gpa, stack);
    const text = "AB\u{AC00}\u{AC01}CD";

    var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto, .{});
    defer line.deinit();
    try std.testing.expectEqual(@as(usize, 3), line.segments.len);
    const korean_key = resolved.entry_keys[1];

    // Simulate the Korean fragment scrolling out of view: nothing touches
    // `cache` for two frames, so it's unused across both resets and gets
    // evicted (used-since-last-reset only survives one reset cycle).
    cw.fonts.reset(cw.gpa, cw.backend);
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expect(cw.fonts.cache.getPtr(korean_key) == null);

    // The stack was evicted with it; a later frame resolves it anew.
    resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    // Scrolled back into view: same text, same stack -- shaped_line_cache
    // still has the old line cached, but its Korean segment now points at
    // an evicted entry. Must reshape from scratch, not silently drop the
    // Korean segment and leave the caller thinking it's Latin-only.
    var line2 = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto, .{});
    defer line2.deinit();
    try std.testing.expectEqual(@as(usize, 3), line2.segments.len);

    const korean_entry_after = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expectEqual(korean_entry_after, line2.segments[1].entry);
}

test "Cache.reset: evicts resolved stacks for sizes no longer used" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    for (1..50) |size| _ = try cw.fonts.resolveStack(cw.gpa, Font.init("Vera").withSize(@floatFromInt(size)));
    cw.fonts.reset(cw.gpa, cw.backend);
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.resolved_stacks.count());
}

test "Cache.resolveStack: a self-doubling alias stops at the expansion budget" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    try dvui.addFontFamily("Fan", &.{ "Fan", "Fan", "Vera" });
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("Fan"));
    try std.testing.expectEqual(@as(usize, 1), resolved.family_fonts.len);
    try std.testing.expectEqualStrings("Vera", resolved.family_fonts[0].familyName());
}

test "Cache.addFamily: re-registering an alias reaches stacks already resolved" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    try dvui.addFontFamily("Swap", &.{"TestLatin"});
    try std.testing.expectEqualStrings("TestLatin", (try cw.fonts.resolveStack(cw.gpa, Font.init("Swap"))).family_fonts[0].familyName());
    try dvui.addFontFamily("Swap", &.{"Vera"});
    try std.testing.expectEqualStrings("Vera", (try cw.fonts.resolveStack(cw.gpa, Font.init("Swap"))).family_fonts[0].familyName());
}

test "Cache.reset: evicts shaped lines unused for a frame" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("Vera"));
    var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, "abc", null, .auto, .{});
    line.deinit();
    try std.testing.expectEqual(@as(usize, 1), cw.fonts.shaped_line_cache.count());
    cw.fonts.reset(cw.gpa, cw.backend);
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.shaped_line_cache.count());
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.shaped_line_bytes);
}

test "Cache.reset: clears an atlas grown past max_atlas_height" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    const entry = try cw.fonts.getOrCreate(cw.gpa, Font.init("Vera"));
    entry.pack_y = Cache.max_atlas_height;
    _ = try entry.glyphInfoGet(cw.gpa, 36);
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 0), entry.glyphs.count());
    try std.testing.expectEqual(Cache.Entry.pad, entry.pack_y);
}

test "Entry.getTextureAtlas: keeps glyph pixels when partial uploads are unsupported" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    const entry = try cw.fonts.getOrCreate(cw.gpa, Font.init("Vera"));
    _ = try entry.glyphInfoGet(cw.gpa, 36);
    _ = try entry.getTextureAtlas(cw.gpa, cw.backend);
    _ = try entry.glyphInfoGet(cw.gpa, 37);
    _ = try entry.getTextureAtlas(cw.gpa, cw.backend);
    try std.testing.expect(entry.glyphs.get(36).?.pixels.len > 0);
    try std.testing.expect(entry.glyphs.get(37).?.pixels.len > 0);
}

test "Cache.reset: drops unreferenced discovered font bytes; findSource reads them back" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    const path = "dvui-font-evict-test.ttf";
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = Source.fallback.bytes });
    defer std.Io.Dir.cwd().deleteFile(dvui.io, path) catch {};
    try cw.fonts.database.append(cw.gpa, .{
        .family = array("DiskVera"),
        .bytes = try cw.gpa.dupe(u8, Source.fallback.bytes),
        .allocator = cw.gpa,
        .path = try cw.gpa.dupe(u8, path),
    });
    const source = &cw.fonts.database.items[cw.fonts.database.items.len - 1];
    for (0..Cache.evict_after_unreferenced_resets) |_| cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 0), source.bytes.len);

    // The re-read assembles the requested face as a fresh standalone sfnt,
    // so it matches the file's tables rather than its bytes.
    const found = cw.fonts.findSource(Font.init("DiskVera")).@"0".?;
    const original = try Cache.Entry.parseFontOrCollection(cw.gpa, Source.fallback.bytes, 0);
    defer original.deinit(cw.gpa);
    const reread = try Cache.Entry.parseFontOrCollection(cw.gpa, found.bytes, 0);
    defer reread.deinit(cw.gpa);
    try std.testing.expectEqual(original.table_records.len, reread.table_records.len);
    for (original.table_records) |record| {
        try std.testing.expectEqualSlices(u8, original.tableData(record.tag).?, reread.tableData(record.tag).?);
    }
}

test "Cache.loadDynamicFallback: rejects a discovered font with no rasterizable outline table" {
    if (system_font_backend == null) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    try dvui.addFont("Vera Sans", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    const font: Font = .find(.{ .family = "Vera Sans", .size = 20 });
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);

    // Simplified Chinese: on recent macOS, CoreText's cascade list for this
    // script can bottom out at a system-UI PingFang face (PingFangUI.ttc)
    // whose glyphs live only in Apple's proprietary `hvgl` table (no glyf/
    // CFF/CFF2) -- unrasterizable here. Whatever font (if any) ends up
    // materialized for this text must have a real outline table; a rejected
    // candidate should leave the codepoints uncovered (rendered via the
    // primary font's notdef) rather than registering a font that produces
    // zero-size glyphs for everything.
    const text = "这是一个中文测试句子。";
    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, text, null, .auto, .{});
    defer line.deinit();

    for (line.segments) |seg| {
        const has_outlines = seg.entry.parsed_font.tableData(.{ 'g', 'l', 'y', 'f' }) != null or
            seg.entry.parsed_font.tableData(.{ 'C', 'F', 'F', ' ' }) != null or
            seg.entry.parsed_font.tableData(.{ 'C', 'F', 'F', '2' }) != null;
        try std.testing.expect(has_outlines);
    }
}

test "Cache.shapeLineText: emoji next to CJK gets its own dynamic-fallback font, not notdef" {
    if (system_font_backend == null) return error.SkipZigTest;

    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();

    const stack: Font = .init("TestLatin");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    // CJK immediately followed by an emoji, both uncovered by TestLatin:
    // each needs its own OS-discovered fallback font. Regression test for
    // two bugs found together: (1) a weak/Common-script codepoint (the
    // emoji, or the space next to it) could ride along in the same shaped
    // run as an adjacent strong-script codepoint's font even when that font
    // doesn't cover it (shaping.zig's font_of run-break check only fired for
    // "strong" script codepoints); (2) `loadDynamicFallback` capped the
    // fallback font file read at 64MiB, silently failing to load Apple
    // Color Emoji.ttc (~180MiB on modern macOS) and returning null.
    const text = "\u{4E2D}\u{6587}\u{1F600}";
    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, text, null, .auto, .{});
    defer line.deinit();

    if (line.segments.len < 2) return error.SkipZigTest; // no dynamic fallback available in this environment

    // Only glyphs actually shaped against a dynamically-discovered fallback
    // font must be non-notdef -- a CJK codepoint can legitimately have no
    // usable fallback at all (e.g. recent macOS's CJK system-UI face is
    // `hvgl`-only and gets rejected by discovery's outline-table check) and
    // falls back to the primary font's .notdef, which is correct, not a
    // regression.
    const primary = cw.fonts.stackEntry(resolved, 0).?;
    for (line.buffer.info.items, 0..) |info, gidx| {
        if (line.entryForGlyph(primary, gidx) == primary) continue;
        try std.testing.expect(info.codepoint != 0); // no glyph should be .notdef
    }
}

test "Cache web fallback: a missing codepoint is requested once and resolves to the arrived font" {
    if (!web_fallback_enabled) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    cw.fonts.web_fallback = .{};
    cw.fonts.fallback_language = "ko";

    const pendingFont = struct {
        fn get(service: *const WebFallback) ?u16 {
            var found: ?u16 = null;
            for (service.font_states, 0..) |state, i| {
                if (state != .pending) continue;
                if (found != null) return null;
                found = @intCast(i);
            }
            return found;
        }
    }.get;

    try std.testing.expect(cw.fonts.webFallbackFont(cw.gpa, 0xAC00) == null);
    cw.fonts.processWebFallback(cw.gpa, std.testing.allocator);
    const service = &cw.fonts.web_fallback.?;
    const font = pendingFont(service).?;
    try std.testing.expect(std.mem.startsWith(u8, service.set.fonts[font].name, "Noto Sans KR "));

    // a later frame hitting the same codepoint requests nothing new
    try std.testing.expect(cw.fonts.webFallbackFont(cw.gpa, 0xAC00) == null);
    cw.fonts.processWebFallback(cw.gpa, std.testing.allocator);
    try std.testing.expectEqual(@as(?u16, font), pendingFont(service));

    cw.fonts.webFallbackLoaded(cw.gpa, font, try cw.gpa.dupe(u8, @embedFile("../fonts/NotoSansKR-Regular.ttf")));
    const arrived = cw.fonts.webFallbackFont(cw.gpa, 0xAC00).?;
    try std.testing.expect(cw.fonts.findSource(arrived).@"0" != null);
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.shaped_line_cache.count());
}
