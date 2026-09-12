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
const discovery_manifest = opentype.discovery_manifest;
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

/// One slot of a family alias: a family name plus optional per-family
/// tweaks, for stacks whose fonts don't agree on size or weight (a CJK
/// fallback that runs visually large next to the Latin primary, say).
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
/// standing for an ordered list of families (CSS font-family model). Name
/// every script you need in that list (e.g. a Latin font, an Arabic font, a
/// CJK font) rather than relying on dynamic OS fallback, which is unreliable
/// on Android/Windows and varies by what's installed elsewhere.
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

/// Fonts that hash the same value use the same glyphs (same Font.Entry).
pub fn hash(self: *const Font) u64 {
    var h = dvui.fnv.init();
    h.update(&self.family);
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
    /// Face index into `bytes` when it's a .ttc collection (OS font
    /// discovery can match a specific weight/style to a non-zero face);
    /// ignored for a plain sfnt.
    collection_index: u32 = 0,
    /// Human-readable family name from the font's own `name` table, for UI
    /// display only -- `family` itself is a synthetic key (e.g. "fb:1a2b3c")
    /// for dynamic-fallback sources, so it isn't fit to print. Empty unless
    /// set by `Cache.loadDynamicFallback`.
    display_family: [NAME_MAX_LEN:0]u8 = @splat(0),

    pub fn familyName(self: *const Source) []const u8 {
        return string(&self.family);
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

const system_font_size_limit = 256 * 1024 * 1024; // needed for big emoji fonts (Apple Color Emoji.ttc is ~180MB)

/// The CSS Fonts Level 3 generic family keywords ("serif", "monospace",
/// ...), usable as a `Font` family anywhere a real family name is -- the
/// OS backend resolves each to whatever it means on this machine.
pub const generic_families = DiscoveryFamilyName.generic_keywords;

/// Every font family installed on this machine, alphabetically, as reported
/// by the OS discovery backend -- so it's device-dependent by nature (a
/// different list on macOS vs. an Android phone), unlike `generic_families`.
/// Empty when there's no backend compiled in (e.g. wasm).
///
/// Names are slices into caller-owned `name_storage`, and both buffers are
/// hard caps: a machine with more families installed than fit yields a
/// truncated list. `gpa` is only borrowed for the duration of the call.
pub fn systemFamilies(names_buf: [][]const u8, name_storage: []u8, gpa: std.mem.Allocator) []const []const u8 {
    const SysBackend = system_font_backend orelse return names_buf[0..0];

    var backend = SysBackend.init() catch return names_buf[0..0];
    defer backend.deinit();

    const needs_allocator = @typeInfo(@TypeOf(SysBackend.availableFamilies)).@"fn".params.len == 4;
    const args = .{ &backend, names_buf, name_storage };
    const families = @call(.auto, SysBackend.availableFamilies, if (needs_allocator) args ++ .{gpa} else args);

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
        &.{DiscoveryFamilyName.fromString(font.familyName())},
        properties,
        &handle_buf,
        &properties_buf,
        &index_buf,
        scratch,
    ) orelse return null;

    const loaded: struct { bytes: []const u8, collection_index: u32 } = switch (handle) {
        .path => |p| .{ .bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, p.path, gpa, .limited(system_font_size_limit)) catch return null, .collection_index = p.font_index },
        .memory => |m| .{ .bytes = gpa.dupe(u8, m.bytes) catch return null, .collection_index = m.font_index },
        .url => return null, // web-only handle; native discovery backends never return one
    };

    return .{
        .family = array(font.familyName()),
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .bytes = loaded.bytes,
        .allocator = gpa,
        .collection_index = loaded.collection_index,
    };
}

/// Resolves `family` against a manifest (family name -> variants -> font
/// URL JSON, e.g. what a Google Fonts-style `css2` API returns) using
/// `opentype.discovery_manifest`, fetches the matched URL over HTTP, and
/// returns it as a `Source`. Unlike `discoverSystemFont`, there's no OS font
/// source to consult here -- the manifest and the URLs it points to are
/// whatever the app supplies, which is why this isn't wired into
/// `Cache.resolveSource`'s automatic fallback chain; call it explicitly for
/// fonts you want served from a remote source instead of/in addition to the
/// OS. Not available on wasm (no synchronous network I/O in a WASM host);
/// returns null there the same as any other unresolved font.
pub fn resolveManifestFont(gpa: std.mem.Allocator, manifest_json: []const u8, font: Font) ?Source {
    if (comptime !@hasDecl(discovery_manifest, "ManifestSource")) return null;

    var source: discovery_manifest.ManifestSource = .init(manifest_json);

    var handle_buf: [16]DiscoveryHandle = undefined;
    var properties_buf: [16]DiscoveryProperties = undefined;
    var index_buf: [16]usize = undefined;
    var url_storage: [4096]u8 = undefined;

    const properties: DiscoveryProperties = .{ .weight = font.weight, .style = font.style, .stretch = font.stretch };

    const handle = selectBestFontMatch(
        &source,
        &.{.{ .title = font.familyName() }},
        properties,
        &handle_buf,
        &properties_buf,
        &index_buf,
        .{ &url_storage, gpa },
    ) orelse return null;

    const url = switch (handle) {
        .url => |u| u.url,
        .path, .memory => return null, // manifest backend only ever returns .url
    };

    const bytes = fetchUrl(gpa, url) orelse return null;

    return .{
        .family = array(font.familyName()),
        .weight = font.weight,
        .style = font.style,
        .stretch = font.stretch,
        .bytes = bytes,
        .allocator = gpa,
    };
}

/// Blocking HTTP GET (bounded by `fetch_timeout`), used only by
/// `resolveManifestFont`. Not available on wasm -- a WASM host has no
/// synchronous network I/O, so fetching a manifest-resolved URL there needs
/// the JS host's async `fetch()` plus a per-frame poll (the same pattern
/// `openFilePicker` uses for the async file picker), which isn't implemented
/// yet.
const fetch_timeout = std.Io.Duration.fromSeconds(10);

fn fetchUrl(gpa: std.mem.Allocator, url: []const u8) ?[]const u8 {
    if (comptime builtin.cpu.arch.isWasm()) return null;

    const io = dvui.io;
    const Result = union(enum) { fetched: ?[]const u8, timed_out: void };

    const run = struct {
        fn fetch(a: std.mem.Allocator, u: []const u8) ?[]const u8 {
            var client: std.http.Client = .{ .allocator = a, .io = dvui.io };
            defer client.deinit();

            var response: std.Io.Writer.Allocating = .init(a);
            defer response.deinit();

            const result = client.fetch(.{
                .location = .{ .url = u },
                .response_writer = &response.writer,
            }) catch return null;
            if (result.status != .ok) return null;

            return response.toOwnedSlice() catch null;
        }
        fn sleep(io_: std.Io) void {
            io_.sleep(fetch_timeout, .awake) catch {};
        }
    };

    var buf: [2]Result = undefined;
    var sel: std.Io.Select(Result) = .init(io, &buf);
    sel.async(.fetched, run.fetch, .{ gpa, url });
    sel.async(.timed_out, run.sleep, .{io});

    const first = sel.await() catch Result{ .timed_out = {} };

    // Drain and free whatever the loser produced -- if the fetch lost the
    // race, it may still complete (and allocate) after we've decided to
    // return the timeout result.
    while (sel.cancel()) |leftover| {
        if (leftover == .fetched) if (leftover.fetched) |bytes| gpa.free(bytes);
    }

    return switch (first) {
        .fetched => |bytes| bytes,
        .timed_out => null,
    };
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
        var result = cw.fonts.textSizeRawShaped(cw.arena(), cw.gpa, resolved, "M", .{}) catch return .{ .w = 10, .h = 10 };
        result.line.deinit();
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

pub const EndMetric = opentype.EndMetric;

/// Byte range of the text to actually produce glyphs for. Bytes outside it
/// still shape -- they are the context Arabic joining, ligatures and kerning
/// resolve against -- but their glyphs are dropped, and the result is rebased
/// so it reads exactly like a shape of `text[start..end]` on its own.
pub const ShapeItem = struct { start: usize, end: usize };

pub const TextSizeOptions = struct {
    max_width: ?f32 = null,
    end_idx: ?*usize = null,
    end_metric: EndMetric = .before,
    ascent_out: ?*f32 = null,
    /// When set, `text` is context and only this range is measured/shaped.
    /// Mutually exclusive with `max_width`: the break decision has to have
    /// been made already for the caller to know the range.
    item: ?ShapeItem = null,
    /// Paragraph base direction for UAX #9 P2/P3. `.auto` is first-strong,
    /// which resolves LTR for a neutral-only or LTR-leading run even inside
    /// an RTL paragraph -- so a caller that knows the paragraph says so.
    base_direction: opentype.unicode.Bidi.ParagraphDirection = .auto,
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
        const s = try self.fallback.measureLogicalPrefix(gpa, &self.line, byte_offset, snap);
        return s.scale(1.0 / self.ss, Size);
    }

    /// Inverse of `measureUpToByteOffset`: which byte a caret dragged `width`
    /// along the run's logical direction lands on.
    pub fn byteOffsetForWidth(self: *ShapedText, gpa: std.mem.Allocator, width: f32, end_metric: Font.EndMetric) std.mem.Allocator.Error!usize {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        const fit = try self.fallback.logicalPrefixForWidth(gpa, &self.line, width * self.ss, end_metric, snap);
        return fit.byte;
    }

    /// Where a caret after `byte_offset` logical bytes sits, measured from
    /// the run's left edge. Not `measureUpToByteOffset`: that is an ink
    /// width, and ink is not where the pen is.
    pub fn caretOffset(self: *ShapedText, byte_offset: usize) f32 {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        return self.fallback.caretPenOffset(&self.line, byte_offset, snap) / self.ss;
    }

    /// Inverse of `caretOffset`.
    pub fn byteAtOffset(self: *ShapedText, x: f32) usize {
        const snap = if (dvui.current_window) |cw| cw.snap_to_pixels else true;
        return self.fallback.byteAtPenOffset(&self.line, x * self.ss, snap);
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

    var options = opts;
    if (opts.max_width) |mwidth| {
        options.max_width = mwidth * ss;
    }

    const result = try cw.fonts.textSizeRawShaped(cw.arena(), gpa, resolved, text, options);

    // Fetched after textSizeRawShaped, not before: it shapes text via
    // shapeLineText, which can insert into self.cache while lazily
    // materializing fallback-family entries -- that can grow/rehash the map
    // and invalidate any *Entry captured beforehand.
    const fallback_entry = cw.fonts.stackEntry(resolved, 0) orelse return null;

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
    /// Values are `*Entry`, not `Entry`, so a `*Entry` handed out by
    /// `getOrCreate`/`stackEntry` stays valid across later inserts into this
    /// map: `std.HashMapUnmanaged` relocates its value storage on any
    /// insert-triggered growth, not only when `reset()` evicts something, and
    /// several callers (e.g. `ShapedText.fallback`, `ShapedLine` segments)
    /// hold a `*Entry` across other fonts being resolved later in the same
    /// frame.
    cache: dvui.TrackingAutoHashMap(u64, *Entry, .get_and_put, void) = .empty,
    /// Stack-level coverage cache; separate from per-entry cache so reset doesn't evict it.
    resolved_stacks: dvui.TrackingAutoHashMap(u64, ResolvedStack, .get_and_put, void) = .empty,
    /// Full-pipeline shape results, keyed by fnv(ResolvedStack.font_hash, text) --
    /// otherwise every unchanged widget (grid cells, static labels) reruns bidi +
    /// GSUB/GPOS from scratch every single frame. Segments hold `*Entry` pointers
    /// into `cache`, which reset() can evict/reallocate, so this is cleared
    /// alongside it rather than surviving resets like `resolved_stacks` does.
    /// NOTE: unbounded growth for distinct (font, text) pairs until the next
    /// reset; fine for grid/label-style static text, revisit with an LRU cap if a
    /// scene with many unique per-frame strings (e.g. live-updating text) shows up.
    shaped_line_cache: std.AutoHashMapUnmanaged(u64, CachedShapedLine) = .empty,
    /// Per-codepoint memo for `discoverDynamicFallback` -- caches a system
    /// discovery lookup (or its failure, stored as `null`) so a codepoint
    /// missing from every registered family only ever triggers one OS query,
    /// not one per shaped line/frame that contains it.
    dynamic_fallback: std.AutoHashMapUnmanaged(u21, ?Font) = .empty,
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
            item.value_ptr.deinit(gpa);
        }
        self.resolved_stacks.deinit(gpa);

        var lit = self.shaped_line_cache.valueIterator();
        while (lit.next()) |line| line.deinit(gpa);
        self.shaped_line_cache.deinit(gpa);

        for (self.database.items) |*source| {
            if (source.allocator) |a| {
                a.free(source.bytes);
            }
        }
        self.database.deinit(gpa);
        self.dynamic_fallback.deinit(gpa);

        var ait = self.family_aliases.iterator();
        while (ait.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        self.family_aliases.deinit(gpa);
    }

    /// Register `alias` as an ordered fallback stack of family names.
    /// Re-registering an alias replaces its list; only stacks resolved after
    /// this call see the change, so register up front.
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
        const key = alias[0..@min(alias.len, NAME_MAX_LEN)];
        if (self.family_aliases.getEntry(key)) |e| {
            gpa.free(e.value_ptr.*);
            e.value_ptr.* = list;
            return;
        }
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        try self.family_aliases.put(gpa, owned_key, list);
    }

    pub fn reset(self: *Cache, gpa: std.mem.Allocator, backend: Backend) void {
        var it = self.cache.iterator();
        while (it.next_resetting()) |kv| {
            var fce = kv.value;
            fce.deinit(gpa, backend);
            gpa.destroy(fce);
        }
        // shaped_line_cache survives resets like resolved_stacks does -- its
        // segments resolve `*Entry` by stable hash at read time (see
        // materializeShapedLine), which invalidates and reshapes any line
        // referencing a font this `reset()` evicted (e.g. scrolled out of
        // view and not re-touched before the next reset) rather than
        // rendering it with segments silently missing.
    }

    /// Cap on `shaped_line_cache` entries before it is dropped wholesale.
    const max_shaped_lines = 4096;

    // ponytail: bulk clear rather than LRU -- eviction order only matters if
    // the cap is hit routinely, and at 4096 lines it isn't. Swap in an LRU if
    // a real workload starts thrashing this.
    fn clearShapedLineCache(self: *Cache, gpa: std.mem.Allocator) void {
        var it = self.shaped_line_cache.valueIterator();
        while (it.next()) |v| v.deinit(gpa);
        self.shaped_line_cache.clearRetainingCapacity();
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

    /// Resolves `font` to a concrete `Source`: exact match, closest CSS
    /// variant match, OS discovery, or the embedded fallback -- in that
    /// order. Shared by `getOrCreate` (full calibrated `Entry`) and
    /// `resolveStack` (cheap parse-only probe for fallback-stack coverage).
    fn resolveSource(self: *Cache, gpa: std.mem.Allocator, raw_font: Font) std.mem.Allocator.Error!Source {
        // An alias names no font of its own; on its own (outside resolveStack)
        // it resolves to its first family.
        const font = if (self.family_aliases.get(raw_font.familyName())) |list| list[0].apply(raw_font) else raw_font;
        const exact, const second = self.findSource(font);
        if (exact) |s| return s;

        const fname = font.name(gpa);
        defer gpa.free(fname);

        if (second) |s| {
            const sname = s.name(gpa);
            defer gpa.free(sname);
            dvui.log.warn("Font {s} not loaded in dvui, using second best {s}", .{ fname, sname });
            return s;
        } else if (discoverSystemFont(gpa, font)) |sys_source| {
            dvui.log.debug("Font {s} resolved via OS font discovery", .{fname});
            try self.database.append(gpa, sys_source);
            return sys_source;
        } else {
            dvui.log.warn("Font {s} not loaded in dvui, using fallback", .{fname});
            return Source.fallback;
        }
    }

    pub fn getOrCreate(self: *Cache, gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*Entry {
        const entry = try self.cache.getOrPut(gpa, font.hash());
        if (entry.found_existing) return entry.value_ptr.*;

        const fname = font.name(gpa);
        defer gpa.free(fname);

        const source = try self.resolveSource(gpa, font);

        //log.debug("FontCacheGet creating font hash {x} ptr {*} size {d} name \"{s}\"", .{ fontHash, bytes.ptr, font.size, font.name });

        const boxed = try gpa.create(Entry);
        errdefer gpa.destroy(boxed);
        boxed.* = Entry.init(gpa, source.bytes, source.collection_index, font) catch |err| blk: {
            dvui.log.err("Font {s} init got {any}, using fallback", .{ fname, err });
            // Fallback bytes under the *requested* hash, not the fallback
            // font's: callers (resolveStack/stackEntry) look this entry up by
            // the hash they asked for, and would find nothing otherwise.
            break :blk Entry.init(gpa, Source.fallback.bytes, Source.fallback.collection_index, font) catch {
                self.cache.map.removeByPtr(entry.key_ptr);
                gpa.destroy(boxed);
                return error.OutOfMemory;
            };
        };
        entry.value_ptr.* = boxed;
        //log.debug("- size {d} ascent {d} height {d}", .{ font.size, entry.ascent, entry.height });
        return boxed;
    }

    pub const ResolvedStack = struct {
        /// Font.hash() this stack was resolved from; used as a shaped_line_cache key.
        font_hash: u64 = 0,
        /// Entry hashes; entries themselves live in Cache.cache.
        entry_hashes: []u64 = &.{},
        /// Single-family Font per stack slot, used to lazily materialize a
        /// full calibrated Entry via `Cache.getOrCreate` the first time a
        /// shaped line actually assigns it a glyph -- see `shapeLineText`.
        family_fonts: []Font = &.{},
        /// Parse-only (no renderer/calibration) font per stack slot, owned
        /// by this struct and independent of `Cache.cache` -- cheap to build
        /// up front for coverage purposes without paying for a fallback
        /// family's Renderer init + ppem calibration until it's actually used.
        raw_fonts: []OtFont = &.{},
        /// Merged codepoint coverage across all entries; built once per stack.
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
            gpa.free(self.entry_hashes);
            gpa.free(self.family_fonts);
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

    /// Load families and cache merged coverage per stack. Only the primary
    /// family (index 0) gets a full calibrated `Entry` here -- fallback
    /// families are parsed just enough to read their cmap coverage; a full
    /// `Entry` (Renderer + ppem calibration) for them is only built lazily
    /// in `shapeLineText`, the first time some shaped text actually needs
    /// glyphs from that family.
    pub fn resolveStack(self: *Cache, gpa: std.mem.Allocator, font: Font) std.mem.Allocator.Error!*ResolvedStack {
        const h = font.hash();
        const found = try self.resolved_stacks.getOrPut(gpa, h);
        if (found.found_existing) {
            // Re-touch the primary family to recreate it if evicted by reset;
            // fallback families re-materialize lazily on next use.
            _ = try self.getOrCreate(gpa, found.value_ptr.family_fonts[0]);
            return found.value_ptr;
        }

        const single: [1]FamilyEntry = .{.{ .family = font.family }};
        const names: []const FamilyEntry = self.family_aliases.get(font.familyName()) orelse &single;

        const entry_hashes = try gpa.alloc(u64, names.len);
        errdefer gpa.free(entry_hashes);
        const family_fonts = try gpa.alloc(Font, names.len);
        errdefer gpa.free(family_fonts);
        const raw_fonts = try gpa.alloc(OtFont, names.len);
        errdefer gpa.free(raw_fonts);
        const per_entry_ranges = try gpa.alloc([]Cmap.Range, names.len);
        defer gpa.free(per_entry_ranges);

        var count: usize = 0;
        errdefer {
            for (per_entry_ranges[0..count]) |r| gpa.free(r);
            for (raw_fonts[0..count]) |*rf| rf.deinit(gpa);
        }

        for (names) |family| {
            const family_font = family.apply(font);
            family_fonts[count] = family_font;
            entry_hashes[count] = family_font.hash();

            const source = try self.resolveSource(gpa, family_font);
            raw_fonts[count] = Entry.parseFontOrCollection(gpa, source.bytes, source.collection_index) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => Entry.parseFontOrCollection(gpa, Source.fallback.bytes, Source.fallback.collection_index) catch |e2| switch (e2) {
                    error.OutOfMemory => |e| return e,
                    else => unreachable, // embedded Vera.ttf is a known-good sfnt
                },
            };

            if (count == 0) _ = try self.getOrCreate(gpa, family_font); // primary family is virtually always needed

            const cmap_data = raw_fonts[count].tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
            per_entry_ranges[count] = try Cmap.coverageRanges(cmap_data, gpa);
            count += 1;
        }
        defer for (per_entry_ranges) |r| gpa.free(r);

        const fallback = try Cmap.FallbackStack.build(gpa, per_entry_ranges);
        found.value_ptr.* = .{ .font_hash = h, .entry_hashes = entry_hashes, .family_fonts = family_fonts, .raw_fonts = raw_fonts, .fallback = fallback };
        return found.value_ptr;
    }

    /// Entry at stack index; null if evicted by reset.
    pub fn stackEntry(self: *Cache, resolved: *const ResolvedStack, index: u8) ?*Entry {
        if (index >= resolved.entry_hashes.len) return null;
        return if (self.cache.getPtr(resolved.entry_hashes[index])) |p| p.* else null;
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
    /// `persist_gpa` (not a frame arena): both `dynamic_fallback` (this
    /// function's own memo) and `database`/the loaded font bytes (inside
    /// `loadDynamicFallback`) live in `Cache`, which outlives the frame --
    /// growing them with an arena that resets after this frame leaves their
    /// backing storage dangling, corrupting the heap the next time anything
    /// touches them (a later frame's `dynamic_fallback.get`, or the byte
    /// buffer's owning-allocator free in `Cache.deinit`).
    pub fn discoverDynamicFallback(self: *Cache, persist_gpa: std.mem.Allocator, codepoint: u21) ?Font {
        if (self.dynamic_fallback.get(codepoint)) |cached| return cached;
        const found = self.loadDynamicFallback(persist_gpa, codepoint);
        self.dynamic_fallback.put(persist_gpa, codepoint, found) catch {};
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

    fn loadDynamicFallback(self: *Cache, persist_gpa: std.mem.Allocator, codepoint: u21) ?Font {
        const SysBackend = system_font_backend orelse return null;
        if (!@hasDecl(SysBackend, "selectFallbackForCodepoint")) return null;

        var backend = SysBackend.init() catch return null;
        defer backend.deinit();

        var path_storage: [4096]u8 = undefined;
        const needs_allocator = @typeInfo(@TypeOf(SysBackend.selectFallbackForCodepoint)).@"fn".params.len == 4;
        const handle: DiscoveryHandle = if (needs_allocator)
            backend.selectFallbackForCodepoint(codepoint, &path_storage, persist_gpa) catch return null
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

        const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, p.path, persist_gpa, .limited(system_font_size_limit)) catch return null;
        self.database.append(persist_gpa, .{
            .family = array(family_name),
            .bytes = bytes,
            .allocator = persist_gpa,
            .collection_index = p.font_index,
            .display_family = readDisplayFamilyName(persist_gpa, bytes, p.font_index),
        }) catch {
            persist_gpa.free(bytes);
            return null;
        };
        return synthetic;
    }

    /// Shape text up to first newline, splitting runs by font stack coverage.
    /// `persist_gpa` backs only `resolved.logged_missing`, which outlives the
    /// frame (cached in `resolved_stacks`) -- passing a per-frame arena there
    /// corrupts the map once the arena resets on the next frame.
    pub fn shapeLineText(self: *Cache, gpa: std.mem.Allocator, persist_gpa: std.mem.Allocator, resolved: *ResolvedStack, text: []const u8, item: ?Font.ShapeItem, base_direction: opentype.unicode.Bidi.ParagraphDirection) std.mem.Allocator.Error!Entry.ShapedLine {
        var key_hash = dvui.fnv.init();
        key_hash.update(std.mem.asBytes(&resolved.font_hash));
        key_hash.update(text);
        if (item) |it| key_hash.update(std.mem.asBytes(&it));
        key_hash.update(std.mem.asBytes(&base_direction));
        const cache_key = key_hash.final();
        if (self.shaped_line_cache.get(cache_key)) |cached| {
            if (try self.materializeShapedLine(gpa, cached)) |line| return line;
            // A segment's font was evicted from `cache` (unused since the
            // last reset -- e.g. scrolled out of view) since this line was
            // cached: the cached line is now unrenderable as-is, so drop it
            // and fall through to reshape from scratch instead of silently
            // rendering with missing segments.
            if (self.shaped_line_cache.fetchRemove(cache_key)) |kv| {
                var v = kv.value;
                v.deinit(persist_gpa);
            }
        }

        const decoded = try Entry.decodeLine(gpa, text);
        var line_codepoints = decoded.codepoints;
        var line_byte_offsets = decoded.byte_offsets;
        errdefer gpa.free(line_codepoints);
        errdefer gpa.free(line_byte_offsets);

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
        // since `raw_fonts` is owned by `resolved` itself. A few trailing
        // slots for dynamically discovered system fonts (see below), for
        // codepoints no registered family covers.
        const dynamic_fallback_cap = 4;
        const max_stack_fonts = resolved.entry_hashes.len + dynamic_fallback_cap;
        const fonts_buf = try gpa.alloc(OtFont, max_stack_fonts);
        defer gpa.free(fonts_buf);
        const hashes_buf = try gpa.alloc(u64, max_stack_fonts);
        defer gpa.free(hashes_buf);
        const family_fonts_buf = try gpa.alloc(Font, max_stack_fonts);
        defer gpa.free(family_fonts_buf);
        var nfonts: usize = resolved.entry_hashes.len;
        for (0..nfonts) |i| {
            fonts_buf[i] = resolved.raw_fonts[i];
            hashes_buf[i] = resolved.entry_hashes[i];
            family_fonts_buf[i] = resolved.family_fonts[i];
        }

        // Query the OS for each newly-uncovered codepoint (skipping any
        // already covered by a font discovered earlier in this same line),
        // until the line is covered or `dynamic_fallback_cap` slots are used
        // -- a line mixing several scripts absent from the static stack
        // needs more than one dynamic font, not just the first.
        var dynamic_cmaps: [dynamic_fallback_cap][]const u8 = undefined;
        var ndynamic: usize = 0;
        if (nfonts > 0) {
            for (decoded.codepoints) |cp| {
                if (nfonts >= max_stack_fonts) break;
                if (resolved.entryIndexFor(cp) != null) continue;
                var covered = false;
                for (dynamic_cmaps[0..ndynamic]) |cm| {
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
                if (self.discoverDynamicFallback(persist_gpa, cp)) |raw_dyn_font| {
                    const dyn_font = raw_dyn_font.withSize(resolved.family_fonts[0].size);
                    const dyn_hash = dyn_font.hash();
                    var already_added = false;
                    for (hashes_buf[resolved.entry_hashes.len..nfonts]) |h| {
                        if (h == dyn_hash) {
                            already_added = true;
                            break;
                        }
                    }
                    if (already_added) continue;
                    // persist_gpa: getOrCreate inserts into self.cache, which
                    // outlives this frame -- gpa here may be a frame-scoped
                    // arena that resets right after this call returns.
                    const dyn_entry = try self.getOrCreate(persist_gpa, dyn_font);
                    fonts_buf[nfonts] = dyn_entry.parsed_font;
                    hashes_buf[nfonts] = dyn_hash;
                    family_fonts_buf[nfonts] = dyn_font;
                    nfonts += 1;
                    const cmap = dyn_entry.parsed_font.tableData(.{ 'c', 'm', 'a', 'p' }) orelse &.{};
                    if (cmap.len > 0 and ndynamic < dynamic_fallback_cap) {
                        dynamic_cmaps[ndynamic] = cmap;
                        ndynamic += 1;
                    }
                }
            }
        }

        var result = Buffer.init(gpa);
        errdefer result.deinit();
        var segments: std.ArrayList(Entry.ShapedLine.EntrySegment) = .empty;
        errdefer segments.deinit(gpa);
        // Entry-hash twin of `segments`, cached in place of raw `*Entry`
        // pointers -- `cache`'s backing array can grow/rehash across frames
        // (loading a new bold/italic/mono variant), which would otherwise
        // leave a persisted segment's pointer dangling.
        var cache_segments: std.ArrayList(CachedShapedLine.Segment) = .empty;
        errdefer cache_segments.deinit(gpa);

        if (decoded.codepoints.len > 0 and nfonts > 0) {
            for (decoded.codepoints) |cp| {
                if (resolved.entryIndexFor(cp) != null) continue;
                var covered = false;
                for (dynamic_cmaps[0..ndynamic]) |cm| {
                    if (Cmap.lookup(cm, cp) != null) {
                        covered = true;
                        break;
                    }
                }
                if (covered) continue;
                _ = self.entryIndexForLogged(resolved, persist_gpa, cp); // diagnostics
            }
            // Bidi outer, font fallback inner, so visual reordering crosses font boundaries.
            const shaped = shapeBidiParagraphWithFallback(gpa, fonts_buf[0..nfonts], decoded.codepoints, base_direction, &.{}, &.{}, &.{}, item_cp) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => BidiFallbackResult{ .buffer = Buffer.init(gpa), .font_indices = &.{} },
            };
            defer gpa.free(shaped.font_indices);
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
                // persist_gpa: see note on the dynamic-fallback getOrCreate above.
                _ = try self.getOrCreate(persist_gpa, family_fonts_buf[fi]);
                g = h;
            }
            g = 0;
            while (g < shaped.font_indices.len) {
                const fi = shaped.font_indices[g];
                var h = g + 1;
                while (h < shaped.font_indices.len and shaped.font_indices[h] == fi) h += 1;
                const fce = try self.getOrCreate(persist_gpa, family_fonts_buf[fi]);
                try segments.append(gpa, .{ .entry = fce, .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
                try cache_segments.append(gpa, .{ .entry_hash = hashes_buf[fi], .glyph_start = @intCast(g), .glyph_end = @intCast(h) });
                g = h;
            }
        }
        result.have_positions = true;

        // Rebase onto the item: from here on the line reads exactly like a
        // shape of `text[item.start..item.end]` alone -- clusters and byte
        // offsets relative to the item -- so every caller's byte-offset math
        // (prefix measurement, hit testing, selection) is unchanged by the
        // context having been there.
        if (item_cp) |it_cp| {
            const it = item.?;
            const new_codepoints = try gpa.dupe(u21, line_codepoints[it_cp.start..it_cp.end]);
            errdefer gpa.free(new_codepoints);
            const new_offsets = try gpa.alloc(u32, it_cp.end - it_cp.start + 1);
            for (new_offsets[0 .. it_cp.end - it_cp.start], line_byte_offsets[it_cp.start..it_cp.end]) |*dst, off| {
                dst.* = off -| @as(u32, @intCast(it.start));
            }
            new_offsets[it_cp.end - it_cp.start] = line_byte_offsets[it_cp.end] -| @as(u32, @intCast(it.start));
            for (result.info.items) |*info| info.cluster -= @intCast(it_cp.start);
            gpa.free(line_codepoints);
            gpa.free(line_byte_offsets);
            line_codepoints = new_codepoints;
            line_byte_offsets = new_offsets;
        }

        const cluster_tables = try result.buildClusterTables(gpa, line_byte_offsets);

        const line: Entry.ShapedLine = .{
            .allocator = gpa,
            .codepoints = line_codepoints,
            .byte_offsets = line_byte_offsets,
            .buffer = result,
            .cluster_starts = cluster_tables.starts,
            .cluster_ends = cluster_tables.ends,
            .segments = try segments.toOwnedSlice(gpa),
        };

        const to_cache: CachedShapedLine = .{
            .codepoints = line_codepoints,
            .byte_offsets = line_byte_offsets,
            .buffer = result,
            .cluster_starts = cluster_tables.starts,
            .cluster_ends = cluster_tables.ends,
            .segments = cache_segments.items,
        };
        if (to_cache.clone(persist_gpa)) |persisted| {
            var to_store = persisted;
            // Every distinct (stack, text) slice ever shaped lands here and
            // reset() deliberately keeps it, so without a cap this grows
            // unbounded: a reflowing TextLayout or the bidi break-retreat
            // loop mints a fresh key per candidate prefix per width.
            if (self.shaped_line_cache.count() >= max_shaped_lines) {
                self.clearShapedLineCache(persist_gpa);
            }
            self.shaped_line_cache.put(persist_gpa, cache_key, to_store) catch to_store.deinit(persist_gpa);
        } else |_| {} // OOM on the persistent copy just means this shape isn't cached
        cache_segments.deinit(gpa);

        return line;
    }

    /// Owned copy of a shape result kept in `shaped_line_cache`. Segments
    /// reference fonts by `entry_hash` (stable across `cache` rehashes)
    /// rather than `*Entry` (see `shapeLineText`'s cache_segments comment);
    /// `materializeShapedLine` resolves them back to live pointers per hit.
    const CachedShapedLine = struct {
        codepoints: []u21,
        byte_offsets: []u32,
        buffer: Buffer,
        cluster_starts: []u32,
        cluster_ends: []u32,
        segments: []Segment,

        const Segment = struct { entry_hash: u64, glyph_start: u32, glyph_end: u32 };

        fn clone(self: CachedShapedLine, gpa: std.mem.Allocator) std.mem.Allocator.Error!CachedShapedLine {
            var buffer = Buffer.init(gpa);
            errdefer buffer.deinit();
            try buffer.info.appendSlice(gpa, self.buffer.info.items);
            try buffer.pos.appendSlice(gpa, self.buffer.pos.items);
            buffer.have_positions = self.buffer.have_positions;

            const codepoints = try gpa.dupe(u21, self.codepoints);
            errdefer gpa.free(codepoints);
            const byte_offsets = try gpa.dupe(u32, self.byte_offsets);
            errdefer gpa.free(byte_offsets);
            const cluster_starts = try gpa.dupe(u32, self.cluster_starts);
            errdefer gpa.free(cluster_starts);
            const cluster_ends = try gpa.dupe(u32, self.cluster_ends);
            errdefer gpa.free(cluster_ends);
            const segments = try gpa.dupe(Segment, self.segments);
            errdefer gpa.free(segments);

            return .{
                .codepoints = codepoints,
                .byte_offsets = byte_offsets,
                .buffer = buffer,
                .cluster_starts = cluster_starts,
                .cluster_ends = cluster_ends,
                .segments = segments,
            };
        }

        fn deinit(self: *CachedShapedLine, gpa: std.mem.Allocator) void {
            self.buffer.deinit();
            gpa.free(self.codepoints);
            gpa.free(self.byte_offsets);
            gpa.free(self.cluster_starts);
            gpa.free(self.cluster_ends);
            gpa.free(self.segments);
        }
    };

    /// Turns a `shaped_line_cache` hit into a caller-owned `Entry.ShapedLine`,
    /// re-resolving each segment's `*Entry` from its stable hash -- `null` if
    /// any segment's font was evicted from `cache` since the line was cached
    /// (the caller reshapes from scratch rather than rendering with segments
    /// silently missing).
    fn materializeShapedLine(self: *Cache, gpa: std.mem.Allocator, cached: CachedShapedLine) std.mem.Allocator.Error!?Entry.ShapedLine {
        var buffer = Buffer.init(gpa);
        errdefer buffer.deinit();
        try buffer.info.appendSlice(gpa, cached.buffer.info.items);
        try buffer.pos.appendSlice(gpa, cached.buffer.pos.items);
        buffer.have_positions = cached.buffer.have_positions;

        const codepoints = try gpa.dupe(u21, cached.codepoints);
        errdefer gpa.free(codepoints);
        const byte_offsets = try gpa.dupe(u32, cached.byte_offsets);
        errdefer gpa.free(byte_offsets);
        const cluster_starts = try gpa.dupe(u32, cached.cluster_starts);
        errdefer gpa.free(cluster_starts);
        const cluster_ends = try gpa.dupe(u32, cached.cluster_ends);
        errdefer gpa.free(cluster_ends);

        var segments: std.ArrayList(Entry.ShapedLine.EntrySegment) = .empty;
        errdefer segments.deinit(gpa);
        for (cached.segments) |seg| {
            const entry_ptr = self.cache.getPtr(seg.entry_hash) orelse {
                segments.deinit(gpa);
                buffer.deinit();
                gpa.free(codepoints);
                gpa.free(byte_offsets);
                gpa.free(cluster_starts);
                gpa.free(cluster_ends);
                return null;
            };
            try segments.append(gpa, .{ .entry = entry_ptr.*, .glyph_start = seg.glyph_start, .glyph_end = seg.glyph_end });
        }

        return .{
            .allocator = gpa,
            .codepoints = codepoints,
            .byte_offsets = byte_offsets,
            .buffer = buffer,
            .cluster_starts = cluster_starts,
            .cluster_ends = cluster_ends,
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
        const default_height: f32 = if (self.stackEntry(resolved, 0)) |fe| fe.height else 0;

        const hard_break = firstHardBreak(text);
        const newline_idx = if (hard_break) |hb| hb.start else text.len;
        // An item measures a known range of already-broken text, so the
        // growing measurement window (and its max_width break search) is
        // both unnecessary and wrong -- the context beyond the window is
        // exactly what it was asked to shape against.
        var window: usize = if (opts.max_width != null and opts.item == null) @min(newline_idx, 64) else newline_idx;

        while (true) {
            var line = try self.shapeLineText(scratch, gpa, resolved, text[0..window], opts.item, opts.base_direction);
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
                // A break inside an RTL run cuts its logical prefix, which is
                // the buffer's trailing glyphs -- the walk above measured in
                // from the other end of the run.
                if (found_break and line.buffer.isRtl()) {
                    if (fallback_entry) |fe| {
                        const fit = try fe.logicalPrefixForWidth(gpa, &line, mwidth, opts.end_metric, snap);
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

        /// Adds a synthetic `wght` coordinate from `font.weight` when the
        /// caller hasn't already pinned `wght` via `withVariation` -- so a
        /// bundled variable font instances at the requested CSS weight
        /// instead of always rendering its default (usually Regular)
        /// instance. A no-op for fonts without a `wght` axis.
        fn effectiveUserCoords(font: Font, buf: *[max_variations + 1]UserCoord) []const UserCoord {
            var n: usize = 0;
            var has_wght = false;
            for (font.variations[0..font.variation_count]) |v| {
                buf[n] = v;
                n += 1;
                if (std.mem.eql(u8, &v.tag, "wght")) has_wght = true;
            }
            if (!has_wght) {
                buf[n] = .{ .tag = "wght".*, .value = font.weight.value };
                n += 1;
            }
            return buf[0..n];
        }

        fn measuredCapHeight(renderer: *Renderer, gpa: std.mem.Allocator, glyph_id: u16) ?f32 {
            // scratch uses lifo; output uses gpa to avoid lifo ordering violation.
            const rendered = renderer.renderGlyph(glyph_id, .{}, dvui.currentWindow().lifo(), gpa) catch return null;
            defer rendered.deinit(gpa);
            if (rendered.bitmap.rows == 0) return null;
            return @floatFromInt(rendered.bitmap.rows);
        }

        /// Load font, calibrating ppem so rendered M height matches font.size.
        pub fn init(gpa: std.mem.Allocator, ttf_bytes: []const u8, collection_index: u32, font: Font) Error!Entry {
            const min_pixel_size: f32 = 1;

            const fname = font.name(gpa);
            errdefer gpa.free(fname);

            const parsed_font = parseFontOrCollection(gpa, ttf_bytes, collection_index) catch |err| {
                dvui.log.warn("Font.Cache.Entry.init() opentype parse error {any} font {s}\n", .{ err, fname });
                return Error.FontError;
            };
            errdefer parsed_font.deinit(gpa);

            var ppem = @max(min_pixel_size, font.size);
            var coords_buf: [max_variations + 1]UserCoord = undefined;
            const user_coords = effectiveUserCoords(font, &coords_buf);
            var renderer = Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = user_coords }) catch |err| {
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
                renderer = Renderer.init(gpa, dvui.currentWindow().lifo(), parsed_font, ppem, .{ .hint_glyf = true, .user_coords = user_coords }) catch |err| {
                    dvui.log.warn("Font.Cache.Entry.init() opentype renderer error {any} font {s}\n", .{ err, fname });
                    return Error.FontError;
                };
                em_height = measuredCapHeight(&renderer, gpa, m_glyph_id) orelse ppem;
            }

            const scale_f = ppem / units_per_em_f;
            const entry: Entry = .{
                .name = fname,
                .parsed_font = parsed_font,
                .renderer = renderer,
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
                        // Renderer output is straight (non-premultiplied) alpha; PMA
                        // needs it premultiplied or edge pixels over-brighten on dark
                        // backgrounds (RGB doesn't fall off with alpha near the edge).
                        .fromColor(.{ .r = src[0], .g = src[1], .b = src[2], .a = src[3] })
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
        pub fn measureLogicalPrefix(self: *Entry, gpa: std.mem.Allocator, line: *const ShapedLine, byte_offset: usize, snap: bool) std.mem.Allocator.Error!Size {
            const r = line.logicalPrefixGlyphs(byte_offset);
            // ponytail: one entry's metrics for every glyph -- a prefix that
            // fell back to a second font measures its ink against the
            // primary; thread entryForGlyph through if that ever shows.
            const s = try opentype.measureGlyphRange(gpa, self, self.ascent, self.height, line.buffer.info.items[r.start..r.end], line.buffer.pos.items[r.start..r.end], r.end - r.start, snap);
            return .{ .w = s.w, .h = s.h };
        }

        pub const PrefixFit = struct { byte: usize, w: f32 };

        /// Longest logical byte prefix of `line` that fits `mwidth` (device
        /// pixels), and its width: the inverse of `measureLogicalPrefix`, and
        /// exact in both directions because it is found by measuring through
        /// that same call at each cluster boundary.
        pub fn logicalPrefixForWidth(self: *Entry, gpa: std.mem.Allocator, line: *const ShapedLine, mwidth: f32, end_metric: Font.EndMetric, snap: bool) std.mem.Allocator.Error!PrefixFit {
            var best: PrefixFit = .{ .byte = 0, .w = 0 };
            // ponytail: re-measures from the run's logical start per candidate
            // (quadratic in glyphs), which a fragment-sized run never notices;
            // make it incremental if whole-paragraph lines ever come through.
            for (line.cluster_ends) |boundary| {
                const w = (try self.measureLogicalPrefix(gpa, line, boundary, snap)).w;
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
            const r = line.logicalPrefixGlyphs(byte_offset);
            // An RTL run's logical prefix is the buffer's *trailing* glyphs,
            // so its caret is at the prefix's left edge -- and an empty
            // prefix sits at the run's right edge, past every glyph.
            const limit = if (!line.isRtl()) r.end else if (r.end == 0) line.buffer.info.items.len else r.start;
            var x: f32 = 0;
            for (line.buffer.pos.items[0..limit], 0..) |pos, gidx| {
                const adv = line.entryForGlyph(self, gidx).toPixels(pos.x_advance);
                x += if (snap) @round(adv) else adv;
            }
            return x;
        }

        /// Inverse of `caretPenOffset`: the caret stop nearest pen x. Pen
        /// offsets run backwards through an RTL run's text, so this picks by
        /// distance rather than walking until a width is exceeded.
        /// ponytail: quadratic in glyphs, same as `logicalPrefixForWidth`;
        /// one click, one fragment-sized run.
        pub fn byteAtPenOffset(self: *Entry, line: *const ShapedLine, x: f32, snap: bool) usize {
            var best: usize = 0;
            var best_d: f32 = @abs(self.caretPenOffset(line, 0, snap) - x);
            for (line.cluster_ends) |boundary| {
                const d = @abs(self.caretPenOffset(line, boundary, snap) - x);
                if (d < best_d) {
                    best_d = d;
                    best = boundary;
                }
            }
            return best;
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

    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, "Hello, world! fi ffi", null, .auto);
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

test "sizeM: memoized result matches a fresh textSizeRawShaped(\"M\") call" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 24 });
    const cw = dvui.currentWindow();

    const ss = dvui.parentGet().screenRectScale(Rect{}).s;
    const resolved = try cw.fonts.resolveStack(cw.gpa, font.withSize(font.size * ss));

    var reference = try cw.fonts.textSizeRawShaped(gpa, gpa, resolved, "M", .{});
    defer reference.line.deinit();

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

test "smoke: bidi/RTL text shapes without crashing" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, font);

    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, "abc \u{0627}\u{0644}\u{0633}\u{0644}\u{0627}\u{0645} xyz", null, .auto);
    defer line.deinit();
    try std.testing.expect(line.buffer.info.items.len > 0);
    // Latin around an Arabic run: the line holds both directions at once, so
    // no byte prefix of it is a contiguous stretch of the line and
    // `TextLayoutWidget` has to reshape each wrapped line's own byte-range.
    try std.testing.expect(line.isMixedDirection());

    // One direction, either one, keeps the shape sliceable by byte offset.
    var ltr = try cw.fonts.shapeLineText(gpa, gpa, resolved, "Hello, world!", null, .auto);
    defer ltr.deinit();
    try std.testing.expect(!ltr.isMixedDirection());
    try std.testing.expect(!ltr.isRtl());

    var rtl = try cw.fonts.shapeLineText(gpa, gpa, resolved, "\u{05e9}\u{05dc}\u{05d5}\u{05dd}", null, .auto);
    defer rtl.deinit();
    try std.testing.expect(!rtl.isMixedDirection());
}

test "an RTL run's logical prefix measures monotonically, and width maps back to it" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    // Four Hebrew letters, two bytes each. Their glyphs come out right to
    // left, so the logical prefix a caret walks over is the *last* stretch
    // of the shape -- what a leading-glyph walk gets backwards.
    const txt = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    var res = (try font.textSizeExShaped(gpa, txt, .{})).?;
    defer res.shaped.deinit();
    // Nothing in the stack covers Hebrew on this platform.
    if (res.shaped.line.buffer.info.items[0].codepoint == 0) return;
    try std.testing.expect(res.shaped.line.isRtl());

    var prev: f32 = -1;
    var off: usize = 0;
    while (off <= txt.len) : (off += 2) {
        const w = (try res.shaped.measureUpToByteOffset(gpa, off)).w;
        try std.testing.expect(w > prev);
        prev = w;

        // And the inverse: the width of a prefix answers with that prefix.
        var end: usize = undefined;
        _ = font.textSizeEx(txt, .{ .max_width = w, .end_idx = &end, .end_metric = .nearest });
        try std.testing.expectEqual(off, end);
    }
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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const stack: Font = .init("TestStack");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    // Fallback family (index 1) isn't materialized into a full Entry until
    // some shaped text actually needs it.
    try std.testing.expectEqual(@as(?*Cache.Entry, null), cw.fonts.stackEntry(resolved, 1));

    // "AB" (Latin) + two Hangul syllables (Korean) + "CD" (Latin) -- Vera
    // has no Hangul glyphs and NotoSansKR-Regular has no use registering it
    // as the primary family, so coverage is naturally disjoint here.
    var line = try cw.fonts.shapeLineText(std.testing.allocator, std.testing.allocator, resolved, "AB\u{AC00}\u{AC01}CD", null, .auto);
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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

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

    var line = try cw.fonts.shapeLineText(std.testing.allocator, std.testing.allocator, resolved, "A\u{AC00}", null, .auto);
    defer line.deinit();
    const korean_entry = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expect(korean_entry.height < primary.height);
}

test "Cache.shapeLineText: shaped_line_cache stays bounded under distinct-slice churn" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestLatin"));

    // Every slice is a distinct cache key, the way a reflowing TextLayout or
    // the bidi retreat loop mints one per candidate prefix.
    var buf: [32]u8 = undefined;
    for (0..Cache.max_shaped_lines + 64) |i| {
        const text = try std.fmt.bufPrint(&buf, "slice-{d}", .{i});
        var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto);
        line.deinit();
    }

    try std.testing.expect(cw.fonts.shaped_line_cache.count() <= Cache.max_shaped_lines);
}

test "Cache.shapeLineText: a shaped_line_cache hit reshapes instead of dropping segments when a fallback font was evicted by reset()" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const stack: Font = .init("TestStack");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);
    const text = "AB\u{AC00}\u{AC01}CD";

    var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto);
    defer line.deinit();
    try std.testing.expectEqual(@as(usize, 3), line.segments.len);

    // Simulate the Korean fragment scrolling out of view: nothing touches
    // `cache` for two frames, so it's unused across both resets and gets
    // evicted (used-since-last-reset only survives one reset cycle).
    cw.fonts.reset(cw.gpa, cw.backend);
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(?*Cache.Entry, null), cw.fonts.stackEntry(resolved, 1));

    // Scrolled back into view: same text, same stack -- shaped_line_cache
    // still has the old line cached, but its Korean segment now points at
    // an evicted entry. Must reshape from scratch, not silently drop the
    // Korean segment and leave the caller thinking it's Latin-only.
    var line2 = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto);
    defer line2.deinit();
    try std.testing.expectEqual(@as(usize, 3), line2.segments.len);

    const korean_entry_after = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expectEqual(korean_entry_after, line2.segments[1].entry);
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
    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, text, null, .auto);
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
    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, text, null, .auto);
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


test "TextSizeOptions.item: shapes with context but reports only the item" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;
    const font: Font = .find(.{ .family = "Vera", .size = 24 });

    var res = (try font.textSizeExShaped(gpa, "Hello", .{ .item = .{ .start = 1, .end = 3 } })).?;
    defer res.shaped.deinit();

    // Only "el" produced glyphs, and the result is rebased so it reads like
    // a standalone shape of "el": two clusters at byte 0 and 1, and the
    // usual byte-offset math lands where a caller slicing "el" expects.
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
    // glyph. This is what per-addText-chunk shaping used to get wrong.
    const word = "\u{0633}\u{0644}";
    var alone = (try font.textSizeExShaped(gpa, word[0..2], .{})).?;
    defer alone.shaped.deinit();
    // No Arabic anywhere in the font stack on this platform: nothing to test.
    if (alone.shaped.line.buffer.info.items[0].codepoint == 0) return;

    var joined = (try font.textSizeExShaped(gpa, word, .{ .item = .{ .start = 0, .end = 2 } })).?;
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
    var res = (try font.textSizeExShaped(gpa, txt, .{})).?;
    defer res.shaped.deinit();
    try std.testing.expect(res.shaped.line.isRtl());

    const advance = res.shaped.caretOffset(0);
    try std.testing.expect(advance > 0);

    // The caret walks leftwards as the logical prefix grows, by one whole
    // glyph each step, and the full prefix lands on the run's left edge.
    var prev = advance;
    var off: usize = 2;
    while (off <= txt.len) : (off += 2) {
        const x = res.shaped.caretOffset(off);
        try std.testing.expect(x < prev);
        // Each step gives back exactly one glyph's advance -- the run's
        // rightmost, since an RTL prefix grows leftwards from there.
        const g = res.shaped.line.buffer.info.items.len - off / 2;
        const entry = res.shaped.line.entryForGlyph(res.shaped.fallback, g);
        const step = @round(entry.toPixels(res.shaped.line.buffer.pos.items[g].x_advance)) / res.shaped.ss;
        try std.testing.expectApproxEqAbs(step, prev - x, 0.01);
        try std.testing.expectEqual(off, res.shaped.byteAtOffset(x));
        prev = x;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), prev, 0.01);
}
