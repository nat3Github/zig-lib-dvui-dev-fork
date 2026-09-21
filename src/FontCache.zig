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

const LineCache = opentype.line_cache.Cache(Font.CacheKey);

pub const ShapedLine = opentype.ShapedLine;

const FamilyAliases = opentype.FamilyAliases(Font, FamilyEntry);

pub const max_alias_depth = FamilyAliases.max_depth;
pub const max_alias_expansions = FamilyAliases.max_expansions;
pub const max_stack_families = FamilyAliases.max_families;

database: std.ArrayList(Source) = .empty,
cache: dvui.TrackingAutoHashMap(Font.CacheKey, *Entry, .get_and_put, void) = .empty,
resolved_stacks: dvui.TrackingAutoHashMap(Font.CacheKey, *ResolvedStack, .get_and_put, void) = .empty,
coverage_cache: opentype.CoverageCache = .{},
line_cache: LineCache = .{},
dynamic_fallback: std.AutoHashMapUnmanaged(u21, ?Font) = .empty,
fallback_language: ?[]const u8 = null,
web_fallback: if (web_fallback_enabled) ?WebFallback else void = if (web_fallback_enabled) null else {},
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

    for (self.database.items) |*source| source.deinit();
    self.database.deinit(gpa);
    self.dynamic_fallback.deinit(gpa);
    if (web_fallback_enabled) {
        if (self.web_fallback) |*service| service.deinit(gpa);
    }

    self.family_aliases.deinit(gpa);
}

pub fn addFamily(self: *Cache, gpa: std.mem.Allocator, alias: []const u8, names: []const []const u8) std.mem.Allocator.Error!void {
    const list = try gpa.alloc(FamilyEntry, names.len);
    defer gpa.free(list);
    for (names, list) |n, *dst| dst.* = .{ .family = array(n) };
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
    var eit = self.cache.iterator();
    while (eit.next_peek()) |kv| kv.value.clearAtlasIfOversized(gpa);
    self.evictUnreferencedFontBytes(gpa);
}

const evict_after_unreferenced_resets = 600;

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
        self.line_cache.clearPlans(gpa);
        source.releaseBytes();
    }
}

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

const max_family_variants = 64;

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
        const path = source.path orelse return .{ null, null };
        if (system_font_backend == null) return .{ null, null };
        const mm = mapFaceFile(path) orelse return .{ null, null };
        source.memory_map = mm;
        source.bytes = mm.memory;
    }

    if (source.weight.value == font.weight.value and source.style == font.style and source.stretch.value == font.stretch.value) {
        return .{ source.*, null };
    }
    return .{ null, source.* };
}

fn resolveSource(self: *Cache, state_gpa: std.mem.Allocator, raw_font: Font) std.mem.Allocator.Error!Source {
    const font = self.family_aliases.firstFamily(raw_font);
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

    const boxed = try state_gpa.create(Entry);
    errdefer state_gpa.destroy(boxed);
    boxed.* = Entry.init(state_gpa, &source, font) catch |err| blk: {
        dvui.log.err("Font {s} init got {any}, using fallback", .{ fname, err });
        break :blk Entry.init(state_gpa, &Source.fallback, font) catch return error.OutOfMemory;
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
        raw_fonts[count] = Entry.parseFontOrCollection(state_gpa, source.bytes, source.collection_index) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => Entry.parseFontOrCollection(state_gpa, Source.fallback.bytes, Source.fallback.collection_index) catch |e2| switch (e2) {
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
    if (system_font_backend == null) return null;
    if (self.dynamic_fallback.get(codepoint)) |cached| return cached;
    const found = self.loadDynamicFallback(state_gpa, codepoint);
    self.dynamic_fallback.put(state_gpa, codepoint, found) catch {};
    return found;
}

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

pub fn webFallbackLoaded(self: *Cache, gpa: std.mem.Allocator, font: u16, bytes: []u8) void {
    if (!web_fallback_enabled) return gpa.free(bytes);
    const service = if (self.web_fallback) |*s| s else return gpa.free(bytes);
    if (!isKnownWebFallbackFont(service, font)) return gpa.free(bytes);
    const parsed = Entry.parseFontOrCollection(gpa, bytes, 0) catch {
        gpa.free(bytes);
        return service.fontFailed(gpa, font);
    };
    gpa.free(parsed.table_records);
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
    self.line_cache.clear(gpa);
}

pub fn setWebFallback(self: *Cache, gpa: std.mem.Allocator, options: WebFallbackOptions) void {
    if (!web_fallback_enabled) return;
    if (self.web_fallback) |*service| service.deinit(gpa);
    self.web_fallback = if (options.enabled) .{ .base_url = options.base_url } else null;
    self.line_cache.clear(gpa);
}

pub fn webFallbackFailed(self: *Cache, gpa: std.mem.Allocator, font: u16) void {
    if (!web_fallback_enabled) return;
    const service = if (self.web_fallback) |*s| s else return;
    if (isKnownWebFallbackFont(service, font)) service.fontFailed(gpa, font);
}

fn isKnownWebFallbackFont(service: *const WebFallback, font: u16) bool {
    return service.tables != null and font < service.set.fonts.len;
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

pub fn shapeLineText(self: *Cache, output: std.mem.Allocator, state_gpa: std.mem.Allocator, resolved: *ResolvedStack, text: []const u8, item: ?Font.ShapeItem, base_direction: opentype.unicode.Bidi.ParagraphDirection, style: Font.ShapeStyle) std.mem.Allocator.Error!ShapedText {
    var discovered: std.ArrayList(LineProvider.Discovered) = .empty;
    defer discovered.deinit(output);
    const provider: LineProvider = .{ .cache = self, .resolved = resolved, .discovered = &discovered, .output = output };

    var result = self.line_cache.shapeLine(
        output,
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
        var shaped = try self.shapeLineText(output, state_gpa, resolved, text[0..window], opts.item, opts.base_direction, style);
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

    fn measuredCapHeight(renderer: *Renderer, glyph_id: u16) ?f32 {
        const bounds = renderer.glyphBounds(glyph_id, .{}, dvui.currentWindow().lifo()) catch return null;
        if (bounds.rows == 0) return null;
        return @floatFromInt(bounds.rows);
    }

    fn loadSbixStrike(gpa: std.mem.Allocator, source: *const Source, ppem: f32) ?[]const u8 {
        if (system_font_backend == null) return null;
        const path = source.path orelse return null;
        const file = std.Io.Dir.cwd().openFile(dvui.io, path, .{}) catch return null;
        defer file.close(dvui.io);
        const rounded: u16 = @intFromFloat(std.math.clamp(@round(ppem), 1, std.math.maxInt(u16)));
        return opentype.parsing.Font.readSbixStrike(gpa, dvui.io, file, source.collection_index, rounded) catch null;
    }

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

        const sbix_strike = if (parsed_font.tableData(.{ 's', 'b', 'i', 'x' }) != null)
            null
        else
            loadSbixStrike(gpa, source, ppem);
        errdefer if (sbix_strike) |strike| gpa.free(strike);
        if (sbix_strike) |strike| renderer.sbix_data = strike;

        const units_per_em_f: f32 = @floatFromInt(renderer.head.units_per_em);

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
            const new_height = @max(needed_height, self.atlas_alloc_height * 2);
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
};
test "Cache.buildCoverage: earlier stack entries win overlapping coverage" {
    const gpa = std.testing.allocator;
    const Range = Cmap.Range;

    const entry0 = [_]Range{ .{ .start = 0x20, .end = 0xFF }, .{ .start = 0x4E00, .end = 0x4E10 } };
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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const stack: Font = .init("TestStack");
    const resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    try std.testing.expectEqual(@as(?*Cache.Entry, null), cw.fonts.stackEntry(resolved, 1));

    var line = try cw.fonts.shapeLineText(std.testing.allocator, std.testing.allocator, resolved, "AB\u{AC00}\u{AC01}CD", null, .auto, .{});
    defer line.deinit();

    const latin_entry = cw.fonts.stackEntry(resolved, 0).?;
    const korean_entry = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expect(latin_entry != korean_entry);

    try std.testing.expectEqual(@as(usize, 3), line.line.segments.len);
    try std.testing.expectEqual(latin_entry, line.entries[line.line.segments[0].font_index]);
    try std.testing.expectEqual(korean_entry, line.entries[line.line.segments[1].font_index]);
    try std.testing.expectEqual(latin_entry, line.entries[line.line.segments[2].font_index]);

    try std.testing.expectEqual(@as(u32, 0), line.line.segments[0].glyph_start);
    try std.testing.expectEqual(line.line.segments[1].glyph_start, line.line.segments[0].glyph_end);
    try std.testing.expectEqual(line.line.segments[2].glyph_start, line.line.segments[1].glyph_end);
    try std.testing.expectEqual(@as(u32, @intCast(line.line.buffer.info.items.len)), line.line.segments[2].glyph_end);

    for (0..line.line.buffer.info.items.len) |gidx| {
        const expected = line.entryForGlyph(latin_entry, gidx);
        if (gidx < line.line.segments[0].glyph_end) {
            try std.testing.expectEqual(latin_entry, expected);
        } else if (gidx < line.line.segments[1].glyph_end) {
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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

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

    const flattened = cw.fonts.family_aliases.flatten(Font.init("TestCycleA"));
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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestTop", &.{ "TestLeft", "TestRight" });
    try dvui.addFontFamily("TestLeft", &.{ "TestLatin", "TestKorean" });
    try dvui.addFontFamily("TestRight", &.{ "TestKorean", "TestLatin" });

    const resolved = try cw.fonts.resolveStack(cw.gpa, Font.init("TestTop"));
    try std.testing.expectEqual(@as(usize, 2), resolved.family_fonts.len);
    try std.testing.expectEqualStrings("TestLatin", resolved.family_fonts[0].familyName());
    try std.testing.expectEqualStrings("TestKorean", resolved.family_fonts[1].familyName());
}

fn expectSameShapedLine(expected: Cache.ShapedLine, actual: Cache.ShapedLine) !void {
    try std.testing.expectEqualSlices(u21, expected.codepoints, actual.codepoints);
    try std.testing.expectEqualSlices(u32, expected.byte_offsets, actual.byte_offsets);
    try std.testing.expectEqualSlices(u32, expected.cluster_starts, actual.cluster_starts);
    try std.testing.expectEqualSlices(u32, expected.cluster_ends, actual.cluster_ends);
    try std.testing.expectEqualSlices(Cache.ShapedLine.Segment, expected.segments, actual.segments);
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
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });
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
        const count = cw.fonts.line_cache.count();
        var hit = try cw.fonts.shapeLineText(gpa, cw.gpa, resolved, case.text, case.item, case.direction, case.style);
        defer hit.deinit();
        try std.testing.expectEqual(count, cw.fonts.line_cache.count());
        try expectSameShapedLine(fresh.line, hit.line);
        try std.testing.expectEqualSlices(*Entry, fresh.entries, hit.entries);
    }
}

test "Cache.shapeLineText: a shaped_line_cache hit reshapes instead of dropping segments when a fallback font was evicted by reset()" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    try dvui.addFont("TestLatin", Source.fallback.bytes, null);
    const cw = dvui.currentWindow();
    try cw.fonts.database.append(cw.gpa, .{ .family = array("TestKorean"), .bytes = @embedFile("fonts/NotoSansKR-Regular.ttf") });

    try dvui.addFontFamily("TestStack", &.{ "TestLatin", "TestKorean" });
    const stack: Font = .init("TestStack");
    var resolved = try cw.fonts.resolveStack(cw.gpa, stack);
    const text = "AB\u{AC00}\u{AC01}CD";

    var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto, .{});
    defer line.deinit();
    try std.testing.expectEqual(@as(usize, 3), line.line.segments.len);
    const korean_key = resolved.entry_keys[1];

    // Korean fragment scrolls out of view: unused for two resets, so evicted.
    cw.fonts.reset(cw.gpa, cw.backend);
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expect(cw.fonts.cache.getPtr(korean_key) == null);

    // The stack was evicted with it; a later frame resolves it anew.
    resolved = try cw.fonts.resolveStack(cw.gpa, stack);

    // Back in view: the cached line points at the evicted entry, so it must reshape.
    var line2 = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, resolved, text, null, .auto, .{});
    defer line2.deinit();
    try std.testing.expectEqual(@as(usize, 3), line2.line.segments.len);

    const korean_entry_after = cw.fonts.stackEntry(resolved, 1).?;
    try std.testing.expectEqual(korean_entry_after, line2.entries[line2.line.segments[1].font_index]);
}

test "Cache.reset: keeps a resolved stack used since the last reset, evicts it one reset later" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    for (1..50) |size| _ = try cw.fonts.resolveStack(cw.gpa, Font.init("Vera").withSize(@floatFromInt(size)));
    const key = Font.init("Vera").withSize(7).cacheKey();

    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expect(cw.fonts.resolved_stacks.containsUsed(key) != null);

    _ = try cw.fonts.resolveStack(cw.gpa, Font.init("Vera").withSize(7));
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expect(cw.fonts.resolved_stacks.containsUsed(key) != null);
    try std.testing.expectEqual(@as(usize, 1), cw.fonts.resolved_stacks.count());

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

test "Cache.reset: keeps a shaped line used since the last reset, evicts it one reset later" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const cw = dvui.currentWindow();
    var line = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, try cw.fonts.resolveStack(cw.gpa, Font.init("Vera")), "abc", null, .auto, .{});
    line.deinit();
    try std.testing.expectEqual(@as(usize, 1), cw.fonts.line_cache.count());

    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 1), cw.fonts.line_cache.count());

    var again = try cw.fonts.shapeLineText(std.testing.allocator, cw.gpa, try cw.fonts.resolveStack(cw.gpa, Font.init("Vera")), "abc", null, .auto, .{});
    again.deinit();
    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 1), cw.fonts.line_cache.count());

    cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.line_cache.count());
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.line_cache.bytes);
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
    for (0..Cache.evict_after_unreferenced_resets - 1) |_| cw.fonts.reset(cw.gpa, cw.backend);
    try std.testing.expect(source.bytes.len > 0);
    cw.fonts.reset(cw.gpa, cw.backend);
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

    // macOS may offer an `hvgl`-only PingFang face (no glyf/CFF) for Chinese.
    // A fallback must have real outlines; otherwise render notdef.
    const text = "这是一个中文测试句子。";
    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, text, null, .auto, .{});
    defer line.deinit();

    for (line.line.segments) |seg| {
        const entry = line.entries[seg.font_index];
        const has_outlines = entry.parsed_font.tableData(.{ 'g', 'l', 'y', 'f' }) != null or
            entry.parsed_font.tableData(.{ 'C', 'F', 'F', ' ' }) != null or
            entry.parsed_font.tableData(.{ 'C', 'F', 'F', '2' }) != null;
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

    // CJK followed by an emoji, both uncovered by TestLatin: each needs its
    // own fallback font, and the emoji must not ride along in the CJK run.
    const text = "\u{4E2D}\u{6587}\u{1F600}";
    var line = try cw.fonts.shapeLineText(gpa, gpa, resolved, text, null, .auto, .{});
    defer line.deinit();

    if (line.line.segments.len < 2) return error.SkipZigTest; // no dynamic fallback available in this environment

    // CJK may legitimately have no usable fallback (hvgl-only), so only
    // glyphs shaped against a fallback font must be non-notdef.
    const primary = cw.fonts.stackEntry(resolved, 0).?;
    for (line.line.buffer.info.items, 0..) |info, gidx| {
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

    cw.fonts.webFallbackLoaded(cw.gpa, font, try cw.gpa.dupe(u8, @embedFile("fonts/NotoSansKR-Regular.ttf")));
    const arrived = cw.fonts.webFallbackFont(cw.gpa, 0xAC00).?;
    try std.testing.expect(cw.fonts.findSource(arrived).@"0" != null);
    try std.testing.expectEqual(@as(usize, 0), cw.fonts.line_cache.count());
}
