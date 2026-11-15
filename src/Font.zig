const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui.zig");
const opentype = @import("opentype");

const Rect = dvui.Rect;
const Size = dvui.Size;
const Texture = dvui.Texture;
const Backend = dvui.Backend;

const UserCoord = opentype.UserCoord;
const Buffer = opentype.Buffer;
const BidiFallbackResult = opentype.BidiFallbackResult;
const DiscoveryFamilyName = opentype.DiscoveryFamilyName;
const OtFont = opentype.Font;
const PositionedGlyph = opentype.PositionedGlyph;
const Renderer = opentype.Renderer;
const Cmap = opentype.Cmap;
const shaping = opentype.shaping;
const shapeBidiParagraphWithFallback = opentype.shapeBidiParagraphWithFallback;
const PlanCache = opentype.PlanCache;
pub const HardBreak = opentype.HardBreak;
pub const firstHardBreak = opentype.firstHardBreak;
pub const trailingHardBreakLen = opentype.trailingHardBreakLen;

/// Font parameters for text rendering; falls back to embedded Vera if no match found.
const Font = @This();

pub const DefaultSize = 10;

pub const Error = error{FontError};
pub const NAME_MAX_LEN = opentype.discovery.FontSet.name_max_len;

pub const array = opentype.discovery.FontSet.name;
pub const string = opentype.discovery.FontSet.nameSlice;

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

pub const max_variations = 4;

/// One slot of a family alias: a family name plus optional size/weight tweaks.
pub const FamilyEntry = struct {
    family: [NAME_MAX_LEN:0]u8 = @splat(0),
    size_scale: f32 = 1,
    weight: ?Weight = null,
    style: ?Style = null,
    stretch: ?Stretch = null,

    pub fn apply(self: FamilyEntry, font: Font) Font {
        var r = font.withFamily(string(&self.family));
        r.size *= self.size_scale;
        if (self.weight) |w| r.weight = w;
        if (self.style) |st| r.style = st;
        if (self.stretch) |sr| r.stretch = sr;
        return r;
    }
};

/// A single family name, or an alias registered with `dvui.addFontFamily`
/// (an ordered fallback list, CSS font-family model).
family: [NAME_MAX_LEN:0]u8 = @splat(0),

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
/// Part of `CacheKey` like weight/style.
variations: [max_variations]UserCoord = @splat(.{ .tag = @splat(0), .value = 0 }),
variation_count: u8 = 0,

/// CSS `font-feature-settings` (`withFeature`). Shaping only, so not in
/// `CacheKey`: toggling a feature reuses the same glyph atlas.
features: [max_features]Feature = @splat(.{ .tag = @splat(0), .value = 0 }),
feature_count: u8 = 0,

/// CSS `tab-size`: a tab advances to the next multiple of this many space
/// advances from the line start. Shaping only, like `features`.
tab_size: u8 = 8,

pub const Feature = opentype.Feature;
pub const max_features = 8;

/// What a `Font` adds to shaping beyond the glyphs its `hash` names.
pub const ShapeStyle = struct {
    features: []const Feature = &.{},
    tab_size: u8 = 8,
    /// Device-pixel pen x the text starts at on its line, so tab stops
    /// count from the line start rather than from the text.
    tab_origin: f32 = 0,
};

pub fn shapeStyle(self: *const Font, tab_origin: f32) ShapeStyle {
    return .{ .features = self.features[0..self.feature_count], .tab_size = self.tab_size, .tab_origin = tab_origin };
}

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
    return Font.init(opts.family).withSize(opts.size).withWeight(opts.weight).withStyle(opts.style).withStretch(opts.stretch).withLineHeight(opts.line_height_factor);
}

/// Builds Font for a family name or family alias; chainable with
/// withSize/withWeight/etc.
pub fn init(family: []const u8) Font {
    return .{ .family = array(family) };
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

pub fn withFamily(self: Font, n: []const u8) Font {
    var r: Font = self;
    r.family = array(n);
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

/// Turns an OpenType feature on or off (e.g. `withFeature("tnum", true)`,
/// `withFeature("liga", false)`), replacing any earlier setting for the
/// same tag. Silently ignored past `max_features` distinct tags.
pub fn withFeature(self: Font, tag: *const [4]u8, on: bool) Font {
    var r = self;
    const value: u32 = @intFromBool(on);
    for (r.features[0..r.feature_count]) |*f| {
        if (std.mem.eql(u8, &f.tag, tag)) {
            f.value = value;
            return r;
        }
    }
    if (r.feature_count >= max_features) return r;
    r.features[r.feature_count] = .{ .tag = tag.*, .value = value };
    r.feature_count += 1;
    return r;
}

pub fn withTabSize(self: Font, spaces: u8) Font {
    var r = self;
    r.tab_size = spaces;
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

pub fn familyName(self: *const Font) []const u8 {
    return string(&self.family);
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

/// Name of underlying Font.Entry.  Might be synthesized or fallback (in that
/// case findSource returns null).
///
/// Slice is invalidated if that entry is removed.
///
/// Only valid between Window.begin/end
pub fn nameEntry(self: *const Font) []const u8 {
    const entry = dvui.fontCacheGet(self.*) catch return "nameEntry: Error";
    return entry.name;
}

pub fn format(self: *const Font, writer: *std.Io.Writer) !void {
    try writer.print("{s}{s}{s} {d}", .{ self.familyName(), weightLabel(self.weight), styleLabel(self.style), self.size });
}

/// Fonts with equal keys use the same glyphs (same Font.Entry). Raw bytes,
/// not a hash, so crafted family names can't collide two fonts onto one entry.
pub const CacheKey = struct {
    bytes: [NAME_MAX_LEN + 3 * 4 + 1 + 1 + max_variations * 8]u8,

    // Picked up by TrackingAutoHashMap in place of AutoContext, whose
    // std.meta.eql compares these bytes one at a time.
    pub const Context = struct {
        pub fn hash(_: Context, key: CacheKey) u64 {
            return std.hash.Wyhash.hash(0, &key.bytes);
        }

        pub fn eql(_: Context, a: CacheKey, b: CacheKey) bool {
            return std.mem.eql(u8, &a.bytes, &b.bytes);
        }
    };
};

pub fn cacheKey(self: *const Font) CacheKey {
    var k: CacheKey = .{ .bytes = @splat(0) };
    @memcpy(k.bytes[0..NAME_MAX_LEN], self.family[0..NAME_MAX_LEN]);
    var i: usize = NAME_MAX_LEN;
    for ([_]f32{ self.size, self.weight.value, self.stretch.value }) |f| {
        std.mem.writeInt(u32, k.bytes[i..][0..4], @bitCast(f), .little);
        i += 4;
    }
    k.bytes[i] = @intFromEnum(self.style);
    k.bytes[i + 1] = self.variation_count;
    i += 2;
    for (self.variations[0..self.variation_count]) |v| {
        @memcpy(k.bytes[i..][0..4], &v.tag);
        std.mem.writeInt(u32, k.bytes[i + 4 ..][0..4], @bitCast(v.value), .little);
        i += 8;
    }
    return k;
}

/// Only valid between Window.begin/end
pub fn findSource(self: *const Font) ?Source {
    const cw = dvui.currentWindow();
    return cw.fonts.findSource(self.*).@"0";
}

/// A face the font database holds: bytes plus the family and properties it
/// is registered under.
pub const Source = opentype.discovery.FontSet.Face;

/// Font that renders from `source`.
pub fn ofSource(source: *const Source) Font {
    return .{ .family = source.family, .weight = source.weight, .style = source.style, .stretch = source.stretch };
}

/// Embedded Bitstream Vera faces, the last resort when nothing resolves a family.
pub const Embedded = struct {
    pub const sans = Source{
        .family = array("Vera"),
        .bytes = @embedFile("fonts/bitstream-vera/Vera.ttf"),
    };
    pub const serif = Source{
        .family = array("Vera Serif"),
        .bytes = @embedFile("fonts/bitstream-vera/VeraSe.ttf"),
    };
    pub const monospace = Source{
        .family = array("Vera Sans Mono"),
        .bytes = @embedFile("fonts/bitstream-vera/VeraMono.ttf"),
    };

    /// A generic keeps its style (serif, monospace) even when no system
    /// font resolved it.
    pub fn forFamily(family: []const u8) Source {
        return switch (DiscoveryFamilyName.fromString(family)) {
            .serif => serif,
            .monospace => monospace,
            .title, .sans_serif, .system_ui => sans,
        };
    }
};

/// On-demand Noto fonts (`opentype.discovery_web_fallback`) for the web,
/// which has no OS fonts to ask; the backend fetches them via
/// `fetchFallbackFont`. The testing backend compiles it in but never fetches.
pub const web_fallback_enabled = opentype.font_fallback and (dvui.backend.kind == .web or dvui.backend.kind == .testing);

/// `Window.InitOptions.web_font_fallback`; read by the web backend only. To
/// switch at runtime: `dvui.currentWindow().fonts.setWebFallback(gpa, .{ .enabled = false })`.
pub const WebFallbackOptions = struct {
    /// false: nothing is fetched; scripts the app's own fonts lack render as tofu.
    enabled: bool = true,
    /// Fonts are fetched from `base_url` + each font's relative path (a
    /// trailing '/' is optional); not copied. The default is Google's font
    /// CDN, as in Flutter web: every visitor's browser then contacts Google
    /// servers, disclosing their IP address (GDPR-relevant). To self-host,
    /// mirror the set with `scripts/mirror_web_fallback.py <dir>` and point
    /// this at wherever that directory is served (cross-origin needs CORS).
    base_url: []const u8 = if (web_fallback_enabled) opentype.discovery_web_fallback.default_base_url else "",
};

/// The CSS generic family keywords "serif", "sans-serif", "monospace" and
/// "system-ui", usable as a `Font` family anywhere a real family name is. The
/// first three resolve to the first installed font of a metric-compatible
/// chain (`opentype.discovery.generic_family_chains`), so text measures and
/// breaks lines the same on every OS; "system-ui" is the OS's own UI font:
///
/// | generic    | macOS                 | Windows         | Linux              | Android         |
/// |------------|-----------------------|-----------------|--------------------|-----------------|
/// | sans-serif | Arial                 | Arial           | Liberation Sans    | Roboto          |
/// | serif      | Times New Roman       | Times New Roman | Liberation Serif   | Noto Serif      |
/// | monospace  | Menlo (iOS: Courier New) | Consolas     | DejaVu Sans Mono   | Droid Sans Mono |
/// | system-ui  | SF Pro                | Segoe UI        | fontconfig's alias | Roboto          |
///
/// On Linux a missing chain font falls to fontconfig's own alias (Fedora
/// ships no DejaVu, so monospace there is Noto Sans Mono); with no system
/// font at all, the embedded Vera Sans / Vera Serif / Vera Sans Mono stand
/// in. Characters the font lacks fall back per codepoint to the OS's pick
/// (Linux prefers the Noto families Android ships); `Cache.database.fallback_language`
/// decides Chinese vs. Japanese vs. Korean Han glyph shapes.
pub const generic_families = DiscoveryFamilyName.generic_keywords;

/// Every installed font family, alphabetically (device-dependent). Empty
/// without a discovery backend (e.g. wasm). Names slice into `name_storage`;
/// both buffers are hard caps, so the list may be truncated.
pub fn systemFamilies(names_buf: [][]const u8, name_storage: []u8, gpa: std.mem.Allocator) []const []const u8 {
    // A `Font`'s family key is a fixed NAME_MAX_LEN array, so a longer name
    // can't round-trip back into a lookup.
    return opentype.discovery.system.availableFamilies(names_buf, name_storage, gpa, NAME_MAX_LEN);
}

pub fn textHeight(self: Font) f32 {
    return self.sizeM(1, 1).h;
}

pub fn lineHeight(self: Font) f32 {
    return self.textHeight() * self.line_height_factor;
}

pub fn sizeM(self: Font, wide: f32, tall: f32) Size {
    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    const ask_size = self.size * ss;
    if (ask_size == 0.0) return .{};

    const cw = dvui.currentWindow();
    const sized_font = self.withSize(ask_size);
    const resolved = cw.fonts.resolveStack(cw.gpa, sized_font) catch return .{ .w = 10, .h = 10 };

    if (resolved.m_size == null) {
        var result = cw.fonts.textSizeRawShaped(cw.arena(), cw.lifo(), cw.gpa, resolved, "M", .{}, .{}) catch return .{ .w = 10, .h = 10 };
        result.shaped.deinit();
        resolved.m_size = result.size;
    }

    const msize = resolved.m_size.?.scale(1.0 / ss, Size);
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

/// `text-overflow: ellipsis` marker: U+2026 when the stack covers it, else "...".
pub fn ellipsis(self: Font) []const u8 {
    const cw = dvui.currentWindow();
    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    const resolved = cw.fonts.resolveStack(cw.gpa, self.withSize(self.size * ss)) catch return "...";
    return if (resolved.entryIndexFor(0x2026) != null) "\u{2026}" else "...";
}

/// Byte length of the prefix of `text`'s first line that still fits
/// `max_width` with `ellipsis()` after it. A logical prefix, so an RTL line
/// loses its left end, and cut on a grapheme boundary.
pub fn ellipsisCut(self: Font, text: []const u8, max_width: f32, opts: TextSizeOptions) usize {
    const measure = struct {
        font: Font,
        opts: TextSizeOptions,

        pub fn fit(m: @This(), line: []const u8, limit: f32) usize {
            var end: usize = 0;
            var o = m.opts;
            o.max_width = limit;
            o.end_idx = &end;
            _ = m.font.textSizeEx(line, o);
            return end;
        }

        pub fn width(m: @This(), prefix: []const u8) f32 {
            return m.font.textSizeEx(prefix, .{ .base_direction = m.opts.base_direction, .tab_origin = m.opts.tab_origin }).w;
        }
    }{ .font = self, .opts = opts };
    return opentype.line.ellipsisCut(text, max_width, self.textSizeEx(self.ellipsis(), .{}).w, measure);
}

pub const EndMetric = opentype.EndMetric;

/// Byte range of `text` to produce glyphs for. Bytes outside it are shaping
/// context only (Arabic joining, ligatures, kerning); the result reads like a
/// shape of `text[start..end]` alone.
pub const ShapeItem = struct { start: usize, end: usize };

pub const TextSizeOptions = struct {
    max_width: ?f32 = null,
    end_idx: ?*usize = null,
    end_metric: EndMetric = .before,
    ascent_out: ?*f32 = null,
    /// When set, `text` is context and only this range is measured/shaped.
    /// Excludes `max_width`.
    item: ?ShapeItem = null,
    /// Paragraph base direction (UAX #9 P2/P3). `.auto` is first-strong, so a
    /// caller that knows the paragraph direction should pass it.
    base_direction: opentype.unicode.Bidi.ParagraphDirection = .auto,
    /// Where on its line `text` starts (logical pixels); tab stops count
    /// from the line start.
    tab_origin: f32 = 0,
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
    var result = self.textSizeExShaped(cw.gpa, cw.arena(), text, opts) catch return .{ .w = 10, .h = 10 };
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
    line: Cache.ShapedLine,
    /// `entries[segment.font_index]` shaped that glyph range; allocated
    /// from the same allocator as `line`.
    entries: []*Cache.Entry,
    ss: f32,
    ascent: f32,

    pub fn deinit(self: *ShapedText) void {
        var shaped: Cache.ShapedText = .{ .line = self.line, .entries = self.entries };
        shaped.deinit();
    }

    /// Entry that shaped the glyph at `glyph_idx`.
    pub fn entryForGlyph(self: *const ShapedText, glyph_idx: usize) *Cache.Entry {
        const font_index = self.line.fontIndexForGlyph(glyph_idx);
        if (font_index >= self.entries.len) return self.fallback;
        return self.entries[font_index];
    }

    /// Glyph metrics by font index, which is how `opentype` asks for them.
    fn metrics(self: *const ShapedText) Cache.ShapedText.Metrics {
        return .{ .entries = self.entries, .fallback = self.fallback };
    }

    pub fn measureUpToByteOffset(self: *ShapedText, state_gpa: std.mem.Allocator, byte_offset: usize) std.mem.Allocator.Error!Size {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const s = try self.line.measureLogicalPrefix(state_gpa, self.metrics(), byte_offset, snap);
        return (Size{ .w = s.w, .h = s.h }).scale(1.0 / self.ss, Size);
    }

    /// Inverse of `measureUpToByteOffset`: which byte a caret dragged `width`
    /// along the run's logical direction lands on.
    pub fn byteOffsetForWidth(self: *ShapedText, state_gpa: std.mem.Allocator, width: f32, end_metric: Font.EndMetric) std.mem.Allocator.Error!usize {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const fit = try self.line.logicalPrefixForWidth(state_gpa, self.metrics(), width * self.ss, end_metric, snap);
        return fit.byte;
    }

    /// Where a caret after `byte_offset` logical bytes sits, measured from
    /// the run's left edge. Not `measureUpToByteOffset`: that is an ink
    /// width, and ink is not where the pen is.
    pub fn caretOffset(self: *ShapedText, byte_offset: usize) f32 {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        return self.line.caretPenOffset(self.metrics(), byte_offset, snap) / self.ss;
    }

    /// Inverse of `caretOffset`.
    pub fn byteAtOffset(self: *ShapedText, x: f32) usize {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        return self.line.byteAtPenOffset(self.metrics(), x * self.ss, snap);
    }
};

pub fn textSizeExShaped(self: Font, state_gpa: std.mem.Allocator, output: std.mem.Allocator, text: []const u8, opts: TextSizeOptions) std.mem.Allocator.Error!?struct { size: Size, shaped: ShapedText } {
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
    const resolved = cw.fonts.resolveStack(state_gpa, sized_font) catch return null;

    var options = opts;
    if (opts.max_width) |mwidth| {
        options.max_width = mwidth * ss;
    }

    var result = try cw.fonts.textSizeRawShaped(output, cw.lifo(), state_gpa, resolved, text, options, self.shapeStyle(opts.tab_origin * ss));

    const fallback_entry = cw.fonts.primaryEntry(state_gpa, resolved) catch {
        result.shaped.deinit();
        return null;
    };

    var ascent = fallback_entry.ascent;
    if (self.line_height_factor < 1.0) {
        ascent = @round(ascent * self.line_height_factor);
    }
    if (opts.ascent_out) |ao| ao.* = ascent / ss;

    return .{
        .size = result.size.scale(1.0 / ss, Size),
        .shaped = .{ .fallback = fallback_entry, .line = result.shaped.line, .entries = result.shaped.entries, .ss = ss, .ascent = ascent },
    };
}

pub const Cache = @import("FontCache.zig");

test {
    @import("std").testing.refAllDecls(@This());
}

test "DOCIMG synthetic bold from a family with only a regular face" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 680, .h = 150 } });
    defer t.deinit();

    const T = struct {
        const family = "SyntheticBoldTest";
        const regular_font: Font = .{ .family = array("Vera Sans"), .size = 20 };
        const synthetic_font: Font = .{ .family = array(family), .size = 20, .weight = .bold };
        const raster = "opentype";
        var regular: Size = .{};
        var synthetic: Size = .{};

        fn frame() !dvui.App.Result {
            if (synthetic_font.withWeight(.normal).findSource() == null) try dvui.addFont(family, @embedFile("fonts/bitstream-vera/Vera.ttf"), null);
            regular = regular_font.textSize("Bold");
            synthetic = synthetic_font.textSize("Bold");

            var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
            defer box.deinit();
            dvui.label(@src(), "Hello World: Regular ({s})", .{raster}, .{ .font = regular_font });
            dvui.label(@src(), "Hello World: Bold fontface ({s})", .{raster}, .{ .font = regular_font.withWeight(.bold) });
            dvui.label(@src(), "Hello World: Bold synthetic ({s})", .{raster}, .{ .font = synthetic_font });
            return .ok;
        }
    };

    try dvui.testing.settle(T.frame);
    try t.saveImage(T.frame, null, "Font-synthetic-bold.png");

    // synthetic bold should be wider but not taller
    try std.testing.expect(T.synthetic.w > T.regular.w);
    try std.testing.expectEqual(T.regular.h, T.synthetic.h);
}
