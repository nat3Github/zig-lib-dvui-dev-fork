const std = @import("std");
const dvui = @import("dvui.zig");
const opentype = @import("opentype");
const Font = @import("Font.zig");

const Size = dvui.Size;
const Texture = dvui.Texture;
const Backend = dvui.Backend;

const UserCoord = opentype.UserCoord;
const Buffer = opentype.Buffer;
const BidiFallbackResult = opentype.BidiFallbackResult;
const DiscoveryProperties = opentype.DiscoveryProperties;
const OtFont = opentype.Font;
const Renderer = opentype.Renderer;
const Cmap = opentype.Cmap;
const shaping = opentype.shaping;
const shapeBidiParagraphWithFallback = opentype.shapeBidiParagraphWithFallback;
const PlanCache = opentype.PlanCache;
const firstHardBreak = opentype.firstHardBreak;

const Source = Font.Source;
const FontSet = opentype.discovery.FontSet;
const FamilyEntry = Font.FamilyEntry;
const WebFallbackOptions = Font.WebFallbackOptions;
const NAME_MAX_LEN = Font.NAME_MAX_LEN;
const max_variations = Font.max_variations;
const Error = Font.Error;

const Cache = @This();

const LineCache = opentype.line_cache.Cache(Font.CacheKey);

pub const ShapedLine = opentype.ShapedLine;

const FamilyAliases = opentype.FamilyAliases(Font, FamilyEntry);

pub const max_alias_depth = FamilyAliases.max_depth;
pub const max_alias_expansions = FamilyAliases.max_expansions;
pub const max_stack_families = FamilyAliases.max_families;

database: FontSet = .{},
cache: dvui.TrackingAutoHashMap(Font.CacheKey, *Entry, .get_and_put, void) = .empty,
resolved_stacks: dvui.TrackingAutoHashMap(Font.CacheKey, *ResolvedStack, .get_and_put, void) = .empty,
coverage_cache: opentype.CoverageCache = .{},
line_cache: LineCache = .{},
family_aliases: FamilyAliases = .{},

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

    self.coverage_cache.deinit(gpa);

    self.line_cache.deinit(gpa);

    self.database.deinit(gpa, dvui.io);

    self.family_aliases.deinit(gpa);
}

pub fn addFamily(self: *Cache, gpa: std.mem.Allocator, alias: []const u8, names: []const []const u8) std.mem.Allocator.Error!void {
    const list = try gpa.alloc(FamilyEntry, names.len);
    defer gpa.free(list);
    for (names, list) |n, *dst| dst.* = .{ .family = Font.array(n) };
    return self.addFamilyEntries(gpa, alias, list);
}

pub fn addFamilyEntries(self: *Cache, gpa: std.mem.Allocator, alias: []const u8, entries: []const FamilyEntry) std.mem.Allocator.Error!void {
    _ = try self.family_aliases.put(gpa, alias[0..@min(alias.len, NAME_MAX_LEN)], entries);
    var sit = self.resolved_stacks.iterator();
    while (sit.next()) |item| {
        item.value_ptr.*.deinit(gpa);
        gpa.destroy(item.value_ptr.*);
    }
    self.resolved_stacks.map.clearRetainingCapacity();
    self.line_cache.clear(gpa);
}

pub const max_atlas_height = 4096;
// 1024x4096 RGBA fits sdl3gpu's 16MB texture transfer buffer.
pub const max_atlas_width = 1024;

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
    self.line_cache.evictUnused(gpa);
    if (self.coverage_cache.map.count() > max_coverage_entries) self.evictUnreferencedCoverage(gpa);
    if (self.database.releaseUnused(dvui.io, self)) self.line_cache.clearPlans(gpa);
}

// Coverage is size-independent and costly to rebuild, so keep it past its stack's eviction until there are many.
const max_coverage_entries = 64;

fn evictUnreferencedCoverage(self: *Cache, gpa: std.mem.Allocator) void {
    var it = self.coverage_cache.map.iterator();
    next: while (it.next()) |kv| {
        var sit = self.resolved_stacks.iterator();
        while (sit.next_peek()) |stack| {
            if (stack.value.fallback.coverage.ptr == kv.value_ptr.coverage.ptr) continue :next;
        }
        kv.value_ptr.deinit(gpa);
        self.coverage_cache.map.removeByPtr(kv.key_ptr);
    }
}

pub fn bytesReferenced(self: *Cache, bytes: []const u8) bool {
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

pub fn findSource(self: *Cache, font: Font) struct { ?Source, ?Source } {
    const match = self.database.find(dvui.io, font.familyName(), .{ .weight = font.weight, .style = font.style, .stretch = font.stretch }) orelse return .{ null, null };
    return if (match.exact) .{ match.face.*, null } else .{ null, match.face.* };
}

fn resolveSource(self: *Cache, state_gpa: std.mem.Allocator, raw_font: Font) std.mem.Allocator.Error!Source {
    const font = self.family_aliases.firstFamily(raw_font);
    const fname = font.name(state_gpa);
    defer state_gpa.free(fname);
    const resolved = try self.database.resolve(state_gpa, dvui.io, font.familyName(), .{ .weight = font.weight, .style = font.style, .stretch = font.stretch }) orelse {
        dvui.log.warn("Font {s} not loaded in dvui, using fallback", .{fname});
        return Font.Embedded.forFamily(font.familyName());
    };
    switch (resolved.how) {
        .exact => {},
        .closest => {
            const sname = resolved.face.name(state_gpa);
            defer state_gpa.free(sname);
            dvui.log.warn("Font {s} not loaded in dvui, using second best {s}", .{ fname, sname });
        },
        .system => dvui.log.debug("Font {s} resolved via OS font discovery", .{fname}),
    }
    return resolved.face;
}

pub fn getOrCreate(self: *Cache, state_gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*Entry {
    const entry = try self.cache.getOrPut(state_gpa, font.cacheKey());
    if (entry.found_existing) return entry.value_ptr.*;
    errdefer self.cache.map.removeByPtr(entry.key_ptr);

    const source = try self.resolveSource(state_gpa, font);

    const boxed = try state_gpa.create(Entry);
    errdefer state_gpa.destroy(boxed);
    boxed.* = Entry.init(state_gpa, &source, font) catch |err| blk: {
        dvui.log.err("Font {f} init got {any}, using fallback", .{ font, err });
        break :blk Entry.init(state_gpa, &Font.Embedded.sans, font) catch |fallback_err|
            // the built-in font is embedded, so a load failure is a build defect, not a runtime condition
            std.debug.panic("built-in fallback font failed to load: {any}", .{fallback_err});
    };
    entry.value_ptr.* = boxed;
    return boxed;
}

pub const ResolvedStack = struct {
    font_key: Font.CacheKey = .{ .bytes = @splat(0) },
    entry_keys: []Font.CacheKey = &.{},
    family_fonts: []Font = &.{},
    raw_fonts: []OtFont = &.{},
    fallback: Cmap.FallbackStack = .{},
    logged_missing: std.AutoHashMapUnmanaged(u21, void) = .empty,
    m_size: ?Size = null,

    pub fn deinit(self: *ResolvedStack, gpa: std.mem.Allocator) void {
        for (self.raw_fonts) |*rf| rf.deinit(gpa);
        gpa.free(self.raw_fonts);
        gpa.free(self.entry_keys);
        gpa.free(self.family_fonts);
        self.logged_missing.deinit(gpa);
    }

    pub fn entryIndexFor(self: *const ResolvedStack, codepoint: u21) ?u8 {
        return self.fallback.entryIndexFor(codepoint);
    }
};

fn coverageCacheKey(names: []const Font) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (names) |family_font| {
        var k = family_font.cacheKey();
        @memset(k.bytes[NAME_MAX_LEN..][0..4], 0); // size
        hasher.update(&k.bytes);
    }
    return hasher.final();
}

pub fn resolveStack(self: *Cache, state_gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*ResolvedStack {
    const font_key = font.cacheKey();
    if (self.resolved_stacks.get(font_key)) |existing| return existing;

    var flattened = self.family_aliases.flatten(font);
    if (flattened.hit_limit) dvui.log.warn("Font family alias {s} nests deeper than {d} or expands more than {d} times (cycle?), ignoring the rest", .{ font.familyName(), max_alias_depth, max_alias_expansions });
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

    var count: usize = 0;
    errdefer for (raw_fonts[0..count]) |*rf| rf.deinit(state_gpa);

    for (names) |family_font| {
        family_fonts[count] = family_font;
        entry_keys[count] = family_font.cacheKey();

        const source = try self.resolveSource(state_gpa, family_font);
        raw_fonts[count] = FontSet.parseFace(state_gpa, source.bytes, source.collection_index) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => FontSet.parseFace(state_gpa, Font.Embedded.sans.bytes, 0) catch |e2| switch (e2) {
                error.OutOfMemory => |e| return e,
                else => unreachable, // embedded Vera.ttf is a known-good sfnt
            },
        };
        count += 1;
    }

    const fallback = try self.coverage_cache.getOrBuild(state_gpa, coverageCacheKey(names), raw_fonts[0..count]);
    const boxed = try state_gpa.create(ResolvedStack);
    errdefer state_gpa.destroy(boxed);
    boxed.* = .{ .font_key = font_key, .entry_keys = entry_keys, .family_fonts = family_fonts, .raw_fonts = raw_fonts, .fallback = fallback };
    try self.resolved_stacks.put(state_gpa, font_key, boxed);
    return boxed;
}

pub fn primaryEntry(self: *Cache, state_gpa: std.mem.Allocator, resolved: *const ResolvedStack) std.mem.Allocator.Error!*Entry {
    if (self.stackEntry(resolved, 0)) |existing| return existing;
    return self.getOrCreate(state_gpa, resolved.family_fonts[0]);
}

pub fn stackEntry(self: *Cache, resolved: *const ResolvedStack, index: u8) ?*Entry {
    if (index >= resolved.entry_keys.len) return null;
    return if (self.cache.getPtr(resolved.entry_keys[index])) |p| p.* else null;
}

pub fn discoverDynamicFallback(self: *Cache, state_gpa: std.mem.Allocator, codepoint: u21) ?Font {
    const family = self.database.fallbackFamily(state_gpa, dvui.io, codepoint) orelse return null;
    return Font.init(FontSet.nameSlice(&family));
}

fn webFallbackFont(self: *Cache, state_gpa: std.mem.Allocator, codepoint: u21) ?Font {
    const family = self.database.webFallbackFamily(state_gpa, codepoint) orelse return null;
    return Font.init(FontSet.nameSlice(&family));
}

pub fn processWebFallback(self: *Cache, gpa: std.mem.Allocator, scratch: std.mem.Allocator) void {
    self.database.processWebFallback(gpa, scratch, struct {
        pub fn fetch(_: @This(), font: u16, url: []const u8) void {
            if (@hasDecl(dvui.backend, "fetchFallbackFont")) dvui.backend.fetchFallbackFont(font, url);
        }
    }{});
}

pub fn webFallbackLoaded(self: *Cache, gpa: std.mem.Allocator, font: u16, bytes: []u8) void {
    if (self.database.webFallbackLoaded(gpa, font, bytes)) self.line_cache.clear(gpa);
}

pub fn setWebFallback(self: *Cache, gpa: std.mem.Allocator, options: WebFallbackOptions) void {
    self.database.setWebFallback(gpa, options.enabled, options.base_url);
    self.line_cache.clear(gpa);
}

pub fn webFallbackFailed(self: *Cache, gpa: std.mem.Allocator, font: u16) void {
    self.database.webFallbackFailed(gpa, font);
}

const LineProvider = struct {
    cache: *Cache,
    resolved: *ResolvedStack,
    discovered: *std.ArrayList(Discovered),
    output: std.mem.Allocator,

    const Discovered = struct { key: Font.CacheKey, font: Font };

    pub fn coversCodepoint(self: LineProvider, codepoint: u21) bool {
        return self.resolved.entryIndexFor(codepoint) != null;
    }

    pub fn fontForCodepoint(self: LineProvider, state_gpa: std.mem.Allocator, codepoint: u21) ?Font.CacheKey {
        const found = self.cache.discoverDynamicFallback(state_gpa, codepoint) orelse
            self.cache.webFallbackFont(state_gpa, codepoint) orelse return null;
        const sized = found.withSize(self.resolved.family_fonts[0].size);
        const key = sized.cacheKey();
        self.discovered.append(self.output, .{ .key = key, .font = sized }) catch return null;
        return key;
    }

    pub fn ensureFont(self: LineProvider, state_gpa: std.mem.Allocator, key: Font.CacheKey) !OtFont {
        const font = self.fontForKey(key) orelse return error.FontUnavailable;
        const entry = try self.cache.getOrCreate(state_gpa, font);
        return entry.parsed_font;
    }

    pub fn hasFont(self: LineProvider, key: Font.CacheKey) bool {
        return self.cache.cache.getPtr(key) != null;
    }

    pub fn toPixels(self: LineProvider, key: Font.CacheKey, font_units: i32) f32 {
        const entry = self.cache.cache.getPtr(key) orelse return 0;
        return entry.*.toPixels(font_units);
    }

    pub fn emboldenUnits(self: LineProvider, key: Font.CacheKey) i32 {
        const entry = self.cache.cache.getPtr(key) orelse return 0;
        if (!entry.*.embolden) return 0;
        return opentype.rasterization.emboldenUnits(entry.*.renderer.head.units_per_em);
    }

    pub fn noteMissingCoverage(self: LineProvider, state_gpa: std.mem.Allocator, codepoint: u21) void {
        logMissingCoverage(self.resolved, state_gpa, codepoint);
    }

    fn fontForKey(self: LineProvider, key: Font.CacheKey) ?Font {
        for (self.resolved.entry_keys, self.resolved.family_fonts) |k, font| {
            if (Font.CacheKey.Context.eql(.{}, k, key)) return font;
        }
        for (self.discovered.items) |d| {
            if (Font.CacheKey.Context.eql(.{}, d.key, key)) return d.font;
        }
        return null;
    }
};

pub fn shapeLineText(self: *Cache, output: std.mem.Allocator, scratch: std.mem.Allocator, state_gpa: std.mem.Allocator, resolved: *ResolvedStack, text: []const u8, item: ?Font.ShapeItem, base_direction: opentype.unicode.Bidi.ParagraphDirection, style: Font.ShapeStyle) std.mem.Allocator.Error!ShapedText {
    var discovered: std.ArrayList(LineProvider.Discovered) = .empty;
    defer discovered.deinit(output);
    const provider: LineProvider = .{ .cache = self, .resolved = resolved, .discovered = &discovered, .output = output };

    var result = self.line_cache.shapeLine(
        output,
        scratch,
        state_gpa,
        provider,
        resolved.font_key,
        resolved.raw_fonts,
        resolved.entry_keys,
        text,
        if (item) |it| .{ .start = it.start, .end = it.end } else null,
        base_direction,
        .{ .features = style.features, .tab_size = style.tab_size, .tab_origin = style.tab_origin },
    ) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
    };
    defer output.free(result.font_keys);
    errdefer result.line.deinit();

    const entries = try output.alloc(*Entry, result.font_keys.len);
    errdefer output.free(entries);
    for (entries, result.font_keys) |*slot, key| {
        slot.* = (self.cache.getPtr(key) orelse return error.OutOfMemory).*;
    }

    return .{ .line = result.line, .entries = entries };
}

pub const ShapedText = struct {
    line: ShapedLine,
    entries: []*Entry,

    pub fn deinit(self: *ShapedText) void {
        const output = self.line.allocator;
        self.line.deinit();
        output.free(self.entries);
    }

    pub fn entryForGlyph(self: ShapedText, fallback: *Entry, glyph_idx: usize) *Entry {
        const font_index = self.line.fontIndexForGlyph(glyph_idx);
        if (font_index >= self.entries.len) return fallback;
        return self.entries[font_index];
    }

    pub const Metrics = struct {
        entries: []const *Entry,
        fallback: *Entry,

        fn entry(self: Metrics, font_index: u16) *Entry {
            if (font_index >= self.entries.len) return self.fallback;
            return self.entries[font_index];
        }

        pub fn glyphInfoGet(self: Metrics, gpa: std.mem.Allocator, font_index: u16, glyph_id: u32) !Entry.GlyphInfo {
            return self.entry(font_index).glyphInfoGet(gpa, glyph_id);
        }

        pub fn toPixels(self: Metrics, font_index: u16, font_units: i32) f32 {
            return self.entry(font_index).toPixels(font_units);
        }

        pub fn ascent(self: Metrics, font_index: u16) f32 {
            return self.entry(font_index).ascent;
        }

        pub fn baseHeight(self: Metrics) f32 {
            return self.fallback.height;
        }

        pub fn gdefTable(self: Metrics, font_index: u16) ?[]const u8 {
            return self.entry(font_index).parsed_font.tableData("GDEF".*);
        }
    };

    pub fn metrics(self: ShapedText, fallback: *Entry) Metrics {
        return .{ .entries = self.entries, .fallback = fallback };
    }
};

fn logMissingCoverage(resolved: *ResolvedStack, gpa: std.mem.Allocator, codepoint: u21) void {
    const block: u21 = codepoint >> 8;
    if (resolved.logged_missing.get(block) != null) return;
    resolved.logged_missing.put(gpa, block, {}) catch {};
    dvui.log.debug("Font: no entry covers codepoint block U+{X:0>4}xx (e.g. U+{X:0>4}), falling back to entry 0 (.notdef)", .{ block, codepoint });
}

fn initialMeasureWindow(resolved: *const ResolvedStack, mwidth: f32, newline_idx: usize) usize {
    const m_advance = if (resolved.m_size) |m| m.w else 0;
    if (!(m_advance > 0) or !std.math.isFinite(mwidth)) return @min(newline_idx, 64);
    const estimate = @min(@as(f32, @floatFromInt(newline_idx)), @max(0, mwidth / m_advance * 2 + 8));
    return @min(newline_idx, @max(16, @as(usize, @intFromFloat(estimate))));
}

pub const MeasureResult = struct {
    size: Size,
    shaped: ShapedText,
};

pub fn textSizeRawShaped(
    self: *Cache,
    output: std.mem.Allocator,
    scratch: std.mem.Allocator,
    state_gpa: std.mem.Allocator,
    resolved: *ResolvedStack,
    text: []const u8,
    opts: Font.TextSizeOptions,
    style: Font.ShapeStyle,
) std.mem.Allocator.Error!MeasureResult {
    const mwidth = opts.max_width orelse dvui.max_float_safe;
    const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
    const default_height: f32 = if (self.primaryEntry(state_gpa, resolved)) |fe| fe.height else |_| 0;

    const hard_break = firstHardBreak(text);
    const newline_idx = if (hard_break) |hb| hb.start else text.len;
    var window: usize = if (opts.max_width != null and opts.item == null) initialMeasureWindow(resolved, mwidth, newline_idx) else newline_idx;

    while (true) {
        var shaped = try self.shapeLineText(output, scratch, state_gpa, resolved, text[0..window], opts.item, opts.base_direction, style);
        errdefer shaped.deinit();
        const line = &shaped.line;

        const fallback_entry = self.stackEntry(resolved, 0);

        const ext: opentype.ShapedLine.Extents = if (fallback_entry) |fe|
            try line.measureGlyphs(
                state_gpa,
                shaped.metrics(fe),
                .{ .start = 0, .end = line.buffer.info.items.len },
                .{ .max = mwidth, .end_metric = opts.end_metric },
                snap,
            )
        else
            .{ .size = .{ .w = 0, .h = default_height }, .glyphs_used = 0 };
        const glyphs_used = ext.glyphs_used;
        const tw = ext.size.w;
        const th = ext.size.h;

        const found_break = glyphs_used < line.buffer.info.items.len;
        if (found_break or window >= newline_idx) {
            if (found_break and line.buffer.isRtl()) {
                if (fallback_entry) |fe| {
                    const fit = try line.logicalPrefixForWidth(state_gpa, shaped.metrics(fe), mwidth, opts.end_metric, snap);
                    if (opts.end_idx) |endout| endout.* = fit.byte;
                    return .{ .size = .{ .w = fit.w, .h = th }, .shaped = shaped };
                }
            }
            if (opts.end_idx) |endout| {
                endout.* = line.byteOffsetForGlyph(glyphs_used);
                if (!found_break) {
                    if (hard_break) |hb| endout.* += hb.len;
                }
            }
            return .{ .size = .{ .w = tw, .h = th }, .shaped = shaped };
        }

        shaped.deinit();
        window = @min(newline_idx, window * 4);
    }
}

pub const Entry = struct {
    name: []const u8, // gpa
    parsed_font: OtFont,
    renderer: Renderer,
    /// Synthetic bold: bold asked for, the source has no bold face or axis.
    embolden: bool = false,
    sbix_strike: ?[]const u8,
    height: f32, // ascender - descender
    ascent: f32, // ascender
    em_height: f32, // measured M height
    /// Glyphs keyed by ID (post-shaping), not Unicode codepoint.
    /// Bounded by `Cache.max_atlas_width` x `Cache.max_atlas_height`.
    glyphs: std.HashMapUnmanaged(u32, GlyphInfo, GlyphIdContext, std.hash_map.default_max_load_percentage) = .empty,
    texture_atlas_cache: ?Texture = null,
    /// Allocated height (may exceed pack_y due to geometric growth).
    atlas_alloc_height: u32 = 0,
    /// Shelf-packer state; decoupled from GPU upload.
    atlas_width: u32 = 0,
    pack_x: u32 = pad,
    pack_y: u32 = pad,
    pack_row_height: u32 = 0,

    // Wyhash over 4 bytes dominated glyphInfoGet; Fibonacci hashing spreads
    // dense glyph ids across both the bucket bits and the top fingerprint bits.
    const GlyphIdContext = struct {
        pub fn hash(_: GlyphIdContext, glyph_id: u32) u64 {
            return @as(u64, glyph_id) *% 0x9E3779B97F4A7C15;
        }
        pub fn eql(_: GlyphIdContext, a: u32, b: u32) bool {
            return a == b;
        }
    };

    /// Padding (px) kept on every side of a packed glyph.
    const pad: u32 = 1;
    const initial_atlas_width: u32 = 512;

    pub const GlyphInfo = struct {
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

    const max_user_coords = max_variations + DiscoveryProperties.max_pinned_axes + 3;

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

    /// Blink's rule: synthesize at 600+ from a face under 600. A `wght` axis
    /// reaching 600 renders the real weight; color glyphs have no outline.
    fn wantsSyntheticBold(font: Font, source: *const Source, parsed_font: OtFont) bool {
        const threshold = Font.Weight.semibold.value;
        if (font.weight.value < threshold or source.weight.value >= threshold) return false;
        for ([_][4]u8{ "COLR".*, "sbix".*, "CBDT".* }) |tag| {
            if (parsed_font.tableData(tag) != null) return false;
        }
        const fvar_data = parsed_font.tableData("fvar".*) orelse return true;
        const lifo = dvui.currentWindow().lifo();
        const axes = opentype.parsing.Table.fvar.axes(lifo, fvar_data) catch return true;
        defer lifo.free(axes);
        for (axes) |axis| {
            if (std.mem.eql(u8, &axis.tag, "wght") and axis.max_value >= threshold) return false;
        }
        return true;
    }

    fn measuredCapHeight(renderer: *Renderer, glyph_id: u16) ?f32 {
        const bounds = renderer.glyphBounds(glyph_id, .{}, dvui.currentWindow().lifo()) catch return null;
        if (bounds.rows == 0) return null;
        return @floatFromInt(bounds.rows);
    }

    fn loadSbixStrike(gpa: std.mem.Allocator, source: *const Source, ppem: f32) ?[]const u8 {
        if (opentype.discovery.system.Backend == null) return null;
        const path = source.path orelse return null;
        const file = std.Io.Dir.cwd().openFile(dvui.io, path, .{}) catch return null;
        defer file.close(dvui.io);
        const rounded: u16 = @intFromFloat(std.math.clamp(@round(ppem), 1, std.math.maxInt(u16)));
        return opentype.parsing.Font.readSbixStrike(gpa, dvui.io, file, source.collection_index, rounded) catch null;
    }

    pub fn init(gpa: std.mem.Allocator, source: *const Source, font: Font) Error!Entry {
        const min_pixel_size: f32 = 1;

        const parsed_font = FontSet.parseFace(gpa, source.bytes, source.collection_index) catch |err| {
            const fname = font.name(gpa);
            defer gpa.free(fname);
            dvui.log.warn("Font.Cache.Entry.init() opentype parse error {any} font {s}\n", .{ err, fname });
            return Error.FontError;
        };
        errdefer parsed_font.deinit(gpa);

        const embolden = wantsSyntheticBold(font, source, parsed_font);
        const fname = if (embolden) blk: {
            const plain = font.name(gpa);
            defer gpa.free(plain);
            break :blk std.fmt.allocPrint(gpa, "{s} Bold Synth", .{plain}) catch "";
        } else font.name(gpa);
        errdefer gpa.free(fname);

        var ppem = @max(min_pixel_size, font.size);
        var coords_buf: [max_user_coords]UserCoord = undefined;
        const user_coords = effectiveUserCoords(font, source.pinnedAxes(), &coords_buf);
        // The cap-height probe below sizes the face, so it measures the
        // outline before emboldening grows it.
        var render_options: opentype.render.RenderOptions = .{ .hint_glyf = true, .user_coords = user_coords };
        var renderer = Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, render_options) catch |err| {
            dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
            return Error.FontError;
        };
        errdefer renderer.deinit(gpa);

        const sbix_strike = if (parsed_font.tableData(.{ 's', 'b', 'i', 'x' }) != null)
            null
        else
            loadSbixStrike(gpa, source, ppem);
        errdefer if (sbix_strike) |strike| gpa.free(strike);
        if (sbix_strike) |strike| renderer.sbix_data = strike;

        const units_per_em_f: f32 = @floatFromInt(renderer.head.units_per_em);

        const extents = parsed_font.horizontalExtents(renderer.head.units_per_em);
        const raw_ascender: f32 = @floatFromInt(extents.ascender);
        const raw_descender: f32 = @floatFromInt(extents.descender);

        const cmap_data = parsed_font.tableData(.{ 'c', 'm', 'a', 'p' });
        const m_glyph_id: u16 = if (cmap_data) |cd| (Cmap.lookup(cd, 'M') orelse 0) else 0;

        var em_height = ppem;
        if (m_glyph_id != 0) probe: {
            const probe_h = measuredCapHeight(&renderer, m_glyph_id) orelse break :probe;
            if (probe_h <= 0) break :probe;
            const ratio = probe_h / ppem;
            const corrected = @max(min_pixel_size, font.size / ratio);
            renderer.setPpem(gpa, dvui.currentWindow().lifo(), corrected, render_options) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            ppem = corrected;
            em_height = measuredCapHeight(&renderer, m_glyph_id) orelse ppem;
        }
        if (embolden) {
            render_options.embolden = true;
            renderer.setPpem(gpa, dvui.currentWindow().lifo(), ppem, render_options) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
        }

        const scale_f = ppem / units_per_em_f;
        const entry: Entry = .{
            .name = fname,
            .parsed_font = parsed_font,
            .renderer = renderer,
            .embolden = embolden,
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

    const drops_uploaded_pixels = Backend.has_texture_update_sub_rect;

    fn dropUploadedPixels(gpa: std.mem.Allocator, gi: *GlyphInfo) void {
        if (!drops_uploaded_pixels) return;
        gpa.free(gi.pixels);
        gi.pixels = &.{};
    }

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

    fn clearAtlas(self: *Entry, gpa: std.mem.Allocator) void {
        var it = self.glyphs.valueIterator();
        while (it.next()) |gi| gpa.free(gi.pixels);
        self.glyphs.clearAndFree(gpa);
        self.invalidateTextureAtlas();
        self.atlas_width = 0;
        self.pack_x = pad;
        self.pack_y = pad;
        self.pack_row_height = 0;
    }

    fn invalidateTextureAtlas(self: *Entry) void {
        if (self.texture_atlas_cache) |tex| {
            dvui.textureDestroyLater(tex);
        }
        self.texture_atlas_cache = null;
        self.atlas_alloc_height = 0;
        var it = self.glyphs.valueIterator();
        while (it.next()) |gi| gi.uploaded = false;
    }

    fn placeGlyph(self: *Entry, w: u32, h: u32) @Vector(2, f32) {
        if (self.atlas_width == 0) {
            self.atlas_width = @max(initial_atlas_width, w + 2 * pad);
        } else if (w + 2 * pad > self.atlas_width) {
            self.atlas_width = @min(max_atlas_width, @max(w + 2 * pad, self.atlas_width * 2));
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
                    const src = gi.pixels[src_index * 4 ..][0..4];
                    break :blk .fromColor(.{ .r = src[0], .g = src[1], .b = src[2], .a = src[3] });
                } else blk: {
                    const coverage = gi.pixels[src_index];
                    break :blk .{ .r = coverage, .g = coverage, .b = coverage, .a = coverage };
                };
            }
        }
    }

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

    pub fn getTextureAtlas(self: *Entry, gpa: std.mem.Allocator, backend: Backend) Backend.TextureError!Texture {
        if (self.atlas_width == 0) {
            if (self.texture_atlas_cache) |tex| return tex;
            const blank = [1]dvui.Color.PMA{.transparent};
            self.texture_atlas_cache = try dvui.textureCreate(&blank, .{ .width = 1, .height = 1 });
            return self.texture_atlas_cache.?;
        }

        const needed_height = self.pack_y + self.pack_row_height + pad;
        if (self.texture_atlas_cache == null or needed_height > self.atlas_alloc_height) {
            const new_height = @min(max_atlas_height, @max(needed_height, self.atlas_alloc_height * 2));
            try self.rebuildAtlasTexture(gpa, new_height);
            return self.texture_atlas_cache.?;
        }

        const tex = self.texture_atlas_cache.?;

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

    pub fn glyphInfoGet(self: *Entry, gpa: std.mem.Allocator, glyph_id: u32) std.mem.Allocator.Error!GlyphInfo {
        if (self.glyphs.get(glyph_id)) |gi| return gi;

        var gi: GlyphInfo = blk: {
            const rendered = self.renderer.renderGlyph(@intCast(glyph_id), .{}, dvui.currentWindow().lifo(), gpa) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => {
                    dvui.log.warn("Font.Cache.Entry.glyphInfoGet() opentype render error {any} font {s} glyph {d}\n", .{ err, self.name, glyph_id });
                    break :blk .{ .leftBearing = 0, .topBearing = 0, .w = 0, .h = 0, .origin = .{ 0, 0 }, .is_color = false, .pixels = &.{}, .uploaded = false };
                },
            };
            break :blk .{
                .leftBearing = @floatFromInt(rendered.bitmap.left),
                .topBearing = @floatFromInt(rendered.bitmap.top),
                .w = @floatFromInt(rendered.bitmap.width),
                .h = @floatFromInt(rendered.bitmap.rows),
                .origin = .{ 0, 0 },
                .is_color = rendered.is_color,
                .pixels = rendered.bitmap.pixels_row_major,
                .uploaded = false,
            };
        };
        errdefer gpa.free(gi.pixels);

        if (gi.w > 0 and gi.h > 0) {
            const w: u32 = @intFromFloat(gi.w);
            const h: u32 = @intFromFloat(gi.h);
            if (w + 2 * pad > max_atlas_width or h + 2 * pad > max_atlas_height) {
                dvui.log.warn("Font.Cache.Entry.glyphInfoGet() glyph {d} of font {s} is {d}x{d}, larger than the atlas, skipped\n", .{ glyph_id, self.name, w, h });
                gi.w = 0;
                gi.h = 0;
                gpa.free(gi.pixels);
                gi.pixels = &.{};
            } else {
                gi.origin = self.placeGlyph(w, h);
                if (self.pack_y + self.pack_row_height + pad > max_atlas_height) {
                    // ponytail: evict everything; a frame needing more than one full atlas thrashes, LRU shelves if that shows up
                    self.clearAtlas(gpa);
                    gi.origin = self.placeGlyph(w, h);
                }
            }
        }

        try self.glyphs.put(gpa, glyph_id, gi);
        return gi;
    }
};
test "Entry.glyphInfoGet: a full atlas is cleared instead of growing past max_atlas_height" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    const entry = try cw.fonts.getOrCreate(cw.gpa, Font.init("Vera"));
    _ = try entry.glyphInfoGet(cw.gpa, 36);
    entry.pack_y = Cache.max_atlas_height;
    const gi = try entry.glyphInfoGet(cw.gpa, 37);
    try std.testing.expectEqual(@as(usize, 1), entry.glyphs.count());
    try std.testing.expectEqual(@as(f32, @floatFromInt(Cache.Entry.pad)), gi.origin[1]);
    try std.testing.expect(entry.atlas_width <= Cache.max_atlas_width);
}

test "Cache.reset: past max_coverage_entries, drops coverage no resolved stack uses" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    for (0..Cache.max_coverage_entries + 1) |i| {
        var fallback = try Cmap.FallbackStack.build(cw.gpa, &.{});
        errdefer fallback.deinit(cw.gpa);
        try cw.fonts.coverage_cache.map.put(cw.gpa, i, fallback);
    }
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("Vera"));
    _ = resolved;
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(u32, 1), cw.fonts.coverage_cache.map.count());
}

test "Entry.getTextureAtlas: keeps glyph pixels when partial uploads are unsupported" {
    if (Cache.Entry.drops_uploaded_pixels) return error.SkipZigTest;
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

test "Entry.getTextureAtlas: drops uploaded glyph pixels when partial uploads are supported; restorePixels re-renders" {
    if (!Cache.Entry.drops_uploaded_pixels) return error.SkipZigTest;
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    const entry = try cw.fonts.getOrCreate(cw.gpa, Font.init("Vera"));
    _ = try entry.glyphInfoGet(cw.gpa, 36);
    _ = try entry.getTextureAtlas(cw.gpa, cw.backend);
    _ = try entry.glyphInfoGet(cw.gpa, 37);
    _ = try entry.getTextureAtlas(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 0), entry.glyphs.get(37).?.pixels.len);
    const gi = entry.glyphs.getPtr(36).?;
    try std.testing.expect(try entry.restorePixels(cw.gpa, 36, gi));
    try std.testing.expect(gi.pixels.len > 0);
}
