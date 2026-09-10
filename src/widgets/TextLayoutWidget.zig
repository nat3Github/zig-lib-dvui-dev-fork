const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("../dvui.zig");
const opentype = @import("opentype");

const Event = dvui.Event;
const Font = dvui.Font;
const Options = dvui.Options;
const Point = dvui.Point;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const FloatingWidget = dvui.FloatingWidget;
const AccessKit = dvui.AccessKit;

const LineBreakStrictness = opentype.LineBreakStrictness;
const WordBreakMode = opentype.WordBreakMode;

const TextLayoutWidget = @This();

/// When break_lines is true, you can't get both a min width and min height,
/// since the width will affect the height.  In this case, min width will be as
/// if break_lines was false, and min_height will be the height needed at the
/// current width.
///
/// In many cases on our first frame we have a width of zero, which would make
/// min height very large, so instead we assume we will get our min width (or
/// 500 if our min width is zero).
pub var defaults: Options = .{
    .name = "TextLayout",
    .role = .group,
    .padding = Rect.all(6),
    .background = true,
    .style = .content,
};

pub const OverflowWrap = enum { normal, anywhere };

pub const InitOptions = struct {
    selection: ?*Selection = null,

    /// If true, break text on space to fit (or any character if width is < 10 Ms)
    break_lines: bool = true,

    /// CSS `line-break`: how strictly to allow breaks around punctuation,
    /// small kana, etc. `.strict` is the untailored UAX #14 default;
    /// `.normal`/`.loose` add more opportunities. See `LineBreakStrictness`.
    line_break: LineBreakStrictness = .strict,

    /// CSS `word-break`: `.normal` is customary UAX #14, `.break_all` allows
    /// breaks between any two letters (CJK-style), `.keep_all` forbids breaks
    /// between letters (keeping runs whole, dictionary breaks still apply).
    word_break: WordBreakMode = .normal,

    /// CSS `overflow-wrap`. `.anywhere` (default, dvui's existing behavior)
    /// breaks an over-long word at a character boundary so it never exceeds
    /// the line; `.normal` lets such a word overflow instead of breaking it
    /// mid-word.
    overflow_wrap: OverflowWrap = .anywhere,

    /// If true, assume text (and text height) is the same as we saw last frame
    /// and only process what is needed for visibility (and copy).
    cache_layout: bool = false,

    /// Whether to enter touch editing mode on a touch-release (no drag) if we
    /// were not focused before the touch.
    touch_edit_just_focused: bool = true,

    focused: ?bool = null,
    show_touch_draggables: bool = true,

    process_events_in_deinit: bool = true,

    /// Paragraph base direction (UAX #9 P2/P3). `.auto` resolves per
    /// paragraph from its first strong character, so an empty line, a
    /// neutral-only line or an LTR-leading line all read left to right --
    /// wrong when the surrounding UI is RTL. Set it to pin the direction.
    base_direction: opentype.unicode.Bidi.ParagraphDirection = .auto,
};

pub const Selection = struct {
    const Affinity = enum {
        before,
        after,
    };

    cursor: usize = 0,
    start: usize = 0,
    end: usize = 0,

    // if the characters on either side of cursor are split across lines:
    // - before means cursor is logically at the end of the first char
    // - after means the cursor is logically at the beginning of the second char
    affinity: Affinity = .after,

    pub fn empty(self: *Selection) bool {
        return self.start == self.end;
    }

    pub fn selectAll(self: *Selection) void {
        self.start = 0;
        self.cursor = 0;
        self.end = std.math.maxInt(usize);
    }

    pub fn moveCursor(self: *Selection, idx: usize, select: bool) void {
        //std.debug.print("moveCursor {d} {}\n", .{ idx, select });
        self.affinity = .after;
        if (select) {
            if (self.cursor == self.start) {
                // move the start
                self.cursor = idx;
                self.start = idx;
            } else {
                // move the end
                self.cursor = idx;
                self.end = idx;
            }
        } else {
            // removing any selection
            self.cursor = idx;
            self.start = idx;
            self.end = idx;
        }

        self.order();
    }

    pub fn order(self: *Selection) void {
        if (self.end < self.start) {
            const tmp = self.start;
            self.start = self.end;
            self.end = tmp;
        }
    }
};

// Text selection information for accesskit.
const TextRunSelectionInfo = struct {
    node_id: dvui.Id,
    /// AccessKit character index within that run's text.
    pos: usize,
};

// Used to record from last frame lines where we need to start with extra
// vertical space, because text later in the line has a larger ascent than
// earlier in the line.
const LineAscent = struct {
    line: usize,
    ascent: f32,
};

/// This is used for word selection - 2 clicks and ctrl+left/right - everything
/// here is not a word, and everything else is.
pub const word_breaks = " \n!\"#$%&()*+,-./:;<=>?@[\\]^_`{|}~";

wd: WidgetData,
corners: [4]?Rect = @splat(null),
corners_min_size: [4]?Size = @splat(null),
corners_last_seen: ?u8 = null,
insert_pt: Point = Point{},
current_line_height: f32 = 0.0,
current_line_ascent: f32 = 0.0,
current_line_ascent_recorded: f32 = 0.0,
line_ascents_idx: usize = 0,
line_ascents: []LineAscent = &.{}, // from last frame
line_ascents_new: std.ArrayList(LineAscent) = .empty, // creating this frame
prevClip: Rect.Physical = .{},
break_lines: bool,
line_break: LineBreakStrictness,
word_break: WordBreakMode,
overflow_wrap: OverflowWrap,
base_direction: opentype.unicode.Bidi.ParagraphDirection,
current_line_width: f32 = 0.0, // width of lines if break_lines was false
touch_edit_just_focused: bool,
process_events_in_deinit: bool,

cursor_pt: ?Point = null,
cursor_event: ?dvui.Event.EventTypes = null,
click_pt: ?Point = null,
click_event: ?dvui.Event.EventTypes = null,

/// Recorded last frame, answered this frame. Click and hover get a slot each:
/// one frame can hold a hover on one chunk and a click on another, and a
/// single slot would let the later one overwrite the earlier.
deferred_click: ?DeferredHit = null,
deferred_hover: ?DeferredHit = null,
/// Recorded this frame, answered next frame.
deferred_click_new: ?DeferredHit = null,
deferred_hover_new: ?DeferredHit = null,
/// Counts clickable/hoverable chunks in draw order, reset each frame.
action_ordinal: usize = 0,
click_num: u8 = 0,
click_num_pt: dvui.Point.Physical = .{},

line: usize = 0,

/// Fragments laid out but not yet drawn, all belonging to the visual line
/// currently being built. UAX #9 cannot place any of them until the whole
/// line's logical text is known, and a line can span several addText calls.
/// Arena-backed, so nothing here needs freeing.
line_frags: std.ArrayList(Fragment) = .empty,
/// Set when any buffered fragment holds bytes that could resolve RTL; when
/// false the line is placed left to right without running the bidi pass.
line_maybe_rtl: bool = false,
/// Byte a point past the far edge of the most recently placed line resolves
/// to; null until a line with fragments has been placed.
line_end_byte: ?usize = null,
/// Left edge of the most recently placed line, which an RTL line's logical
/// end sits at; null until a line with fragments has been placed.
line_left_x: ?f32 = null,
/// UAX #9 P2/P3 runs over the paragraph, not the visual line: once a strong
/// character has fixed the base direction it holds until the next hard break,
/// so a wrapped RTL paragraph whose second line starts with a Latin word
/// stays right-to-left. Null until the paragraph's first strong character.
paragraph_direction: ?opentype.unicode.Bidi.ParagraphDirection = null,
bytes_seen: usize = 0,
first_byte_in_line: usize = 0,
/// might point to `selection_store`
selection: *Selection,

/// For simplicity we only handle a single kind of selection change per frame
sel_move: union(enum) {
    none: void,

    // mouse down to move cursor and dragging to select
    mouse: struct {
        down_pt: ?Point = null, // point we got the mouse down (frame 1)
        byte: ?usize = null, // byte index of pt (find on frame 1, keep while captured)
        drag_pt: ?Point = null, // point of current mouse drag
    },

    // second click or touch selects word at pointer
    // third click selects line at pointer
    expand_pt: struct {
        pt: ?Point = null,
        bytes: [2]usize = .{ 0, 0 }, // start and end of original selection while dragging
        select: bool = true, // false - move cursor, true - change selection
        dragging: bool = false,
        done: bool = false, // finished our work this frame?
        which: enum {
            word,
            line,
            home,
            end,
        },
        last: [2]usize = .{ 0, 0 }, // index of last 2 space/newline we've seen
    },

    // moving left/right by characters
    char_left_right: struct {
        count: i8 = 0,
        select: bool = true, // false - move cursor, true - change selection
        buf: [20]u8 = @splat(0), // only used when count < 0
    },

    // moving cursor up/down
    // - this can be pipelined, so we might get more count on the same frame 2
    // we are adjusting for the previous count
    cursor_updown: struct {
        count: i8 = 0, // positive is down (get this on frame 1, set pt once we see the cursor)
        pt: ?Point = null, // get this on frame 2
        select: bool = true, // false - move cursor, true - change selection
    },

    // moving left/right by words
    word_left_right: struct {
        count: i8 = 0,
        select: bool = true, // false - move cursor, true - change selection
        scratch_kind: enum {
            punc, // space, newline, or ascii puncutation
            word,
        } = .punc,
        // indexes of the last starts of words (only used when count < 0)
        word_start_idx: [5]usize = .{ 0, 0, 0, 0, 0 },
    },
} = .none,

sel_start_r: Rect = .{},
sel_start_r_new: ?Rect = null,
/// visual direction of the fragment each selection edge landed in, so the
/// touch draggables hang off the correct side of their caret
sel_start_rtl: bool = false,
sel_start_rtl_new: bool = false,
sel_end_r: Rect = .{},
sel_end_r_new: ?Rect = null,
sel_end_rtl: bool = false,
sel_end_rtl_new: bool = false,
sel_pts: [2]?Point = [2]?Point{ null, null },

cursor_seen: bool = false,
/// SAFETY: Set in `textAddEx`
cursor_rect: Rect = undefined,
scroll_to_cursor: bool = false,
scroll_to_cursor_next_frame: bool = false,

add_text_done: bool = false,

copy_sel: ?Selection = null,
copy_slice: ?[]u8 = null,

// when this is true and we have focus, show the floating widget with select all, copy, etc.
touch_editing: bool = false,
te_first: bool = true,
te_show_draggables: bool = true,
te_show_context_menu: bool = true,
te_focus_on_touchdown: bool = false,
focus_at_start: bool = false,
/// SAFETY: Set in `touchEditing`
te_floating: FloatingWidget = undefined,

cache_layout: bool = false,
cache_layout_bytes: ?bytesNeededReturn = null,
cache_layout_bytes_seen: usize = 0,
byte_height_ready: ?ByteHeight = null,
byte_heights: []ByteHeight = &.{}, // from last frame
byte_heights_new: std.ArrayList(ByteHeight) = .empty, // creating this frame
byte_height_after_idx: ?usize = null,
byte_height_edit_idx: ?usize = null,

// AccessKit text reading / selection
textrun_parent_prev: ?dvui.Id = null,
textrun_anchor: ?TextRunSelectionInfo = null,
textrun_focus: ?TextRunSelectionInfo = null,
textrun_cursor: ?TextRunSelectionInfo = null,
textrun_last: ?TextRunSelectionInfo = null,
// Did the last textAdd end with a newline?
newline: bool = false,

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *TextLayoutWidget, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    const options = defaults.override(opts);

    self.* = .{
        .wd = WidgetData.init(src, .{ .scroll_when_focused = false }, options),
        .break_lines = init_opts.break_lines,
        .line_break = init_opts.line_break,
        .word_break = init_opts.word_break,
        .overflow_wrap = init_opts.overflow_wrap,
        .base_direction = init_opts.base_direction,
        .cache_layout = init_opts.cache_layout,
        .touch_edit_just_focused = init_opts.touch_edit_just_focused,
        .process_events_in_deinit = init_opts.process_events_in_deinit,

        // SAFETY: set bellow
        .selection = undefined,
    };
    self.selection = if (init_opts.selection) |sel_in| sel_in else dvui.dataGetPtrDefault(null, self.wd.id, "_selection", Selection, .{});

    if (dvui.dataGet(null, self.wd.id, "_touch_editing", bool)) |val| self.touch_editing = val;
    if (dvui.dataGet(null, self.wd.id, "_te_first", bool)) |val| self.te_first = val;
    if (dvui.dataGet(null, self.wd.id, "_te_show_draggables", bool)) |val| self.te_show_draggables = val;
    if (dvui.dataGet(null, self.wd.id, "_te_show_context_menu", bool)) |val| self.te_show_context_menu = val;
    if (dvui.dataGet(null, self.wd.id, "_te_focus_on_touchdown", bool)) |val| self.te_focus_on_touchdown = val;
    if (dvui.dataGet(null, self.wd.id, "_sel_start_r", Rect)) |val| self.sel_start_r = val;
    if (dvui.dataGet(null, self.wd.id, "_sel_start_rtl", bool)) |val| self.sel_start_rtl = val;
    if (dvui.dataGet(null, self.wd.id, "_sel_end_r", Rect)) |val| self.sel_end_r = val;
    if (dvui.dataGet(null, self.wd.id, "_sel_end_rtl", bool)) |val| self.sel_end_rtl = val;
    if (dvui.dataGet(null, self.wd.id, "_click_num", u8)) |val| self.click_num = val;
    if (dvui.dataGet(null, self.wd.id, "_deferred_click", DeferredHit)) |val| self.deferred_click = val;
    if (dvui.dataGet(null, self.wd.id, "_deferred_hover", DeferredHit)) |val| self.deferred_hover = val;
    if (dvui.dataGet(null, self.wd.id, "_click_num_pt", dvui.Point.Physical)) |val| self.click_num_pt = val;
    if (dvui.dataGetSlice(null, self.wd.id, "_byte_heights", []ByteHeight)) |bh| self.byte_heights = bh;
    if (dvui.dataGetSlice(null, self.wd.id, "__line_ascents", []LineAscent)) |la| self.line_ascents = la;

    if (dvui.dataGet(null, self.wd.id, "_scroll_to_cursor", bool) orelse false) {
        dvui.dataRemove(null, self.wd.id, "_scroll_to_cursor");
        self.scroll_to_cursor = true;
    }

    const scale_old = dvui.dataGetPtrDefault(null, self.wd.id, "_scale", f32, dvui.parentGet().screenRectScale(Rect{}).s);
    const scale_new = dvui.parentGet().screenRectScale(Rect{}).s;
    if (self.cache_layout and scale_old.* != scale_new) {
        dvui.log.debug("{x} TextLayoutWidget forcing cache_layout false due to scale change", .{self.data().id});
        self.cache_layout = false;
    }
    scale_old.* = scale_new;

    const break_lines_old = dvui.dataGetPtrDefault(null, self.wd.id, "_break_lines", bool, self.break_lines);
    if (self.cache_layout and break_lines_old.* != self.break_lines) {
        dvui.log.debug("{x} TextLayoutWidget forcing cache_layout false due to break_lines change", .{self.data().id});
        self.cache_layout = false;
    }
    break_lines_old.* = self.break_lines;

    const width_old = dvui.dataGetPtrDefault(null, self.wd.id, "_width", f32, self.data().rect.w);
    if (self.cache_layout and self.break_lines and width_old.* != self.data().rect.w) {
        dvui.log.debug("{x} TextLayoutWidget forcing cache_layout false due to width change while break_lines", .{self.data().id});
        self.cache_layout = false;
    }
    width_old.* = self.data().rect.w;

    self.focus_at_start = init_opts.focused orelse (self.data().id == dvui.focusedWidgetId());

    self.data().register();
    dvui.parentSet(self.widget());

    if (dvui.captured(self.data().id)) {
        if (dvui.dataGet(null, self.data().id, "_sel_move_mouse_byte", usize)) |p| {
            self.sel_move = .{ .mouse = .{ .byte = p } };
        }

        if (dvui.dataGet(null, self.data().id, "_sel_move_expand_pt_which", @TypeOf(self.sel_move.expand_pt.which))) |w| {
            if (dvui.dataGet(null, self.data().id, "_sel_move_expand_pt_bytes", [2]usize)) |bytes| {
                // set done to true, only matters if we are dragging which sets it back to false
                self.sel_move = .{ .expand_pt = .{ .which = w, .bytes = bytes, .done = true } };
            }
        }
    }

    if (dvui.dataGet(null, self.data().id, "_sel_move_cursor_updown_pt", Point)) |p| {
        self.sel_move = .{ .cursor_updown = .{ .pt = p } };
        dvui.dataRemove(null, self.data().id, "_sel_move_cursor_updown_pt");
        if (dvui.dataGet(null, self.data().id, "_sel_move_cursor_updown_select", bool)) |cud| {
            self.sel_move.cursor_updown.select = cud;
            dvui.dataRemove(null, self.data().id, "_sel_move_cursor_updown_select");
        }
    }

    const control_opts: Options = .{};

    const rs = self.data().contentRectScale();

    self.data().borderAndBackground(.{});

    // clip to background rect for possible corner widgets, addTextEx clips to content rect
    self.prevClip = dvui.clip(self.data().backgroundRectScale().r);

    if (init_opts.show_touch_draggables and self.touch_editing and self.te_show_draggables and self.focus_at_start and self.data().visible()) {
        const size = 36;
        {

            // calculate visible before FloatingWidget changes clip

            // We only draw if visible (to prevent drawing way outside the
            // textLayout), but we always process the floating window so that
            // we maintain capture.  That way you can drag a draggable off the
            // textLayout (so it's not visible), which causes a scroll, but
            // when the draggable shows back up you are still dragging it.

            // sel_start_r might be just off the right-hand edge, so widen it
            var cursor = self.sel_start_r;
            cursor.x -= 1;
            cursor.w += 1;
            const visible = !dvui.clipGet().intersect(rs.rectToPhysical(cursor)).empty();

            // an RTL selection starts at the visual right edge, so its
            // draggable hangs to the right of the caret instead
            const hang_left = !self.sel_start_rtl;
            var rect = self.sel_start_r;
            rect.y += rect.h; // move to below the line
            const srs = self.screenRectScale(rect);
            rect = dvui.windowRectScale().rectFromPhysical(srs.r);
            if (hang_left) rect.x -= size;
            rect.w = size;
            rect.h = size;

            var fc: dvui.FloatingWidget = undefined;
            fc.init(@src(), .{}, .{ .rect = rect });

            var offset: Point.Physical = dvui.dataGet(null, fc.data().id, "_offset", Point.Physical) orelse .{};

            const fcrs = fc.data().rectScale();
            const evts = dvui.events();
            for (evts) |*e| {
                if (!dvui.eventMatch(e, .{ .id = fc.data().id, .r = fcrs.r }))
                    continue;

                if (e.evt == .mouse) {
                    const me = e.evt.mouse;
                    if (me.action == .press and me.button.touch()) {
                        dvui.captureMouse(fc.data(), e.num);
                        self.te_show_context_menu = false;
                        offset = (if (hang_left) fcrs.r.topRight() else fcrs.r.topLeft()).diff(me.p);

                        // give an extra offset of half the cursor height
                        offset.y -= self.sel_start_r.h * 0.5 * rs.s;
                    } else if (me.action == .release and me.button.touch()) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    } else if (me.action == .motion and dvui.captured(fc.data().id)) {
                        const corner = me.p.plus(offset);
                        self.sel_pts[0] = self.data().contentRectScale().pointFromPhysical(corner);
                        self.sel_pts[1] = self.sel_end_r.topLeft().plus(.{ .y = self.sel_end_r.h / 2 });

                        self.sel_pts[0].?.y = @min(self.sel_pts[0].?.y, self.sel_pts[1].?.y);

                        dvui.scrollDrag(.{
                            .mouse_pt = e.evt.mouse.p,
                            .screen_rect = self.data().rectScale().r,
                        });
                    }
                }
            }

            if (visible) {
                var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
                defer path.deinit();

                path.addPoint(.{ .x = if (hang_left) fcrs.r.x + fcrs.r.w else fcrs.r.x, .y = fcrs.r.y });
                path.addArc(.{ .x = fcrs.r.x + fcrs.r.w / 2, .y = fcrs.r.y + fcrs.r.h / 2 }, fcrs.r.w / 2, std.math.pi, 0, true);

                path.build().fillConvex(.{ .color = control_opts.color(.fill) });
                path.build().stroke(.{ .thickness = 1.0 * fcrs.s, .color = self.data().options.color(.border), .closed = true });
            }

            dvui.dataSet(null, fc.data().id, "_offset", offset);
            fc.deinit();
        }

        {
            // calculate visible before FloatingWidget changes clip

            // sel_end_r might be just off the right-hand edge, so widen it
            var cursor = self.sel_end_r;
            cursor.x -= 1;
            cursor.w += 1;
            const visible = !dvui.clipGet().intersect(rs.rectToPhysical(cursor)).empty();

            const hang_left = self.sel_end_rtl;
            var rect = self.sel_end_r;
            rect.y += rect.h; // move to below the line
            const srs = self.screenRectScale(rect);
            rect = dvui.windowRectScale().rectFromPhysical(srs.r);
            if (hang_left) rect.x -= size;
            rect.w = size;
            rect.h = size;

            var fc: dvui.FloatingWidget = undefined;
            fc.init(@src(), .{}, .{ .rect = rect });

            var offset: Point.Physical = dvui.dataGet(null, fc.data().id, "_offset", Point.Physical) orelse .{};

            const fcrs = fc.data().rectScale();
            const evts = dvui.events();
            for (evts) |*e| {
                if (!dvui.eventMatch(e, .{ .id = fc.data().id, .r = fcrs.r }))
                    continue;

                if (e.evt == .mouse) {
                    const me = e.evt.mouse;
                    if (me.action == .press and me.button.touch()) {
                        dvui.captureMouse(fc.data(), e.num);
                        self.te_show_context_menu = false;
                        offset = (if (hang_left) fcrs.r.topRight() else fcrs.r.topLeft()).diff(me.p);

                        // give an extra offset of half the cursor height
                        offset.y -= self.sel_start_r.h * 0.5 * rs.s;
                    } else if (me.action == .release and me.button.touch()) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    } else if (me.action == .motion and dvui.captured(fc.data().id)) {
                        const corner = me.p.plus(offset);
                        self.sel_pts[0] = self.sel_start_r.topLeft().plus(.{ .y = self.sel_start_r.h / 2 });
                        self.sel_pts[1] = self.data().contentRectScale().pointFromPhysical(corner);

                        self.sel_pts[1].?.y = @max(self.sel_pts[0].?.y, self.sel_pts[1].?.y);

                        dvui.scrollDrag(.{
                            .mouse_pt = e.evt.mouse.p,
                            .screen_rect = self.data().rectScale().r,
                        });
                    }
                }
            }

            if (visible) {
                var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
                defer path.deinit();

                path.addPoint(.{ .x = if (hang_left) fcrs.r.x + fcrs.r.w else fcrs.r.x, .y = fcrs.r.y });
                path.addArc(.{ .x = fcrs.r.x + fcrs.r.w / 2, .y = fcrs.r.y + fcrs.r.h / 2 }, fcrs.r.w / 2, std.math.pi, 0, true);

                path.build().fillConvex(.{ .color = control_opts.color(.fill) });
                path.build().stroke(.{ .thickness = 1.0 * fcrs.s, .color = self.data().options.color(.border), .closed = true });
            }

            dvui.dataSet(null, fc.data().id, "_offset", offset);
            fc.deinit();
        }
    }

    if (self.data().accesskit_node()) |ak_node| {
        dvui.AccessKit.nodeSetReadOnly(ak_node);
    }

    if (dvui.accesskit_enabled and options.role.? != .none) {
        var vp = dvui.virtualParent(@src(), .{ .role = .label });
        defer vp.deinit();
        var cw = dvui.currentWindow();
        self.textrun_parent_prev = cw.accesskit.text_run_parent;
        cw.accesskit.text_run_parent = vp.data().id;
    }
}

pub fn format(self: *TextLayoutWidget, comptime fmt: []const u8, args: anytype, opts: Options) void {
    comptime if (!std.unicode.utf8ValidateSlice(fmt)) @compileError("Format strings must be valid utf-8");
    const cw = dvui.currentWindow();
    const l = std.fmt.allocPrint(cw.lifo(), fmt, args) catch |err| blk: {
        dvui.logError(@src(), err, "Failed to print", .{});
        break :blk fmt;
    };
    defer if (l.ptr != fmt.ptr) cw.lifo().free(l);
    self.addText(l, opts);
}

pub fn addText(self: *TextLayoutWidget, text: []const u8, opts: Options) void {
    _ = self.addTextEx(text, .none, opts);
}

pub fn addTextClick(self: *TextLayoutWidget, text: []const u8, opts: Options) ?dvui.Event.EventTypes {
    return if (self.addTextEx(text, .click, opts)) |m| m.event else null;
}

pub const AddLinkOptions = struct {
    /// url navigated to when clicked
    url: []const u8,

    /// text shown to user - if null, uses url
    text: ?[]const u8 = null,
};

pub fn addLink(self: *TextLayoutWidget, init_opts: AddLinkOptions, opts: Options) void {
    const defs: Options = .{ .color_text = .{ .color = dvui.themeGet().focus }, .font = dvui.Font.theme(.body).withUnderline(.{}) };
    if (self.addTextClick(init_opts.text orelse init_opts.url, defs.override(opts))) |click_event| {
        const new_window = (click_event == .mouse and (click_event.mouse.button == .middle or click_event.mouse.mod.matchBind("ctrl/cmd")));
        _ = dvui.openURL(.{ .url = init_opts.url, .new_window = new_window });
    }
}

/// A hit answered one frame late, so a clickable chunk doesn't have to force
/// its line out before the bidi pass can place it. Keyed on the chunk's
/// ordinal within the frame rather than its byte offset: offsets shift
/// whenever earlier text changes, ordinals survive re-highlighting.
/// ponytail: the counter is shared across click and hover chunks in draw
/// order, so if the click itself changes how many actionable chunks the
/// frame emits, the stored hit lands on the neighbouring chunk for one
/// frame. Key on a caller-supplied id if that ever bites.
const DeferredHit = struct {
    ordinal: usize,
    event: dvui.Event.EventTypes,
    rect: Rect,
};

/// A hover/click match against a run of text
pub const HoverMatch = struct {
    event: dvui.Event.EventTypes,
    rect: Rect,
};

pub fn addTextHover(self: *TextLayoutWidget, text: []const u8, opts: Options) ?HoverMatch {
    return self.addTextEx(text, .hover, opts);
}

pub fn addTextTooltip(self: *TextLayoutWidget, src: std.builtin.SourceLocation, text: []const u8, tooltip: []const u8, opts: Options) void {
    var tt: dvui.FloatingTooltipWidget = undefined;
    tt.init(src, .{
        .active_rect = .{},
        .position = .sticky,
    }, .{ .id_extra = opts.idExtra() });

    if (self.addTextHover(text, opts)) |_| {
        tt.init_options.active_rect = dvui.windowRectPixels();
    }

    if (tt.shown()) {
        var tl = dvui.textLayout(@src(), .{}, .{ .background = false });
        tl.addText(tooltip, .{});
        tl.deinit();
    }

    tt.deinit();
}

const PointHit = struct { byte: usize, affinity: Selection.Affinity = .after };

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
fn lineEndByte(frags: []const Fragment) usize {
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
};

/// Every caret position on the placed line, ordered left to right on screen.
/// Built from the same reordered fragments `hitLine` walks, so a keyboard
/// step and a mouse click agree about which byte lives where.
/// ponytail: quadratic -- every stop re-measures its fragment's prefix from
/// the start. One line, one keypress; measure before caching anything.
fn visualStops(self: *TextLayoutWidget, arena: std.mem.Allocator) []const CaretStop {
    var stops: std.ArrayList(CaretStop) = .empty;
    for (self.line_frags.items) |f| {
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
            }) catch break;
            if (off >= text.len) break;
            off = @min(text.len, off + (std.unicode.utf8ByteSequenceLength(text[off]) catch 1));
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

/// Steps the caret across the placed line in visual order, consuming `clr`'s
/// count. What is left when the caret reaches the edge of the line is handed
/// back as a *logical* count -- flipped when that edge belongs to an RTL run,
/// since there one step further right is one step earlier in the text.
fn charVisualMove(self: *TextLayoutWidget, clr: *@FieldType(@TypeOf(self.sel_move), "char_left_right")) void {
    if (clr.count == 0 or self.line_frags.items.len == 0) return;
    const stops = self.visualStops(dvui.currentWindow().arena());
    var idx = stopIndex(stops, self.selection.cursor, self.selection.affinity) orelse return;

    var moved = false;
    while (clr.count != 0) {
        const right = clr.count > 0;
        if (right and idx + 1 >= stops.len) break;
        if (!right and idx == 0) break;
        idx = if (right) idx + 1 else idx - 1;
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
    } else if (stops[idx].rtl) {
        clr.count = -clr.count;
    }
}

/// Reading direction of the run the caret sat in last frame. A key arrives
/// before this frame has laid anything out, so a move that has to be decided
/// up front (word steps, which collect their targets during the pass) has
/// only the previous frame to ask.
pub fn caretRtl(self: *TextLayoutWidget) bool {
    return if (self.selection.cursor == self.selection.start) self.sel_start_rtl else self.sel_end_rtl;
}

/// Which way a Left/Right key moves the caret through the *text*. Word steps
/// collect their targets during the layout pass, so unlike char steps they
/// cannot be resolved against the placed line afterwards: they go by the
/// direction of the run the caret sat in last frame.
pub fn logicalStep(self: *TextLayoutWidget, right: bool) i8 {
    return if (right != self.caretRtl()) 1 else -1;
}

/// Collapses a selection to the edge a Left/Right key points at on screen.
pub fn collapseSelection(self: *TextLayoutWidget, right: bool) void {
    if (right != self.caretRtl()) {
        self.selection.moveCursor(self.selection.end, false);
        self.selection.affinity = .before;
    } else {
        self.selection.moveCursor(self.selection.start, false);
    }
}

/// The hit for `p` if the fragment at `index` is the one that owns it. The
/// whole line is rescanned per point per fragment; a line holds a handful of
/// fragments, so caching the answers is not worth the state.
fn hitHere(self: *TextLayoutWidget, p: Point, index: usize) ?PointHit {
    const found = hitLine(self.line_frags.items, p, self.line_end_byte orelse self.bytes_seen) orelse return null;
    return if (found.index == index) found.hit else null;
}

// Called for each piece of text before searching for the cursor.
// Place for selection movement to track points and move the cursor if needed,
// also to track any state they need before the cursor (like word select).
fn selMovePre(self: *TextLayoutWidget, f: Fragment, index: usize) void {
    const past_text = f.bytes_seen + f.text.len;
    switch (self.sel_move) {
        .none => {},
        .mouse => |*m| {
            if (m.down_pt) |p| {
                if (self.hitHere(p, index)) |ba| {
                    m.byte = ba.byte;
                    self.selection.moveCursor(ba.byte, false);
                    self.selection.affinity = ba.affinity;
                    m.down_pt = null;
                } else {
                    // haven't found it yet, keep cursor at end to not trigger cursor_seen
                    self.selection.moveCursor(past_text, false);
                }
            } else if (m.drag_pt) |p| {
                if (self.hitHere(p, index)) |ba| {
                    self.selection.cursor = ba.byte;
                    self.selection.start = @min(m.byte.?, ba.byte);
                    self.selection.end = @max(m.byte.?, ba.byte);
                    self.selection.affinity = ba.affinity;
                    m.drag_pt = null;
                } else {
                    // haven't found it yet, keep cursor at end to not trigger cursor_seen
                    self.selection.cursor = past_text;
                    self.selection.start = @min(m.byte.?, self.selection.cursor);
                    self.selection.end = @max(m.byte.?, self.selection.cursor);
                    self.selection.affinity = .after;
                }
            }
        },
        .expand_pt => |*ep| {
            if (ep.pt) |p| {
                if (self.hitHere(p, index)) |ba| {
                    self.selection.moveCursor(ba.byte, false);
                    self.selection.affinity = ba.affinity;
                    ep.pt = null;
                } else {
                    // haven't found it yet, keep cursor at end to not trigger cursor_seen
                    self.selection.moveCursor(past_text, false);
                }

                if (ep.dragging) {
                    self.selection.start = @min(self.selection.start, ep.bytes[0]);
                    self.selection.end = @max(self.selection.end, ep.bytes[1]);
                }
            }
        },
        .char_left_right => {},
        .cursor_updown => |*cud| {
            if (cud.pt) |p| {
                if (self.hitHere(p, index)) |ba| {
                    self.selection.moveCursor(ba.byte, cud.select);
                    self.selection.affinity = ba.affinity;
                    cud.pt = null;
                } else {
                    // haven't found it yet, keep cursor at end to not trigger cursor_seen
                    self.selection.moveCursor(past_text, cud.select);
                }
            }
        },
        .word_left_right => {},
    }
}

// Called when we transition to a new line without seeing a newline char.
// Place for selection movement that is tracking a point to say that the cursor
// should be at the end of the previous line.
fn lineBreak(self: *TextLayoutWidget) void {
    // Right of the text is the logical start of an RTL line, so take the byte
    // the line placement resolved rather than assuming the pen ended there.
    const line_end = self.line_end_byte orelse self.bytes_seen;
    switch (self.sel_move) {
        .none => {},
        .mouse => |*m| {
            if (m.down_pt) |p| {
                if (p.y < self.insert_pt.y) {
                    // point was past the far edge of the previous line, no newline
                    m.byte = line_end;
                    self.selection.affinity = .before;
                    m.down_pt = null;

                    self.cursorSeen();
                }
            } else if (m.drag_pt) |p| {
                if (p.y < self.insert_pt.y) {
                    // point was past the far edge of the previous line, no newline
                    self.selection.cursor = line_end;
                    self.selection.start = @min(m.byte.?, self.selection.cursor);
                    self.selection.end = @max(m.byte.?, self.selection.cursor);
                    self.selection.affinity = .before;
                    m.drag_pt = null;

                    self.cursorSeen();
                }
            }
        },
        .expand_pt => |*ep| {
            if (ep.pt) |p| {
                if (p.y < self.insert_pt.y) {
                    // point was past the far edge of the previous line, no newline
                    if (ep.last[0] == line_end) {
                        // we are at the end of a line and the ending character
                        // was a space, so ignore it
                        ep.last[0] = ep.last[1];
                        self.selection.moveCursor(line_end -| 1, false);
                    } else {
                        self.selection.moveCursor(line_end, false);
                        self.selection.affinity = .before;
                    }
                    ep.pt = null;

                    self.cursorSeen();
                }
            }

            // if we are doing something like move to end of line, we'll
            // already have moved the cursor to the end of the text and now we
            // find a line break
            if (!ep.done and self.cursor_seen) {
                if (!ep.select) {
                    self.selection.moveCursor(self.selection.cursor, false);
                }

                self.selection.affinity = .before;

                if (!ep.dragging) {
                    ep.bytes[1] = self.selection.end;
                }

                ep.done = true;
            }
        },
        .cursor_updown => |*cud| {
            if (cud.pt) |p| {
                if (p.y < self.insert_pt.y) {
                    // point was past the far edge of the previous line, no newline
                    self.selection.moveCursor(line_end, cud.select);
                    self.selection.affinity = .before;
                    cud.pt = null;

                    self.cursorSeen();
                }
            }
        },
        .char_left_right => {},
        .word_left_right => {},
    }
}

// Called for each text processed (maybe empty), text will not straddle cursor.
// Place for selection movement (like word select) to adjust around cursor.
fn selMoveText(self: *TextLayoutWidget, txt: []const u8, start_idx: usize) void {
    if (txt.len == 0) {
        return;
    }

    switch (self.sel_move) {
        .none => {},
        .mouse => {},
        .expand_pt => |*ep| {
            if (!ep.done) {
                const search = if (ep.which == .word) word_breaks else "\n";
                if (!self.cursor_seen) {
                    // maintain index of last punc we saw
                    if (std.mem.findLastAny(u8, txt, search)) |space| {
                        ep.last[1] = ep.last[0];
                        ep.last[0] = start_idx + space + 1;
                        if (std.mem.findLastAny(u8, txt[0..space], search)) |space2| {
                            ep.last[1] = start_idx + space2 + 1;
                        }
                    }
                } else {
                    // searching for next punc
                    if (std.mem.findAny(u8, txt, search)) |space| {
                        // found within our current text
                        self.selection.moveCursor(start_idx + space, ep.select);
                        ep.done = true;
                    } else {
                        // push the cursor to the end, we might see it in lineBreak
                        self.selection.moveCursor(start_idx + txt.len, ep.select);
                    }

                    if (ep.which == .end) {
                        self.scroll_to_cursor_next_frame = true;
                    }

                    if (!ep.dragging) {
                        ep.bytes[1] = self.selection.end;
                    }

                    if (ep.dragging) {
                        self.selection.start = @min(self.selection.start, ep.bytes[0]);
                        self.selection.end = @max(self.selection.end, ep.bytes[1]);
                    }
                }
            }
        },
        .char_left_right => |*clr| {
            if (!self.cursor_seen and clr.count < 0) {
                // save a small lookback buffer

                for (clr.buf, 0..) |_, i| {
                    if (i + txt.len >= clr.buf.len) {
                        clr.buf[i] = txt[txt.len + i - clr.buf.len];
                    } else {
                        clr.buf[i] = clr.buf[i + txt.len];
                    }
                }
            }

            while (self.cursor_seen and clr.count > 0) {
                var cur = self.selection.cursor;

                if (cur == self.first_byte_in_line and self.selection.affinity == .before and !clr.select) {
                    self.selection.affinity = .after;
                } else if (cur < start_idx + txt.len) {
                    const newline = txt[cur - start_idx] == '\n';

                    // move cursor one utf8 char right
                    cur += std.unicode.utf8ByteSequenceLength(txt[cur - start_idx]) catch 1;

                    self.selection.moveCursor(cur, clr.select);
                    if (cur == start_idx + txt.len and !newline) {
                        self.selection.affinity = .before;
                    }
                } else {
                    // nothing we can do on this iteration
                    break;
                }

                clr.count -= 1;

                self.scroll_to_cursor_next_frame = true;
                dvui.refresh(null, @src(), self.data().id);
            }
        },
        .cursor_updown => {},
        .word_left_right => |*wlr| {
            if (wlr.count < 0) {
                // maintain our list of previous starts of words, looking backwards
                var idx = txt.len -| 1;
                var last_kind: enum { punc, word } = if (std.mem.findAnyPos(u8, txt, idx, word_breaks) != null) .punc else .word;

                var word_start_count: usize = 0;

                loop: while (word_start_count < wlr.word_start_idx.len) {
                    switch (last_kind) {
                        .punc => {
                            if (std.mem.findLastNone(u8, txt[0..idx], word_breaks)) |word_end| {
                                last_kind = .word;
                                idx = word_end;
                            } else {
                                // all punc
                                break :loop;
                            }
                        },
                        .word => {
                            var new_word_start: ?usize = null;
                            if (std.mem.findLastAny(u8, txt[0..idx], word_breaks)) |punc| {
                                last_kind = .punc;
                                idx = punc;
                                new_word_start = idx + 1;
                            } else {
                                // all word
                                idx = 0;
                                if (wlr.scratch_kind == .punc) {
                                    // last char from previous iteration was punc and we started with word
                                    new_word_start = idx;
                                }
                            }

                            if (new_word_start) |ws| {
                                var i = wlr.word_start_idx.len - 1;
                                while (i > word_start_count) : (i -= 1) {
                                    wlr.word_start_idx[i] = wlr.word_start_idx[i - 1];
                                }
                                wlr.word_start_idx[word_start_count] = start_idx + ws;
                                word_start_count += 1;
                            }

                            if (idx == 0) {
                                break :loop;
                            }
                        },
                    }
                }

                // record last character kind for next iteration
                if (std.mem.findAnyPos(u8, txt, txt.len -| 1, word_breaks) != null) {
                    wlr.scratch_kind = .punc;
                } else {
                    wlr.scratch_kind = .word;
                }
            }

            while (self.cursor_seen and wlr.count > 0) {
                // do this first, so if we break out of the loop but never see
                // more text we still scroll to cursor
                self.scroll_to_cursor_next_frame = true;
                dvui.refresh(null, @src(), self.data().id);

                switch (wlr.scratch_kind) {
                    .punc => {
                        // skipping over punc
                        if (std.mem.findNonePos(u8, txt, self.selection.cursor -| start_idx, word_breaks)) |non_blank| {
                            self.selection.moveCursor(start_idx + non_blank, wlr.select);
                            wlr.scratch_kind = .word; // now want to skip over word chars
                        } else {
                            // rest was punc
                            self.selection.moveCursor(start_idx + txt.len, wlr.select);
                            break;
                        }
                    },
                    .word => {
                        // skipping over word chars
                        if (std.mem.findAnyPos(u8, txt, self.selection.cursor -| start_idx, word_breaks)) |punc| {
                            self.selection.moveCursor(start_idx + punc, wlr.select);
                            // done with this one
                            wlr.scratch_kind = .punc; // now want to skip over punc
                            wlr.count -= 1;
                        } else {
                            // rest was word
                            self.selection.moveCursor(start_idx + txt.len, wlr.select);
                            break;
                        }
                    },
                }
            }
        },
    }
}

fn cursorSeen(self: *TextLayoutWidget) void {
    self.cursor_seen = true;
    const cr = self.cursor_rect;

    switch (self.sel_move) {
        .none => {},
        .mouse => {},
        .expand_pt => |*ep| {
            if (!ep.done) {
                switch (ep.which) {
                    .word => {
                        self.selection.start = @max(ep.last[0], self.first_byte_in_line);
                        self.selection.cursor = self.selection.end; // put cursor at end so later expansion works
                    },
                    .line => {
                        self.selection.start = self.first_byte_in_line;
                        self.selection.cursor = self.selection.end; // put cursor at end so later expansion works
                    },
                    .home => {
                        self.selection.moveCursor(self.first_byte_in_line, ep.select);
                        ep.done = true;
                        self.scroll_to_cursor_next_frame = true;
                    },
                    .end => {
                        self.scroll_to_cursor_next_frame = true;
                    },
                }

                if (!ep.dragging) {
                    ep.bytes[0] = self.selection.start;
                    ep.bytes[1] = self.selection.end;
                }

                if (ep.dragging) {
                    self.selection.start = @min(self.selection.start, ep.bytes[0]);
                    self.selection.end = @max(self.selection.end, ep.bytes[1]);
                }

                dvui.refresh(null, @src(), self.data().id);
            }
        },
        .char_left_right => |*clr| {
            // Visual first: on the placed line the caret walks the screen,
            // not the byte stream. Only what runs off the end of the line is
            // left for the logical paths here and in `selMoveText`.
            self.charVisualMove(clr);
            if (clr.count < 0) {
                const oldcur = self.selection.cursor;
                var cur = self.selection.cursor;
                while (clr.count < 0 and cur > 0 and (oldcur - cur + 1) <= clr.buf.len) {
                    if (cur == self.first_byte_in_line and self.selection.affinity == .after and !clr.select) {
                        if (clr.buf[clr.buf.len + cur - oldcur - 1] == '\n') {
                            cur -= 1;
                            self.selection.moveCursor(cur, clr.select);
                        } else {
                            self.selection.affinity = .before;
                        }
                    } else {
                        // move cursor one utf8 char left
                        cur -|= 1;
                        while (cur > 0 and oldcur - cur <= clr.buf.len and clr.buf[clr.buf.len + cur - oldcur] & 0xc0 == 0x80) {
                            // in the middle of a multibyte char
                            cur -|= 1;
                        }

                        var bail = false;
                        while ((oldcur - cur) > clr.buf.len or (cur <= oldcur and clr.buf[clr.buf.len + cur - oldcur] & 0xc0 == 0x80)) {
                            // couldn't get to a good place, so reverse
                            cur += 1;
                            bail = true;
                        }

                        if (bail) break;

                        self.selection.moveCursor(cur, clr.select);
                    }

                    clr.count += 1;
                }

                clr.count = 0;

                self.scroll_to_cursor_next_frame = true;
                dvui.refresh(null, @src(), self.data().id);
            }
        },
        .cursor_updown => |*cud| {
            if (cud.count != 0) {
                // If we had cursor_updown.pt from last frame, we don't get
                // cursor_seen until we've moved the cursor to that point
                const cr_new = cr.plus(.{ .y = @as(f32, @floatFromInt(cud.count)) * cr.h });
                const updown_pt = cr_new.topLeft().plus(.{ .y = cr_new.h / 2 });
                cud.count = 0;

                // forward the pixel position we want the cursor to be in to
                // the next frame
                dvui.dataSet(null, self.data().id, "_sel_move_cursor_updown_pt", updown_pt);
                dvui.dataSet(null, self.data().id, "_sel_move_cursor_updown_select", cud.select);
                dvui.refresh(null, @src(), self.data().id);

                // even though we scrolled to where we thought the cursor would
                // be, we might have moved up from a long line to a short one
                // and need to scroll horizontally
                self.scroll_to_cursor_next_frame = true;
            }
        },
        .word_left_right => |*wlr| {
            if (wlr.count < 0) {
                const idx2 = @min(-wlr.count - 1, wlr.word_start_idx.len - 1);
                self.selection.moveCursor(wlr.word_start_idx[@intCast(idx2)], wlr.select);
                wlr.count = 0;

                self.scroll_to_cursor_next_frame = true;
                dvui.refresh(null, @src(), self.data().id);
            }
        },
    }

    if (self.scroll_to_cursor) {
        dvui.scrollTo(.{
            .screen_rect = self.screenRectScale(cr.outset(self.data().options.paddingGet())).r,
            // cursor might just have transitioned to a new line, so scroll area has not expanded yet
            .over_scroll = true,
        });
    }
}

pub const ByteHeight = struct {
    pub const dist: f32 = 200.0; // record byte/height every this many logical pixels

    /// byte just after a newline (or after the last byte)
    byte: usize,

    /// height from top of text layout content rect
    height: f32,

    /// used to integrate with line_ascents
    line: usize,
};

const bytesNeededReturn = struct { start: usize, end: usize };

pub fn bytesNeeded(self: *TextLayoutWidget, edit_start: usize, edit_end: usize, edit_added: i64) ?bytesNeededReturn {
    if (self.byte_heights.len == 0) return null;

    // intersect our content rect with the clipping rect
    const clip_logical = self.data().contentRectScale().rectFromPhysical(dvui.clipGet());
    const vr = self.data().contentRect().justSize().intersect(clip_logical);

    var start_byte: usize = 0;
    var end_byte: usize = self.byte_heights[self.byte_heights.len - 1].byte;

    const Context = struct { height: f32, byte: usize };
    var context: Context = .{ .height = vr.y, .byte = edit_start };
    var sel_end: usize = edit_end;
    var end_height = vr.y + vr.h;

    if (self.copy_sel) |sel| {
        context.byte = @min(context.byte, sel.start);
        sel_end = @max(sel_end, sel.end);
    }

    var include_cursor = self.scroll_to_cursor;

    // if we are moving the cursor, need to process the text around where we are moving it
    switch (self.sel_move) {
        .none => {},
        .mouse => {}, // all in visible region, excepted below
        .expand_pt => |*ep| {
            switch (ep.which) {
                .word, .line => {}, // all in visible region
                .home, .end => include_cursor = true,
            }
        },
        .char_left_right => include_cursor = true,
        .cursor_updown => |*cud| {
            if (cud.pt) |p| {
                // found cursor last frame, need to include p this frame
                context.height = @min(context.height, p.y);
                end_height = @max(end_height, p.y);
            } else {
                // we are looking for the cursor to move from
                include_cursor = true;
            }
        },
        .word_left_right => include_cursor = true,
    }

    if (include_cursor and self.sel_move != .mouse) {
        context.byte = @min(context.byte, self.selection.cursor);
        sel_end = @max(sel_end, self.selection.cursor);
    }

    // binary search for the start
    const predicateFn = struct {
        fn predicateFn(ctx: Context, item: ByteHeight) bool {
            return item.height <= ctx.height and item.byte < ctx.byte;
        }
    }.predicateFn;

    var first_past_height = std.sort.partitionPoint(ByteHeight, self.byte_heights, context, predicateFn);
    if (first_past_height == self.byte_heights.len) {
        // can't start at the final
        first_past_height -|= 1;
    }

    if (first_past_height > 0) {
        // starting not at the top
        const startBH = self.byte_heights[first_past_height - 1];
        start_byte = startBH.byte;

        self.insert_pt.y = startBH.height;
        self.line = startBH.line;
        self.bytes_seen = start_byte;

        if (!include_cursor and (self.selection.cursor < self.bytes_seen)) {
            std.debug.assert(self.cursor_seen == false);
            self.cursor_rect = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = 10 };
            self.cursorSeen();
        }

        switch (self.sel_move) {
            .word_left_right => |*wlr| {
                if (wlr.count < 0) {
                    // update default so that if someone does tons of word left in
                    // the same frame (so they move to before we started processing
                    // text, they will only go back to this index (instead of 0)
                    for (&wlr.word_start_idx) |*i| {
                        i.* = start_byte;
                    }
                }
            },
            else => {},
        }

        //std.debug.print("setting min height to {d}\n", .{self.insert_pt.y});

        // set min height just to make sure it happens
        const start_size = self.data().options.padSize(.{ .h = self.insert_pt.y });
        self.data().min_size.h = @max(self.data().min_size.h, start_size.h);

        // copy all the ByteHeights we skipped
        self.byte_heights_new.appendSlice(dvui.currentWindow().arena(), self.byte_heights[0..first_past_height]) catch {};

        // copy all the LineAscents we skipped
        var i: usize = 0;
        while (i < self.line_ascents.len and self.line_ascents[i].line < startBH.line) i += 1;
        self.line_ascents_new.appendSlice(dvui.currentWindow().arena(), self.line_ascents[0..i]) catch {};
        self.line_ascents_idx = i;
    }

    // linear scan for the end (but not the final)
    for (self.byte_heights[first_past_height .. self.byte_heights.len - 1], first_past_height..) |bh, i| {
        if (bh.height >= end_height and bh.byte > sel_end) {
            //std.debug.print("found end {d} {d} bh height {d} vr {d} {d} {d}\n", .{ i, self.byte_heights.len, bh.height, vr.y, vr.h, vr.y + vr.h });
            end_byte = bh.byte;

            self.byte_height_after_idx = i;
            break;
        }
    }

    // assume min width stays the same
    self.data().min_size.w = (dvui.minSizeGet(self.data().id) orelse Size.all(0)).w;

    // adjust end_byte for any edits
    if (edit_added >= 0) {
        end_byte += @intCast(edit_added);
    } else {
        end_byte -= @intCast(-edit_added);
    }

    //std.debug.print("bytesNeeded end {d} {d} {d}\n", .{ start_byte, end_byte, edit_added });

    return .{ .start = start_byte, .end = end_byte };
}

fn checkAscent(self: *TextLayoutWidget) void {
    if (self.line_ascents_new.items.len > 0 and
        self.line_ascents_new.items[self.line_ascents_new.items.len - 1].line == self.line)
    {
        if (self.current_line_ascent_recorded != self.line_ascents_new.items[self.line_ascents_new.items.len - 1].ascent) {
            // ascent we are recording this frame is different from last frame
            dvui.refresh(null, @src(), self.data().id);
        }
    }
}

pub fn cacheLayoutBytes(self: *TextLayoutWidget) ?bytesNeededReturn {
    if (self.cache_layout_bytes == null) self.cache_layout_bytes = self.bytesNeeded(std.math.maxInt(usize), 0, 0);
    return self.cache_layout_bytes;
}

const AddTextExAction = enum {
    none,
    click,
    hover,
};

const lastLineBreakOpportunity = opentype.lastLineBreakOpportunity;
const nextLineBreakOpportunity = opentype.nextLineBreakOpportunity;

fn addTextEx(self: *TextLayoutWidget, text_in: []const u8, action: AddTextExAction, opts: Options) ?HoverMatch {
    var ret: ?HoverMatch = null;
    const cw = dvui.currentWindow();

    const ordinal = self.action_ordinal;
    if (action != .none) {
        self.action_ordinal += 1;
        // The hit this chunk got last frame, if it is still the same chunk.
        const slot = if (action == .click) self.deferred_click else self.deferred_hover;
        if (slot) |h| {
            if (h.ordinal == ordinal) ret = .{ .event = h.event, .rect = h.rect };
        }
    }

    // clip to content rect for all text
    _ = dvui.clip(self.data().contentRectScale().r);
    self.newline = false;

    // Slice down to the visible byte range before `toUtf8` below
    var visible_chunk = text_in;
    if (self.cache_layout) {
        if (self.cacheLayoutBytes()) |clb| {
            const start = @min(visible_chunk.len, clb.start -| self.cache_layout_bytes_seen);
            const end = @min(visible_chunk.len, clb.end -| self.cache_layout_bytes_seen);
            self.cache_layout_bytes_seen += visible_chunk.len;

            //std.debug.print("{d} clb {d} .. {d} bytes {d} taking {d} .. {d}\n", .{ self.bytes_seen, clb.start, clb.end, self.cache_layout_bytes_seen, start, end });

            visible_chunk = visible_chunk[start..end];
            if (visible_chunk.len == 0) return null;
        } else {
            // bytesNeeded returned null, we can't do it this frame
            self.cache_layout = false;
        }
    }

    var txt = dvui.toUtf8(cw.lifo(), visible_chunk) catch |err| blk: {
        dvui.logError(@src(), err, "Failed to convert to utf8", .{});
        break :blk visible_chunk;
    };
    defer if (txt.ptr != visible_chunk.ptr) cw.lifo().free(txt);

    const options = self.data().options.override(opts);
    const font = options.fontGet();
    // font.lineHeight() is textHeight() * factor, and textHeight() is
    // sizeM(1,1).h -- reuse msize instead of re-shaping "M" a second time
    // for the same font/scale.
    const msize = font.sizeM(1, 1);
    const line_height = msize.h * font.line_height_factor;

    var container_width = self.data().contentRect().w;
    if (container_width == 0) {
        // if we are not being shown at all, probably this is the first
        // frame for us and we should calculate our min height assuming we
        // get at least our min width

        container_width = self.data().options.min_size_contentGet().w;
        if (container_width == 0) {
            // wasn't given a min width, assume something
            container_width = 500;
        }
    }

    text_loop: while (txt.len > 0) {
        if (self.byte_height_ready) |bhr| {
            //std.debug.print("byte_height_new append {d} {d}\n", .{ bhr.byte, bhr.height });
            self.byte_heights_new.append(cw.arena(), bhr) catch {};
            self.byte_height_ready = null;
        }

        self.current_line_height = @max(self.current_line_height, line_height);

        var linestart: f32 = 0;

        // Often we measure text for a size, then try to render text into that
        // size.  Sometimes due to floating point this width will be very
        // slightly less than the width of the text that textSizeEx below sees,
        // causing a line break.  So give ourselves a tiny bit of extra room.
        var linewidth = container_width + 0.001;
        var width = linewidth - self.insert_pt.x;
        var width_after: f32 = 0;
        for (self.corners, 0..) |corner, i| {
            if (corner) |cor| {
                if (@max(cor.y, self.insert_pt.y) < @min(cor.y + cor.h, self.insert_pt.y + msize.h)) {
                    linewidth -= cor.w;
                    if (linestart == cor.x) {
                        // used below - if we moved over for a widget, we
                        // can drop to the next line expecting more room
                        // later
                        linestart = (cor.x + cor.w);
                    }

                    if (self.insert_pt.x <= (cor.x + cor.w)) {
                        width -= cor.w;
                        if (self.insert_pt.x >= cor.x) {
                            // widget on left side, skip over it
                            self.insert_pt.x = (cor.x + cor.w);
                        } else {
                            // widget on right side, need to add width to min_size below
                            width_after = self.corners_min_size[i].?.w;
                        }
                    }
                }
            }
        }

        var end: usize = undefined;

        // get slice of text that fits within width or ends with newline
        var ascent: f32 = undefined;

        // Shape this fragment once and reuse the shape (full UAX #9 bidi +
        // GSUB/GPOS) for line-break re-measurement, cursor/selection
        // tracking, and the actual glyph render below -- each of those
        // used to trigger its own independent reshape of the same bytes,
        // 3-4x per fragment per frame. `shaped` is scratch-allocated on
        // `cw.arena()` (bulk-freed at frame end), so it's deliberately
        // never `.deinit()`'d here -- only arena-copied out via
        // `shaped_ptr` right before the render call that needs it to
        // outlive this function (see there).
        var shaped: ?Font.ShapedText = null;
        var s: Size = undefined;
        // Set when this fragment's shape holds both directions at once: no
        // byte prefix of it is a contiguous stretch of the line, so we drop
        // to the reshape-per-line path -- which shapes each final line
        // byte-range on its own and is therefore visually correct -- and
        // retreat over-wide lines to a fitting break below.
        var line_is_mixed = false;
        if (font.textSizeExShaped(cw.gpa, txt, .{
            .max_width = if (self.break_lines) width else null,
            .end_idx = &end,
            .ascent_out = &ascent,
            .base_direction = self.baseDir(),
        }) catch null) |res| {
            s = res.size;
            shaped = res.shaped;
            if (shaped) |*st| {
                if (st.line.isMixedDirection()) {
                    // Leave the unused shape for the frame arena to bulk-free
                    // (matches the "never deinit here" convention above).
                    shaped = null;
                    line_is_mixed = true;
                }
            }
        } else {
            s = font.textSizeEx(txt, .{
                .max_width = if (self.break_lines) width else null,
                .end_idx = &end,
                .ascent_out = &ascent,
            });
        }

        // ensure we always get at least 1 codepoint so we make progress
        if (end == 0) {
            end = std.unicode.utf8ByteSequenceLength(txt[0]) catch 1;
            s = if (shaped) |*st| st.measureUpToByteOffset(cw.gpa, end) catch font.textSizeEx(txt[0..end], .{}) else font.textSizeEx(txt[0..end], .{});
        }

        self.newline = Font.trailingHardBreakLen(txt[0..end]) > 0;

        //std.debug.print("{d} 1 txt to {d} \"{s}\"\n", .{ container_width, end, txt[0..end] });

        if (self.break_lines) blk: {

            // try to break on space if:
            // - slice ended due to width (not newline)
            // - linewidth is long enough (otherwise too narrow to break on space)
            if (end < txt.len and !self.newline and linewidth > (10 * msize.w)) {
                // now we are under the length limit but might be in the middle of a word
                // look one char further because we might be right at the end of a word
                if (lastLineBreakOpportunity(dvui.currentWindow().lifo(), txt, end + 1, self.line_break, self.word_break)) |brk| {
                    end = brk;
                    if (shaped) |*st| {
                        const shaped_len = st.line.byte_offsets[st.line.codepoints.len];
                        if (end <= shaped_len) {
                            // Common case: the break point falls inside
                            // what we already shaped above -- re-measure
                            // by summing already-computed advances instead
                            // of reshaping.
                            s = st.measureUpToByteOffset(cw.gpa, end) catch font.textSizeEx(txt[0..end], .{});
                        } else {
                            // Rare: the break search's one-char lookahead
                            // crossed past what was shaped. Fall back to a
                            // single reshape for this fragment (matches
                            // old behavior; `shaped` no longer matches
                            // `end` so downstream reuse is skipped too).
                            shaped = null;
                            s = font.textSizeEx(txt[0..end], .{});
                        }
                    } else {
                        s = font.textSizeEx(txt[0..end], .{});
                    }
                    break :blk; // this part will fit
                }

                // No break opportunity: this is an over-long word. Under
                // `overflow-wrap: normal` extend `end` to the word's next
                // natural break (or end of text) so it renders whole and
                // overflows rather than being char-broken; the drop-to-next-
                // line check below still moves it down first if it isn't
                // already at the line start. Under `.anywhere` (default) keep
                // the width-limited `end`, i.e. a character break.
                if (self.overflow_wrap == .normal) {
                    end = nextLineBreakOpportunity(dvui.currentWindow().lifo(), txt, end, self.line_break, self.word_break) orelse txt.len;
                    shaped = null;
                    s = font.textSizeEx(txt[0..end], .{});
                }
                // else fall through -> character break
            }

            // Bidi: the seed `end`/`s` came from a visual-prefix width walk,
            // which for reordered text can pick a byte range that reshapes
            // wider than `width`. Re-measure the real line, and if we're
            // already at the line start (so dropping down wouldn't help),
            // retreat to the previous break opportunity until it fits (or no
            // earlier break exists -- an unbreakable run, left to overflow).
            if (line_is_mixed) {
                s = font.textSizeEx(txt[0..end], .{});
                const at_line_start = !(linewidth < container_width or self.insert_pt.x > linestart);
                while (at_line_start and s.w > width and end > 0) {
                    const prev = lastLineBreakOpportunity(dvui.currentWindow().lifo(), txt, end, self.line_break, self.word_break) orelse break;
                    if (prev == 0 or prev >= end) break;
                    end = prev;
                    s = font.textSizeEx(txt[0..end], .{});
                }
                self.newline = Font.trailingHardBreakLen(txt[0..end]) > 0;
            }

            // drop to next line without doing anything if:
            // - we are boxed in too much by corner widgets
            // - we aren't starting at the left edge
            // both mean dropping to next line will give us more space
            if (s.w > width and (linewidth < container_width or self.insert_pt.x > linestart)) {
                self.checkAscent();
                self.line += 1;
                self.insert_pt.y += self.current_line_height;
                self.insert_pt.x = 0;
                self.current_line_height = 0;
                self.current_line_ascent = 0;
                self.current_line_ascent_recorded = 0;

                self.flushLine();
                self.lineBreak();

                self.first_byte_in_line = self.bytes_seen;

                continue :text_loop;
            }
        }

        // now we know the line of text we are about to render

        if (self.current_line_ascent == 0.0) {
            // this is the first text
            self.current_line_ascent = ascent;

            while (self.line_ascents.len > self.line_ascents_idx + 1 and self.line_ascents[self.line_ascents_idx].line < self.line) {
                self.line_ascents_idx += 1;
            }
            if (self.line_ascents_idx < self.line_ascents.len and self.line_ascents[self.line_ascents_idx].line == self.line) {
                self.current_line_ascent_recorded = self.line_ascents[self.line_ascents_idx].ascent;
            }
        } else if (ascent > self.current_line_ascent) {
            // we only care if the ascent got bigger, meaning we already laid
            // out some text badly, so need this info for next frame
            if (self.line_ascents_new.items.len > 0 and self.line_ascents_new.items[self.line_ascents_new.items.len - 1].line == self.line) {
                self.line_ascents_new.items[self.line_ascents_new.items.len - 1].ascent = ascent;
            } else {
                self.line_ascents_new.append(cw.arena(), .{ .line = self.line, .ascent = ascent }) catch {};
            }

            self.current_line_ascent = ascent;
        }

        if (shaped) |*st| {
            // A shape running past the fragment can't be sliced from the
            // leading end of an RTL run -- that is the wrong end, and the
            // glyphs it would keep aren't even the ones under `f.text`. So
            // reshape the fragment's own bytes, with the rest of `txt` as
            // context so the break doesn't undo any joining forms. Dropping
            // the shape instead would leave the caret to be placed from ink
            // widths, which is not where the pen is (see `fragCaretX`).
            if (st.line.isRtl() and st.line.byte_offsets[st.line.codepoints.len] != shapeableLen(txt[0..end])) {
                shaped = null;
                if (font.textSizeExShaped(cw.gpa, txt, .{
                    .item = .{ .start = 0, .end = end },
                    .base_direction = self.baseDir(),
                }) catch null) |res| {
                    if (!res.shaped.line.isMixedDirection()) {
                        shaped = res.shaped;
                        s = res.size;
                    }
                }
            }
        }

        self.line_frags.append(cw.arena(), .{
            .text = cw.arena().dupe(u8, txt[0..end]) catch txt[0..end],
            .size = s,
            .ascent = ascent,
            .shaped = shaped,
            .options = options,
            .font = font,
            .action = action,
            .action_ordinal = ordinal,
            .bytes_seen = self.bytes_seen,
            .line = self.line,
            .newline = self.newline,
            .max_ascent = @max(self.current_line_ascent, self.current_line_ascent_recorded),
            .x = self.insert_pt.x,
            .y = self.insert_pt.y,
            // Where the pen lands if this fragment closes the line; the line
            // advance below hasn't run yet, but current_line_height is final.
            .newline_pt = .{ .x = 0, .y = self.insert_pt.y + self.current_line_height },
        }) catch {};
        self.line_maybe_rtl = self.line_maybe_rtl or maybeRtl(txt[0..end]);

        // The line closes right here, so place and draw it before the layout
        // half moves on: lineBreak() below mutates the same selection state
        // emitFragment does, and used to run after it.
        if (self.newline or end < txt.len) self.flushLine();

        // Even if we don't actually render (might be outside clipping region),
        // need to update insert_pt and minSize like we did because our parent
        // might size based on that (might be in a scroll area)
        self.insert_pt.x += s.w;
        self.current_line_width += s.w;
        const size = self.data().options.padSize(.{ .w = self.current_line_width, .h = self.insert_pt.y + s.h });
        self.data().min_size.w = @max(self.data().min_size.w, size.w + width_after);
        self.data().min_size.h = @max(self.data().min_size.h, size.h);

        // discard bytes we've dealt with
        txt = txt[end..];
        self.bytes_seen += end;

        // move insert_pt to next line if we have more text
        if (self.newline or txt.len > 0) {
            self.checkAscent();
            self.line += 1;
            self.insert_pt.y += self.current_line_height;
            self.insert_pt.x = 0;
            self.current_line_height = 0;
            self.current_line_ascent = 0;
            self.current_line_ascent_recorded = 0;

            if (self.newline) {
                const newline_size = self.data().options.padSize(.{ .w = self.current_line_width, .h = self.insert_pt.y + s.h });
                self.data().min_size.w = @max(self.data().min_size.w, newline_size.w);
                self.data().min_size.h = @max(self.data().min_size.h, newline_size.h);
                self.current_line_width = 0.0;

                var last_bh_height: f32 = 0;
                if (self.byte_heights_new.items.len > 0) {
                    last_bh_height = self.byte_heights_new.items[self.byte_heights_new.items.len - 1].height;
                }

                if (self.insert_pt.y > last_bh_height + ByteHeight.dist) {
                    self.byte_height_ready = .{ .byte = self.bytes_seen, .height = self.insert_pt.y, .line = self.line };
                }
            } else if (txt.len > 0) {
                self.lineBreak();
            }

            self.first_byte_in_line = self.bytes_seen;
        }

        if (self.data().options.rect != null) {
            // we were given a rect, so don't need to calculate our min height,
            // so stop as soon as we run off the end of the clipping region
            // this helps for performance
            const nextrs = self.screenRectScale(Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y });
            if (nextrs.r.y > (dvui.clipGet().y + dvui.clipGet().h)) {
                //std.debug.print("stopping after: {s}\n", .{rtxt});
                self.flushLine();
                break :text_loop;
            }
        }
    }

    if (action == .click and (ret != null)) {
        // we can only click when not in touch editing, so that click must have
        // transitioned us into touch editing, but we don't want to transition
        // if the click happened on clickable text
        self.touch_editing = false;
    }

    return ret;
}

/// A cheap pre-filter on UTF-8 lead bytes: true unless the text provably holds
/// no character that bidi could resolve as anything but left-to-right, so
/// Latin -- and CJK, and emoji -- never run the bidi pass. Conservative by
/// construction: a truncated sequence at the end of `text` says yes.
fn maybeRtl(text: []const u8) bool {
    for (text, 0..) |b, i| {
        if (b < 0xd6) continue;
        const next: u8 = if (i + 1 < text.len) text[i + 1] else 0;
        switch (b) {
            // U+0590..U+07FF: Hebrew, Arabic, Syriac, Thaana, NKo.
            0xd6...0xdf => return true,
            // U+0800..U+08FF: Samaritan, Mandaic, Arabic Extended-A.
            0xe0 => if (next >= 0xa0) return true,
            // U+2000..U+207F: the bidi marks, embeddings and isolates.
            0xe2 => if (next <= 0x81) return true,
            // U+FB00..U+FFFF: Hebrew and Arabic presentation forms.
            0xef => if (next >= 0xac) return true,
            // U+10000..U+10FFF and U+1E000..U+1EFFF hold the RTL supplementary
            // blocks; U+1F000.. (emoji) does not.
            0xf0 => if (next == 0x90 or next == 0x9e) return true,
            else => {},
        }
    }
    return false;
}

/// Where a caret with no text to sit against goes: the pen, except that an
/// RTL paragraph starts at the right edge, so an empty line's caret belongs
/// there rather than at x=0.
fn penX(self: *TextLayoutWidget) f32 {
    if (self.baseDir() != .rtl) return self.insert_pt.x;
    if (self.insert_pt.x == 0) {
        const avail = self.data().contentRect().w;
        return if (avail == 0) 0 else avail - 1;
    }
    // The line was right-aligned after the pen moved, so `insert_pt.x` is a
    // width rather than a position.
    // ponytail: the left edge, not the logical end, on a mixed line -- this
    // is the fallback for a caret no fragment claimed.
    return self.line_left_x orelse self.insert_pt.x;
}

/// Base direction in force right now: what this paragraph's first strong
/// character resolved to, or the app-set default until one appears.
fn baseDir(self: *const TextLayoutWidget) opentype.unicode.Bidi.ParagraphDirection {
    return self.paragraph_direction orelse self.base_direction;
}

/// One same-level slice of one buffered fragment: the unit UAX #9 rule L2
/// actually reorders. A fragment straddling a level run (a highlight span
/// holding the space between an RTL word and an LTR one, say) has to be cut
/// here, because the two halves land in different places on screen.
const BidiPiece = struct {
    frag: u32,
    /// Byte range within that fragment's text.
    start: u32,
    end: u32,
    level: u8,
};

/// Runs UAX #9 over the concatenated logical text of `frags` and cuts it into
/// level runs. Bidi sees the whole line, so neutrals and weak types resolve
/// against neighbours in other fragments -- which is exactly what shaping one
/// addText chunk at a time cannot do. Returns null when every level is even,
/// i.e. the line is plain left-to-right and placement is unchanged.
fn bidiPieces(arena: std.mem.Allocator, frags: []const Fragment, base_direction: *opentype.unicode.Bidi.ParagraphDirection) ?[]BidiPiece {
    var total_bytes: usize = 0;
    for (frags) |f| total_bytes += f.text.len;
    if (total_bytes == 0) return null;

    var codepoints: std.ArrayList(u21) = .empty;
    var frag_of: std.ArrayList(u32) = .empty;
    var offset_of: std.ArrayList(u32) = .empty;
    codepoints.ensureTotalCapacityPrecise(arena, total_bytes) catch return null;
    frag_of.ensureTotalCapacityPrecise(arena, total_bytes) catch return null;
    offset_of.ensureTotalCapacityPrecise(arena, total_bytes + 1) catch return null;
    for (frags, 0..) |f, fi| {
        var it: std.unicode.Utf8Iterator = .{ .bytes = f.text, .i = 0 };
        while (true) {
            const at = it.i;
            const cp = it.nextCodepoint() orelse break;
            codepoints.appendAssumeCapacity(cp);
            frag_of.appendAssumeCapacity(@intCast(fi));
            offset_of.appendAssumeCapacity(@intCast(at));
        }
    }
    if (codepoints.items.len == 0) return null;

    const classes = arena.alloc(opentype.unicode.BidiClass, codepoints.items.len) catch return null;
    for (codepoints.items, classes) |cp, *c| c.* = opentype.unicode.BidiClass.of(cp);

    const levels = opentype.unicode.Bidi.paragraphEmbeddingLevels(arena, classes, base_direction.*, codepoints.items) catch return null;
    if (base_direction.* == .auto) {
        if (opentype.unicode.firstStrongDirection(classes)) |strong| {
            base_direction.* = if (strong == .l) .ltr else .rtl;
        }
    }

    var any_rtl = false;
    for (levels) |l| {
        if (l % 2 == 1) any_rtl = true;
    }
    if (!any_rtl) return null;

    var pieces: std.ArrayList(BidiPiece) = .empty;
    for (levels, frag_of.items, offset_of.items, 0..) |lvl, fi, off, i| {
        const cp_end: u32 = if (i + 1 < levels.len and frag_of.items[i + 1] == fi)
            offset_of.items[i + 1]
        else
            @intCast(frags[fi].text.len);
        if (pieces.items.len > 0) {
            const last = &pieces.items[pieces.items.len - 1];
            if (last.frag == fi and last.level == lvl) {
                last.end = cp_end;
                continue;
            }
        }
        pieces.append(arena, .{ .frag = fi, .start = off, .end = cp_end, .level = lvl }) catch return null;
    }
    return pieces.items;
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
fn reshapeWithNeighbourContext(frags: []Fragment, base_direction: opentype.unicode.Bidi.ParagraphDirection) void {
    if (frags.len < 2) return;
    const cw = dvui.currentWindow();
    const arena = cw.arena();

    var any = false;
    for (frags, 0..) |f, i| {
        // A different font is a different shaping run: its glyphs would be
        // context in the wrong typeface, and nothing joins across it anyway.
        const font_hash = f.font.hash();
        const before = if (i > 0 and frags[i - 1].font.hash() == font_hash) contextTail(frags[i - 1].text) else "";
        const after = if (i + 1 < frags.len and frags[i + 1].font.hash() == font_hash) contextHead(frags[i + 1].text) else "";
        const lead = if (stickyBoundary(before, f.text)) before else "";
        const trail = if (stickyBoundary(f.text, after)) after else "";
        if (lead.len == 0 and trail.len == 0) continue;

        const ctx = std.mem.concat(arena, u8, &.{ lead, f.text, trail }) catch continue;
        const res = f.font.textSizeExShaped(cw.gpa, ctx, .{
            .item = .{ .start = lead.len, .end = lead.len + f.text.len },
            .base_direction = base_direction,
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

/// Replaces the buffered line with its level-run pieces, each carrying the x
/// UAX #9 rule L2 puts it at. Pieces stay in logical order so the emit half
/// still walks the text the way the caller wrote it.
fn reorderLineVisual(self: *TextLayoutWidget) void {
    const cw = dvui.currentWindow();
    const arena = cw.arena();
    const frags = self.line_frags.items;
    var base_direction = self.paragraph_direction orelse self.base_direction;
    defer self.paragraph_direction = if (base_direction == .auto) null else base_direction;

    const pieces = bidiPieces(arena, frags, &base_direction) orelse return;

    var out: std.ArrayList(Fragment) = .empty;
    out.ensureTotalCapacityPrecise(arena, pieces.len) catch return;
    for (pieces) |p| {
        const src = frags[p.frag];
        var f = src;
        f.text = src.text[p.start..p.end];
        f.bytes_seen = src.bytes_seen + p.start;
        f.rtl = p.level % 2 == 1;
        if (p.start != 0 or p.end != src.text.len) {
            // Only the piece holding the fragment's tail closes the line.
            f.newline = src.newline and p.end == src.text.len;
            // The fragment's own shape covers bytes this piece doesn't, so
            // it is shaped again -- with the rest of the fragment as context,
            // so cutting a level run out of the middle of a word doesn't undo
            // its joining forms. The result is rebased onto the piece, so
            // both halves can slice it by byte offset.
            f.shaped = null;
            f.render_shaped = null;
            if (src.font.textSizeExShaped(cw.gpa, src.text, .{
                .item = .{ .start = p.start, .end = p.end },
                .base_direction = base_direction,
            }) catch null) |res| {
                f.size = res.size;
                f.render_shaped = res.shaped;
                if (!res.shaped.line.isMixedDirection()) f.shaped = res.shaped;
            } else {
                f.size = src.font.textSizeEx(f.text, .{});
            }
        }
        out.appendAssumeCapacity(f);
    }

    assignVisualX(arena, pieces, out.items, frags[0].x);
    self.line_frags = out;
}

/// Rule L2: walk the pieces in visual order, laying them out left to right
/// from the line's origin, and write back where each one lands. Reordering is
/// a permutation, so the line's total width doesn't change.
fn assignVisualX(arena: std.mem.Allocator, pieces: []const BidiPiece, out: []Fragment, origin: f32) void {
    const levels = arena.alloc(u8, pieces.len) catch return;
    for (pieces, levels) |p, *l| l.* = p.level;
    const order = opentype.unicode.Bidi.reorderVisual(arena, levels) catch return;

    var x = origin;
    for (order) |pi| {
        out[pi].x = x;
        x += out[pi].size.w;
    }
}

/// Right-aligns the line when the paragraph reads right to left. UAX #9
/// places runs relative to a line origin but says nothing about where that
/// origin is; for an RTL paragraph it belongs at the right edge, so the line
/// starts where the reader starts. `TextLayoutWidget` has no general
/// text-align option -- this is base direction only, not a style knob.
fn alignLineToBaseDirection(self: *TextLayoutWidget, frags: []Fragment) void {
    if (self.baseDir() != .rtl or frags.len == 0) return;
    var right = frags[0].x;
    for (frags) |f| right = @max(right, f.x + f.size.w);
    // Same fallback the layout half uses: a widget that hasn't been shown yet
    // has no content rect to align against, so leave the line where it is.
    const avail = self.data().contentRect().w;
    const shift = avail - right;
    if (avail == 0 or shift <= 0) return;
    for (frags) |*f| f.x += shift;
}

/// Places the buffered line in visual order, then draws it in logical order so
/// selection, clipboard and accesskit still see the text the way the caller
/// wrote it.
fn flushLine(self: *TextLayoutWidget) void {
    defer {
        self.line_frags.clearRetainingCapacity();
        self.line_maybe_rtl = false;
    }
    if (self.line_frags.items.len == 0) {
        self.line_end_byte = null;
        self.line_left_x = null;
        return;
    }

    // A flush can land in addTextDone/deinit/rectFor rather than in the
    // addText call that produced the fragments, so re-establish the clip
    // addTextEx set for them -- and put back whatever the caller had.
    const saved_clip = dvui.clip(self.data().contentRectScale().r);
    defer dvui.clipSet(saved_clip);

    // Each fragment snapshotted the line ascent as it stood when it was
    // buffered, so one that turned out to be taller only reached the
    // fragments after it. The line is closed now, so take the real max.
    var line_max_ascent: f32 = 0;
    for (self.line_frags.items) |f| line_max_ascent = @max(line_max_ascent, @max(f.max_ascent, f.ascent));
    for (self.line_frags.items) |*f| f.max_ascent = line_max_ascent;

    reshapeWithNeighbourContext(self.line_frags.items, self.baseDir());
    // An RTL base direction reorders lines holding no RTL character at all:
    // digits take an even level above it and the neutrals between them the
    // odd base level, so `line_maybe_rtl` alone is not the whole gate.
    if (self.line_maybe_rtl or self.baseDir() == .rtl) self.reorderLineVisual();
    self.alignLineToBaseDirection(self.line_frags.items);
    self.line_end_byte = lineEndByte(self.line_frags.items);
    var left = self.line_frags.items[0].x;
    for (self.line_frags.items) |f| left = @min(left, f.x);
    self.line_left_x = left;
    for (self.line_frags.items, 0..) |f, i| self.emitFragment(f, i);

    // A caret at the end of the text with `.after` affinity -- what Ctrl+End
    // leaves -- points at the start of a line that never comes, so no
    // fragment claims it. Take it here, while the line it actually sits on is
    // still placed, or a visual key step finds no stops to walk and falls
    // back to a logical one: on an RTL line, a step the wrong way.
    if (self.add_text_done and !self.cursor_seen) {
        const last = self.line_frags.items[self.line_frags.items.len - 1];
        self.cursor_rect = .{ .x = self.penX(), .y = last.y, .w = 1, .h = last.size.h };
        self.cursorSeen();
    }

    // A hard break ends the paragraph, so the next one resolves P2 afresh.
    if (self.line_frags.items[self.line_frags.items.len - 1].newline) self.paragraph_direction = null;
}

/// One laid-out fragment, ready to draw. Everything here is decided by the
/// layout half of `addTextEx`; emitting is pure logical-order work (selection,
/// cursor, clipboard, accesskit, render), so `x`/`y` are the only inputs that
/// visual reordering has to change.
const Fragment = struct {
    text: []const u8,
    size: Size,
    ascent: f32,
    /// Prefix-safe shape of `text`: set unless the shape mixes both
    /// directions, in which case no byte prefix of it covers a contiguous
    /// stretch of the line. A single RTL run is fine -- the emit half asks
    /// for prefixes by cluster, not by leading glyph.
    shaped: ?Font.ShapedText,
    /// Whole-fragment shape taken with the neighbouring text as context, so
    /// Arabic joining forms and cross-boundary kerning are right. Valid for
    /// rendering only -- an RTL one's glyphs are in visual order.
    render_shaped: ?Font.ShapedText = null,
    options: Options,
    font: Font,
    action: AddTextExAction,
    /// Index of the owning addTextClick/addTextHover call within the frame.
    action_ordinal: usize,
    /// Logical byte offset of `text` within the widget's text.
    bytes_seen: usize,
    line: usize,
    newline: bool,
    max_ascent: f32,
    x: f32,
    y: f32,
    /// Odd bidi embedding level: this piece reads right to left, so its
    /// logical prefix occupies the *right* of `[x, x + size.w)`.
    rtl: bool = false,
    /// Pen origin after this fragment closes its line; only read when `newline`.
    newline_pt: Point,
};

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
fn fragCaretX(f: Fragment, off: usize) f32 {
    if (f.shaped) |shaped| {
        var st = shaped;
        return f.x + st.caretOffset(off);
    }
    return caretX(f, f.font.textSize(f.text[0..off]).w);
}

/// A hit found while emitting is answered next frame; refresh so a still
/// mouse over static text gets that frame.
fn recordHit(self: *TextLayoutWidget, action: AddTextExAction, hit: DeferredHit) void {
    const answered = if (action == .click) self.deferred_click else self.deferred_hover;
    const already_answered = if (answered) |h| h.ordinal == hit.ordinal else false;
    if (action == .click) {
        self.deferred_click_new = hit;
    } else {
        self.deferred_hover_new = hit;
    }
    if (!already_answered) dvui.refresh(null, @src(), self.data().id);
}

/// Bytes of `text` a shape can cover: shaping stops at the first hard break,
/// so a fragment ending in a newline is shaped that newline short.
fn shapeableLen(text: []const u8) usize {
    return if (Font.firstHardBreak(text)) |hb| hb.start else text.len;
}

fn emitFragment(self: *TextLayoutWidget, f: Fragment, index: usize) void {
    const cw = dvui.currentWindow();
    var shaped = f.shaped;
    // How many leading glyphs of
    // `shaped` (if any) correspond to `f.text`, for reuse by
    // cursor/selection tracking and the render call below. Leading is the
    // wrong end of an RTL run, so a shape that overruns the fragment must
    // already have been dropped (see addTextEx).
    if (shaped) |*st| std.debug.assert(!st.line.buffer.isRtl() or st.line.byte_offsets[st.line.codepoints.len] == shapeableLen(f.text));
    const shaped_glyph_limit: ?usize = if (shaped) |*st| st.line.glyphLimitForByteOffset(f.text.len) else null;
    // see if selection needs to be updated

    // if the text changed our selection might be in the middle of utf8 chars, so fix it up
    while (self.selection.start >= f.bytes_seen and self.selection.start < f.bytes_seen + f.text.len and f.text[self.selection.start - f.bytes_seen] & 0xc0 == 0x80) {
        self.selection.start += 1;
    }

    while (self.selection.cursor >= f.bytes_seen and self.selection.cursor < f.bytes_seen + f.text.len and f.text[self.selection.cursor - f.bytes_seen] & 0xc0 == 0x80) {
        self.selection.cursor += 1;
    }

    while (self.selection.end >= f.bytes_seen and self.selection.end < f.bytes_seen + f.text.len and f.text[self.selection.end - f.bytes_seen] & 0xc0 == 0x80) {
        self.selection.end += 1;
    }

    if (f.action != .none) {
        if (self.cursor_pt) |p| {
            const rs = Rect{ .x = f.x, .y = f.y, .w = f.size.w, .h = f.size.h };
            if (p.x > rs.x and p.x < (rs.x + rs.w) and p.y > rs.y and p.y < (rs.y + rs.h)) {
                // point is in this text
                if (f.action == .click) {
                    dvui.cursorSet(.hand);
                } else if (f.action == .hover) {
                    self.recordHit(.hover, .{ .ordinal = f.action_ordinal, .event = self.cursor_event.?, .rect = rs });
                }
            }
        }

        if (self.click_pt) |p| {
            const rs = Rect{ .x = f.x, .y = f.y, .w = f.size.w, .h = f.size.h };
            if (p.x > rs.x and p.x < (rs.x + rs.w) and p.y > rs.y and p.y < (rs.y + rs.h)) {
                if (f.action == .click) {
                    self.recordHit(.click, .{ .ordinal = f.action_ordinal, .event = self.click_event.?, .rect = rs });
                }
            }
        }
    }

    // handle selection movement
    self.selMovePre(f, index);

    if (self.sel_pts[0] != null or self.sel_pts[1] != null) {
        var sel_bytes = [2]?usize{ null, null };
        for (self.sel_pts, 0..) |maybe_pt, i| {
            if (maybe_pt) |p| {
                if (self.hitHere(p, index)) |ba| {
                    sel_bytes[i] = ba.byte;
                    self.sel_pts[i] = null;
                } else {
                    // haven't found it yet, but we might not get anymore
                    sel_bytes[i] = f.bytes_seen + f.text.len;
                }
            }
        }

        //std.debug.print("sel_bytes {?d} {?d}\n", .{ sel_bytes[0], sel_bytes[1] });

        // start off getting both, then maybe getting one
        if (sel_bytes[0] != null and sel_bytes[1] != null) {
            self.selection.cursor = @min(sel_bytes[0].?, sel_bytes[1].?);
            self.selection.start = @min(sel_bytes[0].?, sel_bytes[1].?);
            self.selection.end = @max(sel_bytes[0].?, sel_bytes[1].?);

            // changing touch selection, need to refresh to move draggables
            dvui.refresh(null, @src(), self.data().id);
        } else if (sel_bytes[0] != null or sel_bytes[1] != null) {
            self.selection.end = sel_bytes[0] orelse sel_bytes[1].?;
        }
    }

    // record screen position of selection for touch editing (use s for
    // height in case we are calling textSize with an empty slice)
    if (self.selection.start >= f.bytes_seen and self.selection.start <= f.bytes_seen + f.text.len) {
        const off = self.selection.start -| f.bytes_seen;
        self.sel_start_r_new = .{ .x = fragCaretX(f, off), .y = f.y, .w = 1, .h = f.size.h };
        self.sel_start_rtl_new = f.rtl;
    }

    if (self.selection.end >= f.bytes_seen and self.selection.end <= f.bytes_seen + f.text.len) {
        const off = self.selection.end -| f.bytes_seen;
        self.sel_end_r_new = .{ .x = fragCaretX(f, off), .y = f.y, .w = 1, .h = f.size.h };
        self.sel_end_rtl_new = f.rtl;
    }

    if (!self.cursor_seen and (self.selection.cursor < f.bytes_seen + f.text.len or (self.selection.cursor == f.bytes_seen + f.text.len and self.selection.affinity == .before))) {
        std.debug.assert(self.selection.cursor >= f.bytes_seen);
        const cursor_offset = self.selection.cursor - f.bytes_seen;
        const text_to_cursor = f.text[0..cursor_offset];
        self.cursor_rect = Rect{ .x = fragCaretX(f, cursor_offset), .y = f.y, .w = 1, .h = f.size.h };

        self.selMoveText(text_to_cursor, f.bytes_seen);
        self.cursorSeen(); // might alter selection
        self.selMoveText(f.text[cursor_offset..], f.bytes_seen + cursor_offset);
    } else {
        self.selMoveText(f.text, f.bytes_seen);
    }

    { // Scope here is for deallocating rtxt before handling copying to clipboard on the arena
        const max_ascent = f.max_ascent;
        const y = f.y + (max_ascent - f.ascent);
        const r: Rect = .{ .x = f.x, .y = y, .w = f.size.w, .h = @min(f.size.h, self.data().contentRect().h - y) };
        const rs = self.screenRectScale(r);
        //std.debug.print("renderText: {} {s}\n", .{ rs.r, f.text });
        const rtxt = f.text;

        const textrun_info: ?AccessKit.TextRunOptions = info: {
            if (dvui.accesskit_enabled and cw.accesskit.text_run_parent != null) {
                if (cw.accesskit.nodes.get(cw.accesskit.text_run_parent.?)) |_| {
                    var text_run_widget = dvui.overlay(textRunSrc(), .{
                        .name = "Text Run",
                        .role = .text_run,
                        .id_extra = f.bytes_seen,
                        .rect = r,
                    });
                    defer text_run_widget.deinit();
                    // `pos` is an AccessKit character index into this run's
                    // own text, not a byte offset into the widget's.
                    self.textrun_last = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, rtxt.len) };
                    if (!self.selection.empty()) {
                        if (self.textrun_focus == null and self.selection.cursor >= f.bytes_seen and self.selection.cursor < f.bytes_seen + rtxt.len) {
                            self.textrun_focus = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, self.selection.cursor - f.bytes_seen) };
                        }
                        if (self.textrun_anchor == null) {
                            const anchor = if (self.selection.cursor == self.selection.start) self.selection.end else self.selection.start;
                            if (anchor >= f.bytes_seen and anchor < f.bytes_seen + rtxt.len) {
                                self.textrun_anchor = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, anchor - f.bytes_seen) };
                            }
                        }
                    }
                    if (self.textrun_cursor == null and self.selection.cursor >= f.bytes_seen and self.selection.cursor < f.bytes_seen + rtxt.len) {
                        self.textrun_cursor = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, self.selection.cursor - f.bytes_seen) };
                    }
                    break :info .{
                        .node_id = text_run_widget.data().id,
                        .node_parent_id = cw.accesskit.text_run_parent.?,
                        .controlling_widget_id = if (self.data().options.role.? == .none) cw.accesskit.text_run_parent.? else self.data().id,
                        .line = f.line,
                        .byte_offset = f.bytes_seen,
                        .rtl = f.rtl,
                    };
                }
            }
            break :info null;
        };

        // Hand the shape from above to renderText instead of letting
        // it reshape `rtxt` from scratch -- but it needs to outlive
        // this function (a floating window's render can be deferred to
        // later this frame), so copy the small `ShapedText` header
        // (not the shape's own arrays, already arena-owned) onto
        // `cw.arena()` rather than pointing at this stack frame.
        var render_glyph_limit = shaped_glyph_limit;
        const pre_shaped: ?*const Font.ShapedText = blk: {
            // The context shape covers exactly `f.text`, so it needs no
            // glyph limit, where `shaped` can still run past the fragment.
            const st = f.render_shaped orelse shaped orelse break :blk null;
            if (f.render_shaped != null) render_glyph_limit = st.line.buffer.info.items.len;
            const p = cw.arena().create(Font.ShapedText) catch break :blk null;
            p.* = st;
            break :blk p;
        };

        // Sampled against this run's own `rs.r`, so a gradient resets at
        // each line/style-run boundary; set `gradient.anchor` to a
        // shared rect (e.g. the whole TextLayoutWidget) for a continuous
        // sweep across multiple lines/runs.
        const text_col = f.options.color(.text).split();
        dvui.renderText(.{
            .font = f.font,
            .text = rtxt,
            .rs = rs,
            .color = text_col.color,
            .gradient = text_col.gradient,
            // TODO: Should this take `f.options.background` into account?
            .background_color = if (f.options.color_fill) |cog| cog.toColor() else null,
            .sel_start = self.selection.start -| f.bytes_seen,
            .sel_end = self.selection.end -| f.bytes_seen,
            .sel_color = (dvui.themeGet().text_select orelse dvui.themeGet().color(.highlight, .fill)).opacity(0.75),
            .ak_opts = textrun_info,
            .pre_shaped = pre_shaped,
            .pre_shaped_glyph_limit = render_glyph_limit,
        }) catch |err| {
            dvui.logError(@src(), err, "Failed to render text: {s}", .{rtxt});
        };
    }

    if (self.copy_sel) |sel| {
        // we are copying to clipboard
        if (sel.start < f.bytes_seen + f.text.len) {
            // need to copy some
            const cstart = if (sel.start < f.bytes_seen) 0 else (sel.start - f.bytes_seen);
            const cend = if (sel.end < f.bytes_seen + f.text.len) (sel.end - f.bytes_seen) else f.text.len;

            // initialize or realloc
            if (self.copy_slice) |slice| {
                const old_len = slice.len;
                self.copy_slice = cw.arena().realloc(slice, slice.len + (cend - cstart)) catch slice;
                if (self.copy_slice.?.len == old_len) {
                    dvui.log.debug("copy_slice realloc failed, copying will be incomplete", .{});
                } else {
                    @memcpy(self.copy_slice.?[old_len..], f.text[cstart..cend]);
                }
            } else {
                self.copy_slice = cw.arena().dupe(u8, f.text[cstart..cend]) catch |err| blk: {
                    dvui.logError(@src(), err, "Could not allocate copy slice for text: {s}", .{f.text[cstart..cend]});
                    break :blk null;
                };
            }

            // push to clipboard if done
            if (sel.end <= f.bytes_seen + f.text.len) {
                dvui.clipboardTextSet(self.copy_slice.?);
                self.copy_sel = null;
                cw.arena().free(self.copy_slice.?);
                self.copy_slice = null;
            }
        }
    }

    if (!self.cursor_seen) {
        // until we see the cursor, record the last position it could be
        // in, could be moving to a new line next iteration
        self.cursor_rect = Rect{ .x = fragCaretX(f, f.text.len), .y = f.y, .w = 1, .h = f.size.h };
    }

    if (f.newline and (self.selection.start == f.bytes_seen + f.text.len)) {
        self.sel_start_r_new = .{ .x = f.newline_pt.x, .y = f.newline_pt.y, .w = 1, .h = f.size.h };
        self.sel_start_rtl_new = f.rtl;
    }

    if (f.newline and (self.selection.end == f.bytes_seen + f.text.len)) {
        self.sel_end_r_new = .{ .x = f.newline_pt.x, .y = f.newline_pt.y, .w = 1, .h = f.size.h };
        self.sel_end_rtl_new = f.rtl;
    }
}

pub fn addTextDone(self: *TextLayoutWidget, opts: Options) void {
    if (self.add_text_done) {
        dvui.log.debug("TextLayoutWidget {x} addTextDone() called multiple times", .{self.data().id});
    }

    // Set before the flush: it tells the last line that no fragment is coming
    // to claim a caret sitting past its end.
    self.add_text_done = true;

    self.flushLine();

    self.checkAscent();

    if (self.cache_layout and self.byte_heights.len > 0) {
        var edit_height: f32 = undefined;
        if (self.byte_height_after_idx) |i| {
            // this is not the final one
            const bh = self.byte_heights[i];

            // we expected to end at bh.height without edits, this is the extra
            // height the edits gave (might be negative)
            edit_height = self.insert_pt.y - bh.height;
            const edit_bytes: i64 = @as(i64, @intCast(self.bytes_seen)) - @as(i64, @intCast(bh.byte));
            const edit_lines: i64 = @as(i64, @intCast(self.line)) - @as(i64, @intCast(bh.line));

            // these are the height and bytes we are skipping
            const extra_height = self.byte_heights[self.byte_heights.len - 1].height - bh.height;
            const extra_bytes = self.byte_heights[self.byte_heights.len - 1].byte - bh.byte;
            self.bytes_seen += extra_bytes;

            // set min height
            const end_size = self.data().options.padSize(.{ .h = self.insert_pt.y + extra_height });
            self.data().min_size.h = @max(self.data().min_size.h, end_size.h);

            // adjust for edits
            for (self.byte_heights[i..self.byte_heights.len]) |*bhh| {
                bhh.height += edit_height;
                if (edit_bytes >= 0) {
                    bhh.byte += @intCast(edit_bytes);
                } else {
                    bhh.byte -= @intCast(-edit_bytes);
                }
                if (edit_lines >= 0) {
                    bhh.line += @intCast(edit_lines);
                } else {
                    bhh.line -= @intCast(-edit_lines);
                }
            }

            // copy all the ByteHeights we skipped, but not the final one
            self.byte_heights_new.appendSlice(dvui.currentWindow().arena(), self.byte_heights[i .. self.byte_heights.len - 1]) catch {};

            var k: usize = self.line_ascents_idx;
            while (k < self.line_ascents.len and self.line_ascents[k].line < self.line) k += 1;
            for (self.line_ascents[k..self.line_ascents.len]) |*la| {
                if (edit_lines >= 0) {
                    la.line += @intCast(edit_lines);
                } else {
                    la.line -= @intCast(-edit_lines);
                }
            }
            self.line_ascents_new.appendSlice(dvui.currentWindow().arena(), self.line_ascents[k..self.line_ascents.len]) catch {};
        } else {
            // use the final one
            var bh = &self.byte_heights[self.byte_heights.len - 1];

            // we expected to end at bh.height without edits, this is the extra
            // height the edits gave (might be negative)
            const os = self.data().options;
            const contentMinSize = self.data().min_size.padNeg(os.paddingGet()).padNeg(os.borderGet()).padNeg(os.marginGet());
            edit_height = contentMinSize.h - bh.height;

            // adjust previous height for sanity check below
            bh.height += edit_height;
        }

        std.debug.assert(self.cache_layout_bytes_seen == self.bytes_seen);
        //std.debug.print("edit_height {d}\n", .{edit_height});

        // TODO: if edit_height is negative, we might not render some text for a frame - need to scan further in byte_heights until we find one that is not visible
    }

    const os = self.data().options;
    const contentMinSize = self.data().min_size.padNeg(os.paddingGet()).padNeg(os.borderGet()).padNeg(os.marginGet());
    self.byte_heights_new.append(dvui.currentWindow().arena(), .{ .byte = self.bytes_seen, .height = contentMinSize.h, .line = self.line }) catch {};

    if (self.cache_layout and self.byte_heights.len > 0) {
        // sanity check
        const old = self.byte_heights[self.byte_heights.len - 1].height;
        const new = self.byte_heights_new.items[self.byte_heights_new.items.len - 1].height;
        if (new < (old - 1.0) or new > (old + 1.0)) {
            dvui.logError(@src(), error.CacheLayoutError, "the height of the processed text changed by {d}, cache_layout should have been false this frame", .{new - old});
            self.byte_heights_new.clearAndFree(dvui.currentWindow().arena());
        }
    }
    //std.debug.print("final height: {d} at {d}\n", .{ contentMinSize.h, self.bytes_seen });

    //const crs = self.data().contentRectScale();
    //for (self.byte_heights_new.items) |bhn| {
    //    //std.debug.print("bh: {d} - {d}\n", .{ bhn.byte, bhn.height });
    //    const p: dvui.Path = .{ .points = &.{
    //        crs.pointToPhysical(.{ .x = 0, .y = bhn.height }),
    //        crs.pointToPhysical(.{ .x = 100, .y = bhn.height }),
    //    } };
    //    p.stroke(.{ .thickness = 1, .color = .red });
    //}

    self.selection.cursor = @min(self.selection.cursor, self.bytes_seen);
    self.selection.start = @min(self.selection.start, self.bytes_seen);
    self.selection.end = @min(self.selection.end, self.bytes_seen);

    const options = self.data().options.override(opts);
    const text_height = options.fontGet().textHeight();

    if (!self.cursor_seen) {
        self.cursor_rect = Rect{ .x = self.penX(), .y = self.insert_pt.y, .w = 1, .h = text_height };
        self.cursorSeen();
    }

    if (self.copy_sel) |_| {
        // we are copying to clipboard and never stopped
        dvui.clipboardTextSet(self.copy_slice orelse "");

        self.copy_sel = null;
        if (self.copy_slice) |cs| {
            dvui.currentWindow().arena().free(cs);
        }
        self.copy_slice = null;
    }

    // handle selection movement
    // - this logic must work even if addText() is never called
    switch (self.sel_move) {
        .none => {},
        .mouse => |*m| {
            if (m.down_pt) |_| {
                m.byte = self.bytes_seen;
                self.selection.moveCursor(self.bytes_seen, false);
                m.down_pt = null;
            }

            if (m.drag_pt) |_| {
                self.selection.cursor = self.bytes_seen;
                self.selection.start = @min(m.byte.?, self.bytes_seen);
                self.selection.end = @max(m.byte.?, self.bytes_seen);
                m.drag_pt = null;
            }
        },
        .expand_pt => |*ep| {
            if (!ep.done and !ep.select) {
                self.selection.moveCursor(self.selection.cursor, false);
            }
        },
        .char_left_right => {},
        .cursor_updown => |*cud| {
            if (cud.pt) |_| {
                self.selection.moveCursor(self.bytes_seen, cud.select);
                cud.pt = null;
            }
        },
        .word_left_right => {},
    }

    if (self.sel_start_r_new) |start_r| {
        if (!self.sel_start_r.equals(start_r)) {
            dvui.refresh(null, @src(), self.data().id);
        }
        self.sel_start_r = start_r;
        self.sel_start_rtl = self.sel_start_rtl_new;
    }

    if (self.selection.start > self.bytes_seen or self.bytes_seen == 0) {
        self.sel_start_r = .{ .x = self.penX(), .y = self.insert_pt.y, .w = 1, .h = text_height };
        self.sel_start_rtl = self.baseDir() == .rtl;
        if (self.selection.start > self.bytes_seen) {
            dvui.refresh(null, @src(), self.data().id);
        }
    }

    if (self.sel_end_r_new) |end_r| {
        if (!self.sel_end_r.equals(end_r)) {
            dvui.refresh(null, @src(), self.data().id);
        }
        self.sel_end_r = end_r;
        self.sel_end_rtl = self.sel_end_rtl_new;
    }

    if (self.selection.end > self.bytes_seen or self.bytes_seen == 0) {
        self.sel_end_r = .{ .x = self.penX(), .y = self.insert_pt.y, .w = 1, .h = text_height };
        self.sel_end_rtl = self.baseDir() == .rtl;
        if (self.selection.end > self.bytes_seen) {
            dvui.refresh(null, @src(), self.data().id);
        }
    }

    const cw = dvui.currentWindow();
    if (dvui.accesskit_enabled) if (cw.accesskit.text_run_parent) |text_run_parent| {
        if (cw.accesskit.nodes.get(text_run_parent)) |parent_node| {
            if (self.bytes_seen == 0 or self.newline) {
                // No empty text run was created as no text was rendered. Create one here.
                self.textRunCreateEmpty(if (self.data().options.role.? == .none) cw.accesskit.text_run_parent.? else self.data().id, self.bytes_seen == 0);
            }

            if (!self.selection.empty()) {
                self.textrun_anchor = self.textrun_anchor orelse self.textrun_last;
                self.textrun_focus = self.textrun_focus orelse self.textrun_last;

                if (self.textrun_anchor) |anchor| {
                    if (self.textrun_focus) |focus| {
                        AccessKit.nodeSetTextSelection(parent_node, .{
                            .anchor = .{ .node = anchor.node_id.asU64(), .character_index = anchor.pos },
                            .focus = .{ .node = focus.node_id.asU64(), .character_index = focus.pos },
                        });
                    }
                }
            } else {
                // if we didn't find the cursor, it must be at the end
                if (self.textrun_cursor orelse self.textrun_last) |cursor| {
                    AccessKit.nodeSetTextSelection(parent_node, .{
                        .anchor = .{ .node = cursor.node_id.asU64(), .character_index = cursor.pos },
                        .focus = .{ .node = cursor.node_id.asU64(), .character_index = cursor.pos },
                    });
                }
            }
        }
    };
}

/// Creates an empty text run
/// make sure to set accesskit.text_run_parent before calling.
pub fn textRunCreateEmpty(self: *TextLayoutWidget, controlling_widget: dvui.Id, first_line: bool) void {
    const text_height = self.data().options.fontGet().textHeight();

    const crect = self.data().contentRect();
    const empty_space: Rect = .{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = @max(0, @min(text_height, crect.h - self.insert_pt.y)) };
    var vp = dvui.overlay(if (first_line) textRunSrc() else @src(), .{ .name = "Text Run", .role = .text_run, .rect = empty_space });
    defer vp.deinit();
    // An empty run has one place to be: character 0.
    self.textrun_last = .{ .node_id = vp.data().id, .pos = 0 };
    dvui.currentWindow().accesskit.textRunCreateEmpty(
        vp.data().id,
        controlling_widget,
        self.line,
        self.bytes_seen,
        self.data().contentRectScale().rectToPhysical(empty_space),
    );
}

pub fn touchEditing(self: *TextLayoutWidget) ?*FloatingWidget {
    if (self.touch_editing and self.te_show_context_menu and self.focus_at_start and self.data().visible()) {
        self.te_floating.init(@src(), .{
            .from = self.data().rectScale().r.intersect(dvui.clipGet()).topRight(),
            .from_gravity_x = 0,
            .from_gravity_y = 0,
        }, .{});
        return &self.te_floating;
    }

    return null;
}

pub fn touchEditingMenu(self: *TextLayoutWidget) void {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .corners = dvui.ButtonWidget.defaults.cornersGet(),
        .background = true,
        .border = dvui.Rect.all(1),
    });
    defer hbox.deinit();

    if (dvui.buttonIcon(
        @src(),
        "select all",
        dvui.entypo.swap,
        .{},
        .{},
        .{ .min_size_content = .{ .h = 20 }, .margin = Rect.all(2) },
    )) {
        self.selection.selectAll();
    }

    if (dvui.buttonIcon(
        @src(),
        "copy",
        dvui.entypo.copy,
        .{},
        .{},
        .{ .min_size_content = .{ .h = 20 }, .margin = Rect.all(2) },
    )) {
        self.copy();
    }
}

pub fn widget(self: *TextLayoutWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *TextLayoutWidget) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *TextLayoutWidget, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    // A child widget draws as soon as it is created, so text added before it
    // has to be on screen first -- and its own geometry is not something the
    // bidi pass can reorder around.
    self.flushLine();

    _ = id;

    // For corner widgets, they might want to be closer to the border than the
    // text, so fit them without padding, but then need to adjust origin
    // because screenRectScale assumes we placed in the contentRect
    var ret = dvui.placeIn(self.data().backgroundRect().justSize(), min_size, e, g);
    ret.x -= self.data().options.paddingGet().x;
    ret.y -= self.data().options.paddingGet().y;

    const i: usize = if (g.y < 0.5) if (g.x < 0.5)
        0 // upleft
    else
        1 // upright
    else if (g.x < 0.5)
        2 // downleft
    else
        3; // downright

    self.corners[i] = ret;
    self.corners_last_seen = @intCast(i);
    return ret;
}

pub fn screenRectScale(self: *TextLayoutWidget, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *TextLayoutWidget, s: Size) void {
    if (self.corners_last_seen) |ls| {
        self.corners_min_size[ls] = s;
    }
    // we calculate our min size in deinit() after we have seen our text
}

// Using this function helps prevent accidentally using the selection when the
// end is way too large, because the way we do select all is to set end to
// maxInt(usize) and fix it up the next frame.
//
// Either the caller knows the max (like TextEntryWidget), or they can pass
// maxInt(usize) and be clued into what might happen.
pub fn selectionGet(self: *TextLayoutWidget, max: usize) *Selection {
    self.selection.start = @min(self.selection.start, max);
    self.selection.cursor = @min(self.selection.cursor, max);
    self.selection.end = @min(self.selection.end, max);
    return self.selection;
}

pub fn matchEvent(self: *TextLayoutWidget, e: *Event) bool {
    if (self.touch_editing and e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.touch()) {
        self.te_show_draggables = true;
        self.te_show_context_menu = true;
        dvui.refresh(null, @src(), self.data().id);
    }

    return dvui.eventMatchSimple(e, self.data());
}

pub fn processEvents(self: *TextLayoutWidget) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e);
    }
}

pub fn processEvent(self: *TextLayoutWidget, e: *Event) void {
    switch (e.evt) {
        .mouse => |me| {
            if (me.action == .focus) {
                e.handle(@src(), self.data());
                // focus so that we can receive keyboard input
                dvui.focusWidget(self.data().id, null, e.num);
            } else if (me.action == .press and (me.button.pointer() or me.button == .middle)) {
                e.handle(@src(), self.data());
                // capture and start drag
                dvui.captureMouse(self.data(), e.num);
                dvui.dragPreStart(me.button, me.p, .{ .cursor = .ibeam });

                if (me.button.touch()) {
                    self.te_focus_on_touchdown = self.focus_at_start;
                    if (self.touch_editing) {
                        self.te_show_context_menu = false;

                        // need to refresh draggables
                        dvui.refresh(null, @src(), self.data().id);
                    }
                } else if (me.button.pointer()) {
                    // a click always sets sel_move - has the highest priority
                    const p = self.data().contentRectScale().pointFromPhysical(me.p);
                    self.sel_move = .{ .mouse = .{ .down_pt = p } };
                    self.scroll_to_cursor = true;

                    if (self.click_num == 1) {
                        // select word we touched
                        self.sel_move = .{ .expand_pt = .{ .which = .word, .pt = p } };
                    } else if (self.click_num == 2) {
                        // select line we touched
                        self.sel_move = .{ .expand_pt = .{ .which = .line, .pt = p } };
                    }
                }
            } else if (me.action == .release and (me.button.pointer() or me.button == .middle)) {
                e.handle(@src(), self.data());

                if (dvui.captured(self.data().id)) {
                    if (!self.touch_editing and dvui.dragging(me.p, null) == null) {
                        // click without drag
                        self.click_pt = self.data().contentRectScale().pointFromPhysical(me.p);
                        self.click_event = e.evt;

                        if (me.button.pointer()) {
                            self.click_num += 1;
                            self.click_num_pt = me.p;
                            if (self.click_num >= 3) {
                                self.click_num = 0;
                            }
                        }
                    }

                    if (me.button.touch()) {
                        // this was a touch-release without drag, which transitions
                        // us between touch editing
                        const p = self.data().contentRectScale().pointFromPhysical(me.p);

                        if (self.te_focus_on_touchdown) {
                            self.touch_editing = !self.touch_editing;
                            // move cursor to point
                            self.sel_move = .{ .mouse = .{ .down_pt = p } };
                            if (self.touch_editing) {
                                // select word we touched
                                self.sel_move = .{ .expand_pt = .{ .which = .word, .pt = p } };
                            }
                        } else {
                            if (self.touch_edit_just_focused) {
                                self.touch_editing = true;
                            }
                            if (self.te_first) {
                                // This is the very first time we are entering
                                // touch editing from not having focus, we want to
                                // position the cursor.
                                self.te_first = false;

                                // select word we touched
                                self.sel_move = .{ .expand_pt = .{ .which = .word, .pt = p } };
                            }
                        }
                        dvui.refresh(null, @src(), self.data().id);
                    }

                    dvui.captureMouse(null, e.num);
                    dvui.dragEnd();
                }
            } else if (me.action == .motion and dvui.captured(self.data().id)) {
                if (dvui.dragging(me.p, null)) |_| {
                    self.click_num = 0;
                    if (!me.button.touch()) {
                        e.handle(@src(), self.data());
                        if (self.sel_move == .mouse) {
                            self.sel_move.mouse.drag_pt = self.data().contentRectScale().pointFromPhysical(me.p);
                        } else if (self.sel_move == .expand_pt) {
                            self.sel_move.expand_pt.pt = self.data().contentRectScale().pointFromPhysical(me.p);
                            self.sel_move.expand_pt.done = false;
                            self.sel_move.expand_pt.dragging = true;
                        }
                        dvui.scrollDrag(.{
                            .mouse_pt = me.p,
                            .screen_rect = self.data().rectScale().r,
                        });
                    } else {
                        // user intended to scroll with a finger swipe
                        // release our capture including this event so a
                        // containing scroll container can get it
                        dvui.captureMouse(null, e.num - 1); // stop possible drag and capture
                        dvui.dragEnd();
                    }
                }
            } else if (me.action == .motion) {
                if (self.click_num > 0) {
                    const dp = me.p.diff(self.click_num_pt).toNatural();
                    if (@abs(dp.x) > dvui.Dragging.threshold or @abs(dp.y) > dvui.Dragging.threshold) {
                        self.click_num = 0;
                    }
                }
            } else if (me.action == .position) {
                self.cursor_pt = self.data().contentRectScale().pointFromPhysical(me.p);
                self.cursor_event = e.evt;
            }
        },
        .key => |ke| blk: {
            if (ke.action == .down and ke.matchBind("text_start_select")) {
                e.handle(@src(), self.data());
                self.selection.moveCursor(0, true);
                self.scroll_to_cursor = true;
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("text_end_select")) {
                e.handle(@src(), self.data());
                self.selection.moveCursor(std.math.maxInt(usize), true);
                self.scroll_to_cursor = true;
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("line_start_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .expand_pt = .{ .which = .home } };
                }
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("line_end_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .expand_pt = .{ .which = .end } };
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("word_left_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .word_left_right = .{} };
                }
                if (self.sel_move == .word_left_right) {
                    self.sel_move.word_left_right.count += self.logicalStep(false);
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("word_right_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .word_left_right = .{} };
                }
                if (self.sel_move == .word_left_right) {
                    self.sel_move.word_left_right.count += self.logicalStep(true);
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_left_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .char_left_right = .{} };
                }
                if (self.sel_move == .char_left_right) {
                    self.sel_move.char_left_right.count -= 1;
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_right_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .char_left_right = .{} };
                }
                if (self.sel_move == .char_left_right) {
                    self.sel_move.char_left_right.count += 1;
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_up_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .cursor_updown = .{} };
                }
                if (self.sel_move == .cursor_updown) {
                    self.sel_move.cursor_updown.count -= 1;
                }
                break :blk;
            }

            if ((ke.action == .down or ke.action == .repeat) and ke.matchBind("char_down_select")) {
                e.handle(@src(), self.data());
                if (self.sel_move == .none) {
                    self.sel_move = .{ .cursor_updown = .{} };
                }
                if (self.sel_move == .cursor_updown) {
                    self.sel_move.cursor_updown.count += 1;
                }
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("copy")) {
                e.handle(@src(), self.data());
                self.copy();
                break :blk;
            }

            if (ke.action == .down and ke.matchBind("select_all")) {
                e.handle(@src(), self.data());
                self.selection.selectAll();
                break :blk;
            }
        },
        .text => |te| {
            switch (te.action) {
                .selection => |sel| {
                    self.selection.moveCursor(sel.start, false);
                    self.selection.moveCursor(sel.end, true);
                    self.scroll_to_cursor = true;
                },
                else => {},
            }
        },
        else => {},
    }
}

// must be called before addText()
pub fn copy(self: *TextLayoutWidget) void {
    self.copy_sel = self.selection.*;
}

pub fn deinit(self: *TextLayoutWidget) void {
    // addTextDone() normally drains this; a caller that skipped it must not
    // lose the last line.
    self.flushLine();

    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    if (!self.add_text_done) {
        self.addTextDone(.{});
    }

    if (self.process_events_in_deinit) {
        // handle mouse cursor here after all addText because some might set the cursor
        const evts = dvui.events();
        for (evts) |*e| {
            if (!self.matchEvent(e))
                continue;

            if (e.evt == .mouse and e.evt.mouse.action == .position) {
                dvui.cursorSet(.ibeam);
            }
        }
    }

    if (dvui.accesskit_enabled) {
        const cw = dvui.currentWindow();
        cw.accesskit.text_run_parent = self.textrun_parent_prev;
    }

    if (self.deferred_click_new) |h| {
        dvui.dataSet(null, self.data().id, "_deferred_click", h);
    } else {
        dvui.dataRemove(null, self.data().id, "_deferred_click");
    }
    if (self.deferred_hover_new) |h| {
        dvui.dataSet(null, self.data().id, "_deferred_hover", h);
    } else {
        dvui.dataRemove(null, self.data().id, "_deferred_hover");
    }
    dvui.dataSet(null, self.data().id, "_touch_editing", self.touch_editing);
    dvui.dataSet(null, self.data().id, "_te_first", self.te_first);
    dvui.dataSet(null, self.data().id, "_te_show_draggables", self.te_show_draggables);
    dvui.dataSet(null, self.data().id, "_te_show_context_menu", self.te_show_context_menu);
    dvui.dataSet(null, self.data().id, "_te_focus_on_touchdown", self.te_focus_on_touchdown);
    dvui.dataSet(null, self.data().id, "_sel_start_r", self.sel_start_r);
    dvui.dataSet(null, self.data().id, "_sel_start_rtl", self.sel_start_rtl);
    dvui.dataSet(null, self.data().id, "_sel_end_r", self.sel_end_r);
    dvui.dataSet(null, self.data().id, "_sel_end_rtl", self.sel_end_rtl);
    dvui.dataSet(null, self.data().id, "_selection", self.selection.*);
    dvui.dataSetSlice(null, self.data().id, "_byte_heights", self.byte_heights_new.items);
    dvui.dataSetSlice(null, self.data().id, "__line_ascents", self.line_ascents_new.items);

    if (self.scroll_to_cursor_next_frame) {
        dvui.dataSet(null, self.data().id, "_scroll_to_cursor", true);
    }

    if (dvui.captured(self.data().id)) {
        if (self.sel_move == .mouse) {
            // once we figure out where the mousedown was, we need to save it
            // as long as we are dragging
            dvui.dataSet(null, self.data().id, "_sel_move_mouse_byte", self.sel_move.mouse.byte.?);
        } else if (self.sel_move == .expand_pt and (self.sel_move.expand_pt.which == .word or self.sel_move.expand_pt.which == .line)) {
            dvui.dataSet(null, self.data().id, "_sel_move_expand_pt_which", self.sel_move.expand_pt.which);
            dvui.dataSet(null, self.data().id, "_sel_move_expand_pt_bytes", self.sel_move.expand_pt.bytes);
        }
    }
    if (self.click_num == 0) {
        dvui.dataRemove(null, self.data().id, "_click_num");
        dvui.dataRemove(null, self.data().id, "_click_num_pt");
    } else {
        dvui.dataSet(null, self.data().id, "_click_num", self.click_num);
        dvui.dataSet(null, self.data().id, "_click_num_pt", self.click_num_pt);
    }
    dvui.clipSet(self.prevClip);

    // check if the widgets are taller than the text
    const left_height = (self.corners_min_size[0] orelse Size{}).h + (self.corners_min_size[2] orelse Size{}).h;
    const right_height = (self.corners_min_size[1] orelse Size{}).h + (self.corners_min_size[3] orelse Size{}).h;
    // adjust for corner widgets not being inside textLayout's padding
    const padded = self.data().options.padSize(.{ .h = @max(left_height, right_height) }).padNeg(self.data().options.paddingGet());
    self.data().min_size.h = @max(self.data().min_size.h, padded.h);

    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

// used to make sure the text run's id doesn't change between empty, non-empty and placeholder.
fn textRunSrc() std.builtin.SourceLocation {
    return @src();
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "bidiPieces: level runs cross addText chunk boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two styled chunks on one visual line, the way syntax highlighting emits
    // them. Base direction resolves RTL off the first strong character.
    var frags: [2]Fragment = undefined;
    frags[0].text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    frags[1].text = " world";

    var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
    const pieces = bidiPieces(arena, &frags, &dir) orelse return error.TestExpectedPieces;

    // The second chunk is cut: its leading space is a neutral between an RTL
    // and an LTR run, so it resolves to the paragraph level and travels with
    // the Hebrew, not with "world".
    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expectEqual(@as(u8, 1), pieces[0].level);
    try std.testing.expectEqual(@as(u32, 1), pieces[1].frag);
    try std.testing.expectEqual(@as(u32, 0), pieces[1].start);
    try std.testing.expectEqual(@as(u32, 1), pieces[1].end);
    try std.testing.expectEqual(@as(u8, 1), pieces[1].level);
    try std.testing.expectEqual(@as(u8, 2), pieces[2].level);

    const levels = try arena.alloc(u8, pieces.len);
    for (pieces, levels) |p, *l| l.* = p.level;
    const order = try opentype.unicode.Bidi.reorderVisual(arena, levels);

    // The logically-first chunk draws rightmost -- the whole point.
    try std.testing.expectEqualSlices(usize, &.{ 2, 1, 0 }, order);
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

    var alone = (try font.textSizeExShaped(gpa, frags[0].text, .{})).?;
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

test "bidiPieces: left-to-right lines are left alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var frags: [2]Fragment = undefined;
    frags[0].text = "const ";
    frags[1].text = "x = 1;";
    var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
    try std.testing.expect(bidiPieces(arena_state.allocator(), &frags, &dir) == null);
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

test "reorderLineVisual: a piece cut mid-fragment is reshaped with the rest as context" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var pieces: usize = 0;
        var leading_has_render_shape = false;
        var cut_has_render_shape = false;
        var cut_text: []const u8 = "";

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            const font: Font = .find(.{ .family = "Vera", .size = 16 });
            const arena = dvui.currentWindow().arena();

            // Same shape as the bidiPieces test above: the second fragment's
            // leading space belongs to the RTL run, so " world" is cut in two
            // and "world" is a piece that does not start at byte 0.
            var frags: [2]Fragment = std.mem.zeroes([2]Fragment);
            frags[0].text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
            frags[1].text = " world";
            for (&frags) |*f| {
                f.font = font;
                f.size = font.textSizeEx(f.text, .{});
            }
            tl.line_frags.appendSlice(arena, &frags) catch {};
            tl.reorderLineVisual();

            pieces = tl.line_frags.items.len;
            if (pieces == 3) {
                leading_has_render_shape = tl.line_frags.items[1].render_shaped != null;
                cut_has_render_shape = tl.line_frags.items[2].render_shaped != null;
                cut_text = tl.line_frags.items[2].text;
            }
            tl.line_frags.clearRetainingCapacity();
            tl.addTextDone(.{});
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    try std.testing.expectEqual(@as(usize, 3), fns.pieces);
    try std.testing.expectEqualStrings("world", fns.cut_text);
    // Every cut piece is reshaped against the whole fragment, the leading
    // one included: its parent's shape covers bytes it doesn't own, and in
    // an RTL run those are the ones its own glyphs sit behind.
    try std.testing.expect(fns.leading_has_render_shape);
    // The one that had to shape again did it with the whole fragment around
    // it, so it still has a drawable shape rather than falling back to a
    // context-free reshape at render time.
    try std.testing.expect(fns.cut_has_render_shape);
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

test "e2e: an RTL line built from two addText chunks stays one line" {
    // Smoke cover for the buffer/reorder/emit path with real fonts and real
    // shaping; the placement itself is asserted in the two tests above.
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var width: f32 = 0;
        var height: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .tag = "tl" });
            tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd}", .{});
            tl.addText(" world", .{});
            tl.addTextDone(.{});
            width = tl.data().min_size.w;
            height = tl.data().min_size.h;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // Reordering is a permutation, so the line is as wide as its content and
    // never wrapped.
    try std.testing.expect(fns.width > 60);
    try std.testing.expect(fns.height < 40);
}

test "maybeRtl: only text bidi could reorder pays for the pass" {
    try std.testing.expect(!maybeRtl("const x = 1;"));
    try std.testing.expect(!maybeRtl("\u{4f60}\u{597d}")); // CJK
    try std.testing.expect(!maybeRtl("\u{1f600}")); // emoji
    try std.testing.expect(!maybeRtl("caf\u{e9}")); // Latin-1 supplement

    try std.testing.expect(maybeRtl("\u{05e9}")); // Hebrew
    try std.testing.expect(maybeRtl("\u{0627}")); // Arabic
    try std.testing.expect(maybeRtl("\u{0660}")); // Arabic-Indic digit
    try std.testing.expect(maybeRtl("\u{0840}")); // Mandaic
    try std.testing.expect(maybeRtl("\u{200f}")); // RLM
    try std.testing.expect(maybeRtl("\u{fb2a}")); // Hebrew presentation form
    try std.testing.expect(maybeRtl("\u{10800}")); // Cypriot
    try std.testing.expect(maybeRtl("\u{1e900}")); // Adlam
}

test "bidiPieces: base direction carries across the lines of a paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const visualOrder = struct {
        fn f(a: std.mem.Allocator, pieces: []const BidiPiece) ![]const usize {
            const levels = try a.alloc(u8, pieces.len);
            for (pieces, levels) |p, *l| l.* = p.level;
            return opentype.unicode.Bidi.reorderVisual(a, levels);
        }
    }.f;

    // First line of the paragraph: its strong character is Hebrew.
    var first: [1]Fragment = undefined;
    first[0].text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
    _ = bidiPieces(arena, &first, &dir) orelse return error.TestExpectedPieces;
    try std.testing.expectEqual(opentype.unicode.Bidi.ParagraphDirection.rtl, dir);

    // Second line starts with a Latin word, but it is still that paragraph, so
    // the logically-first piece belongs on the right.
    var second: [2]Fragment = undefined;
    second[0].text = "world ";
    second[1].text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
    const carried = bidiPieces(arena, &second, &dir) orelse return error.TestExpectedPieces;
    const carried_order = try visualOrder(arena, carried);
    try std.testing.expectEqual(@as(usize, 0), carried_order[carried_order.len - 1]);

    // Resolved on its own, that same line would read left-to-right instead --
    // the flip this fix exists to prevent.
    var fresh: opentype.unicode.Bidi.ParagraphDirection = .auto;
    const alone = bidiPieces(arena, &second, &fresh) orelse return error.TestExpectedPieces;
    const alone_order = try visualOrder(arena, alone);
    try std.testing.expectEqual(@as(usize, 0), alone_order[0]);
}

test "e2e: a clickable chunk is reordered, and answers one frame late" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var clicks: usize = 0;
        var content: dvui.Rect.Physical = .{};
        var scale: f32 = 1;

        fn frame() !dvui.App.Result {
            // No expand: the widget hugs the text, so the RTL line origin is
            // the content rect's left edge and this stays a reorder test.
            var tl = dvui.textLayout(@src(), .{}, .{});
            tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd} ", .{});
            if (tl.addTextClick("world", .{})) |_| clicks += 1;
            tl.addTextDone(.{});
            const rs = tl.data().contentRectScale();
            content = rs.r;
            scale = rs.s;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // The link is logically last but visually first, so it sits at the left
    // edge -- which it could not if it still flushed its own line.
    const c = fns.content;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = c.x + 4, .y = c.y + 4 } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);

    try std.testing.expectEqual(@as(usize, 1), fns.clicks);
}

test "e2e: splitting a mixed chunk measures the same as splitting by hand" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var one_chunk: f32 = 0;
        var two_chunks: f32 = 0;

        fn frame() !dvui.App.Result {
            {
                var tl = dvui.textLayout(@src(), .{}, .{});
                tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd} world", .{});
                tl.addTextDone(.{});
                one_chunk = tl.data().min_size.w;
                tl.deinit();
            }
            {
                var tl = dvui.textLayout(@src(), .{}, .{});
                tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd}", .{});
                tl.addText(" world", .{});
                tl.addTextDone(.{});
                two_chunks = tl.data().min_size.w;
                tl.deinit();
            }
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // The one-chunk line is cut into level-run pieces, and the leading piece
    // keeps the chunk's shape while the rest are reshaped; both paths have to
    // agree, or the line's pieces overlap or leave a gap.
    try std.testing.expect(fns.one_chunk > 60);
    try std.testing.expectApproxEqAbs(fns.two_chunks, fns.one_chunk, 1.0);
}

test "e2e: a wrapped RTL paragraph stays inside its width" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        /// Width of every line laid end to end: min_size.w only resets on a
        /// hard break, so for this text it is the whole paragraph's advance.
        var total_width: f32 = 0;
        var avail: f32 = 0;
        var lines: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .rect = .{ .w = 120, .h = 180 } });
            tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd} world \u{05e9}\u{05dc}\u{05d5}\u{05dd} again \u{05e9}\u{05dc}\u{05d5}\u{05dd}", .{});
            tl.addTextDone(.{});
            total_width = tl.data().min_size.w;
            avail = tl.data().contentRect().w;
            lines = @floatFromInt(tl.line + 1);
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // The retreat loop in the layout half exists so a bidi line that reshapes
    // wider than its seed break point gets a narrower one instead of spilling.
    // Drop it and the same text fits in fewer, over-wide lines.
    try std.testing.expect(fns.lines > 1);
    try std.testing.expect(fns.total_width / fns.lines <= fns.avail);
}

test "e2e: an RTL paragraph starts at the right edge" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var clicks: usize = 0;
        var content: dvui.Rect.Physical = .{};
        var scale: f32 = 1;
        var hit: ?Rect = null;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            // RLM first, so P2/P3 resolve the paragraph RTL even though the
            // only word here is Latin.
            tl.addText("\u{200f}", .{});
            if (tl.addTextClick("world", .{})) |_| clicks += 1;
            tl.addText(" \u{05e9}\u{05dc}\u{05d5}\u{05dd}", .{});
            tl.addTextDone(.{});
            const rs = tl.data().contentRectScale();
            content = rs.r;
            scale = rs.s;
            hit = if (tl.deferred_click) |h| h.rect else null;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    const c = fns.content;

    // The widget is far wider than the text. Left edge is now empty space.
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = c.x + 4, .y = c.y + 4 } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqual(@as(usize, 0), fns.clicks);

    // The line ends flush with the content rect's right edge, and the
    // logically-first chunk is the one that lands there.
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = c.x + c.w - 6, .y = c.y + 4 } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqual(@as(usize, 1), fns.clicks);

    const r = fns.hit orelse return error.TestExpectedHit;
    try std.testing.expectApproxEqAbs(fns.content.w / dvui.currentWindow().natural_scale, r.x + r.w, 0.5);
}

test "recordHit: a click and a hover in the same frame both answer" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var clicks: usize = 0;
        var hovers: usize = 0;
        var rs: dvui.RectScale = .{};

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            if (tl.addTextClick("AAAA", .{})) |_| clicks += 1;
            tl.addText("        ", .{});
            if (tl.addTextHover("BBBB", .{})) |_| hovers += 1;
            tl.addTextDone(.{});
            rs = tl.data().contentRectScale();
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    const font = (Options{}).fontGet();
    const click_pt = fns.rs.pointToPhysical(.{ .x = 2, .y = 2 });
    const hover_pt = fns.rs.pointToPhysical(.{ .x = font.textSizeEx("AAAA        ", .{}).w + 2, .y = 2 });

    // Click lands on the first chunk, then the mouse moves onto the second
    // before the frame's single position event -- one frame, two hits, two
    // different chunks. With one slot the later one used to win.
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = click_pt });
    try dvui.testing.click(.left);
    _ = try cw.addEventMouseMotion(.{ .pt = hover_pt });
    try dvui.testing.settle(fns.frame);

    try std.testing.expectEqual(@as(usize, 1), fns.clicks);
    try std.testing.expectEqual(@as(usize, 1), fns.hovers);
}

test "line ascent: a buffered fragment carries the line's ascent" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 100 } });
    defer t.deinit();

    const fns = struct {
        var max_ascent: f32 = -1;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .break_lines = true }, .{ .expand = .both });
            tl.addText("wrapping text that needs at least two lines to fit", .{});
            // emitFragment draws at y + (max_ascent - ascent), so a zero here
            // puts every line one full ascent above where it belongs.
            max_ascent = if (tl.line_frags.items.len > 0) tl.line_frags.items[0].max_ascent else -1;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.max_ascent > 0);
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
    const pieces = bidiPieces(arena, &frags, &dir) orelse return error.TestExpectedPieces;
    try std.testing.expectEqual(@as(usize, 2), pieces.len);

    var out: [2]Fragment = frags;
    for (&out, pieces) |*f, p| f.rtl = p.level % 2 == 1;
    assignVisualX(arena, pieces, &out, 0);

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

test "e2e: a click lands in the run under it, not the logically-first one" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        const first = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}";
        const second = "\u{05e2}\u{05d5}\u{05dc}\u{05dd}";
        var sel: Selection = .{};
        var content: dvui.Rect.Physical = .{};
        var scale: f32 = 1;
        var w_first: f32 = 0;
        var w_first_half: f32 = 0;
        var w_second_half: f32 = 0;
        var total: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .selection = &sel }, .{});
            const font = tl.data().options.fontGet();
            w_first = font.textSizeEx(first, .{}).w;
            w_first_half = font.textSizeEx(first[0..4], .{}).w;
            w_second_half = font.textSizeEx(second[0..4], .{}).w;
            total = w_first + font.textSizeEx(second, .{}).w;
            tl.addText(first, .{});
            tl.addText(second, .{});
            tl.addTextDone(.{});
            const rs = tl.data().contentRectScale();
            content = rs.r;
            scale = rs.s;
            tl.deinit();
            return .ok;
        }

        fn clickAt(x: f32) !void {
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = content.x + x * scale, .y = content.y + 4 } });
            try dvui.testing.click(.left);
            try dvui.testing.settle(frame);
        }
    };

    try dvui.testing.settle(fns.frame);

    // Both chunks are level 1, so L2 puts the logically-second one on the
    // left of the line and the first one at the right edge. Two letters in
    // from that edge is byte 4 of the first chunk -- the exact byte, not
    // just the right run: the click is measured against the same shape the
    // run was laid out with, walked by cluster from its logical start.
    try fns.clickAt(fns.total - fns.w_first_half);
    try std.testing.expectEqual(@as(usize, 4), fns.sel.cursor);

    // The left run reads right to left too, so two letters into it means
    // two letters left of *its* right edge, not of the line's.
    try fns.clickAt(fns.total - fns.w_first - fns.w_second_half);
    try std.testing.expectEqual(fns.first.len + 4, fns.sel.cursor);
}

test "e2e: a wrapping RTL fragment answers clicks by cluster, not by leading glyph" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        // No spaces, so the wrap is a character wrap in the middle of the
        // fragment: the shape covers more bytes than the line keeps, which
        // is the case addTextEx drops for RTL (slicing it by leading-glyph
        // limit would take the wrong end of the run).
        const text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}\u{05e2}\u{05d5}\u{05dc}\u{05dd}\u{05e9}\u{05dc}\u{05d5}\u{05dd}\u{05e2}\u{05d5}\u{05dc}\u{05dd}";
        var sel: Selection = .{};
        var content: dvui.Rect.Physical = .{};
        var scale: f32 = 1;
        var lines: usize = 0;
        var line_h: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .selection = &sel }, .{ .rect = .{ .w = 60, .h = 180 } });
            line_h = tl.data().options.fontGet().lineHeight();
            tl.addText(text, .{});
            tl.addTextDone(.{});
            const rs = tl.data().contentRectScale();
            content = rs.r;
            scale = rs.s;
            lines = tl.line + 1;
            tl.deinit();
            return .ok;
        }

        fn clickAt(x: f32, y: f32) !void {
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = content.x + x * scale, .y = content.y + y * scale } });
            try dvui.testing.click(.left);
            try dvui.testing.settle(frame);
        }
    };

    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.lines > 1);

    const right = fns.content.w / dvui.currentWindow().natural_scale - 1;

    // An RTL line reads from its right edge, so the first line's right edge
    // is byte 0 and the second line's is where the first one ended.
    try fns.clickAt(right, fns.line_h * 0.5);
    try std.testing.expectEqual(@as(usize, 0), fns.sel.cursor);

    try fns.clickAt(right, fns.line_h * 1.5);
    const wrap = fns.sel.cursor;
    try std.testing.expect(wrap > 0);
    try std.testing.expect(wrap < fns.text.len);

    // Same byte reached from the other side: the first line's left edge is
    // its logical end.
    try fns.clickAt(1, fns.line_h * 0.5);
    try std.testing.expectEqual(wrap, fns.sel.cursor);
}

test "e2e: a wrapped RTL line places its caret on the pen, not on an ink width" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        // Same character-wrapped fragment as above: its shape covers more
        // bytes than the first line keeps, so that line only has a shape to
        // place a caret from because addTextEx reshapes its own byte range.
        const text = "\u{05e9}\u{05dc}\u{05d5}\u{05dd}\u{05e2}\u{05d5}\u{05dc}\u{05dd}\u{05e9}\u{05dc}\u{05d5}\u{05dd}\u{05e2}\u{05d5}\u{05dc}\u{05dd}";
        var sel: Selection = .{};
        var caret: Rect = .{};
        var font: Font = undefined;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .selection = &sel }, .{ .rect = .{ .w = 60, .h = 180 } });
            font = tl.data().options.fontGet();
            tl.addText(text, .{});
            tl.addTextDone(.{});
            caret = tl.cursor_rect;
            tl.deinit();
            return .ok;
        }

        fn caretAt(byte: usize, affinity: Selection.Affinity) !Rect {
            sel.cursor = byte;
            sel.start = byte;
            sel.end = byte;
            sel.affinity = affinity;
            try dvui.testing.settle(frame);
            return caret;
        }
    };

    // Walk the first line a codepoint at a time; the caret leaving its y is
    // where the line wrapped.
    var xs: [32]f32 = undefined;
    var stops: usize = 0;
    const first = try fns.caretAt(0, .after);
    var off: usize = 0;
    while (off < fns.text.len) : (off += 2) {
        const c = try fns.caretAt(off, .after);
        if (c.y != first.y) break;
        xs[stops] = c.x;
        stops += 1;
    }
    const wrap = off;
    try std.testing.expect(wrap > 0);
    try std.testing.expect(wrap < fns.text.len);

    // The line's left pen edge: every other caret on it is measured against
    // this, so the line's origin never enters the comparison.
    const left = (try fns.caretAt(wrap, .before)).x;

    var ref = (try fns.font.textSizeExShaped(std.testing.allocator, fns.text[0..wrap], .{})).?;
    defer ref.shaped.deinit();

    for (xs[0..stops], 0..) |x, k| {
        // An ink-width caret drifts by a different amount at every stop; a
        // pen one lands on the glyph boundary the renderer drew.
        try std.testing.expectApproxEqAbs(ref.shaped.caretOffset(k * 2), x - left, 0.5);
    }
}

test "base_direction: an RTL base right-aligns a line holding no RTL character" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
        var caret_x: f32 = 0;
        var avail: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .base_direction = dir }, .{ .expand = .horizontal });
            tl.addText("abc", .{});
            avail = tl.data().contentRect().w;
            tl.addTextDone(.{});
            // The cursor starts at byte 0, so its rect is the line's left
            // edge when the line is left-aligned.
            caret_x = tl.cursor_rect.x;
            tl.deinit();
            return .ok;
        }
    };

    fns.dir = .auto;
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(@abs(fns.caret_x) < 0.01);

    fns.dir = .rtl;
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.caret_x > 0);
    try std.testing.expect(fns.caret_x < fns.avail);
}

test "base_direction: an empty RTL paragraph puts its caret on the right" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
        var caret_x: f32 = 0;
        var avail: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .base_direction = dir }, .{ .expand = .horizontal });
            avail = tl.data().contentRect().w;
            tl.addTextDone(.{});
            caret_x = tl.cursor_rect.x;
            tl.deinit();
            return .ok;
        }
    };

    fns.dir = .auto;
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(@abs(fns.caret_x) < 0.01);

    fns.dir = .rtl;
    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqual(fns.avail - 1, fns.caret_x);
}

test "visualStops: fragments meeting inside one run share a caret position" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
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

            const stops = tl.visualStops(arena);
            const out = arena.alloc(usize, stops.len) catch return .ok;
            for (stops, out) |st, *b| b.* = st.byte;
            bytes = out;

            tl.line_frags.clearRetainingCapacity();
            tl.addTextDone(.{});
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4, 5 }, fns.bytes);
}


test "e2e: an RTL line ending in a newline keeps its shape" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            defer tl.deinit();
            // Shaping stops at the hard break, so the shape is one byte
            // shorter than the fragment -- which used to trip emitFragment.
            tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd}\n\n", .{});
            tl.addTextDone(.{});
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
}
