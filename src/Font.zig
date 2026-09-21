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
const DiscoveryHandle = opentype.DiscoveryHandle;
const DiscoveryProperties = opentype.DiscoveryProperties;
const DiscoveryFamilyName = opentype.DiscoveryFamilyName;
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
const PlanCache = opentype.PlanCache;
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
    const len = @min(s.len, NAME_MAX_LEN); // OS-supplied family names can exceed the key size
    @memcpy(v[0..len], s[0..len]);
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

pub const Source = struct {
    family: [NAME_MAX_LEN:0]u8 = @splat(0),
    size: f32 = 0, // zero means size-agnostic
    weight: Weight = .normal,
    style: Style = .normal,
    stretch: Stretch = .normal,

    bytes: []const u8, // ttf bytes
    /// Set when `bytes` is a mapping of the font file rather than a heap
    /// copy; released by `destroy`, not by `allocator`.
    memory_map: ?std.Io.File.MemoryMap = null,
    /// If not null, this will be used to free ttf_bytes.
    allocator: ?std.mem.Allocator = null,
    /// Face index into `bytes` when it's a .ttc collection (OS font
    /// discovery can match a specific weight/style to a non-zero face);
    /// ignored for a plain sfnt.
    collection_index: u32 = 0,
    /// Axis values the discovered face is a named instance of (e.g. Android's
    /// sans-serif-condensed = Roboto at wdth 75); beat the request's
    /// weight/stretch but lose to `withVariation`.
    pinned_axes: [DiscoveryProperties.max_pinned_axes]UserCoord = undefined,
    pinned_axis_count: u8 = 0,
    /// Family name from the font's `name` table, for display: `family` may be
    /// a synthetic key (e.g. "fb:1a2b3c"). Empty unless set by `Cache.loadDynamicFallback`.
    display_family: [NAME_MAX_LEN:0]u8 = @splat(0),
    /// File `bytes` came from, owned by `allocator`; set only for
    /// OS-discovered fonts. `Cache.reset` may drop such bytes while unused
    /// (leaving `bytes` empty) and `Cache.findSource` reads them back.
    path: ?[]const u8 = null,
    /// Consecutive `Cache.reset`s that found `bytes` unreferenced.
    unreferenced_resets: u16 = 0,

    pub fn familyName(self: *const Source) []const u8 {
        return string(&self.family);
    }

    pub fn pinnedAxes(self: *const Source) []const UserCoord {
        return self.pinned_axes[0..self.pinned_axis_count];
    }

    /// `display_family` if set, else `familyName()` -- use this to show the
    /// user which font a `Source` came from.
    pub fn displayName(self: *const Source) []const u8 {
        const d = string(&self.display_family);
        return if (d.len > 0) d else self.familyName();
    }

    pub fn name(self: *const Source, allocator: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.familyName(), weightLabel(self.weight), styleLabel(self.style) }) catch "";
    }

    /// Font that renders from this source.
    pub fn font(self: *const Source) Font {
        return .{ .family = self.family, .weight = self.weight, .style = self.style, .stretch = self.stretch };
    }

    /// Drops `bytes` alone, leaving the rest of the `Source` usable so
    /// `findSource` can map them back in from `path`.
    pub fn releaseBytes(self: *Source) void {
        if (self.memory_map) |*mm| {
            mm.destroy(dvui.io);
            self.memory_map = null;
        } else if (self.allocator) |alloc| {
            alloc.free(self.bytes);
        }
        self.bytes = &.{};
    }

    pub fn deinit(self: *Source) void {
        defer self.* = undefined;
        self.releaseBytes();
        if (self.allocator) |alloc| {
            if (self.path) |p| alloc.free(p);
        }
    }

    pub const fallback = Source{
        .family = array("Vera"),
        .bytes = @embedFile("fonts/bitstream-vera/Vera.ttf"),
    };
    pub const fallback_serif = Source{
        .family = array("Vera Serif"),
        .bytes = @embedFile("fonts/bitstream-vera/VeraSe.ttf"),
    };
    pub const fallback_monospace = Source{
        .family = array("Vera Sans Mono"),
        .bytes = @embedFile("fonts/bitstream-vera/VeraMono.ttf"),
    };

    /// Embedded last resort for `family`: a generic keeps its style (serif,
    /// monospace) even when no system font resolved it.
    pub fn fallbackFor(family: []const u8) Source {
        return switch (DiscoveryFamilyName.fromString(family)) {
            .serif => fallback_serif,
            .monospace => fallback_monospace,
            .title, .sans_serif, .system_ui => fallback,
        };
    }
};

pub const system_font_backend: ?type = blk: {
    if (@hasDecl(discovery_fontconfig, "Fontconfig")) break :blk discovery_fontconfig.Fontconfig;
    if (@hasDecl(discovery_core_text, "CoreText")) break :blk discovery_core_text.CoreText;
    if (@hasDecl(discovery_directwrite, "DirectWrite")) break :blk discovery_directwrite.DirectWrite;
    if (@hasDecl(discovery_android, "Android")) break :blk discovery_android.Android;
    break :blk null;
};

/// On-demand Noto fonts (`opentype.discovery_web_fallback`) for the web,
/// which has no OS fonts to ask; the backend fetches them via
/// `fetchFallbackFont`. The testing backend compiles it in but never fetches.
pub const web_fallback_enabled = opentype.font_fallback and (dvui.backend.kind == .web or dvui.backend.kind == .testing);
pub const WebFallback = if (web_fallback_enabled) opentype.discovery_web_fallback.Service else void;

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

/// The whole font file, memory-mapped: only the pages actually parsed or
/// rasterized fault in, so a few glyphs out of a 55MB CJK face cost a few
/// pages instead of a full read. Where mapping is unavailable it reads the
/// file instead. `MAP.SHARED`: a file truncated underneath us faults on
/// access rather than returning short data.
pub fn mapFaceFile(path: []const u8) ?std.Io.File.MemoryMap {
    const file = std.Io.Dir.cwd().openFile(dvui.io, path, .{}) catch return null;
    defer file.close(dvui.io);
    const size = (file.stat(dvui.io) catch return null).size;
    return file.createMemoryMap(dvui.io, .{
        .len = std.math.cast(usize, size) orelse return null,
        .protection = .{ .read = true },
        .populate = false,
    }) catch null;
}

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
/// (Linux prefers the Noto families Android ships); `Cache.fallback_language`
/// decides Chinese vs. Japanese vs. Korean Han glyph shapes.
pub const generic_families = DiscoveryFamilyName.generic_keywords;

/// Every installed font family, alphabetically (device-dependent). Empty
/// without a discovery backend (e.g. wasm). Names slice into `name_storage`;
/// both buffers are hard caps, so the list may be truncated.
pub fn systemFamilies(names_buf: [][]const u8, name_storage: []u8, gpa: std.mem.Allocator) []const []const u8 {
    const SysBackend = system_font_backend orelse return names_buf[0..0];

    var backend = SysBackend.init() catch return names_buf[0..0];
    defer backend.deinit();

    const families = backend.availableFamilies(names_buf, name_storage, gpa);

    // A `Font`'s family key is a fixed NAME_MAX_LEN array, so a longer name
    // can't round-trip back into a lookup -- drop it rather than offer it.
    var count: usize = 0;
    for (names_buf[0..families.len]) |family| {
        if (family.len > NAME_MAX_LEN) continue;
        names_buf[count] = family;
        count += 1;
    }

    const sorted = names_buf[0..count];
    std.mem.sortUnstable([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(a, b);
        }
    }.lessThan);
    return sorted;
}

/// Finds `font`'s family via OS font discovery and loads it: the last resort
/// before the embedded Vera font.
pub fn discoverSystemFont(gpa: std.mem.Allocator, font: Font) ?Source {
    const SysBackend = system_font_backend orelse return null;

    var backend = SysBackend.init() catch return null;
    defer backend.deinit();

    var handle_buf: [16]DiscoveryHandle = undefined;
    var properties_buf: [16]DiscoveryProperties = undefined;
    var index_buf: [16]usize = undefined;
    var path_storage: [4096]u8 = undefined;

    const properties: DiscoveryProperties = .{ .weight = font.weight, .style = font.style, .stretch = font.stretch };

    const match = selectBestFontMatch(
        &backend,
        &.{DiscoveryFamilyName.fromString(font.familyName())},
        properties,
        &handle_buf,
        &properties_buf,
        &index_buf,
        .{ &path_storage, gpa },
    ) orelse return null;

    const loaded: struct { bytes: []const u8, collection_index: u32, path: ?[]const u8 = null, map: ?std.Io.File.MemoryMap = null } = switch (match.handle) {
        .path => |p| blk: {
            const path = gpa.dupe(u8, p.path) catch return null;
            const mm = mapFaceFile(p.path) orelse {
                gpa.free(path);
                return null;
            };
            break :blk .{ .bytes = mm.memory, .collection_index = p.font_index, .path = path, .map = mm };
        },
        .memory => |m| .{ .bytes = gpa.dupe(u8, m.bytes) catch return null, .collection_index = m.font_index },
        .url => return null, // web-only handle; native discovery backends never return one
    };

    var source: Source = .{
        .family = array(font.familyName()),
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .bytes = loaded.bytes,
        .memory_map = loaded.map,
        .allocator = gpa,
        .collection_index = loaded.collection_index,
        .path = loaded.path,
    };
    for (match.properties.pinnedAxes(), 0..) |axis, i| source.pinned_axes[i] = .{ .tag = axis.tag, .value = axis.value };
    source.pinned_axis_count = match.properties.pinned_axis_count;
    return source;
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
        var result = cw.fonts.textSizeRawShaped(cw.arena(), cw.gpa, resolved, "M", .{}, .{}) catch return .{ .w = 10, .h = 10 };
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
    var end: usize = 0;
    const ellipsis_w = self.textSizeEx(self.ellipsis(), .{}).w;
    var measure = opts;
    measure.max_width = max_width - ellipsis_w;
    measure.end_idx = &end;
    _ = self.textSizeEx(text, measure);
    var cut: usize = 0;
    while (cut < end) {
        const next = opentype.unicode.nextGraphemeBoundary(text, cut);
        if (next > end) break;
        cut = next;
    }
    // The walk above measures inside the whole line's shape; the prefix is
    // drawn shaped on its own (joining forms at the cut can differ), so
    // confirm against that.
    const prefix_opts: TextSizeOptions = .{ .base_direction = opts.base_direction, .tab_origin = opts.tab_origin };
    while (cut > 0 and self.textSizeEx(text[0..cut], prefix_opts).w + ellipsis_w > max_width) {
        var prev: usize = 0;
        while (true) {
            const next = opentype.unicode.nextGraphemeBoundary(text, prev);
            if (next >= cut) break;
            prev = next;
        }
        cut = prev;
    }
    return cut;
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

    var result = try cw.fonts.textSizeRawShaped(output, state_gpa, resolved, text, options, self.shapeStyle(opts.tab_origin * ss));

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

test "tab stops: a tab reaches the next multiple of tab_size spaces from the line start" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;
    const cw = dvui.currentWindow();
    const font: Font = .find(.{ .family = "Vera", .size = 24 });
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);
    const entry = try cw.fonts.primaryEntry(cw.gpa, resolved);

    var space = try cw.fonts.shapeLineText(gpa, gpa, resolved, " ", null, .auto, .{});
    defer space.deinit();
    const space_glyph = space.line.buffer.info.items[0].codepoint;
    const space_px = entry.toPixels(space.line.buffer.pos.items[0].x_advance);

    const cases = [_]struct { text: []const u8, origin: f32, stop: f32 }{
        .{ .text = "\tb", .origin = 0, .stop = 4 },
        .{ .text = "a\tb", .origin = 0, .stop = 4 },
        .{ .text = "\tb", .origin = 5 * space_px, .stop = 8 },
        // Less than half a space short of a stop skips to the one after.
        .{ .text = "\tb", .origin = 3.8 * space_px, .stop = 8 },
    };
    for (cases) |c| {
        var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, c.text, null, .auto, .{ .tab_size = 4, .tab_origin = c.origin });
        defer line.deinit();
        const tab = std.mem.indexOfScalar(u8, c.text, '\t').?;
        try std.testing.expectEqual(space_glyph, line.line.buffer.info.items[tab].codepoint);
        try std.testing.expectApproxEqAbs(c.stop * space_px - c.origin, line.line.caretPenOffset(line.metrics(entry), c.text.len - 1, false), 1);
    }
}

test "features: liga off splits a ligature, tnum evens out digit advances" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;
    const cw = dvui.currentWindow();
    try dvui.addFont("Aleo VF", @embedFile("fonts/Aleo/Aleo-VariableFont_wght.ttf"), null);
    try dvui.addFont("OpenDyslexic", @embedFile("fonts/OpenDyslexic/compiled/OpenDyslexic-Regular.otf"), null);

    const aleo: Font = .find(.{ .family = "Aleo VF", .size = 24 });
    const aleo_stack = try cw.fonts.resolveStack(cw.gpa, aleo);
    var liga = try cw.fonts.shapeLineText(gpa, gpa, aleo_stack, "office", null, .auto, aleo.shapeStyle(0));
    defer liga.deinit();
    const no_liga_font = aleo.withFeature("liga", false);
    var no_liga = try cw.fonts.shapeLineText(gpa, gpa, aleo_stack, "office", null, .auto, no_liga_font.shapeStyle(0));
    defer no_liga.deinit();
    try std.testing.expectEqual(5, liga.line.buffer.info.items.len);
    try std.testing.expectEqual(6, no_liga.line.buffer.info.items.len);

    const dys: Font = .find(.{ .family = "OpenDyslexic", .size = 24 });
    const dys_stack = try cw.fonts.resolveStack(cw.gpa, dys);
    var proportional = try cw.fonts.shapeLineText(gpa, gpa, dys_stack, "17", null, .auto, dys.shapeStyle(0));
    defer proportional.deinit();
    const tnum_font = dys.withFeature("tnum", true);
    var tabular = try cw.fonts.shapeLineText(gpa, gpa, dys_stack, "17", null, .auto, tnum_font.shapeStyle(0));
    defer tabular.deinit();
    const p = proportional.line.buffer.pos.items;
    const tn = tabular.line.buffer.pos.items;
    try std.testing.expect(p[0].x_advance != p[1].x_advance);
    try std.testing.expectEqual(tn[0].x_advance, tn[1].x_advance);
}

test "ellipsisCut: nothing fits once max_width is under the ellipsis itself" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const fns = struct {
        fn frame() !dvui.App.Result {
            const font = Font.theme(.body);
            const ellipsis_w = font.textSize(font.ellipsis()).w;
            try std.testing.expectEqual(@as(usize, 0), font.ellipsisCut("hello", ellipsis_w / 2, .{}));
            try std.testing.expectEqual(@as(usize, 0), font.ellipsisCut("hello", 0, .{}));
            return .ok;
        }
    };
    try dvui.testing.settle(fns.frame);
}

test "line_height_factor: spaces lines apart above 1.0, shrinks line and ascent below it" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const fns = struct {
        fn frame() !dvui.App.Result {
            const font = Font.theme(.body);
            const one = font.textSize("a").h;
            try std.testing.expectApproxEqAbs(one * 2, font.withLineHeight(1.0).textSize("a\nb").h, 0.01);
            try std.testing.expectApproxEqAbs(one * 3, font.withLineHeight(2.0).textSize("a\nb").h, 0.01);
            try std.testing.expectApproxEqAbs(one, font.withLineHeight(0.5).textSize("a\nb").h, 0.01);
            try std.testing.expectApproxEqAbs(font.textHeight() * 1.5, font.withLineHeight(1.5).lineHeight(), 0.01);

            var ascent: f32 = 0;
            _ = font.textSizeEx("a", .{ .ascent_out = &ascent });
            try std.testing.expect(ascent > 0);
            var tall: f32 = 0;
            _ = font.withLineHeight(2.0).textSizeEx("a", .{ .ascent_out = &tall });
            try std.testing.expectApproxEqAbs(ascent, tall, 0.01);
            var short: f32 = 0;
            _ = font.withLineHeight(0.5).textSizeEx("a", .{ .ascent_out = &short });
            try std.testing.expect(short < ascent);
            return .ok;
        }
    };
    try dvui.testing.settle(fns.frame);
}

test "ellipsisCut: widest grapheme-aligned logical prefix that fits with the ellipsis" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const fns = struct {
        fn frame() !dvui.App.Result {
            const font = Font.theme(.body);
            const texts = [_][]const u8{
                "The quick brown fox jumps over the lazy dog",
                "\u{05e9}\u{05dc}\u{05d5}\u{05dd} \u{05e2}\u{05d5}\u{05dc}\u{05dd} \u{05d6}\u{05d4} \u{05de}\u{05e9}\u{05e4}\u{05d8} \u{05d0}\u{05e8}\u{05d5}\u{05da}",
                "e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}e\u{0301}",
            };
            for (texts) |text| {
                const max_w = font.textSize(text).w / 2;
                const ellipsis_w = font.textSize(font.ellipsis()).w;
                const cut = font.ellipsisCut(text, max_w, .{});
                try std.testing.expect(cut > 0 and cut < text.len);
                var boundary: usize = 0;
                while (boundary < cut) boundary = opentype.unicode.nextGraphemeBoundary(text, boundary);
                try std.testing.expectEqual(cut, boundary);
                try std.testing.expect(font.textSize(text[0..cut]).w + ellipsis_w <= max_w + 0.5);
                const next = opentype.unicode.nextGraphemeBoundary(text, cut);
                try std.testing.expect(font.textSize(text[0..next]).w + ellipsis_w > max_w - 0.5);
            }
            return .ok;
        }
    };
    try dvui.testing.settle(fns.frame);
}

test "smoke: shape + measure + rasterize against embedded Vera.ttf" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 24 });
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);
    const entry = try cw.fonts.primaryEntry(cw.gpa, resolved);

    try std.testing.expect(entry.ascent > 0);
    try std.testing.expect(entry.height > 0);
    try std.testing.expect(entry.em_height > 0);

    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, "Hello, world! fi ffi", null, .auto, .{});
    defer line.deinit();

    try std.testing.expect(line.line.buffer.info.items.len > 0);
    for (line.line.buffer.info.items) |info| {
        try std.testing.expect(info.codepoint != 0);
    }

    var end_idx: usize = 0;
    var result = try cw.fonts.textSizeRawShaped(gpa, gpa, resolved, "Hello, world!", .{ .end_idx = &end_idx }, .{});
    defer result.shaped.deinit();
    try std.testing.expect(result.size.w > 0);
    try std.testing.expect(result.size.h > 0);
    try std.testing.expectEqual(@as(usize, "Hello, world!".len), end_idx);

    const gi = try entry.glyphInfoGet(gpa, line.line.buffer.info.items[0].codepoint);
    try std.testing.expect(gi.w > 0);
    try std.testing.expect(gi.h > 0);
}

test "sizeM: memoized result matches a fresh textSizeRawShaped(\"M\") call" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 24 });
    const cw = dvui.currentWindow();

    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    const resolved = try cw.fonts.resolveStack(cw.gpa, font.withSize(font.size * ss));

    var reference = try cw.fonts.textSizeRawShaped(gpa, gpa, resolved, "M", .{}, .{});
    defer reference.shaped.deinit();

    const expected = reference.size.scale(1.0 / ss, Size);

    const first = font.sizeM(1, 1);
    try std.testing.expectApproxEqAbs(expected.w, first.w, 0.01);
    try std.testing.expectApproxEqAbs(expected.h, first.h, 0.01);
    try std.testing.expect(resolved.m_size != null);

    // Second call hits the memoized ResolvedStack.m_size, not the shaping pipeline.
    const second = font.sizeM(2, 3);
    try std.testing.expectApproxEqAbs(expected.w * 2, second.w, 0.02);
    try std.testing.expectApproxEqAbs(expected.h * 3, second.h, 0.03);
}

test "isMixedDirection: true only for a line that holds both directions" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);

    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, "abc \u{0627}\u{0644}\u{0633}\u{0644}\u{0627}\u{0645} xyz", null, .auto, .{});
    defer line.deinit();
    try std.testing.expect(line.line.buffer.info.items.len > 0);
    // Latin around an Arabic run: the line holds both directions at once, so
    // no byte prefix of it is a contiguous stretch of the line and
    // `TextLayoutWidget` has to reshape each wrapped line's own byte-range.
    try std.testing.expect(line.line.isMixedDirection());

    // One direction, either one, keeps the shape sliceable by byte offset.
    var ltr = try cw.fonts.shapeLineText(gpa, gpa, resolved, "Hello, world!", null, .auto, .{});
    defer ltr.deinit();
    try std.testing.expect(!ltr.line.isMixedDirection());
    try std.testing.expect(!ltr.line.isRtl());

    var rtl = try cw.fonts.shapeLineText(gpa, gpa, resolved, "\u{05e9}\u{05dc}\u{05d5}\u{05dd}", null, .auto, .{});
    defer rtl.deinit();
    try std.testing.expect(!rtl.line.isMixedDirection());
}

test "an RTL run's logical prefix measures monotonically, and width maps back to it" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    // Hebrew: the glyphs come out right to left, so the logical prefix a
    // caret walks over is the *last* stretch of the shape.
    const txt = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    var res = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, txt, .{})).?;
    defer res.shaped.deinit();
    if (res.shaped.line.buffer.info.items[0].codepoint == 0) return error.SkipZigTest;
    try std.testing.expect(res.shaped.line.isRtl());

    var prev: f32 = -1;
    var off: usize = 0;
    while (off <= txt.len) : (off += 2) {
        const w = (try res.shaped.measureUpToByteOffset(gpa, off)).w;
        try std.testing.expect(w > prev);
        prev = w;

        var end: usize = undefined;
        _ = font.textSizeEx(txt, .{ .max_width = w, .end_idx = &end, .end_metric = .nearest });
        try std.testing.expectEqual(off, end);
    }
}

test "a wrapped fragment breaks at the same place however the measurement window is seeded" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    // Long enough that the growing window takes several rounds to reach the
    // break: a mis-seeded window shows up here as a break that fits badly or
    // moves backwards as the allowed width grows.
    const txt = "The quick brown fox jumps over the lazy dog, and then keeps running past the second and third fence before it finally stops.";

    var prev_end: usize = 0;
    var width: f32 = 40;
    while (width <= 400) : (width += 37) {
        var end: usize = undefined;
        const fit = font.textSizeEx(txt, .{ .max_width = width, .end_idx = &end, .end_metric = .before });
        try std.testing.expect(end > 0);
        try std.testing.expect(fit.w <= width);
        try std.testing.expect(end >= prev_end);
        prev_end = end;
    }
}

test "measureLogicalPrefix: glyphs from a fallback font measure with that font's metrics" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });
    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestStack").withSize(24));

    const text = "AB\u{AC00}\u{AC01}CD";
    var whole = try cw.fonts.textSizeRawShaped(std.testing.allocator, std.testing.allocator, resolved, text, .{}, .{});
    defer whole.shaped.deinit();
    const latin_entry = cw.fonts.stackEntry(resolved, 0).?;
    const prefix = try whole.shaped.line.measureLogicalPrefix(std.testing.allocator, whole.shaped.metrics(latin_entry), text.len, true);
    try std.testing.expectApproxEqAbs(whole.size.w, prefix.w, 0.01);
}

test "TextSizeOptions.item: shapes with context but reports only the item" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;
    const font: Font = .find(.{ .family = "Vera", .size = 24 });

    var res = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, "Hello", .{ .item = .{ .start = 1, .end = 3 } })).?;
    defer res.shaped.deinit();

    try std.testing.expectEqual(@as(usize, 2), res.shaped.line.buffer.info.items.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, res.shaped.line.byte_offsets);
    try std.testing.expectEqual(@as(u32, 0), res.shaped.line.buffer.info.items[0].cluster);
    try std.testing.expectEqual(@as(u32, 1), res.shaped.line.buffer.info.items[1].cluster);
    try std.testing.expectEqual(@as(usize, 1), res.shaped.line.glyphLimitForByteOffset(1));
    try std.testing.expectEqual(@as(f32, font.textSizeEx("el", .{}).w), res.size.w);
}

test "TextSizeOptions.item: a joining neighbour changes the glyph chosen" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;
    const font: Font = .find(.{ .family = "Vera", .size = 24 });

    // seen + lam. Shaped alone, seen takes its isolated form; shaped with the
    // lam as (discarded) context it must take its initial form -- a different
    // glyph.
    const word = "\u{0633}\u{0644}";
    var alone = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, word[0..2], .{})).?;
    defer alone.shaped.deinit();
    if (alone.shaped.line.buffer.info.items[0].codepoint == 0) return error.SkipZigTest;

    var joined = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, word, .{ .item = .{ .start = 0, .end = 2 } })).?;
    defer joined.shaped.deinit();
    try std.testing.expectEqual(@as(usize, 1), joined.shaped.line.buffer.info.items.len);
    try std.testing.expect(joined.shaped.line.buffer.info.items[0].codepoint !=
        alone.shaped.line.buffer.info.items[0].codepoint);
}

test "caret pen offsets step one glyph at a time through an RTL run" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    // Four Hebrew letters, two bytes each. Coverage does not matter here:
    // bidi reorders the clusters whether or not the stack has the glyphs.
    const txt = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    var res = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, txt, .{})).?;
    defer res.shaped.deinit();
    try std.testing.expect(res.shaped.line.isRtl());

    const advance = res.shaped.caretOffset(0);
    try std.testing.expect(advance > 0);

    var prev = advance;
    var off: usize = 2;
    while (off <= txt.len) : (off += 2) {
        const x = res.shaped.caretOffset(off);
        try std.testing.expect(x < prev);
        // An RTL prefix grows leftwards, so its next glyph is the run's
        // rightmost not-yet-counted one.
        const g = res.shaped.line.buffer.info.items.len - off / 2;
        const entry = res.shaped.entryForGlyph(g);
        const step = @round(entry.toPixels(res.shaped.line.buffer.pos.items[g].x_advance)) / res.shaped.ss;
        try std.testing.expectApproxEqAbs(step, prev - x, 0.01);
        try std.testing.expectEqual(off, res.shaped.byteAtOffset(x));
        prev = x;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), prev, 0.01);
}

test "caret stops inside a ligature sit at the font's GDEF caret" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    try dvui.addFont("TestAleo", @embedFile("fonts/Aleo/static/Aleo-Regular.ttf"), null);
    const font: Font = .find(.{ .family = "TestAleo", .size = 32 });
    var res = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, "fix", .{})).?;
    defer res.shaped.deinit();
    // "fi" ligates into one glyph, "x" stays its own.
    try std.testing.expectEqual(@as(usize, 2), res.shaped.line.buffer.info.items.len);

    const x0 = res.shaped.caretOffset(0);
    const x1 = res.shaped.caretOffset(1);
    const x2 = res.shaped.caretOffset(2);
    try std.testing.expect(x0 < x1 and x1 < x2);
    // Aleo's LigCaretList puts the fi caret at 300 of the glyph's 601 units.
    try std.testing.expectApproxEqAbs((x2 - x0) * 300.0 / 601.0, x1 - x0, 0.01);
    try std.testing.expectEqual(@as(usize, 1), res.shaped.byteAtOffset(x1));
    try std.testing.expectEqual(@as(usize, 1), res.shaped.byteAtOffset(x1 + 1));
}
