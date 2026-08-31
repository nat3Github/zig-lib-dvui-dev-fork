const std = @import("std");
const dvui = @import("dvui.zig");
const opentype = @import("opentype");

const Rect = dvui.Rect;
const Size = dvui.Size;
const Texture = dvui.Texture;
const Backend = dvui.Backend;

const UserCoord = opentype.UserCoord;
const Buffer = opentype.Buffer;
const BidiFallbackResult = opentype.BidiFallbackResult;
const DiscoveryHandle = opentype.DiscoveryHandle;
const DiscoveryProperties = opentype.DiscoveryProperties;
const OtFont = opentype.Font;
const PositionedGlyph = opentype.PositionedGlyph;
const Renderer = opentype.Renderer;
const Cmap = opentype.Cmap;
const shaping = opentype.shaping;
const discovery_fontconfig = opentype.discovery_fontconfig;
const discovery_core_text = opentype.discovery_core_text;
const discovery_directwrite = opentype.discovery_directwrite;
const discovery_android = opentype.discovery_android;
const selectBestFontMatch = opentype.selectBestFontMatch;
const shapeBidiParagraphWithFallback = opentype.shapeBidiParagraphWithFallback;
pub const HardBreak = opentype.HardBreak;
pub const firstHardBreak = opentype.firstHardBreak;
pub const trailingHardBreakLen = opentype.trailingHardBreakLen;

/// Font parameters for text rendering; falls back to embedded Vera if no match found.
const Font = @This();

pub const DefaultSize = 10;

pub const Error = error{FontError};
pub const NAME_MAX_LEN = 50;

pub fn array(s: []const u8) [NAME_MAX_LEN:0]u8 {
    var v: [NAME_MAX_LEN:0]u8 = @splat(0);
    @memcpy(v[0..s.len], s);
    return v;
}

pub fn string(s: *const [NAME_MAX_LEN:0]u8) [:0]const u8 {
    return std.mem.sliceTo(s, 0);
}

/// CSS-style numeric weight (100-900) with closest-match support; see
/// `opentype.discovery.findBestMatch`.
pub const Weight = opentype.discovery.Weight;
pub const Style = opentype.discovery.Style;
pub const Stretch = opentype.discovery.Stretch;

pub const Underline = struct {
    /// Percent of font size, will always be at least 1 logical pixel
    thick: f32 = 0.1,
};

pub const Strike = struct {
    /// Percent of font size, will always be at least 1 logical pixel
    thick: f32 = 0.1,
};

pub const max_families = 4;
pub const max_variations = 4;

/// Ordered family names, most-preferred first (CSS font-family model).
families: [max_families][NAME_MAX_LEN:0]u8 = @splat(@splat(0)),
family_count: u8 = 1,

/// Height of a capital M in logical pixels.  After converting to physical
/// pixels, the font will have an integer M height <= size.
size: f32 = DefaultSize,
weight: Weight = .normal,
style: Style = .normal,
stretch: Stretch = .normal,

/// Can be changed for any font, no query.
line_height_factor: f32 = 1.2,
underline: ?Underline = null,
strike: ?Strike = null,

/// Variable-font axis positions (fvar/gvar instancing), separate from weight/style.
/// Affects hash/atlas caching like weight/style do.
variations: [max_variations]UserCoord = @splat(.{ .tag = @splat(0), .value = 0 }),
variation_count: u8 = 0,

pub const FindOptions = struct {
    family: []const u8,

    /// Height of capital M in logical pixels.
    size: f32 = DefaultSize,
    weight: Weight = .normal,
    style: Style = .normal,
    stretch: Stretch = .normal,
    line_height_factor: f32 = 1.2,
};

pub fn find(opts: FindOptions) Font {
    return Font.init(&.{opts.family}).withSize(opts.size).withWeight(opts.weight).withStyle(opts.style).withStretch(opts.stretch).withLineHeight(opts.line_height_factor);
}

/// Builds Font with 1-4 families; chainable with withSize/withWeight/etc.
pub fn init(names: []const []const u8) Font {
    std.debug.assert(names.len >= 1 and names.len <= max_families);
    var r: Font = .{ .family_count = @intCast(names.len) };
    for (names, 0..) |n, i| r.families[i] = array(n);
    return r;
}

pub const ThemeFontName = enum {
    body,
    heading,
    title,
    mono,
};

pub fn theme(which: ThemeFontName) Font {
    switch (which) {
        .body => return dvui.themeGet().font_body,
        .heading => return dvui.themeGet().font_heading,
        .title => return dvui.themeGet().font_title,
        .mono => return dvui.themeGet().font_mono,
    }
}

/// Collapses to a single family, discarding any others already set.
pub fn withFamily(self: Font, n: []const u8) Font {
    var r: Font = self;
    r.families = @splat(@splat(0));
    r.families[0] = array(n);
    r.family_count = 1;
    return r;
}

pub fn withSize(self: Font, s: f32) Font {
    var r = self;
    r.size = s;
    return r;
}

pub fn larger(self: Font, ds: f32) Font {
    var r = self;
    r.size += ds;
    return r;
}

pub fn withWeight(self: Font, w: Weight) Font {
    var r = self;
    r.weight = w;
    return r;
}

pub fn withStyle(self: Font, s: Style) Font {
    var r = self;
    r.style = s;
    return r;
}

pub fn withStretch(self: Font, s: Stretch) Font {
    var r = self;
    r.stretch = s;
    return r;
}

pub fn withLineHeight(self: Font, factor: f32) Font {
    var r = self;
    r.line_height_factor = factor;
    return r;
}

/// Sets one variable-font axis (e.g. `withVariation("wght", 650)`),
/// replacing any existing entry for the same tag. Silently ignored past
/// `max_variations` distinct axes.
pub fn withVariation(self: Font, tag: *const [4]u8, value: f32) Font {
    var r = self;
    for (r.variations[0..r.variation_count]) |*v| {
        if (std.mem.eql(u8, &v.tag, tag)) {
            v.value = value;
            return r;
        }
    }
    if (r.variation_count >= max_variations) return r;
    r.variations[r.variation_count] = .{ .tag = tag.*, .value = value };
    r.variation_count += 1;
    return r;
}

pub fn withUnderline(self: Font, underline: ?Underline) Font {
    var r = self;
    r.underline = underline;
    return r;
}

pub fn withStrike(self: Font, strike: ?Strike) Font {
    var r = self;
    r.strike = strike;
    return r;
}

pub fn familyAt(self: *const Font, i: usize) []const u8 {
    return string(&self.families[i]);
}

pub fn familyName(self: *const Font) []const u8 {
    return self.familyAt(0);
}

/// Single-family Font for family index i (used by Cache.resolveStack).
fn singleFamily(self: Font, i: usize) Font {
    var r = self;
    r.families = @splat(@splat(0));
    r.families[0] = self.families[i];
    r.family_count = 1;
    return r;
}

fn weightLabel(w: Weight) []const u8 {
    return if (w.value >= Weight.bold.value) " Bold" else "";
}

fn styleLabel(s: Style) []const u8 {
    return switch (s) {
        .normal => "",
        .italic => " Italic",
        .oblique => " Oblique",
    };
}

pub fn name(self: *const Font, allocator: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weightLabel(self.weight), styleLabel(self.style) }) catch "";
}

pub fn format(self: *const Font, writer: *std.Io.Writer) !void {
    try writer.print("{s}{s}{s} {d}", .{ self.familyName(), weightLabel(self.weight), styleLabel(self.style), self.size });
}

/// Fonts that hash the same value use the same glyphs (same Font.Entry).
pub fn hash(self: *const Font) u64 {
    var h = dvui.fnv.init();
    for (self.families[0..self.family_count]) |f| h.update(&f);
    h.update(std.mem.asBytes(&self.size));
    h.update(std.mem.asBytes(&self.weight));
    h.update(std.mem.asBytes(&self.style));
    h.update(std.mem.asBytes(&self.stretch));
    for (self.variations[0..self.variation_count]) |v| h.update(std.mem.asBytes(&v));
    return h.final();
}

/// Only valid between Window.begin/end
pub fn findSource(self: *const Font) ?Source {
    const cw = dvui.currentWindow();
    return cw.fonts.findSource(self.*).@"0";
}

pub const Source = struct {
    family: [NAME_MAX_LEN:0]u8 = @splat(0),
    size: f32 = 0, // zero means size-agnostic
    weight: Weight = .normal,
    style: Style = .normal,
    stretch: Stretch = .normal,

    bytes: []const u8, // ttf bytes
    /// If not null, this will be used to free ttf_bytes.
    allocator: ?std.mem.Allocator = null,

    pub fn familyName(self: *const Source) []const u8 {
        return string(&self.family);
    }

    pub fn name(self: *const Source, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weightLabel(self.weight), styleLabel(self.style) }) catch "";
    }

    /// Font that renders from this source.
    pub fn font(self: *const Source) Font {
        var r: Font = .{ .weight = self.weight, .style = self.style, .stretch = self.stretch };
        r.families[0] = self.family;
        return r;
    }

    pub fn deinit(self: *Source) void {
        defer self.* = undefined;
        if (self.allocator) |alloc| {
            alloc.free(self.bytes);
        }
    }

    pub const fallback = Source{
        .family = array("Vera"),
        .bytes = @embedFile("fonts/bitstream-vera/Vera.ttf"),
    };
};

const system_font_backend: ?type = blk: {
    if (@hasDecl(discovery_fontconfig, "Fontconfig")) break :blk discovery_fontconfig.Fontconfig;
    if (@hasDecl(discovery_core_text, "CoreText")) break :blk discovery_core_text.CoreText;
    if (@hasDecl(discovery_directwrite, "DirectWrite")) break :blk discovery_directwrite.DirectWrite;
    if (@hasDecl(discovery_android, "Android")) break :blk discovery_android.Android;
    break :blk null;
};

/// Resolves `font`'s family against the OS font-discovery backend, reads
/// the matched font file, and returns it as a `Source` -- the last resort
/// before `Cache.getOrCreate` falls back to the embedded Vera font, for
/// families the app never registered with `dvui.addFont`.
fn discoverSystemFont(gpa: std.mem.Allocator, font: Font) ?Source {
    const SysBackend = system_font_backend orelse return null;

    var backend = SysBackend.init() catch return null;
    defer backend.deinit();

    var handle_buf: [16]DiscoveryHandle = undefined;
    var properties_buf: [16]DiscoveryProperties = undefined;
    var index_buf: [16]usize = undefined;
    var path_storage: [4096]u8 = undefined;

    const properties: DiscoveryProperties = .{ .weight = font.weight, .style = font.style, .stretch = font.stretch };

    const needs_allocator = @typeInfo(@TypeOf(SysBackend.selectFamilyByName)).@"fn".params.len == 6;
    const scratch = if (needs_allocator) .{ &path_storage, gpa } else .{&path_storage};

    const handle = selectBestFontMatch(
        &backend,
        &.{.{ .title = font.familyName() }},
        properties,
        &handle_buf,
        &properties_buf,
        &index_buf,
        scratch,
    ) orelse return null;

    const bytes: []const u8 = switch (handle) {
        .path => |p| std.Io.Dir.cwd().readFileAlloc(dvui.io, p.path, gpa, .limited(64 * 1024 * 1024)) catch return null,
        .memory => |m| gpa.dupe(u8, m.bytes) catch return null,
    };

    return .{
        .family = array(font.familyName()),
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .bytes = bytes,
        .allocator = gpa,
    };
}

pub fn textHeight(self: Font) f32 {
    return self.sizeM(1, 1).h;
}

pub fn lineHeight(self: Font) f32 {
    return self.textHeight() * self.line_height_factor;
}

pub fn sizeM(self: Font, wide: f32, tall: f32) Size {
    const msize: Size = self.textSize("M");
    return .{ .w = msize.w * wide, .h = msize.h * tall };
}

/// handles multiple lines
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn textSize(self: Font, text: []const u8) Size {
    if (text.len == 0) {
        // just want the normal text height
        return .{ .w = 0, .h = self.textHeight() };
    }

    var ret = Size{};

    var line_height_adj: f32 = 0.0;
    var end: usize = 0;
    while (end < text.len) {
        if (end > 0) {
            ret.h += line_height_adj;
        }

        var end_idx: usize = undefined;
        var s = self.textSizeEx(text[end..], .{ .end_idx = &end_idx, .end_metric = .before });
        if (self.line_height_factor >= 1.0) {
            line_height_adj = s.h * (self.line_height_factor - 1.0);
        } else {
            s.h *= self.line_height_factor;
        }
        ret.h += s.h;
        ret.w = @max(ret.w, s.w);

        end += end_idx;
    }

    return ret;
}

pub const EndMetric = opentype.EndMetric;

pub const TextSizeOptions = struct {
    max_width: ?f32 = null,
    end_idx: ?*usize = null,
    end_metric: EndMetric = .before,
    ascent_out: ?*f32 = null,
};

/// textSizeEx always stops at a newline, use textSize to get multiline sizes
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn textSizeEx(self: Font, text: []const u8, opts: TextSizeOptions) Size {
    // Distinguish zero-size ask ({0,0}) from font-cache OOM ({10,10}).
    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    if (self.size * ss == 0.0) {
        if (opts.ascent_out) |ao| ao.* = 0;
        if (opts.end_idx) |endout| endout.* = text.len;
        return Size{};
    }

    const cw = dvui.currentWindow();
    var result = self.textSizeExShaped(cw.gpa, text, opts) catch return .{ .w = 10, .h = 10 };
    if (result) |*r| {
        defer r.shaped.deinit();
        return r.size;
    }
    if (opts.ascent_out) |ao| ao.* = 10;
    if (opts.end_idx) |endout| endout.* = text.len;
    return .{ .w = 10, .h = 10 };
}

/// Shape reusable across text measurement and rendering without reshaping.
pub const ShapedText = struct {
    fallback: *Cache.Entry,
    line: Cache.Entry.ShapedLine,
    ss: f32,
    ascent: f32,

    pub fn deinit(self: *ShapedText) void {
        self.line.deinit();
    }

    pub fn measureUpToByteOffset(self: *ShapedText, gpa: std.mem.Allocator, byte_offset: usize) std.mem.Allocator.Error!Size {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const glyph_limit = self.line.glyphLimitForByteOffset(byte_offset);
        const s = try self.fallback.measureGlyphRange(gpa, &self.line, glyph_limit, snap);
        return s.scale(1.0 / self.ss, Size);
    }

    pub fn byteOffsetForWidth(self: *ShapedText, gpa: std.mem.Allocator, glyph_limit: usize, width: f32, end_metric: Font.EndMetric) std.mem.Allocator.Error!usize {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const glyphs_used = try self.fallback.glyphsForWidth(gpa, &self.line, glyph_limit, width * self.ss, end_metric, snap);
        return self.line.byteOffsetForGlyph(glyphs_used);
    }
};

pub fn textSizeExShaped(self: Font, gpa: std.mem.Allocator, text: []const u8, opts: TextSizeOptions) std.mem.Allocator.Error!?struct { size: Size, shaped: ShapedText } {
    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    const ask_size = self.size * ss;

    if (opts.ascent_out) |ao| ao.* = 10;
    if (opts.end_idx) |endout| endout.* = text.len;
    if (ask_size == 0.0) {
        if (opts.ascent_out) |ao| ao.* = 0;
        return null;
    }

    const sized_font = self.withSize(ask_size);
    const cw = dvui.currentWindow();
    const resolved = cw.fonts.resolveStack(cw.gpa, sized_font) catch return null;
    const fallback_entry = cw.fonts.stackEntry(resolved, 0) orelse return null;

    var options = opts;
    if (opts.max_width) |mwidth| {
        options.max_width = mwidth * ss;
    }

    const result = try cw.fonts.textSizeRawShaped(cw.arena(), gpa, resolved, text, options);

    var ascent = fallback_entry.ascent;
    if (self.line_height_factor < 1.0) {
        ascent = @round(ascent * self.line_height_factor);
    }
    if (opts.ascent_out) |ao| ao.* = ascent / ss;

    return .{
        .size = result.size.scale(1.0 / ss, Size),
        .shaped = .{ .fallback = fallback_entry, .line = result.line, .ss = ss, .ascent = ascent },
    };
}

pub const Cache = struct {
    database: std.ArrayList(Source) = .empty,
    cache: dvui.TrackingAutoHashMap(u64, Entry, .get_and_put, void) = .empty,
    /// Stack-level coverage cache; separate from per-entry cache so reset doesn't evict it.
    resolved_stacks: dvui.TrackingAutoHashMap(u64, ResolvedStack, .get_and_put, void) = .empty,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
        defer self.* = undefined;
        var it = self.cache.iterator();
        while (it.next()) |item| {
            item.value_ptr.deinit(gpa, backend);
        }
        self.cache.deinit(gpa);

        var sit = self.resolved_stacks.iterator();
        while (sit.next()) |item| {
            item.value_ptr.deinit(gpa);
        }
        self.resolved_stacks.deinit(gpa);

        for (self.database.items) |*source| {
            if (source.allocator) |a| {
                a.free(source.bytes);
            }
        }
        self.database.deinit(gpa);
    }

    pub fn reset(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
        var it = self.cache.iterator();
        while (it.next_resetting()) |kv| {
            var fce = kv.value;
            fce.deinit(gpa, backend);
        }
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

        if (source.weight.value == font.weight.value and source.style == font.style and source.stretch.value == font.stretch.value) {
            return .{ source.*, null }; // exact match
        }
        return .{ null, source.* };
    }

    pub fn getOrCreate(self: *Cache, gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*Entry {
        const entry = try self.cache.getOrPut(gpa, font.hash());
        if (entry.found_existing) return entry.value_ptr;

        const fname = font.name(gpa);
        defer gpa.free(fname);

        const exact, const second = self.findSource(font);

        const source = exact orelse blk: {
            if (second) |s| {
                const sname = s.name(gpa);
                defer gpa.free(sname);
                dvui.log.warn("Font {s} not loaded in dvui, using second best {s}", .{ fname, sname });
                break :blk s;
            } else if (discoverSystemFont(gpa, font)) |sys_source| {
                dvui.log.debug("Font {s} resolved via OS font discovery", .{fname});
                try self.database.append(gpa, sys_source);
                break :blk sys_source;
            } else {
                dvui.log.warn("Font {s} not loaded in dvui, using fallback", .{fname});
                break :blk Source.fallback;
            }
        };

        //log.debug("FontCacheGet creating font hash {x} ptr {*} size {d} name \"{s}\"", .{ fontHash, bytes.ptr, font.size, font.name });

        entry.value_ptr.* = Entry.init(gpa, source.bytes, font) catch |err| {
            dvui.log.err("Font {s} init got {any}, using fallback", .{ fname, err });
            // Remove the invalid font cache entry, something went wrong reading the ttf_bytes
            self.cache.map.removeByPtr(entry.key_ptr);
            // Substitute the known good fallback font
            return self.getOrCreate(gpa, Source.fallback.font());
        };
        //log.debug("- size {d} ascent {d} height {d}", .{ font.size, entry.ascent, entry.height });
        return entry.value_ptr;
    }

    pub const ResolvedStack = struct {
        /// Entry hashes; entries themselves live in Cache.cache.
        entry_hashes: [Font.max_families]u64 = @splat(0),
        entry_count: u8 = 0,
        /// Merged codepoint coverage across all entries; built once per stack.
        fallback: Cmap.FallbackStack = .{},
        /// Warned codepoint blocks (cp >> 8) to suppress duplicate warnings.
        logged_missing: std.AutoHashMapUnmanaged(u21, void) = .empty,

        pub fn deinit(self: *ResolvedStack, gpa: std.mem.Allocator) void {
            self.fallback.deinit(gpa);
            self.logged_missing.deinit(gpa);
        }

        /// Stack index of the highest-priority entry covering `codepoint`,
        /// or null if nothing in the stack does (caller should fall back
        /// to entry 0 and expect `.notdef`).
        pub fn entryIndexFor(self: *const ResolvedStack, codepoint: u21) ?u8 {
            return self.fallback.entryIndexFor(codepoint);
        }
    };

    /// Load families and cache merged coverage per stack.
    pub fn resolveStack(self: *Cache, gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*ResolvedStack {
        const h = font.hash();
        const found = try self.resolved_stacks.getOrPut(gpa, h);
        if (found.found_existing) {
            // Re-touch families to recreate any evicted by reset.
            for (0..font.family_count) |i| {
                _ = try self.getOrCreate(gpa, font.singleFamily(i));
            }
            return found.value_ptr;
        }

        var entry_hashes: [Font.max_families]u64 = @splat(0);
        var per_entry_ranges: [Font.max_families][]Cmap.Range = undefined;
        var count: u8 = 0;
        errdefer for (per_entry_ranges[0..count]) |r| gpa.free(r);

        for (0..font.family_count) |i| {
            const family_font = font.singleFamily(i);
            const entry = try self.getOrCreate(gpa, family_font);
            entry_hashes[count] = family_font.hash();
            const cmap_data = entry.parsed_font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
            per_entry_ranges[count] = try Cmap.coverageRanges(cmap_data, gpa);
            count += 1;
        }
        defer for (per_entry_ranges[0..count]) |r| gpa.free(r);

        const fallback = try Cmap.FallbackStack.build(gpa, per_entry_ranges[0..count]);
        found.value_ptr.* = .{ .entry_hashes = entry_hashes, .entry_count = count, .fallback = fallback };
        return found.value_ptr;
    }

    /// Entry at stack index; null if evicted by reset.
    pub fn stackEntry(self: *Cache, resolved: *const ResolvedStack, index: u8) ?*Entry {
        if (index >= resolved.entry_count) return null;
        return self.cache.getPtr(resolved.entry_hashes[index]);
    }

    /// Shape text up to first newline, splitting runs by font stack coverage.
    /// `persist_gpa` backs only `resolved.logged_missing`, which outlives the
    /// frame (cached in `resolved_stacks`) -- passing a per-frame arena there
    /// corrupts the map once the arena resets on the next frame.
    pub fn shapeLineText(self: *Cache, gpa: std.mem.Allocator, persist_gpa: std.mem.Allocator, resolved: *ResolvedStack, text: []const u8) std.mem.Allocator.Error!Entry.ShapedLine {
        const decoded = try Entry.decodeLine(gpa, text);
        errdefer gpa.free(decoded.codepoints);
        errdefer gpa.free(decoded.byte_offsets);

        // Fallback font stack in priority order. An entry may have been
        // evicted from `cache` since resolve (see `stackEntry`); skip it.
        var fonts_buf: [Font.max_families]OtFont = undefined;
        var entries_buf: [Font.max_families]*Entry = undefined;
        var nfonts: usize = 0;
        var idx: u8 = 0;
        while (idx < resolved.entry_count) : (idx += 1) {
            if (self.stackEntry(resolved, idx)) |e| {
                fonts_buf[nfonts] = e.parsed_font;
                entries_buf[nfonts] = e;
                nfonts += 1;
            }
        }

        var result = Buffer.init(gpa);
        errdefer result.deinit();
        var segments: std.ArrayList(Entry.ShapedLine.EntrySegment) = .empty;
        errdefer segments.deinit(gpa);

        if (decoded.codepoints.len > 0 and nfonts > 0) {
            for (decoded.codepoints) |cp| _ = self.entryIndexForLogged(resolved, persist_gpa, cp); // diagnostics
            // Bidi outer, font fallback inner, so visual reordering crosses font boundaries.
            const shaped = shapeBidiParagraphWithFallback(gpa, fonts_buf[0..nfonts], decoded.codepoints, .auto, &.{}, &.{}, &.{}) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => BidiFallbackResult{ .buffer = Buffer.init(gpa), .font_indices = &.{} },
            };
            defer gpa.free(shaped.font_indices);
            result.deinit();
            result = shaped.buffer;

            // Coalesce consecutive same-font glyphs into segments.
            var g: usize = 0;
            while (g < shaped.font_indices.len) {
                const fi = shaped.font_indices[g];
                var h = g + 1;
                while (h < shaped.font_indices.len and shaped.font_indices[h] == fi) h += 1;
                try segments.append(gpa, .{ .entry = entries_buf[fi], .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
                g = h;
            }
        }
        result.have_positions = true;

        const cluster_tables = try result.buildClusterTables(gpa, decoded.byte_offsets);

        return .{
            .allocator = gpa,
            .codepoints = decoded.codepoints,
            .byte_offsets = decoded.byte_offsets,
            .buffer = result,
            .cluster_starts = cluster_tables.starts,
            .cluster_ends = cluster_tables.ends,
            .segments = try segments.toOwnedSlice(gpa),
        };
    }

    /// `resolved.entryIndexFor(codepoint)`, falling back to entry 0 and
    /// warning once per uncovered codepoint block (`codepoint >> 8`).
    fn entryIndexForLogged(self: *Cache, resolved: *ResolvedStack, gpa: std.mem.Allocator, codepoint: u21) u8 {
        _ = self;
        if (resolved.entryIndexFor(codepoint)) |idx| return idx;
        const block: u21 = codepoint >> 8;
        if (resolved.logged_missing.get(block) == null) {
            resolved.logged_missing.put(gpa, block, {}) catch {};
            dvui.log.warn("Font: no entry covers codepoint block U+{X:0>4}xx (e.g. U+{X:0>4}), falling back to entry 0 (.notdef)", .{ block, codepoint });
        }
        return 0;
    }

    pub fn textSizeRawShaped(
        self: *Cache,
        scratch: std.mem.Allocator,
        gpa: std.mem.Allocator,
        resolved: *ResolvedStack,
        text: []const u8,
        opts: Font.TextSizeOptions,
    ) std.mem.Allocator.Error!Entry.MeasureResult {
        const mwidth = opts.max_width orelse dvui.max_float_safe;
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const fallback_entry = self.stackEntry(resolved, 0);
        const default_height: f32 = if (fallback_entry) |fe| fe.height else 0;

        const hard_break = firstHardBreak(text);
        const newline_idx = if (hard_break) |hb| hb.start else text.len;
        var window: usize = if (opts.max_width != null) @min(newline_idx, 64) else newline_idx;

        while (true) {
            var line = try self.shapeLineText(scratch, gpa, resolved, text[0..window]);
            errdefer line.deinit();

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
                const gi = try fce.glyphInfoGet(gpa, info.codepoint);
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
            window = @min(newline_idx, window * 2);
        }
    }

    pub const Entry = struct {
        name: []const u8, // gpa
        parsed_font: OtFont,
        renderer: Renderer,
        height: f32, // ascender - descender
        ascent: f32, // ascender
        em_height: f32, // measured M height
        /// Glyphs keyed by ID (post-shaping), not Unicode codepoint.
        // TODO: no eviction -- a font entry's atlas grows unbounded under pathological glyph churn (e.g. heavy CJK), eventually hitting backend texture-size limits.
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
            /// Rasterized RGBA bytes (w*h*4), gpa-owned.
            pixels: []u8,
            /// Uploaded to current texture_atlas_cache yet.
            uploaded: bool,
        };

        pub fn toPixels(self: Entry, font_units: i32) f32 {
            return self.renderer.unitsToPixels(font_units);
        }

        fn measuredCapHeight(renderer: *Renderer, gpa: std.mem.Allocator, glyph_id: u16) ?f32 {
            // scratch uses lifo; output uses gpa to avoid lifo ordering violation.
            const rendered = renderer.renderGlyph(glyph_id, .{}, dvui.currentWindow().lifo(), gpa) catch return null;
            defer rendered.deinit(gpa);
            if (rendered.bitmap.rows == 0) return null;
            return @floatFromInt(rendered.bitmap.rows);
        }

        /// Load font, calibrating ppem so rendered M height matches font.size.
        pub fn init(gpa: std.mem.Allocator, ttf_bytes: []const u8, font: Font) Error!Entry {
            const min_pixel_size: f32 = 1;

            const fname = font.name(gpa);
            errdefer gpa.free(fname);

            const parsed_font = OtFont.parse(gpa, ttf_bytes) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype parse error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            errdefer parsed_font.deinit(gpa);

            var ppem = @max(min_pixel_size, font.size);
            var renderer = Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = font.variations[0..font.variation_count] }) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            errdefer renderer.deinit(gpa);

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
                const probe_h = measuredCapHeight(&renderer, gpa, m_glyph_id) orelse break :probe;
                if (probe_h <= 0) break :probe;
                const ratio = probe_h / ppem;
                const corrected = @max(min_pixel_size, font.size / ratio);
                renderer.deinit(gpa);
                ppem = corrected;
                renderer = Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = font.variations[0..font.variation_count] }) catch |err| {
                    dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                    return Error.FontError;
                };
                em_height = measuredCapHeight(&renderer, gpa, m_glyph_id) orelse ppem;
            }

            const scale_f = ppem / units_per_em_f;
            var entry: Entry = .{
                .name = fname,
                .parsed_font = parsed_font,
                .renderer = renderer,
                .ascent = @trunc(raw_ascender * scale_f),
                .height = (raw_ascender - raw_descender) * scale_f,
                .em_height = em_height,
            };

            // Pre-place Latin-1 (0x20-0xFF) to avoid per-run atlas growth.
            // CJK/emoji filled lazily to avoid load-time lag.
            if (cmap_data) |cd| {
                var codepoint: u21 = 0x20;
                while (codepoint <= 0xFF) : (codepoint += 1) {
                    const glyph_id = Cmap.lookup(cd, codepoint) orelse continue;
                    if (glyph_id == 0) continue;
                    _ = entry.glyphInfoGet(gpa, glyph_id) catch {};
                }
            }

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
            if (self.texture_atlas_cache) |tex| backend.textureDestroy(tex);
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
                    const src = gi.pixels[(row * out_w + col) * 4 ..][0..4];
                    const dest = (oy + row) * dst_stride + (ox + col);
                    dst[dest] = if (gi.is_color)
                        .{ .r = src[0], .g = src[1], .b = src[2], .a = src[3] }
                    else
                        // Coverage-only: broadcast alpha as premultiplied white.
                        .{ .r = src[3], .g = src[3], .b = src[3], .a = src[3] };
                }
            }
        }

        /// Rebuild whole GPU texture from cached bitmaps at new_height.
        fn rebuildAtlasTexture(self: *Entry, gpa: std.mem.Allocator, new_height: u32) Backend.TextureError!void {
            const pixel_count = @as(usize, self.atlas_width) * new_height;
            const pixels = try gpa.alloc(dvui.Color.PMA, pixel_count);
            defer gpa.free(pixels);
            @memset(pixels, .transparent);

            var it = self.glyphs.valueIterator();
            while (it.next()) |gi| {
                blitGlyph(gi, pixels, self.atlas_width, @intFromFloat(gi.origin[0]), @intFromFloat(gi.origin[1]));
                gi.uploaded = true;
            }

            const new_tex = try dvui.textureCreate(pixels, .{ .width = self.atlas_width, .height = new_height });
            if (self.texture_atlas_cache) |old| dvui.textureDestroyLater(old);
            self.texture_atlas_cache = new_tex;
            self.atlas_alloc_height = new_height;
        }

        /// Ensure all placed glyphs have reached GPU texture (full build or incremental upload).
        pub fn getTextureAtlas(self: *Entry, gpa: std.mem.Allocator, backend: Backend) Backend.TextureError!Texture {
            if (self.glyphs.count() == 0) {
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

            // textureUpdateSubRect requires atlas-width stride; share buffer across glyphs.
            const row_pixels = try gpa.alloc(dvui.Color.PMA, @as(usize, self.atlas_width) * self.atlas_alloc_height);
            defer gpa.free(row_pixels);
            @memset(row_pixels, .transparent);

            var it = self.glyphs.valueIterator();
            while (it.next()) |gi| {
                if (gi.uploaded) continue;
                const out_w: u32 = @intFromFloat(gi.w);
                const out_h: u32 = @intFromFloat(gi.h);
                if (out_w == 0 or out_h == 0) {
                    gi.uploaded = true;
                    continue;
                }
                const ox: u32 = @intFromFloat(gi.origin[0]);
                const oy: u32 = @intFromFloat(gi.origin[1]);
                blitGlyph(gi, row_pixels, self.atlas_width, ox, oy);
                backend.textureUpdateSubRect(tex, @ptrCast(row_pixels.ptr), ox, oy, out_w, out_h) catch |err| switch (err) {
                    error.NotImplemented => {
                        // Backend doesn't support partial uploads; full rebuild instead.
                        try self.rebuildAtlasTexture(gpa, self.atlas_alloc_height);
                        return self.texture_atlas_cache.?;
                    },
                    else => |e| return e,
                };
                gi.uploaded = true;
            }
            return tex;
        }

        /// Rasterize glyph and place in atlas; getTextureAtlas uploads later.
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
                defer rendered.deinit(gpa);
                const byte_len = @as(usize, rendered.bitmap.width) * rendered.bitmap.rows * 4;
                break :blk .{
                    .leftBearing = @floatFromInt(rendered.bitmap.left),
                    .topBearing = @floatFromInt(rendered.bitmap.top),
                    .w = @floatFromInt(rendered.bitmap.width),
                    .h = @floatFromInt(rendered.bitmap.rows),
                    .origin = .{ 0, 0 },
                    .is_color = rendered.is_color,
                    .pixels = try gpa.dupe(u8, rendered.bitmap.pixels_row_major[0..byte_len]),
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

            /// True if bidi reordering moved glyphs out of logical order.
            pub fn isBidi(self: ShapedLine) bool {
                var prev: u32 = 0;
                for (self.buffer.info.items) |info| {
                    if (info.cluster < prev) return true;
                    prev = info.cluster;
                }
                return false;
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

        /// Size of glyphs up to glyph_limit; no reshaping.
        pub fn measureGlyphRange(self: *Entry, gpa: std.mem.Allocator, line: *const ShapedLine, glyph_limit: usize, snap: bool) std.mem.Allocator.Error!Size {
            const s = try opentype.measureGlyphRange(gpa, self, self.ascent, self.height, line.buffer.info.items, line.buffer.pos.items, glyph_limit, snap);
            return .{ .w = s.w, .h = s.h };
        }

        /// Glyph count where cumulative advance crosses mwidth; used for hit-testing.
        pub fn glyphsForWidth(self: *Entry, gpa: std.mem.Allocator, line: *const ShapedLine, glyph_limit: usize, mwidth: f32, end_metric: Font.EndMetric, snap: bool) std.mem.Allocator.Error!usize {
            return opentype.glyphsForWidth(gpa, self, line.buffer.info.items, line.buffer.pos.items, glyph_limit, mwidth, end_metric, snap);
        }
    };
};

test {
    @import("std").testing.refAllDecls(@This());
}

test "firstHardBreak / trailingHardBreakLen: UAX #14 mandatory breaks" {
    const t = std.testing;
    try t.expectEqual(@as(?HardBreak, null), firstHardBreak("plain text"));
    try t.expectEqual(HardBreak{ .start = 1, .len = 1 }, firstHardBreak("a\nb").?); // LF
    try t.expectEqual(HardBreak{ .start = 1, .len = 2 }, firstHardBreak("a\r\nb").?); // CRLF is one break
    try t.expectEqual(HardBreak{ .start = 1, .len = 1 }, firstHardBreak("a\rb").?); // lone CR
    try t.expectEqual(HardBreak{ .start = 0, .len = 1 }, firstHardBreak("\x0bx").?); // VT
    try t.expectEqual(HardBreak{ .start = 1, .len = 2 }, firstHardBreak("a\u{0085}b").?); // NEL
    try t.expectEqual(HardBreak{ .start = 1, .len = 3 }, firstHardBreak("a\u{2028}b").?); // LS
    try t.expectEqual(HardBreak{ .start = 1, .len = 3 }, firstHardBreak("a\u{2029}").?); // PS at end
    // a lone 0xe2/0xc2 lead byte that isn't LS/PS/NEL must not be a break
    try t.expectEqual(@as(?HardBreak, null), firstHardBreak("caf\u{00e9}")); // é = 0xc3 0xa9
    try t.expectEqual(@as(?HardBreak, null), firstHardBreak("\u{2022}")); // bullet = 0xe2 0x80 0xa2

    try t.expectEqual(@as(usize, 0), trailingHardBreakLen("no break"));
    try t.expectEqual(@as(usize, 1), trailingHardBreakLen("line\n"));
    try t.expectEqual(@as(usize, 2), trailingHardBreakLen("line\r\n"));
    try t.expectEqual(@as(usize, 1), trailingHardBreakLen("line\r"));
    try t.expectEqual(@as(usize, 3), trailingHardBreakLen("line\u{2028}"));
    try t.expectEqual(@as(usize, 0), trailingHardBreakLen("a\nb")); // break not at end
}

test "smoke: shape + measure + rasterize against embedded Vera.ttf" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 24 });
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);
    const entry = cw.fonts.stackEntry(resolved, 0).?;

    try std.testing.expect(entry.ascent > 0);
    try std.testing.expect(entry.height > 0);
    try std.testing.expect(entry.em_height > 0);
    std.debug.print("ascent={d} height={d} em_height={d}\n", .{ entry.ascent, entry.height, entry.em_height });

    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, "Hello, world! fi ffi");
    defer line.deinit();

    try std.testing.expect(line.buffer.info.items.len > 0);
    std.debug.print("shaped {d} glyphs from {d} codepoints\n", .{ line.buffer.info.items.len, line.codepoints.len });
    for (line.buffer.info.items) |info| {
        try std.testing.expect(info.codepoint != 0);
    }

    var end_idx: usize = 0;
    var result = try cw.fonts.textSizeRawShaped(gpa, gpa, resolved, "Hello, world!", .{ .end_idx = &end_idx });
    defer result.line.deinit();
    std.debug.print("measured size w={d} h={d} end_idx={d}\n", .{ result.size.w, result.size.h, end_idx });
    try std.testing.expect(result.size.w > 0);
    try std.testing.expect(result.size.h > 0);
    try std.testing.expectEqual(@as(usize, "Hello, world!".len), end_idx);

    const gi = try entry.glyphInfoGet(gpa, line.buffer.info.items[0].codepoint);
    std.debug.print("glyph0 w={d} h={d} left={d} top={d} is_color={}\n", .{ gi.w, gi.h, gi.leftBearing, gi.topBearing, gi.is_color });
    try std.testing.expect(gi.w > 0);
    try std.testing.expect(gi.h > 0);
}

test "smoke: bidi/RTL text shapes without crashing" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);

    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, "abc \u{0627}\u{0644}\u{0633}\u{0644}\u{0627}\u{0645} xyz");
    defer line.deinit();
    try std.testing.expect(line.buffer.info.items.len > 0);
    // The Arabic run is RTL, so its glyphs are reordered out of logical
    // order -- `isBidi` must catch this so `TextLayoutWidget` reshapes each
    // wrapped line's own byte-range instead of slicing a visual prefix.
    try std.testing.expect(line.isBidi());

    // Pure-LTR text keeps clusters monotone, so the fast visual-prefix reuse
    // path stays enabled (isBidi false).
    var ltr = try cw.fonts.shapeLineText(gpa, gpa, resolved, "Hello, world!");
    defer ltr.deinit();
    try std.testing.expect(!ltr.isBidi());
}

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

    var resolved: Cache.ResolvedStack = .{ .entry_count = 2, .fallback = fallback };

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
    try dvui.addFont("TestKorean", @embedFile("fonts/NotoSansKR-Regular.ttf"), null);

    const stack: Font = .init(&.{ "TestLatin", "TestKorean" });
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    const latin_entry = cw.fonts.stackEntry(resolved, 0).?;
    const korean_entry = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expect(latin_entry != korean_entry);

    // "AB" (Latin) + two Hangul syllables (Korean) + "CD" (Latin) -- Vera
    // has no Hangul glyphs and NotoSansKR-Regular has no use registering it
    // as the primary family, so coverage is naturally disjoint here.
    var line = try cw.fonts.shapeLineText(std.testing.allocator, std.testing.allocator, resolved, "AB\u{AC00}\u{AC01}CD");
    defer line.deinit();

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
