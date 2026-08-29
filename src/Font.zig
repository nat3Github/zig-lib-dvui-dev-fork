const std = @import("std");
const dvui = @import("dvui.zig");
const ot = @import("opentype");

const Rect = dvui.Rect;
const Size = dvui.Size;
const Texture = dvui.Texture;
const Backend = dvui.Backend;

/// Font represents the parameters that dvui will try to satisfy when rendering
/// text.  If a matching font is not found, dvui will log an error and use the
/// internal fallback font.
///
/// Usually specified with `find`:
/// const f: Font = .find(.{ .family = "Vera", .size = 12 });
///
/// To source a Font from the theme, use `theme`:
/// const f: Font = .theme(.mono);
/// const f = Font.theme(mono).larger(2);
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

pub const Weight = enum {
    normal,
    bold,
};

pub const Style = enum {
    normal,
    italic,
};

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

/// Ordered families to satisfy this Font from, most-preferred first -- same
/// model as CSS `font-family: A, B, C`. Usually just one (`family_count ==
/// 1`); weight/style/size apply uniformly across every family the same way
/// CSS's fallback list doesn't carry independent style per entry.
///
/// Changing any of these might query for a font.
families: [max_families][NAME_MAX_LEN:0]u8 = @splat(@splat(0)),
family_count: u8 = 1,

/// Height of a capital M in logical pixels.  After converting to physical
/// pixels, the font will have an integer M height <= size.
size: f32 = DefaultSize,
weight: Weight = .normal,
style: Style = .normal,

/// Can be changed for any font, no query.
line_height_factor: f32 = 1.2,
underline: ?Underline = null,
strike: ?Strike = null,

/// Variable-font axis positions fed straight to the rasterizer's
/// `user_coords` (fvar/gvar instancing). Selection (which face discovery
/// loads) still comes from `weight`/`style`; these instance the loaded face
/// and win at the rasterizer on overlap. Any axis set here joins `hash()`,
/// so each distinct position gets its own glyph atlas -- same as `weight`
/// and `style` already fork entries.
variations: [max_variations]ot.render.UserCoord = @splat(.{ .tag = @splat(0), .value = 0 }),
variation_count: u8 = 0,

pub const FindOptions = struct {
    family: []const u8,

    /// Height of capital M in logical pixels.
    size: f32 = DefaultSize,
    weight: Weight = .normal,
    style: Style = .normal,
    line_height_factor: f32 = 1.2,
};

pub fn find(opts: FindOptions) Font {
    return Font.init(&.{opts.family}).withSize(opts.size).withWeight(opts.weight).withStyle(opts.style).withLineHeight(opts.line_height_factor);
}

/// Builds a Font backed by 1-4 families, most-preferred first -- e.g. for a
/// CJK-with-Latin-fallback stack: `Font.init(&.{ "Noto Sans", "Noto Sans JP" })`.
/// Weight/style/size default like a plain `Font{}` and can be chained with
/// `withSize`/`withWeight`/etc same as any other Font.
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

/// A single-family Font matching this one's family `i` -- used to load and
/// cache each family in a multi-family Font independently (see
/// `Cache.resolveStack`).
fn singleFamily(self: Font, i: usize) Font {
    var r = self;
    r.families = @splat(@splat(0));
    r.families[0] = self.families[i];
    r.family_count = 1;
    return r;
}

pub fn name(self: *const Font, allocator: std.mem.Allocator) []const u8 {
    const weight = switch (self.weight) {
        .normal => "",
        .bold => " Bold",
    };
    const style = switch (self.style) {
        .normal => "",
        .italic => " Italic",
    };
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weight, style }) catch "";
}

pub fn format(self: *const Font, writer: *std.Io.Writer) !void {
    const weight = switch (self.weight) {
        .normal => "",
        .bold => " Bold",
    };
    const style = switch (self.style) {
        .normal => "",
        .italic => " Italic",
    };
    try writer.print("{s}{s}{s} {d}", .{ self.familyName(), weight, style, self.size });
}

/// Fonts that hash the same value use the same glyphs (same Font.Entry).
pub fn hash(self: *const Font) u64 {
    var h = dvui.fnv.init();
    for (self.families[0..self.family_count]) |f| h.update(&f);
    h.update(std.mem.asBytes(&self.size));
    h.update(std.mem.asBytes(&self.weight));
    h.update(std.mem.asBytes(&self.style));
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
    size: f32 = 0, // zero means this source can be any size
    weight: Weight = .normal,
    style: Style = .normal,

    // currently we assume that a single ttf only produces one
    bytes: []const u8, // points to ttf bytes
    /// If not null, this will be used to free ttf_bytes.
    allocator: ?std.mem.Allocator = null,

    pub fn familyName(self: *const Source) []const u8 {
        return string(&self.family);
    }

    pub fn name(self: *const Source, allocator: std.mem.Allocator) []const u8 {
        const weight = switch (self.weight) {
            .normal => "",
            .bold => " Bold",
        };
        const style = switch (self.style) {
            .normal => "",
            .italic => " Italic",
        };
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weight, style }) catch "";
    }

    /// Return a Font that will render from this source.
    pub fn font(self: *const Source) Font {
        var r: Font = .{ .weight = self.weight, .style = self.style };
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
    if (@hasDecl(ot.discovery.fontconfig, "Fontconfig")) break :blk ot.discovery.fontconfig.Fontconfig;
    if (@hasDecl(ot.discovery.core_text, "CoreText")) break :blk ot.discovery.core_text.CoreText;
    if (@hasDecl(ot.discovery.directwrite, "DirectWrite")) break :blk ot.discovery.directwrite.DirectWrite;
    if (@hasDecl(ot.discovery.android, "Android")) break :blk ot.discovery.android.Android;
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

    var handle_buf: [16]ot.discovery.Handle = undefined;
    var properties_buf: [16]ot.discovery.Properties = undefined;
    var index_buf: [16]usize = undefined;
    var path_storage: [4096]u8 = undefined;

    const properties: ot.discovery.Properties = .{
        .weight = if (font.weight == .bold) .bold else .normal,
        .style = if (font.style == .italic) .italic else .normal,
    };

    const needs_allocator = @typeInfo(@TypeOf(SysBackend.selectFamilyByName)).@"fn".params.len == 6;
    const scratch = if (needs_allocator) .{ &path_storage, gpa } else .{&path_storage};

    const handle = ot.discovery.selectBestMatch(
        &backend,
        &.{.{ .title = font.familyName() }},
        properties,
        &handle_buf,
        &properties_buf,
        &index_buf,
        scratch,
    ) catch return null;

    const bytes: []const u8 = switch (handle) {
        .path => |p| std.Io.Dir.cwd().readFileAlloc(dvui.io, p.path, gpa, .limited(64 * 1024 * 1024)) catch return null,
        .memory => |m| gpa.dupe(u8, m.bytes) catch return null,
    };

    return .{
        .family = array(font.familyName()),
        .weight = font.weight,
        .style = font.style,
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

pub const EndMetric = enum {
    before, // end_idx stops before text goes past max_width
    nearest, // end_idx stops at start of character closest to max_width
};

/// A UAX #14 mandatory (hard) line break dvui honors while laying out text:
/// LF, VT, FF, CR, CRLF, NEL (U+0085), LS (U+2028) and PS (U+2029) -- the
/// break-class BK/CR/LF/NL characters. `start` is the byte offset of the
/// break, `len` the byte length of the sequence (CRLF is one break of len 2).
pub const HardBreak = struct { start: usize, len: usize };

/// First hard break in `text`, or null. Byte scan (no full UTF-8 decode) --
/// ponytail: linear per line, swap for a SIMD lead-byte search if text
/// measurement ever shows up hot.
pub fn firstHardBreak(text: []const u8) ?HardBreak {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            0x0a, 0x0b, 0x0c => return .{ .start = i, .len = 1 }, // LF, VT, FF
            0x0d => return .{ .start = i, .len = if (i + 1 < text.len and text[i + 1] == 0x0a) 2 else 1 }, // CR / CRLF
            0xc2 => if (i + 1 < text.len and text[i + 1] == 0x85) return .{ .start = i, .len = 2 }, // NEL
            0xe2 => if (i + 2 < text.len and text[i + 1] == 0x80 and (text[i + 2] == 0xa8 or text[i + 2] == 0xa9))
                return .{ .start = i, .len = 3 }, // LS / PS
            else => {},
        }
    }
    return null;
}

/// Byte length of a hard break at the very end of `text`, else 0.
pub fn trailingHardBreakLen(text: []const u8) usize {
    const n = text.len;
    if (n == 0) return 0;
    if (n >= 3 and text[n - 3] == 0xe2 and text[n - 2] == 0x80 and (text[n - 1] == 0xa8 or text[n - 1] == 0xa9)) return 3; // LS/PS
    if (n >= 2 and text[n - 2] == 0x0d and text[n - 1] == 0x0a) return 2; // CRLF
    if (n >= 2 and text[n - 2] == 0xc2 and text[n - 1] == 0x85) return 2; // NEL
    switch (text[n - 1]) {
        0x0a, 0x0b, 0x0c, 0x0d => return 1, // LF, VT, FF, CR
        else => return 0,
    }
}

pub const TextSizeOptions = struct {
    max_width: ?f32 = null,
    end_idx: ?*usize = null,
    end_metric: EndMetric = .before,
    /// Kerning now comes from the font's own GPOS table as part of shaping
    /// and can no longer be selectively disabled per-call the way the old
    /// FreeType/stb pairwise-kerning lookup was -- kept here only so
    /// existing call sites that set it don't fail to compile.
    kerning: ?bool = null,
    kern_in: ?[]u32 = null,
    kern_out: ?[]u32 = null,
    ascent_out: ?*f32 = null,
};

/// textSizeEx always stops at a newline, use textSize to get multiline sizes
///
/// Only valid between `Window.begin`and `Window.end`.
pub fn textSizeEx(self: Font, text: []const u8, opts: TextSizeOptions) Size {
    // textSizeExShaped collapses two different failure modes into a single
    // null (zero-size ask vs. font-cache OOM); check the zero-size case
    // ourselves so it can still return {0,0} while OOM falls back to {10,10}.
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
    // Only the font-cache-lookup failure path remains here.
    if (opts.ascent_out) |ao| ao.* = 10;
    if (opts.end_idx) |endout| endout.* = text.len;
    return .{ .w = 10, .h = 10 };
}

/// A shape (`Cache.Entry.ShapedLine`) kept alive past the `textSizeExShaped`
/// call that produced it, plus enough of that call's context (`fallback`,
/// the logical/device scale `ss`) to reuse it: re-measure a trimmed
/// sub-range (`Cache.Entry.measureGlyphRange`) or hand it straight to
/// `dvui.renderText` (`TextOptions.pre_shaped`) instead of reshaping the
/// same bytes again. Caller owns this and must `.deinit()` it.
pub const ShapedText = struct {
    /// Entry for family index 0 -- used for glyphs outside any segment
    /// (shouldn't happen in practice, see `ShapedLine.entryForGlyph`).
    fallback: *Cache.Entry,
    line: Cache.Entry.ShapedLine,
    ss: f32,
    ascent: f32,

    pub fn deinit(self: *ShapedText) void {
        self.line.deinit();
    }

    /// Logical-pixel size of this shape's glyphs up to (not including) the
    /// glyph whose cluster starts at `byte_offset`, without reshaping --
    /// see `Cache.Entry.measureGlyphRange` / `ShapedLine.glyphLimitForByteOffset`.
    ///
    /// // ponytail: measures every glyph against `fallback`'s scale/metrics
    /// rather than each glyph's own entry (`ShapedLine.entryForGlyph`) --
    /// fine while nothing wires a multi-family Font into `TextLayoutWidget`
    /// (single-family fonts only ever have one entry anyway); revisit if
    /// that changes.
    pub fn measureUpToByte(self: *ShapedText, gpa: std.mem.Allocator, byte_offset: usize) std.mem.Allocator.Error!Size {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const glyph_limit = self.line.glyphLimitForByteOffset(byte_offset);
        const s = try self.fallback.measureGlyphRange(gpa, &self.line, glyph_limit, snap);
        return s.scale(1.0 / self.ss, Size);
    }

    /// Byte offset among the first `glyph_limit` glyphs of this shape
    /// where an x-coordinate `width` (logical pixels) lands, using
    /// `end_metric` break semantics -- see `Cache.Entry.glyphsForWidth`.
    /// Used for width-driven mouse/touch text-selection hit-testing
    /// without reshaping. Same single-entry caveat as `measureUpToByte`.
    pub fn byteForWidth(self: *ShapedText, gpa: std.mem.Allocator, glyph_limit: usize, width: f32, end_metric: Font.EndMetric) std.mem.Allocator.Error!usize {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const glyphs_used = try self.fallback.glyphsForWidth(gpa, &self.line, glyph_limit, width * self.ss, end_metric, snap);
        return self.line.byteOffsetForGlyph(glyphs_used);
    }
};

/// Same as `textSizeEx` but returns the `ShapedText` (shape + font entry)
/// it measured against instead of discarding it. `TextLayoutWidget` uses
/// this to shape a line fragment once per frame and reuse that single
/// shape for line-break trimming, cursor tracking, and the actual glyph
/// render -- each of those was previously a full independent UAX #9
/// bidi + GSUB/GPOS reshape of the same bytes. Returns null in the same
/// degenerate cases `textSizeEx` silently falls back on (zero-size ask,
/// uncached font); caller should fall back to plain `textSizeEx`.
///
/// Only valid between `Window.begin`and `Window.end`.
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
    /// Keyed by `Font.hash()` of the whole stack. Kept separate from
    /// `cache` (which is keyed per single-family sub-`Font`, i.e. per stack
    /// *entry*, see `singleFamily`) so a stack's merged coverage
    /// table is computed once and reused, never invalidated by `reset`
    /// evicting the individual entries it points at by hash (see
    /// `stackEntry`, which just returns null for a hash `reset` dropped).
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

    pub fn findSource(self: *Cache, font: Font) struct { ?Source, ?Source } {
        var second_best: ?usize = null;
        for (self.database.items, 0..) |*source, i| {
            if (std.mem.eql(u8, font.familyName(), source.familyName())) {
                if (font.weight == source.weight and font.style == source.style) {
                    return .{ source.*, null }; // exact match
                }

                if (font.weight == source.weight) {
                    // second best is same family name and same weight
                    second_best = i;
                } else if (second_best == null) {
                    // at least the family name is the same
                    second_best = i;
                }
            }
        }

        if (second_best) |sb| {
            return .{ null, self.database.items[sb] };
        }

        return .{ null, null };
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

    pub const Coverage = struct {
        entry_index: u8,
        range: ot.parsing.Table.cmap.Range,
    };

    pub const ResolvedStack = struct {
        /// `Font.hash()` of each stack entry, in priority order -- entries
        /// themselves live in `Cache.cache` (see `stackEntry`); this only
        /// stores enough to look them back up.
        entry_hashes: [Font.max_families]u64 = @splat(0),
        entry_count: u8 = 0,
        /// Merged, sorted, non-overlapping codepoint coverage across every
        /// entry, earlier entries winning on overlap -- built once by
        /// `resolveStack`, not walked per glyph.
        coverage: []Coverage = &.{},
        /// Codepoint blocks (`cp >> 8`) already warned about via
        /// `entryIndexFor` returning null, so a run of uncovered codepoints
        /// logs once per block instead of once per glyph -- see
        /// `Cache.shapeLineText`.
        logged_missing: std.AutoHashMapUnmanaged(u21, void) = .empty,

        pub fn deinit(self: *ResolvedStack, gpa: std.mem.Allocator) void {
            gpa.free(self.coverage);
            self.logged_missing.deinit(gpa);
        }

        /// Stack index of the highest-priority entry covering `codepoint`,
        /// or null if nothing in the stack does (caller should fall back
        /// to entry 0 and expect `.notdef`).
        pub fn entryIndexFor(self: *const ResolvedStack, codepoint: u21) ?u8 {
            var lo: usize = 0;
            var hi: usize = self.coverage.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const r = self.coverage[mid].range;
                if (codepoint < r.start) {
                    hi = mid;
                } else if (codepoint > r.end) {
                    lo = mid + 1;
                } else {
                    return self.coverage[mid].entry_index;
                }
            }
            return null;
        }
    };

    /// Sweep-line merge of each stack entry's cmap coverage into one sorted
    /// table, earlier entries (lower index) winning any overlap. Breakpoints
    /// are the union of every range's start/end+1 across all entries, so
    /// the interval between consecutive breakpoints has a single winner --
    /// cheap since a font-stack's per-font range count tops out in the low
    /// thousands even for CJK-heavy fonts, and this only runs once per
    /// distinct stack (see `resolveStack`).
    fn buildCoverage(gpa: std.mem.Allocator, per_entry_ranges: []const []const ot.parsing.Table.cmap.Range) std.mem.Allocator.Error![]Coverage {
        var breakpoints: std.ArrayList(u32) = .empty;
        defer breakpoints.deinit(gpa);
        for (per_entry_ranges) |ranges| {
            for (ranges) |r| {
                try breakpoints.append(gpa, r.start);
                try breakpoints.append(gpa, @as(u32, r.end) + 1);
            }
        }
        if (breakpoints.items.len == 0) return &.{};
        std.mem.sort(u32, breakpoints.items, {}, std.sort.asc(u32));

        var uniq: std.ArrayList(u32) = .empty;
        defer uniq.deinit(gpa);
        for (breakpoints.items) |bp| {
            if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1] != bp) try uniq.append(gpa, bp);
        }

        var out: std.ArrayList(Coverage) = .empty;
        errdefer out.deinit(gpa);
        var k: usize = 0;
        while (k + 1 < uniq.items.len) : (k += 1) {
            const lo = uniq.items[k];
            const hi = uniq.items[k + 1]; // exclusive
            const probe: u21 = @intCast(lo);
            const winner: ?u8 = for (per_entry_ranges, 0..) |ranges, idx| {
                if (rangesContain(ranges, probe)) break @intCast(idx);
            } else null;

            if (winner) |w| {
                if (out.items.len > 0 and out.items[out.items.len - 1].entry_index == w and out.items[out.items.len - 1].range.end + 1 == lo) {
                    out.items[out.items.len - 1].range.end = @intCast(hi - 1);
                } else {
                    try out.append(gpa, .{ .entry_index = w, .range = .{ .start = @intCast(lo), .end = @intCast(hi - 1) } });
                }
            }
        }
        return out.toOwnedSlice(gpa);
    }

    fn rangesContain(ranges: []const ot.parsing.Table.cmap.Range, cp: u21) bool {
        var lo: usize = 0;
        var hi: usize = ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (cp < ranges[mid].start) {
                hi = mid;
            } else if (cp > ranges[mid].end) {
                lo = mid + 1;
            } else {
                return true;
            }
        }
        return false;
    }

    /// Loads (or reuses) every family in `font` via `getOrCreate`, then
    /// computes and caches the merged coverage table once per distinct
    /// stack (`Font.hash()`) -- repeat calls with the same stack are a
    /// single hash lookup rather than a re-walk of every entry's cmap.
    pub fn resolveStack(self: *Cache, gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*ResolvedStack {
        const h = font.hash();
        const found = try self.resolved_stacks.getOrPut(gpa, h);
        if (found.found_existing) {
            // `cache` entries are evicted by `reset` independently of the
            // (never-reset) resolved stack, so re-touch each family: marks it
            // used again, recreating it if a prior frame's `reset` dropped it,
            // so the cached coverage never points at a missing entry and
            // `stackEntry` can't return null under the caller (see `reset`).
            for (0..font.family_count) |i| {
                _ = try self.getOrCreate(gpa, font.singleFamily(i));
            }
            return found.value_ptr;
        }

        var entry_hashes: [Font.max_families]u64 = @splat(0);
        var per_entry_ranges: [Font.max_families][]ot.parsing.Table.cmap.Range = undefined;
        var count: u8 = 0;
        errdefer for (per_entry_ranges[0..count]) |r| gpa.free(r);

        for (0..font.family_count) |i| {
            const family_font = font.singleFamily(i);
            const entry = try self.getOrCreate(gpa, family_font);
            entry_hashes[count] = family_font.hash();
            const cmap_data = entry.parsed_font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
            per_entry_ranges[count] = try ot.parsing.Table.cmap.coverageRanges(cmap_data, gpa);
            count += 1;
        }
        defer for (per_entry_ranges[0..count]) |r| gpa.free(r);

        const coverage = try buildCoverage(gpa, per_entry_ranges[0..count]);
        found.value_ptr.* = .{ .entry_hashes = entry_hashes, .entry_count = count, .coverage = coverage };
        return found.value_ptr;
    }

    /// The `Entry` behind stack index `index` of a `ResolvedStack` --
    /// returns null if that entry got evicted from `cache` by `reset`
    /// since the stack was resolved (caller should fall back to index 0).
    pub fn stackEntry(self: *Cache, resolved: *const ResolvedStack, index: u8) ?*Entry {
        if (index >= resolved.entry_count) return null;
        return self.cache.getPtr(resolved.entry_hashes[index]);
    }

    /// Decodes `text` up to the first newline (see `Entry.decodeLine`) and
    /// shapes it against `resolved`: each codepoint is assigned the
    /// highest-priority stack entry that covers it
    /// (`ResolvedStack.entryIndexFor`), maximal same-entry runs are shaped
    /// independently with full bidi resolution
    /// (`ot.shaping.shapeBidiParagraph`), and the resulting buffers are
    /// concatenated in logical (text) order
    /// -- each run already comes back in its own visual order, so no
    /// further reordering is needed across run boundaries (same pattern as
    /// `ot.shaping.shapeWithFallback`'s span stitching).
    ///
    /// A codepoint covered by nothing in the stack falls back to entry 0
    /// (renders `.notdef` there) and gets one deduplicated warning per
    /// codepoint block (`cp >> 8`) rather than one per codepoint.
    pub fn shapeLineText(self: *Cache, gpa: std.mem.Allocator, resolved: *ResolvedStack, text: []const u8) std.mem.Allocator.Error!Entry.ShapedLine {
        const decoded = try Entry.decodeLine(gpa, text);
        errdefer gpa.free(decoded.codepoints);
        errdefer gpa.free(decoded.byte_offsets);

        // Fallback font stack in priority order. An entry may have been
        // evicted from `cache` since resolve (see `stackEntry`); skip it.
        var fonts_buf: [Font.max_families]ot.parsing.Font = undefined;
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

        var result = ot.shaping.Buffer.init(gpa);
        errdefer result.deinit();
        var segments: std.ArrayList(Entry.ShapedLine.EntrySegment) = .empty;
        errdefer segments.deinit(gpa);

        if (decoded.codepoints.len > 0 and nfonts > 0) {
            // Diagnostics only: warn once per uncovered codepoint block.
            // shapeBidiParagraphWithFallback itself falls back silently to
            // font 0 (.notdef) for a codepoint no font in the stack covers.
            for (decoded.codepoints) |cp| _ = self.entryIndexForLogged(resolved, gpa, cp);

            // Bidi/level itemization outer, font fallback inner, so visual
            // reordering crosses font boundaries -- e.g. a Latin word (primary
            // font) embedded in Arabic (fallback font) lands in the right
            // visual place. Per-glyph font_indices index into fonts_buf.
            const shaped = ot.shaping.shapeBidiParagraphWithFallback(gpa, fonts_buf[0..nfonts], decoded.codepoints, .auto, &.{}, &.{}, &.{}) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => ot.shaping.BidiFallbackResult{ .buffer = ot.shaping.Buffer.init(gpa), .font_indices = &.{} },
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

    /// Doesn't scale the font or max_width, always stops at newlines.
    ///
    /// Shapes against the resolved stack (`shapeLineText`), looking up each
    /// glyph's own entry (`ShapedLine.entryForGlyph`) for scale/metrics --
    /// correct even when different runs land in different families.
    ///
    /// `shapeLineText` has no notion of max_width and always shapes up to
    /// the next newline; called with the full remaining text of a long
    /// unbroken paragraph on every wrapped line (the common
    /// `TextLayoutWidget` case, since it doesn't pre-window text), that
    /// would turn each line's measurement into O(remaining paragraph) work
    /// -- O(n^2) for the whole paragraph. Grow the shaped window
    /// geometrically instead of shaping the whole remaining line up front,
    /// so a measurement only costs ~2x the glyphs actually needed to find
    /// the break point.
    ///
    /// Returns the `ShapedLine` measured against instead of discarding it,
    /// so a caller that needs to slice a further byte- or width-limited
    /// sub-range out of the same text (line-break trimming, cursor
    /// tracking, the actual glyph render) can reuse this shape via
    /// `ShapedLine.glyphLimitForByteOffset` + `Entry.measureGlyphRange`
    /// instead of calling `shapeLineText` again from scratch. Caller owns
    /// `.line` and must `.deinit()` it.
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
            var line = try self.shapeLineText(scratch, resolved, text[0..window]);
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
        parsed_font: ot.parsing.Font,
        renderer: ot.render.Renderer,
        /// F26Dot6 units_per_em -> ppem scale factor, same convention as
        /// `ot.render.Renderer.renderBuffer`'s internal `scale` -- glyph
        /// positions/advances from a shaped `Buffer` are in font units and
        /// need this to become device pixels.
        scale: i32,
        height: f32, // ascender - descender, in device pixels
        ascent: f32, // ascender (integer-ish), in device pixels
        em_height: f32, // height of M, in device pixels
        /// Keyed by glyph id (post-shaping `GlyphInfo.codepoint`), not
        /// Unicode codepoint -- shaping breaks the 1:1 codepoint/glyph
        /// assumption the old FreeType/stb-backed cache relied on.
        glyphs: std.AutoHashMapUnmanaged(u32, GlyphInfo) = .empty,
        texture_atlas_cache: ?Texture = null,
        /// Height (px) of the texture actually allocated for
        /// `texture_atlas_cache` -- can exceed `pack_y` (over-allocated on
        /// growth so most new glyphs don't force a resize).
        atlas_alloc_height: u32 = 0,
        /// Shelf-packer state, backend-agnostic (assigned in `glyphInfoGet`
        /// as soon as a glyph is first seen, independent of whether a GPU
        /// texture exists yet -- see `getTextureAtlas` for why placement is
        /// decoupled from upload).
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
            leftBearing: f32, // horizontal distance from pen to glyph pixels left edge
            topBearing: f32, // vertical distance from pen to glyph pixels top edge
            w: f32, // width of bounding box
            h: f32, // height of bounding box
            /// Raw pixel origin (top-left) within the atlas texture, NOT
            /// normalized -- placement is append-only (see `placeGlyph`),
            /// so this never changes after being assigned once. Normalized
            /// to UV space at render time (`render.zig`) by dividing by the
            /// atlas texture's current size.
            origin: @Vector(2, f32),
            /// See `ot.render.PositionedGlyph.is_color` -- true for
            /// COLR/sbix/CBDT glyphs, which must be blitted as-is rather
            /// than tinted by the caller's text color.
            is_color: bool,
            /// Rasterized RGBA bytes (w*h*4), gpa-owned, captured once in
            /// `glyphInfoGet`. `getTextureAtlas` blits from this instead of
            /// re-invoking `renderer.renderGlyph` (real outline decode +
            /// scan conversion, unlike the old FreeType/stb path's cheap
            /// bitmap fetch) whenever the atlas texture needs to grow.
            pixels: []u8,
            /// Whether this glyph's pixels have been uploaded into the
            /// current `texture_atlas_cache` yet. Cleared on every atlas
            /// texture recreation (growth); set once `getTextureAtlas`
            /// uploads it (full rebuild or `textureUpdateSubRect`).
            uploaded: bool,
        };

        pub fn toPixels(self: Entry, font_units: i32) f32 {
            return @as(f32, @floatFromInt(ot.rasterization.ftMulFix(font_units, self.scale))) / 64.0;
        }

        fn measuredCapHeight(renderer: *ot.render.Renderer, gpa: std.mem.Allocator, glyph_id: u16) ?f32 {
            // scratch (outline/mask temp buffers) uses the frame's lifo stack;
            // output must NOT share it -- renderGlyph interleaves an output
            // alloc between two scratch allocs, so freeing scratch top-down
            // while the output alloc still sits above it would violate the
            // lifo's strict push/pop ordering.
            const rendered = renderer.renderGlyph(glyph_id, .{}, dvui.currentWindow().lifo(), gpa) catch return null;
            defer rendered.deinit(gpa);
            if (rendered.bitmap.rows == 0) return null;
            return @floatFromInt(rendered.bitmap.rows);
        }

        /// Load the underlying font, calibrating a continuous (non-integer)
        /// ppem so the rendered capital-M height matches `font.size`
        /// directly -- unlike the old FreeType/stb path, `ot.render.Renderer`
        /// takes a real-valued ppem, so no separate "achieved vs requested
        /// size" rescale is needed anywhere downstream (see textSizeEx).
        pub fn init(gpa: std.mem.Allocator, ttf_bytes: []const u8, font: Font) Error!Entry {
            const min_pixel_size: f32 = 1;

            const fname = font.name(gpa);
            errdefer gpa.free(fname);

            const parsed_font = ot.parsing.Font.parse(gpa, ttf_bytes) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype parse error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            errdefer parsed_font.deinit(gpa);

            const head_data = parsed_font.tableData(.{ 'h', 'e', 'a', 'd' }) orelse return Error.FontError;
            const head = ot.parsing.Table.head.parse(head_data) catch return Error.FontError;
            const units_per_em_f: f32 = @floatFromInt(head.units_per_em);

            // impl's Table.hhea only exposes number_of_h_metrics; read the
            // ascender/descender fields directly rather than growing that
            // table's public surface for this dvui-only need.
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
            const m_glyph_id: u16 = if (cmap_data) |cd| (ot.parsing.Table.cmap.lookup(cd, 'M') orelse 0) else 0;

            var ppem = @max(min_pixel_size, font.size);
            var renderer = ot.render.Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = font.variations[0..font.variation_count] }) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            errdefer renderer.deinit(gpa);

            var em_height = ppem;
            if (m_glyph_id != 0) probe: {
                const probe_h = measuredCapHeight(&renderer, gpa, m_glyph_id) orelse break :probe;
                if (probe_h <= 0) break :probe;
                const ratio = probe_h / ppem;
                const corrected = @max(min_pixel_size, font.size / ratio);
                renderer.deinit(gpa);
                ppem = corrected;
                renderer = ot.render.Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = font.variations[0..font.variation_count] }) catch |err| {
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
                .scale = ot.rasterization.ftDivFix(@as(i32, @intFromFloat(@round(ppem))) * 64, head.units_per_em),
                .ascent = @trunc(raw_ascender * scale_f),
                .height = (raw_ascender - raw_descender) * scale_f,
                .em_height = em_height,
            };

            // Pre-place printable Latin-1 (0x20-0xFF) glyphs before any text
            // is ever drawn -- mirrors main's `glyph_info_ascii`, which
            // rasterized this same range eagerly at load time. Without it,
            // a typical Latin-script page's first frame discovers new
            // glyphs one text run at a time, forcing an atlas
            // grow/rebuild per run instead of (usually) just one overall.
            // Other scripts (CJK, emoji, ...) still fill in lazily via
            // `glyphInfoGet` -- eagerly rasterizing a whole 20k-glyph CJK
            // font here would trade first-paint lag for load-time lag.
            if (cmap_data) |cd| {
                var codepoint: u21 = 0x20;
                while (codepoint <= 0xFF) : (codepoint += 1) {
                    const glyph_id = ot.parsing.Table.cmap.lookup(cd, codepoint) orelse continue;
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

        /// Destroys the current GPU texture (if any) and marks every known
        /// glyph as needing re-upload. Only called when the atlas texture
        /// itself must be recreated (growth) -- glyph *placement* is
        /// separate and never invalidated (see `placeGlyph`).
        fn invalidateTextureAtlas(self: *Entry) void {
            if (self.texture_atlas_cache) |tex| {
                dvui.textureDestroyLater(tex);
            }
            self.texture_atlas_cache = null;
            self.atlas_alloc_height = 0;
            var it = self.glyphs.valueIterator();
            while (it.next()) |gi| gi.uploaded = false;
        }

        /// Assigns `w`x`h` a permanent, never-moving pixel origin in the
        /// atlas via simple shelf packing. Backend-agnostic and safe to call
        /// without a live GPU/Backend (see `glyphInfoGet`) -- growing the
        /// shelf width (rare: a single glyph wider than the current width)
        /// is the only case that repositions already-placed glyphs, since
        /// row-wrap points shift; everything else is append-only.
        fn placeGlyph(self: *Entry, w: u32, h: u32) @Vector(2, f32) {
            if (self.atlas_width == 0) {
                self.atlas_width = @max(initial_atlas_width, w + 2 * pad);
            } else if (w + 2 * pad > self.atlas_width) {
                // Grow geometrically (like atlas_alloc_height below) so a run
                // of glyphs discovered in increasing-width order doesn't
                // trigger a full repack + texture rebuild per glyph.
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

        /// Re-runs the shelf packer over every already-known glyph after
        /// `atlas_width` changes. Rare (only when a single glyph turns out
        /// wider than the current shelf width) -- moves existing origins,
        /// so it also forces a full texture rebuild on the next
        /// `getTextureAtlas` call.
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

        /// Blits `gi`'s cached bitmap into `dst` (row stride `dst_stride`) at
        /// pixel offset `(ox, oy)`. Shared by a full atlas rebuild (`ox`/`oy`
        /// = `gi.origin`) and a single-glyph `textureUpdateSubRect` upload
        /// (`ox`/`oy` = 0, into a tightly-packed `w`x`h` buffer).
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
                        // Coverage-only glyph: broadcast alpha into rgb
                        // ("premultiplied white") so dvui's tint-multiply
                        // draw path colors it correctly; is_color glyphs
                        // above keep their real color untouched.
                        .{ .r = src[3], .g = src[3], .b = src[3], .a = src[3] };
                }
            }
        }

        /// Rebuilds the whole GPU texture from every glyph's cached bitmap
        /// (already positioned by `placeGlyph`/`repackAll`) at `new_height`,
        /// destroying the old texture. Only needed when the atlas must grow
        /// or has never been created -- an already-placed glyph never needs
        /// this, see `getTextureAtlas`.
        fn rebuildAtlasTexture(self: *Entry, gpa: std.mem.Allocator, backend: Backend, new_height: u32) Backend.TextureError!void {
            const pixel_count = @as(usize, self.atlas_width) * new_height;
            const pixels = try gpa.alloc(dvui.Color.PMA, pixel_count);
            defer gpa.free(pixels);
            @memset(pixels, .transparent);

            var it = self.glyphs.valueIterator();
            while (it.next()) |gi| {
                blitGlyph(gi, pixels, self.atlas_width, @intFromFloat(gi.origin[0]), @intFromFloat(gi.origin[1]));
                gi.uploaded = true;
            }

            const new_tex = try backend.textureCreate(@ptrCast(pixels.ptr), .{ .width = self.atlas_width, .height = new_height });
            if (self.texture_atlas_cache) |old| dvui.textureDestroyLater(old);
            self.texture_atlas_cache = new_tex;
            self.atlas_alloc_height = new_height;
        }

        /// This needs to be called before rendering of glyphs as the uv coordinates
        /// of the glyphs will not be correct if the atlas needs to be generated.
        ///
        /// Glyph placement (`glyphInfoGet`/`placeGlyph`) is append-only and
        /// backend-agnostic; this function's only job is making sure every
        /// placed glyph's pixels have actually reached the GPU texture,
        /// doing the cheapest thing that achieves that: a `textureCreate`
        /// only when the texture doesn't exist yet or needs to grow taller,
        /// a `textureUpdateSubRect` per new glyph otherwise.
        pub fn getTextureAtlas(self: *Entry, gpa: std.mem.Allocator, backend: Backend) Backend.TextureError!Texture {
            if (self.glyphs.count() == 0) {
                if (self.texture_atlas_cache) |tex| return tex;
                const blank: [4]u8 = @splat(0);
                self.texture_atlas_cache = try backend.textureCreate(@ptrCast(&blank), .{ .width = 1, .height = 1 });
                return self.texture_atlas_cache.?;
            }

            const needed_height = self.pack_y + self.pack_row_height + pad;
            if (self.texture_atlas_cache == null or needed_height > self.atlas_alloc_height) {
                // Grow geometrically so most new glyphs don't force a resize.
                const new_height = @max(needed_height, self.atlas_alloc_height * 2);
                try self.rebuildAtlasTexture(gpa, backend, new_height);
                return self.texture_atlas_cache.?;
            }

            const tex = self.texture_atlas_cache.?;
            // Backend.textureUpdateSubRect requires `pixels` strided like the
            // full texture (pitch = atlas_width * bpp), same as a full
            // textureUpdate -- not a tightly-packed w x h buffer (see the
            // working reference caller in Examples/applets.zig). One
            // atlas-width-strided scratch buffer is shared across every
            // glyph uploaded this call instead of allocating per glyph.
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
                        // Backend can't do partial uploads -- fall back to a
                        // full rebuild, which uploads everything at once.
                        try self.rebuildAtlasTexture(gpa, backend, self.atlas_alloc_height);
                        return self.texture_atlas_cache.?;
                    },
                    else => |e| return e,
                };
                gi.uploaded = true;
            }
            return tex;
        }

        /// Rasterizes (or fetches the cached metrics for) `glyph_id`, placing
        /// it in the atlas's packing layout immediately. This never touches
        /// the GPU/`Backend` -- placement is pure geometry, so this stays
        /// callable from measurement-only paths (and tests) that don't have
        /// a live `Backend`. `getTextureAtlas` is what actually uploads the
        /// pixels, lazily, the next time text is drawn.
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
                    .pixels = try gpa.dupe(u8, rendered.bitmap.pixels[0..byte_len]),
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
            /// `codepoints.len + 1` entries: byte offset of each codepoint,
            /// plus a trailing entry for the end of the shaped text.
            byte_offsets: []u32,
            buffer: ot.shaping.Buffer,
            /// Distinct `info.cluster` values actually used in `buffer`,
            /// ascending, with `cluster_ends[i]` = byte offset where that
            /// cluster ends (the next used cluster's start, or end of
            /// text). Built once so `clusterByteRange` can look up a
            /// glyph's logical byte range without assuming buffer (visual)
            /// order matches logical order -- needed because a merged
            /// cluster can span codepoints that never appear as any
            /// glyph's `cluster` value.
            cluster_starts: []u32,
            cluster_ends: []u32,
            /// Built by `Cache.shapeLineText`: contiguous glyph-index
            /// ranges of `buffer`, each attributed to the `Entry` that
            /// shaped it, in ascending order (one segment even for a
            /// single-family Font; empty only for empty text). Ranges are in
            /// visual order -- `shapeBidiParagraphWithFallback` does bidi
            /// itemization outside font fallback, so a run's glyphs are
            /// already reordered across font boundaries before segmenting.
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

            /// Entry that shaped glyph `glyph_idx`. `fallback` is returned
            /// for a plain (non-stack) line, where `segments` is empty.
            pub fn entryForGlyph(self: ShapedLine, fallback: *Entry, glyph_idx: usize) *Entry {
                for (self.segments) |seg| {
                    if (glyph_idx >= seg.glyph_start and glyph_idx < seg.glyph_end) return seg.entry;
                }
                return fallback;
            }

            /// Logical byte range `[start, end)` of the cluster that glyph
            /// `buffer.info.items[glyph_idx]` belongs to. Unlike
            /// `byteOffsetForGlyph`/`glyphLimitForByteOffset`, this never
            /// looks at a *different* glyph's position in the buffer, so
            /// it stays correct for glyphs inside an RTL run, where the
            /// next glyph in visual (buffer) order has a *smaller* cluster
            /// than the current one.
            pub fn clusterByteRange(self: ShapedLine, glyph_idx: usize) struct { start: usize, end: usize } {
                return self.buffer.clusterByteRange(self.cluster_starts, self.cluster_ends, self.byte_offsets, glyph_idx);
            }

            /// Byte offset in the original text immediately after the first
            /// `glyph_count` glyphs in shaped (visual) order. Exact for LTR
            /// text; for bidi-reordered runs this walks array order rather
            /// than logical order, so the byte offset it yields mid-RTL-run
            /// is a *visual* prefix, not a logical one. Callers that must be
            /// bidi-correct therefore do not slice a reordered shape through
            /// this: selection highlight uses `clusterByteRange` (order-
            /// independent), and line-wrap trim/measure/render reshape each
            /// final line's own byte-range (see `ShapedLine.isBidi` and
            /// `TextLayoutWidget.addTextEx`). Remaining visual-order caller:
            /// mouse/touch hit-testing inside an RTL run, where the byte this
            /// maps a click to can still be off by a cluster.
            pub fn byteOffsetForGlyph(self: ShapedLine, glyph_count: usize) usize {
                return self.buffer.byteOffsetForGlyph(self.byte_offsets, glyph_count);
            }

            /// Inverse of `byteOffsetForGlyph`: smallest glyph count whose
            /// `byteOffsetForGlyph` result is >= `byte_offset`. Lets a
            /// caller slice an already-shaped line at a byte boundary
            /// found some other way (a UAX #14 break search, a cursor byte
            /// offset) without reshaping. Same visual-vs-logical-order
            /// caveat as `byteOffsetForGlyph`.
            pub fn glyphLimitForByteOffset(self: ShapedLine, byte_offset: usize) usize {
                return self.buffer.glyphLimitForByteOffset(self.byte_offsets, byte_offset);
            }

            /// True if bidi reordering moved glyphs out of logical order --
            /// i.e. the shaped (visual) buffer's clusters are non-monotone.
            /// When this holds, the visual-prefix reuse in
            /// `byteOffsetForGlyph`/`glyphLimitForByteOffset`/`measureUpToByte`
            /// is unsafe (a visual prefix isn't a logical prefix), so callers
            /// must reshape the exact line byte-range instead of slicing this
            /// shape -- see `TextLayoutWidget.addTextEx`.
            pub fn isBidi(self: ShapedLine) bool {
                var prev: u32 = 0;
                for (self.buffer.info.items) |info| {
                    if (info.cluster < prev) return true;
                    prev = info.cluster;
                }
                return false;
            }
        };

        /// Decodes `text` up to (not including) the first newline into
        /// codepoints + their byte offsets (`byte_offsets.len ==
        /// codepoints.len + 1`, the trailing entry being the end of the
        /// decoded range). Used by `Cache.shapeLineText`.
        fn decodeLine(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!struct { codepoints: []u21, byte_offsets: []u32 } {
            var codepoints: std.ArrayList(u21) = .empty;
            errdefer codepoints.deinit(gpa);
            var byte_offsets: std.ArrayList(u32) = .empty;
            errdefer byte_offsets.deinit(gpa);

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

        /// Size (device pixels) of shaped glyphs `line.buffer.info.items[0..glyph_limit]`
        /// -- no reshaping, no width-break search. Used to re-measure an
        /// already-shaped `line` (from `textSizeRawShaped`) after trimming
        /// it to a byte offset found some other way (a UAX #14 break, a
        /// cursor position) via `ShapedLine.glyphLimitForByteOffset`.
        pub fn measureGlyphRange(self: *Entry, gpa: std.mem.Allocator, line: *const ShapedLine, glyph_limit: usize, snap: bool) std.mem.Allocator.Error!Size {
            var x: f32 = 0;
            var minx: f32 = 0;
            var maxx: f32 = 0;
            var miny: f32 = 0;
            var maxy: f32 = self.height;
            const limit = @min(glyph_limit, line.buffer.info.items.len);
            for (line.buffer.info.items[0..limit], line.buffer.pos.items[0..limit]) |info, pos| {
                const gi = try self.glyphInfoGet(gpa, info.codepoint);
                const off_x = self.toPixels(pos.x_offset);
                const adv = self.toPixels(pos.x_advance);
                const adv_used = if (snap) @round(adv) else adv;

                minx = @min(minx, x + off_x + gi.leftBearing);
                maxx = @max(maxx, x + off_x + gi.leftBearing + gi.w);
                maxx = @max(maxx, x + adv_used);

                miny = @min(miny, self.ascent - gi.topBearing);
                maxy = @max(maxy, self.ascent - gi.topBearing + gi.h);

                x += adv_used;
            }
            return .{ .w = maxx - minx, .h = maxy - miny };
        }

        /// Glyph count (via `ShapedLine.byteOffsetForGlyph`) among the
        /// first `glyph_limit` glyphs of `line` where cumulative advance
        /// crosses `mwidth` (device pixels), using the same `.before`/
        /// `.nearest` break semantics as `textSizeRawShaped`. No
        /// reshaping -- used for width-driven hit-testing (mouse/touch
        /// text selection) against an already-shaped line.
        pub fn glyphsForWidth(self: *Entry, gpa: std.mem.Allocator, line: *const ShapedLine, glyph_limit: usize, mwidth: f32, end_metric: Font.EndMetric, snap: bool) std.mem.Allocator.Error!usize {
            var x: f32 = 0;
            var minx: f32 = 0;
            var maxx: f32 = 0;
            var tw: f32 = 0;
            var glyphs_used: usize = 0;
            var nearest_break = false;
            const limit = @min(glyph_limit, line.buffer.info.items.len);

            for (line.buffer.info.items[0..limit], line.buffer.pos.items[0..limit], 0..) |info, pos, gidx| {
                const gi = try self.glyphInfoGet(gpa, info.codepoint);
                const off_x = self.toPixels(pos.x_offset);
                const adv = self.toPixels(pos.x_advance);
                const adv_used = if (snap) @round(adv) else adv;

                minx = @min(minx, x + off_x + gi.leftBearing);
                maxx = @max(maxx, x + off_x + gi.leftBearing + gi.w);
                maxx = @max(maxx, x + adv_used);

                if ((maxx - minx) > mwidth) {
                    switch (end_metric) {
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
                x += adv_used;

                if (nearest_break) break;
            }
            return glyphs_used;
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

    var line = try cw.fonts.shapeLineText(gpa, resolved, "Hello, world! fi ffi");
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

    var line = try cw.fonts.shapeLineText(gpa, resolved, "abc \u{0627}\u{0644}\u{0633}\u{0644}\u{0627}\u{0645} xyz");
    defer line.deinit();
    try std.testing.expect(line.buffer.info.items.len > 0);
    // The Arabic run is RTL, so its glyphs are reordered out of logical
    // order -- `isBidi` must catch this so `TextLayoutWidget` reshapes each
    // wrapped line's own byte-range instead of slicing a visual prefix.
    try std.testing.expect(line.isBidi());

    // Pure-LTR text keeps clusters monotone, so the fast visual-prefix reuse
    // path stays enabled (isBidi false).
    var ltr = try cw.fonts.shapeLineText(gpa, resolved, "Hello, world!");
    defer ltr.deinit();
    try std.testing.expect(!ltr.isBidi());
}

test "Cache.buildCoverage: earlier stack entries win overlapping coverage" {
    const gpa = std.testing.allocator;
    const Range = ot.parsing.Table.cmap.Range;

    // entry 0 (highest priority): covers Latin-1 and a slice of CJK
    const entry0 = [_]Range{ .{ .start = 0x20, .end = 0xFF }, .{ .start = 0x4E00, .end = 0x4E10 } };
    // entry 1: overlaps entry 0's CJK slice, also covers Cyrillic (ranges
    // must stay ascending -- rangesContain binary-searches them, same
    // invariant `coverageRanges` guarantees for a real font's cmap)
    const entry1 = [_]Range{ .{ .start = 0x400, .end = 0x4FF }, .{ .start = 0x4E00, .end = 0x9FFF } };

    const coverage = try Cache.buildCoverage(gpa, &.{ &entry0, &entry1 });
    defer gpa.free(coverage);

    var resolved: Cache.ResolvedStack = .{ .entry_count = 2, .coverage = coverage };

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
    var line = try cw.fonts.shapeLineText(std.testing.allocator, resolved, "AB\u{AC00}\u{AC01}CD");
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
