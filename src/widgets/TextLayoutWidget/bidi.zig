const std = @import("std");
const dvui = @import("../../dvui.zig");
const opentype = @import("opentype");

const Font = dvui.Font;
const TextLayoutWidget = @import("../TextLayoutWidget.zig");
const Fragment = TextLayoutWidget.Fragment;

/// Level runs of the buffered line; see `opentype.unicode.Bidi.lineRuns`.
pub fn bidiPieces(arena: std.mem.Allocator, frags: []const Fragment, base_direction: *opentype.unicode.Bidi.ParagraphDirection) ?[]const opentype.unicode.Bidi.LineRun {
    const texts = arena.alloc([]const u8, frags.len) catch return null;
    for (frags, texts) |f, *t| t.* = f.text;
    return opentype.unicode.Bidi.lineRuns(arena, texts, base_direction) catch null;
}

/// How much of a neighbouring fragment to carry into a fragment's own
/// shaping call as context. Cursive joining and kerning reach one glyph past
/// the boundary and ligatures a couple more, so this is a cap rather than the
/// whole neighbour -- taking the whole line would make one flush O(n^2) in
/// fragment count.
/// ponytail: 32 bytes each side; raise it if a real feature ever spans more.
const neighbour_context_bytes = 32;

fn contextTail(text: []const u8) []const u8 {
    if (text.len <= neighbour_context_bytes) return text;
    var i = text.len - neighbour_context_bytes;
    while (i < text.len and text[i] & 0xc0 == 0x80) i += 1;
    return text[i..];
}

fn contextHead(text: []const u8) []const u8 {
    if (text.len <= neighbour_context_bytes) return text;
    var i: usize = neighbour_context_bytes;
    while (i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return text[0..i];
}

/// Nothing joins, ligates or kerns across whitespace, so a boundary with
/// whitespace on either side needs no context pass.
fn stickyBoundary(before: []const u8, after: []const u8) bool {
    if (before.len == 0 or after.len == 0) return false;
    return !std.ascii.isWhitespace(before[before.len - 1]) and !std.ascii.isWhitespace(after[0]);
}

/// Shaping is per addText chunk, so an Arabic word split across two chunks
/// gets no cursive joining and nothing kerns across the split. Re-shape every
/// fragment that abuts a non-whitespace boundary with its neighbours' bytes
/// as context -- their glyphs are discarded, they only get to influence this
/// fragment's -- and re-place the line, since joined forms are narrower than
/// the isolated ones the layout half measured.
pub fn reshapeWithNeighbourContext(frags: []Fragment, base_direction: opentype.unicode.Bidi.ParagraphDirection) void {
    if (frags.len < 2) return;
    const cw = dvui.currentWindow();
    const arena = cw.arena();

    var any = false;
    for (frags, 0..) |f, i| {
        // A different font is a different shaping run: its glyphs would be
        // context in the wrong typeface, and nothing joins across it anyway.
        const font_key = f.font.cacheKey();
        const before = if (i > 0 and std.meta.eql(frags[i - 1].font.cacheKey(), font_key)) contextTail(frags[i - 1].text) else "";
        const after = if (i + 1 < frags.len and std.meta.eql(frags[i + 1].font.cacheKey(), font_key)) contextHead(frags[i + 1].text) else "";
        const lead = if (stickyBoundary(before, f.text)) before else "";
        const trail = if (stickyBoundary(f.text, after)) after else "";
        if (lead.len == 0 and trail.len == 0) continue;

        const ctx = std.mem.concat(arena, u8, &.{ lead, f.text, trail }) catch continue;
        const res = f.font.textSizeExShaped(cw.gpa, cw.arena(), ctx, .{
            .item = .{ .start = lead.len, .end = lead.len + f.text.len },
            .base_direction = base_direction,
            .tab_origin = f.x,
        }) catch continue orelse continue;
        frags[i].render_shaped = res.shaped;
        frags[i].size.w = res.size.w;
        // Same rule as the layout half: a shape holding both directions is
        // only good for drawing, never for slicing by byte offset.
        if (!res.shaped.line.isMixedDirection()) frags[i].shaped = res.shaped;
        any = true;
    }
    if (!any) return;

    var x = frags[0].x;
    for (frags) |*fp| {
        fp.x = x;
        x += fp.size.w;
    }
}
/// Rule L2: walk the pieces in visual order, laying them out left to right
/// from the line's origin, and write back where each one lands. Reordering is
/// a permutation, so the line's total width doesn't change.
pub fn assignVisualX(arena: std.mem.Allocator, pieces: []const opentype.unicode.Bidi.LineRun, out: []Fragment, origin: f32) void {
    const levels = arena.alloc(u8, pieces.len) catch return;
    for (pieces, levels) |p, *l| l.* = p.level;
    const order = opentype.unicode.Bidi.reorderVisual(arena, levels) catch return;

    var x = origin;
    for (order) |pi| {
        out[pi].x = x;
        x += out[pi].size.w;
    }
}

test "reshapeWithNeighbourContext: a word split across chunks joins across the split" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const gpa = std.testing.allocator;

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    // seen+lam | alef+meem, i.e. one Arabic word handed to addText twice.
    const word = "\u{0633}\u{0644}\u{0627}\u{0645}";

    var frags: [2]Fragment = std.mem.zeroes([2]Fragment);
    frags[0].text = word[0..4];
    frags[1].text = word[4..];
    for (&frags) |*f| {
        f.font = font;
        f.size = font.textSizeEx(f.text, .{});
        f.shaped = null;
        f.render_shaped = null;
    }
    frags[0].x = 7;
    const before_width = frags[0].size.w + frags[1].size.w;

    reshapeWithNeighbourContext(&frags, .auto);

    try std.testing.expect(frags[0].render_shaped != null);
    try std.testing.expect(frags[1].render_shaped != null);
    // The line is re-placed off the new widths, so the second chunk starts
    // where the first one now ends -- not where its isolated width put it.
    try std.testing.expectEqual(@as(f32, 7), frags[0].x);
    try std.testing.expectEqual(frags[0].x + frags[0].size.w, frags[1].x);

    var alone = (try font.textSizeExShaped(dvui.currentWindow().gpa, gpa, frags[0].text, .{})).?;
    defer alone.shaped.deinit();
    // Nothing in the stack covers Arabic on this platform (every glyph is
    // .notdef): the plumbing above is all there is to check here.
    if (alone.shaped.line.buffer.info.items[0].codepoint == 0) return;

    // With the alef visible as context, seen+lam take joining forms -- a
    // different glyph sequence from the same bytes shaped on their own, which
    // is exactly what per-chunk shaping could not produce.
    const ctx_glyphs = frags[0].render_shaped.?.line.buffer.info.items;
    const alone_glyphs = alone.shaped.line.buffer.info.items;
    var same = ctx_glyphs.len == alone_glyphs.len;
    if (same) {
        for (ctx_glyphs, alone_glyphs) |a, b| {
            if (a.codepoint != b.codepoint) same = false;
        }
    }
    try std.testing.expect(!same);
    // Joined forms are narrower than isolated ones.
    try std.testing.expect(frags[0].size.w + frags[1].size.w < before_width);
}

test "stickyBoundary: only a boundary that could join or kern pays for a reshape" {
    try std.testing.expect(stickyBoundary("foo", "bar"));
    try std.testing.expect(!stickyBoundary("foo ", "bar"));
    try std.testing.expect(!stickyBoundary("foo", " bar"));
    try std.testing.expect(!stickyBoundary("", "bar"));
    // Cut on a codepoint boundary, never mid-sequence.
    const long = "x" ** 40 ++ "\u{0633}\u{0644}";
    try std.testing.expect(std.unicode.utf8ValidateSlice(contextTail(long)));
    try std.testing.expect(std.unicode.utf8ValidateSlice(contextHead(long)));
    try std.testing.expectEqual(@as(usize, neighbour_context_bytes), contextHead(long).len);
}
test "assignVisualX: the logically-first chunk lands rightmost" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var frags: [2]Fragment = undefined;
    frags[0].text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    frags[1].text = " world";
    var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
    const pieces = bidiPieces(arena, &frags, &dir) orelse return error.TestExpectedPieces;

    // Stand-in widths: Hebrew 40, space 5, "world" 50.
    var out: [3]Fragment = undefined;
    const widths = [_]f32{ 40, 5, 50 };
    for (&out, widths) |*o, w| o.size = .{ .w = w, .h = 10 };

    assignVisualX(arena, pieces, &out, 0);

    // "world" first, then the space, then the Hebrew: 0, 50, 55.
    try std.testing.expectEqual(@as(f32, 55), out[0].x);
    try std.testing.expectEqual(@as(f32, 50), out[1].x);
    try std.testing.expectEqual(@as(f32, 0), out[2].x);
}
