const std = @import("std");
const dvui = @import("../../dvui.zig");
const opentype = @import("opentype");

const Font = dvui.Font;
const Options = dvui.Options;
const Point = dvui.Point;

const TextLayoutWidget = @import("../TextLayoutWidget.zig");
const Fragment = TextLayoutWidget.Fragment;
const Selection = TextLayoutWidget.Selection;
const bidi = @import("bidi.zig");

pub const PointHit = struct { byte: usize, affinity: Selection.Affinity = .after };

/// Byte a point inside `f` lands on. An RTL run's logical prefix grows
/// leftwards from its right edge, so the width is measured from there --
/// otherwise clicking the visually-first letter of an Arabic or Hebrew word
/// lands on the last byte of it.
fn hitWithin(f: Fragment, p: Point) PointHit {
    // Hit-tested against the already-shaped line's pen positions, the same
    // places `fragCaretX` puts the caret, so a click and the caret it leaves
    // behind agree. The reshape below is the last resort for a fragment that
    // never got shaped, and can only measure widths.
    var pt_end: usize = undefined;
    if (f.shaped) |shaped| {
        var st = shaped;
        // A shape can cover more text than the fragment does (an LTR one is
        // only required to *start* with it), so its far stops are not this
        // fragment's to hand out.
        pt_end = @min(st.byteAtOffset(p.x - f.x), f.text.len);
    } else {
        const how_far = if (f.rtl) (f.x + f.size.w) - p.x else p.x - f.x;
        _ = f.font.textSizeEx(f.text, .{ .max_width = how_far, .end_idx = &pt_end, .end_metric = .nearest });
    }
    // Landing on the run's logical end is the far side of a level-run
    // boundary: `.before` keeps the caret there instead of letting the
    // logically-next run claim the byte and draw it elsewhere on the line.
    return .{ .byte = f.bytes_seen + pt_end, .affinity = if (pt_end == f.text.len) .before else .after };
}

/// Which fragment of one buffered line answers a hit-test point, and where on
/// it the point lands. `frags` is in logical order but rule L2 permutes the
/// line on screen, so the scan runs across it by `x` -- the coordinate the
/// reorder wrote -- rather than walking the text the way the caller supplied
/// it. `line_end` answers a point past the far edge of the line: that is the
/// logical end of an LTR line and the logical start of an RTL one.
fn hitLine(frags: []const Fragment, p: Point, line_end: usize) ?struct { index: usize, hit: PointHit } {
    if (frags.len == 0) return null;
    // Above the line there is no x to read, so the answer is where the line
    // starts in the text, not where it starts on screen.
    if (p.y < frags[0].y) return .{ .index = 0, .hit = .{ .byte = frags[0].bytes_seen } };

    var before: ?usize = null;
    var past_end: ?usize = null;
    for (frags, 0..) |f, i| {
        if (p.y >= f.y + f.size.h) continue;
        if (p.x < f.x) {
            if (before == null or f.x < frags[before.?].x) before = i;
        } else if (p.x < f.x + f.size.w) {
            return .{ .index = i, .hit = hitWithin(f, p) };
        } else if (f.newline) {
            past_end = i;
        }
    }
    if (before) |i| {
        const f = frags[i];
        return .{ .index = i, .hit = .{ .byte = if (f.rtl) f.bytes_seen + f.text.len else f.bytes_seen } };
    }
    // Without a hard break the line ends because it wrapped, and `lineBreak`
    // answers that once the pen has moved on.
    if (past_end) |i| return .{ .index = i, .hit = .{ .byte = line_end } };
    return null;
}

/// Far-right byte of the line: the logical end when it reads left to right,
/// the logical start when it reads right to left.
pub fn lineEndByte(frags: []const Fragment) usize {
    var last = frags[0];
    for (frags) |f| {
        if (f.x + f.size.w > last.x + last.size.w) last = f;
    }
    if (last.rtl) return last.bytes_seen;
    return last.bytes_seen + last.text.len - Font.trailingHardBreakLen(last.text);
}

/// One place the caret can sit on the placed line, and where that is on
/// screen. `rtl` is the direction of the run it belongs to, which is what
/// decides where the caret goes when a step runs off the end of the line.
const CaretStop = struct {
    x: f32,
    byte: usize,
    affinity: Selection.Affinity,
    rtl: bool,
    frag: usize,
};

/// Every caret position on the placed line, ordered left to right on screen.
/// Built from the same reordered fragments `hitLine` walks, so a keyboard
/// step and a mouse click agree about which byte lives where.
/// ponytail: quadratic -- every stop re-measures its fragment's prefix from
/// the start. One line, one keypress; measure before caching anything.
fn visualStops(self: *TextLayoutWidget, arena: std.mem.Allocator) []const CaretStop {
    var stops: std.ArrayList(CaretStop) = .empty;
    for (self.line_frags.items, 0..) |f, frag| {
        // A trailing hard break is not a caret position of its own: the
        // caret past it belongs to the next line, which this walk can't see.
        const text = f.text[0 .. f.text.len - Font.trailingHardBreakLen(f.text)];
        var off: usize = 0;
        while (true) {
            stops.append(arena, .{
                .x = fragCaretX(f, off),
                .byte = f.bytes_seen + off,
                .affinity = if (off == text.len) .before else .after,
                .rtl = f.rtl,
                .frag = frag,
            }) catch break;
            if (off >= text.len) break;
            off = opentype.unicode.nextGraphemeBoundary(text, off);
        }
    }
    std.mem.sort(CaretStop, stops.items, {}, struct {
        fn lessThan(_: void, a: CaretStop, b: CaretStop) bool {
            return a.x < b.x;
        }
    }.lessThan);

    // Two fragments meeting inside one level run (an addText chunk boundary,
    // a highlight span) both name that byte at the same x. That is one caret
    // position, and leaving both in would eat a keypress moving nowhere --
    // unlike a level-run boundary, where the same byte has two real homes at
    // two different x.
    var kept: usize = 0;
    for (stops.items) |st| {
        if (kept > 0) {
            const prev = &stops.items[kept - 1];
            if (prev.byte == st.byte and @abs(prev.x - st.x) < 0.01) {
                if (st.affinity == .after) prev.* = st;
                continue;
            }
        }
        stops.items[kept] = st;
        kept += 1;
    }
    return stops.items[0..kept];
}

/// Which stop the caret is at. A level-run boundary is two stops sharing a
/// byte at two different x, so affinity picks between them; a stale affinity
/// still finds the byte.
fn stopIndex(stops: []const CaretStop, byte: usize, affinity: Selection.Affinity) ?usize {
    var by_byte: ?usize = null;
    for (stops, 0..) |st, i| {
        if (st.byte != byte) continue;
        if (st.affinity == affinity) return i;
        by_byte = by_byte orelse i;
    }
    return by_byte;
}

/// The neighbouring stop that sits somewhere else on screen. Where two level
/// runs meet, two different bytes are drawn at one x (the end of "abc" and
/// the logical end of the RTL run after it); stepping between them would eat
/// a keypress that moves nothing. Of the bytes sharing the x it lands on, it
/// keeps to the fragment it is leaving, so a selection grows by exactly the
/// text the caret passed over.
fn nextVisualStop(stops: []const CaretStop, from: usize, right: bool) ?usize {
    var found: ?usize = null;
    var i = from;
    while (true) {
        if (right) {
            if (i + 1 >= stops.len) return found;
            i += 1;
        } else {
            if (i == 0) return found;
            i -= 1;
        }
        if (found) |f| {
            if (@abs(stops[i].x - stops[f].x) >= 0.01) return f;
            if (stops[i].frag == stops[from].frag) return i;
        } else if (@abs(stops[i].x - stops[from].x) >= 0.01) {
            if (stops[i].frag == stops[from].frag) return i;
            found = i;
        }
    }
}

/// Steps the caret across the placed line in visual order, consuming `clr`'s
/// count. What is left when the caret reaches the edge of the line is handed
/// back as a *logical* count -- flipped when that edge belongs to an RTL run,
/// since there one step further right is one step earlier in the text.
pub fn charVisualMove(self: *TextLayoutWidget, clr: *@FieldType(@TypeOf(self.sel_move), "char_left_right")) void {
    if (clr.count == 0 or self.line_frags.items.len == 0) return;
    const stops = visualStops(self, dvui.currentWindow().arena());
    var idx = stopIndex(stops, self.selection.cursor, self.selection.affinity) orelse return;

    var moved = false;
    while (clr.count != 0) {
        const right = clr.count > 0;
        idx = nextVisualStop(stops, idx, right) orelse break;
        self.selection.moveCursor(stops[idx].byte, clr.select);
        self.selection.affinity = stops[idx].affinity;
        clr.count -= if (right) 1 else -1;
        moved = true;
    }

    if (moved) {
        // ponytail: a count that outran the line after a step that landed is
        // dropped rather than resumed on the neighbouring line -- it takes
        // two steps in one frame to reach, and key repeat brings the rest.
        clr.count = 0;
        self.scroll_to_cursor_next_frame = true;
        dvui.refresh(null, @src(), self.data().id);
    } else {
        var line_first: usize = std.math.maxInt(usize);
        var line_last: usize = 0;
        for (self.line_frags.items) |f| {
            line_first = @min(line_first, f.bytes_seen);
            line_last = @max(line_last, f.bytes_seen + f.text.len - Font.trailingHardBreakLen(f.text));
        }
        const edge = stops[idx].byte;
        if (edge != line_first and edge != line_last) {
            // ponytail: the edge of a mixed-direction line can sit mid-text
            // ("abc مرحبا" ends visually at the Arabic's first byte), where
            // a logical step would jump back into this line; stop instead.
            // Continuing onto the next line from there needs the next line.
            clr.count = 0;
        } else if (stops[idx].rtl) {
            clr.count = -clr.count;
        }
    }
}

/// The hit for `p` if the fragment at `index` is the one that owns it. The
/// whole line is rescanned per point per fragment; a line holds a handful of
/// fragments, so caching the answers is not worth the state.
pub fn hitHere(self: *TextLayoutWidget, p: Point, index: usize) ?PointHit {
    const found = hitLine(self.line_frags.items, p, self.line_end_byte orelse self.bytes_seen) orelse return null;
    return if (found.index == index) found.hit else null;
}

/// Where the caret sits after `prefix_w` of the fragment's *logical* text.
/// In an RTL run that prefix is laid out from the right edge, so the caret
/// walks leftwards -- which is what makes the two sides of a level-run
/// boundary two distinct screen positions rather than one.
fn caretX(f: Fragment, prefix_w: f32) f32 {
    return if (f.rtl) f.x + f.size.w - prefix_w else f.x + prefix_w;
}

/// Where the caret sits after `off` logical bytes of the fragment. Reads the
/// shape's pen positions, so it lands exactly on a glyph boundary
/// `renderText` drew at; a width-derived x drifts into the glyphs, because
/// `f.size.w` and a prefix width are both ink boxes and neither is additive.
pub fn fragCaretX(f: Fragment, off: usize) f32 {
    if (f.shaped) |shaped| {
        var st = shaped;
        return f.x + st.caretOffset(off);
    }
    return caretX(f, f.font.textSize(f.text[0..off]).w);
}

test "caretX/hitWithin: the two sides of a level-run boundary are two places" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    var f: Fragment = std.mem.zeroes(Fragment);
    f.x = 10;
    f.size = .{ .w = 50, .h = 12 };
    try std.testing.expectEqual(@as(f32, 10), caretX(f, 0));
    try std.testing.expectEqual(@as(f32, 60), caretX(f, 50));

    f.rtl = true;
    // Byte 0 of an RTL run is at its right edge and its last byte at the
    // left, so a cursor on the far side of a run boundary is drawn somewhere
    // else entirely from one on the near side.
    try std.testing.expectEqual(@as(f32, 60), caretX(f, 0));
    try std.testing.expectEqual(@as(f32, 10), caretX(f, 50));

    const txt = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    const opts: Options = .{};
    var g: Fragment = std.mem.zeroes(Fragment);
    g.text = txt;
    g.font = opts.fontGet();
    g.options = opts;
    g.size = .{ .w = opts.fontGet().textSizeEx(txt, .{}).w, .h = 12 };
    g.rtl = true;

    // Just inside the right edge: the logically-first byte.
    try std.testing.expectEqual(@as(usize, 0), hitWithin(g, .{ .x = g.size.w - 1, .y = 1 }).byte);

    // At the left edge: the logical end, and `.before` so the caret stays on
    // this run instead of the logically-next one claiming the byte.
    const last = hitWithin(g, .{ .x = 0.5, .y = 1 });
    try std.testing.expectEqual(txt.len, last.byte);
    try std.testing.expectEqual(Selection.Affinity.before, last.affinity);

    // Same click, read as LTR, lands on the opposite end -- what it used to do.
    g.rtl = false;
    try std.testing.expectEqual(@as(usize, 0), hitWithin(g, .{ .x = 0.5, .y = 1 }).byte);
}

test "hitLine: a click resolves against the reordered line, not logical order" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts: Options = .{};
    // Two Hebrew fragments (a style change mid-sentence): both level 1, so
    // L2 swaps them and logical order stops matching visual order.
    var frags: [2]Fragment = std.mem.zeroes([2]Fragment);
    frags[0].text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    frags[1].text = "\u{05e2}\u{05d5}\u{05dc}\u{05dd}";
    for (&frags, 0..) |*f, i| {
        f.options = opts;
        f.font = opts.fontGet();
        f.size = opts.fontGet().textSizeEx(f.text, .{});
        f.bytes_seen = if (i == 0) 0 else frags[0].text.len;
    }

    var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
    const pieces = bidi.bidiPieces(arena, &frags, &dir) orelse return error.TestExpectedPieces;
    try std.testing.expectEqual(@as(usize, 2), pieces.len);

    var out: [2]Fragment = frags;
    for (&out, pieces) |*f, p| f.rtl = p.level % 2 == 1;
    bidi.assignVisualX(arena, pieces, &out, 0);

    // L2 put the logically-first fragment on the right.
    try std.testing.expect(out[0].x > out[1].x);

    // A click in the middle of the visually-left run belongs to frags[1],
    // even though a logical scan reaches frags[0] first.
    const p: Point = .{ .x = out[1].x + out[1].size.w / 2, .y = 1 };
    const found = hitLine(&out, p, lineEndByte(&out)) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(@as(usize, 1), found.index);
    try std.testing.expect(found.hit.byte > frags[0].text.len);
    try std.testing.expect(found.hit.byte < frags[0].text.len + frags[1].text.len);

    // Right of an RTL line is where it starts reading, so the far edge is
    // byte 0 -- not the end of the text.
    try std.testing.expectEqual(@as(usize, 0), lineEndByte(&out));
    const past: Point = .{ .x = out[0].x + out[0].size.w + 10, .y = 1 };
    try std.testing.expect(hitLine(&out, past, lineEndByte(&out)) == null);

    // Left of it is the logical end.
    const left = hitLine(&out, .{ .x = -5, .y = 1 }, lineEndByte(&out)) orelse return error.TestExpectedHit;
    try std.testing.expectEqual(frags[0].text.len + frags[1].text.len, left.hit.byte);
}

test "visualStops: fragments meeting inside one run share a caret position" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        // Copied out of the frame arena, which is gone once `settle` returns.
        var bytes_buf: [16]usize = undefined;
        var bytes: []usize = &.{};

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            const arena = dvui.currentWindow().arena();
            const font: Font = .find(.{ .family = "Vera", .size = 16 });

            var frags: [2]Fragment = std.mem.zeroes([2]Fragment);
            frags[0].text = "hel";
            frags[1].text = "lo";
            frags[1].bytes_seen = 3;
            var x: f32 = 0;
            for (&frags) |*f| {
                f.font = font;
                f.size = font.textSizeEx(f.text, .{});
                f.x = x;
                x += f.size.w;
            }
            tl.line_frags.appendSlice(arena, &frags) catch {};

            const stops = visualStops(tl, arena);
            const n = @min(stops.len, bytes_buf.len);
            for (stops[0..n], bytes_buf[0..n]) |st, *b| b.* = st.byte;
            bytes = bytes_buf[0..n];

            tl.line_frags.clearRetainingCapacity();
            tl.addTextDone(.{});
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, fns.bytes);
}
