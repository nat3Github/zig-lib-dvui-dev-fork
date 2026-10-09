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

/// Test hook: sees each placed line's fragments, in their final visual
/// positions, before they are emitted.
pub var line_probe: ?*const fn (frags: []const Fragment) void = null;

pub const OverflowWrap = enum { normal, anywhere };
pub const TextAlign = opentype.line.Align;

pub const InitOptions = struct {
    selection: ?*Selection = null,

    /// If true, break text on space to fit (or any character if width is < 10 Ms)
    break_lines: bool = true,

    /// CSS `line-break`: `.strict` is plain UAX #14, `.normal`/`.loose` allow
    /// more breaks around punctuation and small kana.
    line_break: LineBreakStrictness = .strict,

    /// CSS `word-break`: `.break_all` allows breaks between any letters,
    /// `.keep_all` forbids them between letters.
    word_break: WordBreakMode = .normal,

    /// CSS `overflow-wrap`: `.anywhere` (default) character-breaks an over-long
    /// word, `.normal` lets it overflow.
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

    /// Paragraph base direction (UAX #9 P2/P3). `.auto` uses the first strong
    /// character, so empty or neutral-only lines read left to right; set it for
    /// RTL UIs.
    base_direction: opentype.unicode.Bidi.ParagraphDirection = .auto,

    /// CSS `text-align`, applied to each line once it is broken. `.start`
    /// and `.end` follow the paragraph's resolved direction. No justify.
    text_align: TextAlign = .start,

    /// CSS `line-clamp`: lay out at most this many lines, ending the last in an
    /// ellipsis if the text didn't fit. A last line ended by a hard break gets
    /// no ellipsis.
    max_lines: ?usize = null,
};

pub const Selection = struct {
    pub const Affinity = opentype.line.Affinity;

    cursor: usize = 0,
    start: usize = 0,
    end: usize = 0,

    // if the characters on either side of cursor are split across lines:
    // - before means cursor is logically at the end of the first char
    // - after means the cursor is logically at the beginning of the second char
    affinity: Affinity = .after,

    /// Anchor of a selection extended from the keyboard, which is selected
    /// visually: the graphemes on screen between the anchor and the cursor.
    /// Across a direction boundary that can be several logical ranges, and
    /// `start`/`end` are then their outer bounds. Ignored once cursor, start
    /// or end is written by anything but `moveCursor` or layout.
    visual: Visual = .{},

    pub const max_split_ranges = opentype.line.VisualSelection.max_ranges;

    pub const Caret = opentype.line.Caret;

    pub const Visual = struct {
        anchor: Caret = .{ .byte = 0, .affinity = .after },
        cursor: usize = std.math.maxInt(usize),
        start: usize = 0,
        end: usize = 0,
        ranges: [max_split_ranges][2]usize = undefined,
        /// Below 2 the selection is the single range start..end.
        ranges_len: u8 = 0,
        /// Where Left/Right collapse the selection. Set by layout.
        left: ?Caret = null,
        right: ?Caret = null,
    };

    pub fn visualCurrent(self: *const Selection) bool {
        return self.visual.cursor == self.cursor and self.visual.start == self.start and self.visual.end == self.end;
    }

    /// The end of the selection that stays put while it is extended.
    pub fn anchor(self: *const Selection) Caret {
        if (self.visualCurrent()) return self.visual.anchor;
        if (self.cursor == self.start) return .{ .byte = self.end, .affinity = .before };
        return .{ .byte = self.start, .affinity = .after };
    }

    /// Logical ranges of a split selection in text order; empty when the
    /// selection is the single range start..end.
    pub fn splitRanges(self: *const Selection) []const [2]usize {
        if (!self.visualCurrent() or self.visual.ranges_len < 2) return &.{};
        return self.visual.ranges[0..self.visual.ranges_len];
    }

    pub fn empty(self: *Selection) bool {
        return self.start == self.end;
    }

    pub fn selectAll(self: *Selection) void {
        self.start = 0;
        self.cursor = 0;
        self.end = std.math.maxInt(usize);
    }

    pub fn moveCursor(self: *Selection, idx: usize, select: bool) void {
        if (select) {
            const anchor_caret: Caret = if (self.empty()) .{ .byte = self.cursor, .affinity = self.affinity } else self.anchor();
            self.cursor = idx;
            self.start = @min(anchor_caret.byte, idx);
            self.end = @max(anchor_caret.byte, idx);
            self.visual = .{ .anchor = anchor_caret, .cursor = idx, .start = self.start, .end = self.end };
        } else {
            self.cursor = idx;
            self.start = idx;
            self.end = idx;
        }
        self.affinity = .after;
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

pub const Region = struct { start: usize, end: usize };

/// Frame-to-frame state under one data key: one lookup per frame and one
/// allocation per widget instead of one per field.
const State = struct {
    prev_scale: f32,
    prev_break_lines: bool,
    prev_width: f32,
    // when this is true and we have focus, show the floating widget with select all, copy, etc.
    touch_editing: bool = false,
    te_first: bool = true,
    te_show_draggables: bool = true,
    te_show_context_menu: bool = true,
    te_focus_on_touchdown: bool = false,
    sel_start_r: Rect = .{},
    sel_end_r: Rect = .{},
    /// visual direction of the fragment each selection edge landed in, so the
    /// touch draggables hang off the correct side of their caret
    sel_start_rtl: bool = false,
    sel_end_rtl: bool = false,
    /// Direction of the fragment the caret was drawn in.
    cursor_rtl: bool = false,
    /// Direction of the paragraph the caret was drawn in.
    cursor_paragraph_rtl: bool = false,
    click_num: u8 = 0,
    click_num_pt: dvui.Point.Physical = .{},
    /// Recorded last frame, answered this frame. Click and hover have separate
    /// slots so one can't overwrite the other.
    deferred_click: ?DeferredHit = null,
    deferred_hover: ?DeferredHit = null,
};

const cache_layout_debug = false;

wd: WidgetData,
state: *State,
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
visual_width: f32 = 0,
break_lines: bool,
wrap: opentype.line.Wrap,
base_direction: opentype.unicode.Bidi.ParagraphDirection,
text_align: TextAlign,
max_lines: ?usize,
/// `max_lines` was reached: the rest of the text is only counted, not laid out.
clamped: bool = false,
/// How far alignment moved the most recently placed line.
line_shift: f32 = 0,
current_line_width: f32 = 0.0, // width of lines if break_lines was false
touch_edit_just_focused: bool,
process_events_in_deinit: bool,

cursor_pt: ?Point = null,
cursor_event: ?dvui.Event.EventTypes = null,
click_pt: ?Point = null,
click_event: ?dvui.Event.EventTypes = null,

/// Recorded this frame, answered next frame.
deferred_click_new: ?DeferredHit = null,
deferred_hover_new: ?DeferredHit = null,
/// Counts clickable/hoverable chunks in draw order, reset each frame.
action_ordinal: usize = 0,

line: usize = 0,

/// Fragments of the visual line being built. Bidi can only place them once
/// the whole line is known, which can span several addText calls. Arena-backed.
text_line: TextLine = .{},
/// cacheLayoutNext skipped part of the buffered line.
line_skipped: bool = false,
/// Byte a point past the far edge of the most recently placed line resolves
/// to; null until a line with fragments has been placed.
line_end_byte: ?usize = null,
/// Left edge of the most recently placed line, which an RTL line's logical
/// end sits at; null until a line with fragments has been placed.
line_left_x: ?f32 = null,
/// Paragraph direction from its first strong character (UAX #9 P2/P3), held
/// until the next hard break. Null until one is seen.
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
        anchor: ?Selection.Caret = null, // caret at pt (find on frame 1, keep while captured)
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
        buf: [20]u8 = @splat(0),
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

sel_start_r_new: ?Rect = null,
sel_start_rtl_new: bool = false,
sel_end_r_new: ?Rect = null,
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

/// How the line being emitted is selected, set per line by `flushLine`.
line_selection: LineSelection = .{ .bytes = .{ 0, 0 } },
/// A keyboard-extended selection's ranges and ends as this frame lays them out.
visual_build: VisualBuild = .{},

focus_at_start: bool = false,
/// SAFETY: Set in `touchEditing`
te_floating: FloatingWidget = undefined,

cache_layout: bool = false,
cache_layout_last_byte: usize = 0,
cache_layout_region: ?Region = null,
byte_height_ready: ?BytePos = null,
byte_heights: []BytePos = &.{}, // from last frame
byte_heights_new: std.ArrayList(BytePos) = .empty, // creating this frame
byte_height_after_idx: ?usize = null,
byte_height_edit_idx: ?usize = null,
byte_height_width: f32 = 0.0,
edit_start: usize = std.math.maxInt(usize),
edit_end: usize = 0,
edit_added: i64 = 0,

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
    const scale_new = dvui.parentGet().screenRectScale(Rect{}).s;

    self.* = .{
        .wd = WidgetData.init(src, .{ .scroll_when_focused = false }, options),
        // SAFETY: set below
        .state = undefined,
        .break_lines = init_opts.break_lines,
        .wrap = .{ .strictness = init_opts.line_break, .word_break = init_opts.word_break, .anywhere = init_opts.overflow_wrap == .anywhere },
        .base_direction = init_opts.base_direction,
        .text_align = init_opts.text_align,
        .max_lines = init_opts.max_lines,
        .cache_layout = init_opts.cache_layout,
        .touch_edit_just_focused = init_opts.touch_edit_just_focused,
        .process_events_in_deinit = init_opts.process_events_in_deinit,

        // SAFETY: set below
        .selection = undefined,
    };
    self.state = dvui.dataGetPtrDefault(null, self.wd.id, "__state", State, .{
        .prev_scale = scale_new,
        .prev_break_lines = init_opts.break_lines,
        .prev_width = self.data().rect.w,
    });
    self.selection = if (init_opts.selection) |sel_in| sel_in else dvui.dataGetPtrDefault(null, self.wd.id, "_selection", Selection, .{});

    if (dvui.dataGetSlice(null, self.wd.id, "__byte_pos", []BytePos)) |bh| self.byte_heights = bh;
    if (dvui.dataGetSlice(null, self.wd.id, "__line_ascents", []LineAscent)) |la| self.line_ascents = la;

    if (dvui.dataGet(null, self.wd.id, "_scroll_to_cursor", bool) orelse false) {
        dvui.dataRemove(null, self.wd.id, "_scroll_to_cursor");
        self.scroll_to_cursor = true;
    }

    if (self.cache_layout and self.state.prev_scale != scale_new) {
        dvui.log.debug("{x} TextLayoutWidget forcing cache_layout false due to scale change", .{self.data().id});
        self.cache_layout = false;
    }
    self.state.prev_scale = scale_new;

    if (self.cache_layout and self.state.prev_break_lines != self.break_lines) {
        dvui.log.debug("{x} TextLayoutWidget forcing cache_layout false due to break_lines change", .{self.data().id});
        self.cache_layout = false;
    }
    self.state.prev_break_lines = self.break_lines;

    if (self.cache_layout and self.break_lines and self.state.prev_width != self.data().rect.w) {
        dvui.log.debug("{x} TextLayoutWidget forcing cache_layout false due to width change while break_lines", .{self.data().id});
        self.cache_layout = false;
    }
    self.state.prev_width = self.data().rect.w;

    self.focus_at_start = init_opts.focused orelse (self.data().id == dvui.focusedWidgetId());

    self.data().register();
    dvui.parentSet(self.widget());

    if (dvui.captured(self.data().id)) {
        if (dvui.dataGet(null, self.data().id, "_sel_move_mouse_anchor", Selection.Caret)) |anchor| {
            self.sel_move = .{ .mouse = .{ .anchor = anchor } };
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

    // visual_width is for cache_layout, once we've clipped to content rect we
    // get a smaller width if at the very left or right (due to padding)
    self.visual_width = self.data().contentRectScale().rectFromPhysical(dvui.clipGet()).w;
    if (self.visual_width == 0) self.visual_width = 500;

    if (init_opts.show_touch_draggables and self.state.touch_editing and self.state.te_show_draggables and self.focus_at_start and self.data().visible()) {
        const size = 36;
        {

            // calculate visible before FloatingWidget changes clip

            // We only draw if visible (to prevent drawing way outside the
            // textLayout), but we always process the floating window so that
            // we maintain capture.  That way you can drag a draggable off the
            // textLayout (so it's not visible), which causes a scroll, but
            // when the draggable shows back up you are still dragging it.

            // sel_start_r might be just off the right-hand edge, so widen it
            var cursor = self.state.sel_start_r;
            cursor.x -= 1;
            cursor.w += 1;
            const visible = !dvui.clipGet().intersect(rs.rectToPhysical(cursor)).empty();

            // an RTL selection starts at the visual right edge, so its
            // draggable hangs to the right of the caret instead
            const hang_left = !self.state.sel_start_rtl;
            var rect = self.state.sel_start_r;
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
                        self.state.te_show_context_menu = false;
                        offset = (if (hang_left) fcrs.r.topRight() else fcrs.r.topLeft()).diff(me.p);

                        // give an extra offset of half the cursor height
                        offset.y -= self.state.sel_start_r.h * 0.5 * rs.s;
                    } else if (me.action == .release and me.button.touch() and dvui.captured(fc.data().id)) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd(me.button);
                    } else if (me.action == .motion and dvui.captured(fc.data().id)) {
                        const corner = me.p.plus(offset);
                        self.sel_pts[0] = self.data().contentRectScale().pointFromPhysical(corner);
                        self.sel_pts[1] = self.state.sel_end_r.topLeft().plus(.{ .y = self.state.sel_end_r.h / 2 });

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
            var cursor = self.state.sel_end_r;
            cursor.x -= 1;
            cursor.w += 1;
            const visible = !dvui.clipGet().intersect(rs.rectToPhysical(cursor)).empty();

            const hang_left = self.state.sel_end_rtl;
            var rect = self.state.sel_end_r;
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
                        self.state.te_show_context_menu = false;
                        offset = (if (hang_left) fcrs.r.topRight() else fcrs.r.topLeft()).diff(me.p);

                        // give an extra offset of half the cursor height
                        offset.y -= self.state.sel_start_r.h * 0.5 * rs.s;
                    } else if (me.action == .release and me.button.touch() and dvui.captured(fc.data().id)) {
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd(me.button);
                    } else if (me.action == .motion and dvui.captured(fc.data().id)) {
                        const corner = me.p.plus(offset);
                        self.sel_pts[0] = self.state.sel_start_r.topLeft().plus(.{ .y = self.state.sel_start_r.h / 2 });
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

/// A hit answered one frame late, keyed on the chunk's ordinal in the frame
/// (byte offsets shift when earlier text changes). If a click changes how many
/// actionable chunks the frame has, the hit lands on a neighbour for one frame.
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

/// Direction the caret moved in last frame: its run's, or the paragraph's at
/// a line's first or last byte. Keys arrive before this frame's layout.
pub fn caretRtl(self: *TextLayoutWidget) bool {
    return self.state.cursor_rtl;
}

/// Which way an Alt+Left/Right word step moves through the text: by the
/// direction of the caret's paragraph last frame (TextKit).
pub fn logicalStep(self: *TextLayoutWidget, right: bool) i8 {
    return if (right != self.state.cursor_paragraph_rtl) 1 else -1;
}

/// Collapses a selection to the edge a Left/Right key points at on screen.
pub fn collapseSelection(self: *TextLayoutWidget, right: bool) void {
    if (self.selection.visualCurrent()) {
        if (if (right) self.selection.visual.right else self.selection.visual.left) |caret| {
            self.selection.moveCursor(caret.byte, false);
            self.selection.affinity = caret.affinity;
            return;
        }
    }
    if (right != self.caretRtl()) {
        self.selection.moveCursor(self.selection.end, false);
        self.selection.affinity = .before;
    } else {
        self.selection.moveCursor(self.selection.start, false);
    }
}

// Called for each piece of text before searching for the cursor.
// Place for selection movement to track points and move the cursor if needed,
// also to track any state they need before the cursor (like word select).
fn selMovePre(self: *TextLayoutWidget, f: Fragment, index: usize) void {
    const past_text = f.byte + f.text.len;
    switch (self.sel_move) {
        .none => {},
        .mouse => |*m| {
            if (m.down_pt) |p| {
                if (self.hitHere(p, index)) |ba| {
                    m.anchor = .{ .byte = ba.byte, .affinity = ba.affinity };
                    self.selection.moveCursor(ba.byte, false);
                    self.selection.affinity = ba.affinity;
                    m.down_pt = null;
                } else {
                    // haven't found it yet, keep cursor at end to not trigger cursor_seen
                    self.selection.moveCursor(past_text, false);
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

/// Extends the selection from the mouse-down caret to `byte`, selected
/// visually like a keyboard extension (TextKit).
fn mouseDragSet(self: *TextLayoutWidget, anchor: Selection.Caret, byte: usize, affinity: Selection.Affinity) void {
    const sel = self.selection;
    sel.cursor = byte;
    sel.start = @min(anchor.byte, byte);
    sel.end = @max(anchor.byte, byte);
    sel.affinity = affinity;
    sel.visual = .{ .anchor = anchor, .cursor = byte, .start = sel.start, .end = sel.end };
}

/// `mouseDragSet` after lines were drawn without the drag: void this frame's
/// visual build and draw the selection next frame.
fn mouseDragTo(self: *TextLayoutWidget, anchor: Selection.Caret, byte: usize, affinity: Selection.Affinity) void {
    self.mouseDragSet(anchor, byte, affinity);
    self.visual_build.basis = .{};
    dvui.refresh(null, @src(), self.data().id);
}

/// Resolves a drag against the placed line before it is selected. A line the
/// pointer is past selects as if the drag ended beyond it, which is how the
/// settled selection draws it, so the drag frame draws what later frames do.
fn mouseDragLine(self: *TextLayoutWidget) void {
    const m = &self.sel_move.mouse;
    const p = m.drag_pt orelse return;
    const anchor = m.anchor orelse return;
    const frags = self.text_line.pieces.items;
    const line_end = self.line_end_byte.?;
    const line_last = self.text_line.bytes()[1];
    const hit: ?Selection.Caret = if (self.text_line.hit(fragment_shaping, p.x, p.y, line_end)) |found| found.caret else for (frags) |f| {
        // Beside the line past its far edge: it wrapped, or it ends the text.
        if (p.y < f.y + f.h) break .{ .byte = line_end, .affinity = if (line_end == line_last) .before else .after };
    } else null;
    if (hit) |h| {
        m.drag_pt = null;
        self.mouseDragSet(anchor, h.byte, h.affinity);
    } else {
        var past_line: usize = 0;
        for (frags) |f| past_line = @max(past_line, f.byte + f.text.len);
        self.mouseDragSet(anchor, past_line, .after);
    }
    if (self.visual_build.basis != null) self.visual_build.basis = self.selection.visual;
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
                    m.anchor = .{ .byte = line_end, .affinity = .before };
                    self.selection.affinity = .before;
                    m.down_pt = null;

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
            // A visual step can run off the line's start edge and turn into a
            // logical step back, so keep the lookback for either direction.
            if (!self.cursor_seen) {
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

                    cur = start_idx + opentype.unicode.nextGraphemeBoundary(txt, cur - start_idx);

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
                var last_kind: enum { punc, word } = if (opentype.unicode.findWordByte(txt, idx, txt.len, .forward, false) != null) .punc else .word;

                var word_start_count: usize = 0;

                loop: while (word_start_count < wlr.word_start_idx.len) {
                    switch (last_kind) {
                        .punc => {
                            if (opentype.unicode.findWordByte(txt, 0, idx, .backward, true)) |word_end| {
                                last_kind = .word;
                                idx = word_end;
                            } else {
                                // all punc
                                break :loop;
                            }
                        },
                        .word => {
                            var new_word_start: ?usize = null;
                            if (opentype.unicode.findWordByte(txt, 0, idx, .backward, false)) |punc| {
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
                if (opentype.unicode.findWordByte(txt, txt.len -| 1, txt.len, .forward, false) != null) {
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
                        if (opentype.unicode.findWordByte(txt, self.selection.cursor -| start_idx, txt.len, .forward, true)) |non_blank| {
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
                        if (opentype.unicode.findWordByte(txt, self.selection.cursor -| start_idx, txt.len, .forward, false)) |punc| {
                            self.selection.moveCursor(start_idx + punc, wlr.select);
                            // done with this one
                            wlr.scratch_kind = .punc; // now want to skip over punc
                            wlr.count -= 1;
                        } else {
                            // rest was word
                            self.selection.moveCursor(start_idx + txt.len, wlr.select);
                            self.selection.affinity = .before;
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
    self.state.cursor_paragraph_rtl = self.baseDir() == .rtl;
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
                    .home, .end => {
                        // Cmd+Left/Right go to the line's left/right edge, which is its
                        // logical end/start in a right-to-left paragraph.
                        if ((ep.which == .home) != (self.baseDir() == .rtl)) {
                            self.selection.moveCursor(self.first_byte_in_line, ep.select);
                            ep.done = true;
                        } else {
                            ep.which = .end;
                        }
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
            // Visual steps first; only what runs off the end of the line is left for
            // the logical paths here and in `selMoveText`.
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

/// These cached markers are how we deal with very long documents.  We want to
/// process only the portion that will appear on screen (in the clip region),
/// plus the selection/cursor if needed.
///
/// We record the byte offset at the start of lines at vertical checkpoints.
/// This allows selecting a vertical subset.  We always have one at the very end.
///
/// For long lines (when !break_lines) we record the byte offset at horizontal
/// checkpoints.  This allows skipping internal portions of very long lines
/// (but not the start or end).
pub const BytePos = struct {
    /// Record BytePos (+dist) after a newline if we've gone this many logical pixels vertically.
    pub const y_sep: f32 = 200.0;

    /// byte just after a newline (or after the last byte)
    byte: usize,

    /// positive: y from top of text layout content rect
    /// negative: -x from left
    dist: f32,

    /// width of all text from previous BytePos to this one
    width: f32,

    /// used to integrate with line_ascents
    line: usize,
};

fn addEdits(self: *TextLayoutWidget, bytes: usize) usize {
    if (bytes >= self.edit_end) {
        if (self.edit_added >= 0) {
            return bytes + @as(usize, @intCast(self.edit_added));
        } else {
            return bytes - @as(usize, @intCast(-self.edit_added));
        }
    }

    return bytes;
}

const CacheLayoutNeed = struct {
    vr: Rect, // w/h already have x/y added in
    start: usize,
    end: usize,
};

// Return first of consecutive pair of BytePos we can skip over:
// * both horizontal (dist < 0) on same line
// * both on same side of vr (visible logical Rect but w/h are maxes, already added)
// * both on same side of cursor/selection/edit range
fn cacheLayoutPair(bps: []BytePos, need: CacheLayoutNeed) ?usize {
    for (bps, 0..) |a, k| {
        if (a.dist >= 0) continue;
        if (k + 1 == bps.len) continue;
        const b = bps[k + 1];
        if (b.dist >= 0) continue;
        if (a.line != b.line) continue;

        if (!((a.byte < need.start and b.byte < need.start) or (a.byte > need.end and b.byte > need.end))) continue;

        // FIXME: need an appropriate curtain for cursor movement (what is the curtain we use vertically?)
        if ((-a.dist < need.vr.x and -b.dist < need.vr.x) or
            (need.vr.w < -a.dist and need.vr.w < -b.dist))
        {
            return k;
        }
    }

    return null;
}

// Return the Rect and byte range we need to run
fn cacheLayoutNeeded(self: *TextLayoutWidget) CacheLayoutNeed {
    // intersect our content rect with the clipping rect
    const rs = self.data().contentRectScale();
    const clip_logical = rs.rectFromPhysical(dvui.clipGet());
    var vr = self.data().contentRect().justSize().intersect(clip_logical);

    // convert to min/max
    vr.w = vr.x + vr.w;
    vr.h = vr.y + vr.h;

    // expand to include mouse pointer (like click-dragging where the mouse
    // pointer might be outside our content rect)
    const mouse = switch (self.sel_move) {
        .mouse => |m| m.down_pt orelse m.drag_pt,
        .expand_pt => |ep| ep.pt,
        else => null,
    };

    if (mouse) |m| {
        vr.x = @min(vr.x, m.x);
        vr.y = @min(vr.y, m.y);

        vr.w = @max(vr.w, m.x);
        vr.h = @max(vr.h, m.y);
    }

    if (self.sel_move == .expand_pt and self.sel_move.expand_pt.which == .word) {
        // we are locating the cursor and expanding selection from there to
        // include a word, so we need vr to include the cursor and (hopefully)
        // whole word
        vr.x -= 200;
        vr.w += 200;
    }

    var force_start: usize = self.edit_start;
    var force_end: usize = self.edit_end;

    if (self.copy_sel) |sel| {
        force_start = @min(force_start, sel.start);
        force_end = @max(force_end, sel.end);
    }

    // CURSOR_NOTE: This whole cursor thing is because in cases where we are looking
    // for the cursor, or the cursor is moving further into the document,
    // addText keeps pushing the cursor to the end of the processed text until
    // it finds where it should go.
    //
    // But that interferes with finding how many BytePos we can skip (search
    // for CURSOR_NOTE), because the assumption is that the end of the region
    // is > cursor, but if addText moves the cursor (positively), then
    // force_end can be >= the region end.
    //
    // Example is expand_pt .end - we must run the bytes including the cursor,
    // but once we find it addText will keep moving the cursor to the end of
    // the processed bytes until we get to the end of the line.
    //
    // So if the cursor might be moved positively during addText, we want to
    // stop including it once we've seen it.
    var exclude_cursor = false;

    // if we are moving the cursor, need to process the text around where we are moving it
    switch (self.sel_move) {
        .none => {},
        .mouse => exclude_cursor = true,
        .expand_pt => |*ep| {
            switch (ep.which) {
                .word, .line => {
                    // we are searching for the cursor this frame, it will be in vr
                    exclude_cursor = true;
                    // .word - after cursor found, selection expanded on both
                    // sides, that's why vr is expanded above, so it
                    // (hopefully) includes the entire word
                    //
                    // .line - we always run the start and end of each line, so
                    // this works even if we skip parts in the middle
                },
                .home, .end => {
                    if (self.selection.cursor > self.bytes_seen) {
                        force_start = @min(force_start, self.selection.cursor);
                        force_end = @max(force_end, self.selection.cursor);
                    }
                },
            }
        },
        .char_left_right => |*clr| {
            if (clr.count < 0) {
                force_start = @min(force_start, self.selection.cursor -| clr.buf.len);
                force_end = @max(force_end, self.selection.cursor);
            } else if (clr.count > 0 and self.selection.cursor > self.bytes_seen) {
                force_start = @min(force_start, self.selection.cursor);
                force_end = @max(force_end, self.selection.cursor +| clr.buf.len);
            }
        },
        .cursor_updown => |*cud| {
            if (cud.pt) |p| {
                // found cursor last frame, need to include p this frame
                vr.y = @min(vr.y, p.y);
                vr.h = @max(vr.h, p.y);
                vr.x = @min(vr.x, p.x);
                vr.w = @max(vr.w, p.x);
                exclude_cursor = true;
            } else {
                // we are looking for the cursor to move from
                force_start = @min(force_start, self.selection.cursor);
                force_end = @max(force_end, self.selection.cursor);
            }
        },
        .word_left_right => |*wlr| {
            if (wlr.count < 0) {
                force_start = @min(force_start, self.selection.cursor -| 200);
                force_end = @max(force_end, self.selection.cursor);
            } else if (wlr.count > 0 and self.selection.cursor > self.bytes_seen) {
                force_start = @min(force_start, self.selection.cursor);
                force_end = @max(force_end, self.selection.cursor +| 200);
            }
        },
    }

    if (self.scroll_to_cursor and !exclude_cursor) {
        force_start = @min(force_start, self.selection.cursor);
        force_end = @max(force_end, self.selection.cursor);
    }

    return .{ .vr = vr, .start = force_start, .end = force_end };
}

/// Return start/end bytes for the current visible region.
///
/// Bytes to `addText` before the current region are counted and dropped.
///
/// The current region will be returned until bytes received >= region end.
/// The next call to this function will advance to the next visible region.
///
/// Note that if bytes past the current region are given to `addText`, it will
/// internally call this to advance the region.
///
/// After the last visible region, returns maxInt(usize) as both start and end.
///
/// When cache_layout is false or can't be used in a frame, returns 0,maxInt(usize).
pub fn cacheLayoutNext(self: *TextLayoutWidget) Region {
    if (!self.cache_layout or self.byte_heights.len == 0) {
        return .{ .start = 0, .end = std.math.maxInt(usize) };
    }

    if (self.cache_layout_region) |clr| {
        if (clr.start == std.math.maxInt(usize)) return clr; // we are past the last region

        if (self.bytes_seen == clr.end) {
            if (self.bytes_seen == self.cache_layout_last_byte) {
                // this was the last region
                self.cache_layout_region = .{ .start = std.math.maxInt(usize), .end = std.math.maxInt(usize) };
                return self.cache_layout_region.?;
            }

            // advance to next region, first find ourselves, we ended on a horizontal BytePos
            var i: usize = 0;
            for (self.byte_heights, 0..) |bh, k| {
                if (self.bytes_seen == self.addEdits(bh.byte)) {
                    i = k;
                    std.debug.assert(bh.dist < 0);
                    break;
                }
            }

            const need = self.cacheLayoutNeeded();
            if (cache_layout_debug) std.debug.print("need {any}\n", .{need});

            // find start of next region (see CURSOR_NOTE above)
            const bhi = self.byte_heights[i];
            var start: usize = 0;
            for (self.byte_heights[i + 1 ..], 0..) |bh, k| {
                if (bh.dist < 0 and bh.line == bhi.line) {
                    if ((-bhi.dist > need.vr.w or (-bhi.dist < need.vr.x and -bh.dist < need.vr.x)) and
                        (bhi.byte > need.end or (bhi.byte < need.start and bh.byte < need.start)))
                    {
                        start = i + 1 + k;
                    }
                } else {
                    break;
                }
            }

            // we should have found one, because a region only ends if there is a pair at the end
            std.debug.assert(i < start);

            // copy skipped BytePos
            const extra_dist = -self.byte_heights[i].dist - self.insert_pt.x;
            // adjust for edits
            for (self.byte_heights[i .. start + 1]) |*bhh| {
                bhh.byte = self.addEdits(bhh.byte);
                bhh.dist += extra_dist;
                bhh.line = self.line; // we only skip on the current line, editing might have moved this line
            }
            self.byte_heights_new.appendSlice(dvui.currentWindow().arena(), self.byte_heights[i..start]) catch {};

            // look for negative space we can skip, need two consecutive same line non-visible BytePos
            const last = self.byte_height_after_idx orelse self.byte_heights.len - 1;
            var end: ?usize = null;
            if (start + 1 < last) {
                if (cacheLayoutPair(self.byte_heights[start + 1 .. last], need)) |k| {
                    end = start + 1 + k;
                }
            }

            self.cache_layout_region = .{
                .start = self.byte_heights[start].byte, // addEdits already done
                .end = self.addEdits(self.byte_heights[end orelse last].byte),
            };

            self.insert_pt.x = -self.byte_heights[start].dist;
            self.line_skipped = true;
            self.current_line_width += -self.byte_heights[start].dist - -self.byte_heights[i].dist;

            // all on a single line, no need to check affinity
            if (!self.cursor_seen and self.bytes_seen < self.selection.cursor and self.selection.cursor < self.cache_layout_region.?.start) {
                //std.debug.print("  cursor seen at {d}\n", .{self.insert_pt.x});
                self.cursor_rect = Rect{ .x = self.insert_pt.x, .y = self.insert_pt.y, .w = 1, .h = 10 };
                self.cursorSeen();
            }

            return self.cache_layout_region.?;
        }

        // still in curent region
        return clr;
    }

    const need = self.cacheLayoutNeeded();
    if (cache_layout_debug) std.debug.print("need initial {any}\n", .{need});

    var start_byte: usize = 0;
    var end_byte: usize = self.byte_heights[self.byte_heights.len - 1].byte;

    // linear search for the start, because we have to use width
    var start: usize = 0; // zero means start at the top, otherwise start-1 is index into byte_heights
    for (self.byte_heights, 0..) |bh, i| {
        if (bh.dist < 0) continue;

        if (bh.dist <= need.vr.y and bh.byte < need.start) {
            self.data().min_size.w = @max(self.data().min_size.w, bh.width);
            start = i + 1;
        } else {
            break;
        }
    }

    if (start == self.byte_heights.len) {
        // can't start at the final
        start -|= 1;
    }

    if (start > 0) {
        // starting not at the top, skipping some
        const startBH = self.byte_heights[start - 1];
        start_byte = startBH.byte;

        self.insert_pt.y = startBH.dist;
        self.line = startBH.line;

        if (self.selection.cursor < start_byte) {
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

        // copy all the BytePos we skipped
        self.byte_heights_new.appendSlice(dvui.currentWindow().arena(), self.byte_heights[0..start]) catch {};

        // copy all the LineAscents we skipped
        var i: usize = 0;
        while (i < self.line_ascents.len and self.line_ascents[i].line < startBH.line) i += 1;
        self.line_ascents_new.appendSlice(dvui.currentWindow().arena(), self.line_ascents[0..i]) catch {};
        self.line_ascents_idx = i;
    }

    // linear scan for the end (but not the final)
    for (self.byte_heights[start .. self.byte_heights.len - 1], start..) |bh, i| {
        if (bh.dist < 0) continue;
        if (bh.dist >= need.vr.h and bh.byte > need.end) {
            //std.debug.print("found end {d} {d} bh height {d} vr {d} {d} {d}\n", .{ i, self.byte_heights.len, bh.height, vr.y, vr.h, vr.y + vr.h });
            end_byte = bh.byte;

            self.byte_height_after_idx = i;
            break;
        }
    }

    // adjust end_byte for any edits
    if (self.edit_added >= 0) {
        end_byte += @intCast(self.edit_added);
    } else {
        end_byte -= @intCast(-self.edit_added);
    }

    self.cache_layout_last_byte = end_byte;
    //std.debug.print("bytesNeeded end {d} {d} {d}\n", .{ start_byte, end_byte, edit_added });

    // look for negative space we can skip, need two consecutive same line
    // non-visible BytePos (must be on same side of visible rect)
    const last = self.byte_height_after_idx orelse self.byte_heights.len - 1;
    if (start < last) {
        if (cacheLayoutPair(self.byte_heights[start..last], need)) |k| {
            end_byte = self.addEdits(self.byte_heights[start + k].byte);
        }
    }

    self.cache_layout_region = .{ .start = start_byte, .end = end_byte };
    return self.cache_layout_region.?;
}

/// Set edit start, end (in previous frame bytes), and added bytes for this
/// frame.  Used when cache_layout is true.  Call before `cacheLayoutNext()`.
pub fn cacheLayoutEdit(self: *TextLayoutWidget, edit_start: usize, edit_end: usize, edit_added: i64) void {
    self.edit_start = edit_start;
    self.edit_end = edit_end;
    self.edit_added = edit_added;
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

const AddTextExAction = enum {
    none,
    click,
    hover,
};

fn addTextEx(self: *TextLayoutWidget, text_in: []const u8, action: AddTextExAction, opts: Options) ?HoverMatch {
    var chunk = text_in;
    var ret: ?HoverMatch = null;
    const ordinal = self.action_ordinal;
    if (action != .none) {
        self.action_ordinal += 1;
        // The hit this call got last frame, if it is still the same call.
        const slot = if (action == .click) self.state.deferred_click else self.state.deferred_hover;
        if (slot) |h| {
            if (h.ordinal == ordinal) ret = .{ .event = h.event, .rect = h.rect };
        }
    }

    while (true) {
        const cln = self.cacheLayoutNext();
        const start = @min(chunk.len, cln.start -| self.bytes_seen);
        const end = @min(chunk.len, cln.end -| self.bytes_seen);

        if (cache_layout_debug) std.debug.print("addTextEx {d} {d} cln {d} {d} start {d} end {d}\n", .{ self.bytes_seen, chunk.len, cln.start, cln.end, start, end });

        if (end > start) {
            // throw away up to start
            self.bytes_seen += start;

            // run start-end
            self.addTextExInner(chunk[start..end], action, ordinal, opts);

            if (end == chunk.len) break;

            chunk = chunk[end..];
        } else {
            // don't need anything or chunk is empty
            self.bytes_seen += chunk.len;
            break;
        }
    }

    if (action == .click and (ret != null)) {
        // we can only click when not in touch editing, so that click must have
        // transitioned us into touch editing, but we don't want to transition
        // if the click happened on clickable text
        self.state.touch_editing = false;
    }

    return ret;
}

fn addTextExInner(self: *TextLayoutWidget, text_in: []const u8, action: AddTextExAction, ordinal: usize, opts: Options) void {
    const cw = dvui.currentWindow();

    if (self.clamped) {
        self.bytes_seen += text_in.len;
        return;
    }

    // clip to content rect for all text
    _ = dvui.clip(self.data().contentRectScale().r);
    self.newline = false;

    const utf8_chunk = dvui.toUtf8(cw.lifo(), text_in) catch |err| blk: {
        dvui.logError(@src(), err, "Failed to convert to utf8", .{});
        break :blk text_in;
    };
    // `txt` is advanced below, so free the original slice, not what's left.
    defer if (utf8_chunk.ptr != text_in.ptr) cw.lifo().free(utf8_chunk);
    var txt = utf8_chunk;

    const options = self.data().options.override(opts);
    const font = options.fontGet();
    const msize = font.sizeM(1, 1);
    const line_height = font.lineHeight();

    var container_width = self.data().contentRect().w;
    if (dvui.firstFrame(self.data().id) or container_width == 0) {
        // If first frame or we are not being shown at all, assume we'll get a
        // large width.  This only matters when break_lines is true.
        //
        // It prevents the following sequence:
        // * first frame we get a narrow or zero width
        //   * break lines tons and report a large height (but correct width)
        //
        // * second frame we get a correct width but large height
        //   * render text, it doesn't take up all the height so large empty space below
        //   * report correct width and height
        //
        // * third frame correct
        //
        // This sequence visually is show too tall (empty) height and correct
        // smaller, which reads as a glitch.
        //
        // The tradeoff is the opposite (where we end up narrow):
        // * first frame we assume we'll get a large width
        //   * break few lines and report small height (but correct width)
        //
        // * second frame we get a correct narrow width
        //   * we only have vertical space for some of the text
        //   * report correct width and height
        //
        // * third frame correct
        //
        // This sequence visually is show too short (full) height and correct
        // larger, which reads as content loading.

        container_width = 1000;
    }

    text_loop: while (txt.len > 0) {
        if (self.byte_height_ready) |bhr| {
            //std.debug.print("byte_height_new append {d} {d} {d} {d}\n", .{ bhr.byte, bhr.height, bhr.line, bhr.width });
            self.byte_heights_new.append(cw.arena(), bhr) catch {};
            self.byte_height_ready = null;
            self.byte_height_width = 0.0;
        }

        if (!self.break_lines) {
            var last_bp_x: f32 = 0;
            if (self.byte_heights_new.items.len > 0) {
                const bp = self.byte_heights_new.items[self.byte_heights_new.items.len - 1];
                if (bp.dist < 0 and self.line == bp.line) last_bp_x = -bp.dist;
            }

            if (self.insert_pt.x > last_bp_x + self.visual_width) {
                self.byte_heights_new.append(cw.arena(), .{ .byte = self.bytes_seen, .dist = -self.insert_pt.x, .line = self.line, .width = self.insert_pt.y }) catch {};
            }
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

        // Shaped once, reused for re-measuring, cursor/selection and rendering.
        // Arena-allocated, so never deinit'd.
        var shaped: ?Font.ShapedText = null;
        var s: Size = undefined;
        // The shape holds both directions, so no byte prefix is contiguous on
        // screen: reshape each line and retreat over-wide lines below.
        var line_is_mixed = false;
        if (shapeSliceable(font, txt, .{
            .max_width = if (self.break_lines) width else if (self.cache_layout) self.visual_width + 10 else null,
            .end_idx = &end,
            .ascent_out = &ascent,
            .base_direction = self.baseDir(),
            .tab_origin = self.insert_pt.x,
        })) |res| {
            s = res.size;
            shaped = res.shaped;
            line_is_mixed = shaped == null;
        } else {
            s = font.textSizeEx(txt, .{
                .max_width = if (self.break_lines) width else null,
                .end_idx = &end,
                .ascent_out = &ascent,
                .tab_origin = self.insert_pt.x,
            });
        }

        // ensure we always get at least 1 codepoint so we make progress
        if (end == 0) {
            end = std.unicode.utf8ByteSequenceLength(txt[0]) catch 1;
            s = if (shaped) |*st| st.measureUpToByteOffset(cw.gpa, end) catch font.textSizeEx(txt[0..end], .{ .tab_origin = self.insert_pt.x }) else font.textSizeEx(txt[0..end], .{ .tab_origin = self.insert_pt.x });
        }

        self.newline = Font.trailingHardBreakLen(txt[0..end]) > 0;

        //std.debug.print("{d} 1 txt to {d} \"{s}\"\n", .{ container_width, end, txt[0..end] });

        if (self.break_lines) blk: {

            // Cut by width, not newline: retreat to a break opportunity. With none,
            // `overflow_wrap` either overflows the word or breaks a character.
            if (end < txt.len and !self.newline) {
                if (self.wrap.point(cw.lifo(), txt, end)) |brk| {
                    end = brk.end;
                    if (brk.overflow) {
                        shaped = null;
                        s = font.textSizeEx(txt[0..end], .{ .tab_origin = self.insert_pt.x });
                    } else {
                        self.newline = Font.trailingHardBreakLen(txt[0..end]) > 0;
                        const shaped_len = if (shaped) |*st| st.line.byte_offsets[st.line.codepoints.len] else 0;
                        if (shaped != null and end <= shaped_len) {
                            // break inside the shaped range: sum the existing advances
                            s = shaped.?.measureUpToByteOffset(cw.gpa, brk.ink_end) catch font.textSizeEx(txt[0..brk.ink_end], .{ .tab_origin = self.insert_pt.x });
                        } else {
                            shaped = null;
                            s = font.textSizeEx(txt[0..brk.ink_end], .{ .tab_origin = self.insert_pt.x });
                        }
                        break :blk; // this part will fit
                    }
                }
            }

            // Reordered text can reshape wider than the seed break. At the line start,
            // retreat to earlier breaks until it fits (an unbreakable run overflows).
            if (line_is_mixed) {
                s = font.textSizeEx(txt[0..end], .{ .tab_origin = self.insert_pt.x });
                const at_line_start = !(linewidth < container_width or self.insert_pt.x > linestart);
                while (at_line_start and s.w > width and end > 0) {
                    end = self.wrap.previous(cw.lifo(), txt, end) orelse break;
                    s = font.textSizeEx(txt[0..end], .{ .tab_origin = self.insert_pt.x });
                }
                self.newline = Font.trailingHardBreakLen(txt[0..end]) > 0;
            }

            // drop to next line without doing anything if:
            // - we are boxed in too much by corner widgets
            // - we aren't starting at the left edge
            // both mean dropping to next line will give us more space
            if (s.w > width and (linewidth < container_width or self.insert_pt.x > linestart) and !self.onLastLine(line_height, msize.h)) {
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

        if (self.onLastLine(line_height, msize.h) and ((self.break_lines and end < txt.len and !self.newline) or s.w > width)) {
            end = font.ellipsisCut(txt, width, .{ .base_direction = self.baseDir(), .tab_origin = self.insert_pt.x });
            self.newline = false;
            self.clamped = true;
            shaped = null;
            if (shapeSliceable(font, txt[0..end], .{ .base_direction = self.baseDir(), .tab_origin = self.insert_pt.x })) |res| {
                s = res.size;
                shaped = res.shaped;
            } else {
                s = font.textSizeEx(txt[0..end], .{ .tab_origin = self.insert_pt.x });
            }
        }

        if (shaped) |*st| {
            // A shape running past the fragment can't be sliced (the leading end is the
            // wrong one for RTL), so reshape the fragment's bytes with the rest of `txt`
            // as context to keep joining forms.
            if (st.line.isRtl() and st.line.byte_offsets[st.line.codepoints.len] != shapeableLen(txt[0..end])) {
                shaped = null;
                if (shapeSliceable(font, txt, .{
                    .item = .{ .start = 0, .end = end },
                    .base_direction = self.baseDir(),
                    .tab_origin = self.insert_pt.x,
                })) |res| if (res.shaped != null) {
                    shaped = res.shaped;
                    s = res.size;
                };
            }
        }

        self.text_line.append(cw.arena(), .{
            .text = cw.arena().dupe(u8, txt[0..end]) catch txt[0..end],
            .byte = self.bytes_seen,
            .x = self.insert_pt.x,
            .y = self.insert_pt.y,
            .w = s.w,
            .h = s.h,
            .newline = self.newline,
            .data = .{
                .ascent = ascent,
                .shaped = shaped,
                .options = options,
                .font = font,
                .action = action,
                .action_ordinal = ordinal,
                .line = self.line,
                .max_ascent = @max(self.current_line_ascent, self.current_line_ascent_recorded),
                // Where the pen lands if this fragment closes the line; the line
                // advance below hasn't run yet, but current_line_height is final.
                .newline_pt = .{ .x = 0, .y = self.insert_pt.y + self.current_line_height },
            },
        }) catch {};

        if (self.clamped) {
            // The ellipsis is a fragment of its own so selection and copy
            // never see it, but it joins the line's bidi pass and lands at
            // the logical end.
            var ef = self.text_line.pieces.getLast();
            ef.text = font.ellipsis();
            const ellipsis_size = font.textSizeEx(ef.text, .{});
            ef.w = ellipsis_size.w;
            ef.h = ellipsis_size.h;
            ef.data.shaped = null;
            ef.data.action = .none;
            ef.byte += end;
            ef.x += s.w;
            ef.data.ellipsis = true;
            self.text_line.append(cw.arena(), ef) catch {};
            self.flushLine();
            self.insert_pt.x += s.w + ef.w;
            self.current_line_width += s.w + ef.w;
            const size = self.data().options.padSize(.{ .w = self.current_line_width, .h = self.insert_pt.y + s.h });
            self.data().min_size.w = @max(self.data().min_size.w, size.w + width_after);
            self.data().min_size.h = @max(self.data().min_size.h, size.h);
            self.bytes_seen += txt.len;
            break :text_loop;
        }

        // Place and draw the line before lineBreak() changes the selection state
        // emitFragment uses.
        if (self.newline or (self.break_lines and end < txt.len)) self.flushLine();

        // Even if we don't actually render (might be outside clipping region),
        // need to update insert_pt and minSize like we did because our parent
        // might size based on that (might be in a scroll area)
        self.insert_pt.x += s.w;
        self.current_line_width += s.w;
        const size = self.data().options.padSize(.{ .w = self.current_line_width, .h = self.insert_pt.y + s.h });
        self.byte_height_width = @max(self.byte_height_width, size.w + width_after);
        self.data().min_size.w = @max(self.data().min_size.w, size.w + width_after);
        self.data().min_size.h = @max(self.data().min_size.h, size.h);

        // discard bytes we've dealt with
        txt = txt[end..];
        self.bytes_seen += end;

        // move insert_pt to next line if we have more text
        if (self.newline or (self.break_lines and txt.len > 0)) {
            self.checkAscent();
            self.line += 1;
            self.insert_pt.y += self.current_line_height;
            self.insert_pt.x = 0;
            self.current_line_height = 0;
            self.current_line_ascent = 0;
            self.current_line_ascent_recorded = 0;

            if (self.newline) {
                const newline_size = self.data().options.padSize(.{ .w = self.current_line_width, .h = self.insert_pt.y + s.h });
                self.byte_height_width = @max(self.byte_height_width, newline_size.w);
                self.data().min_size.w = @max(self.data().min_size.w, newline_size.w);
                self.data().min_size.h = @max(self.data().min_size.h, newline_size.h);
                self.current_line_width = 0.0;

                var last_bh_height: f32 = 0;
                var i = self.byte_heights_new.items.len;
                while (i > 0) : (i -= 1) {
                    const bp = self.byte_heights_new.items[i - 1];
                    if (bp.dist > 0) {
                        last_bh_height = bp.dist;
                        break;
                    }
                }

                if (self.insert_pt.y > last_bh_height + BytePos.y_sep) {
                    self.byte_height_ready = .{ .byte = self.bytes_seen, .dist = self.insert_pt.y, .line = self.line, .width = self.byte_height_width };
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
}

/// Caret x with no text to sit against: the pen, or the right edge in an
/// RTL paragraph.
fn penX(self: *TextLayoutWidget) f32 {
    if (self.insert_pt.x == 0) {
        const avail = self.data().contentRect().w;
        const factor = self.text_align.factor(self.baseDir() == .rtl);
        return if (avail == 0 or factor == 0) 0 else @min(avail * factor, avail - 1);
    }
    // `insert_pt.x` is a width here: the line was aligned after the pen moved.
    // On a mixed line this is the left edge, not the logical end.
    if (self.baseDir() == .rtl) return self.line_left_x orelse self.insert_pt.x;
    return self.insert_pt.x + self.line_shift;
}

fn onLastLine(self: *TextLayoutWidget, line_height: f32, text_height: f32) bool {
    if (self.max_lines) |max| {
        if (self.line + 1 >= max) return true;
    }

    // Height cap: stop at the last whole line instead of clipping one. The cap
    // comes from max_size_content, never our own rect (fed by our min size, it
    // would shrink a line per frame). A trailing line reserves text_height.
    if (self.cache_layout) return false;
    const avail = self.data().options.max_size_contentGet().h;
    if (avail >= dvui.max_float_safe) return false;
    return self.insert_pt.y + line_height + text_height > avail + 0.01;
}

/// Base direction in force right now: what this paragraph's first strong
/// character resolved to, or the app-set default until one appears.
fn baseDir(self: *const TextLayoutWidget) opentype.unicode.Bidi.ParagraphDirection {
    return self.paragraph_direction orelse self.base_direction;
}

/// Places the buffered line in visual order, then draws it in logical order so
/// selection, clipboard and accesskit still see the text the way the caller
/// wrote it.
fn flushLine(self: *TextLayoutWidget) void {
    defer {
        self.text_line.clear();
        self.line_skipped = false;
    }
    if (self.text_line.pieces.items.len == 0) {
        self.line_end_byte = null;
        self.line_left_x = null;
        return;
    }

    // A flush can run from addTextDone/deinit/rectFor, so restore the clip
    // addTextEx set for these fragments, then the caller's.
    const saved_clip = dvui.clip(self.data().contentRectScale().r);
    defer dvui.clipSet(saved_clip);

    // Fragments captured the line ascent when buffered; use the final max.
    var line_max_ascent: f32 = 0;
    for (self.text_line.pieces.items) |f| line_max_ascent = @max(line_max_ascent, @max(f.data.max_ascent, f.data.ascent));
    for (self.text_line.pieces.items) |*f| f.data.max_ascent = line_max_ascent;

    if (self.text_line.needsReorder(self.baseDir())) {
        // Horizontal BytePos hold logical pen x, which reordering moves, so
        // this line can't be skipped next frame.
        const line = self.text_line.pieces.items[0].data.line;
        const bps = &self.byte_heights_new;
        while (bps.items.len > 0 and bps.items[bps.items.len - 1].dist < 0 and bps.items[bps.items.len - 1].line == line) _ = bps.pop();
        if (self.line_skipped) dvui.refresh(null, @src(), self.data().id);
    }
    var direction = self.baseDir();
    self.line_shift = self.text_line.place(dvui.currentWindow().arena(), fragment_shaping, &direction, self.text_align, self.data().contentRect().w);
    self.paragraph_direction = if (direction == .auto) null else direction;

    const frags = self.text_line.pieces.items;
    self.line_end_byte = self.text_line.endByte();
    self.line_left_x = self.text_line.leftX();
    if (line_probe) |probe| probe(frags);
    if (self.sel_move == .mouse) self.mouseDragLine();
    self.line_selection = self.lineSelection();
    const cursor_seen_before = self.cursor_seen;
    for (frags, 0..) |f, i| self.emitFragment(f, i);

    // A caret at the end of the text with `.after` affinity (Ctrl+End) belongs
    // to no fragment, so claim it while its line is placed.
    if (self.add_text_done and !self.cursor_seen) {
        const last = frags[frags.len - 1];
        self.cursor_rect = .{ .x = self.penX(), .y = last.y, .w = 1, .h = last.h };
        self.cursorSeen();
    }
    if (!cursor_seen_before and self.cursor_seen) {
        if (self.lineCaret(.{ .byte = self.selection.cursor, .affinity = self.selection.affinity })) |st| {
            self.cursor_rect.x = st.x;
            // The line's first and last byte move from the paragraph's edges.
            const line_bytes = self.text_line.bytes();
            const at_line_edge = self.selection.cursor == line_bytes[0] or self.selection.cursor == line_bytes[1];
            self.state.cursor_rtl = if (at_line_edge) self.baseDir() == .rtl else st.rtl;
        }
    }

    // A hard break ends the paragraph, so the next one resolves P2 afresh.
    if (frags[frags.len - 1].newline) self.paragraph_direction = null;
}

/// What the line engine carries along with each fragment. Bidi reordering
/// only changes a fragment's `x`; emitting (selection, cursor, clipboard,
/// accesskit, render) is logical-order work.
pub const FragmentData = struct {
    ascent: f32,
    /// Shape of the text that can be sliced by byte prefix; null when it
    /// mixes directions.
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
    line: usize,
    max_ascent: f32,
    /// Pen origin after this fragment closes its line; only read when `newline`.
    newline_pt: Point,
    /// `max_lines` marker: drawn, but holds none of the widget's text.
    ellipsis: bool = false,
};

const TextLine = opentype.line.Line(FragmentData);
pub const Fragment = TextLine.Piece;

/// How the line engine measures and reshapes fragments.
pub const fragment_shaping = struct {
    pub fn caretOffset(_: @This(), f: *const Fragment, off: usize) f32 {
        if (f.data.shaped) |shaped| {
            var st = shaped;
            return st.caretOffset(off);
        }
        const prefix_w = f.data.font.textSize(f.text[0..off]).w;
        return if (f.rtl) f.w - prefix_w else prefix_w;
    }

    pub fn byteAtOffset(_: @This(), f: *const Fragment, x: f32) usize {
        if (f.data.shaped) |shaped| {
            var st = shaped;
            return st.byteAtOffset(x);
        }
        var end: usize = undefined;
        const how_far = if (f.rtl) f.w - x else x;
        _ = f.data.font.textSizeEx(f.text, .{ .max_width = how_far, .end_idx = &end, .end_metric = .nearest });
        return end;
    }

    pub fn sameRun(_: @This(), a: *const Fragment, b: *const Fragment) bool {
        return std.meta.eql(a.data.font.cacheKey(), b.data.font.cacheKey());
    }

    pub fn reshape(_: @This(), f: *Fragment, context: []const u8, item_start: usize, opts: TextLine.ReshapeOptions) bool {
        const cw = dvui.currentWindow();
        if (opts.split) {
            f.data.shaped = null;
            f.data.render_shaped = null;
        }
        const res = (f.data.font.textSizeExShaped(cw.gpa, cw.arena(), context, .{
            .item = .{ .start = item_start, .end = item_start + f.text.len },
            .base_direction = opts.base_direction,
            .tab_origin = opts.tab_origin,
        }) catch null) orelse {
            if (opts.split) {
                const size = f.data.font.textSizeEx(f.text, .{});
                f.w = size.w;
                f.h = size.h;
            }
            return false;
        };
        f.data.render_shaped = res.shaped;
        f.w = res.size.w;
        if (opts.split) f.h = res.size.h;
        if (!res.shaped.line.isMixedDirection()) f.data.shaped = res.shaped;
        return true;
    }
}{};

/// A hit found while emitting is answered next frame; refresh so a still
/// mouse over static text gets that frame.
fn recordHit(self: *TextLayoutWidget, action: AddTextExAction, hit: DeferredHit) void {
    const answered = if (action == .click) self.state.deferred_click else self.state.deferred_hover;
    const already_answered = if (answered) |h| h.ordinal == hit.ordinal else false;
    if (action == .click) {
        self.deferred_click_new = hit;
    } else {
        self.deferred_hover_new = hit;
    }
    if (!already_answered) dvui.refresh(null, @src(), self.data().id);
}

/// `shaped` is null when the text mixes directions: such a shape is only good
/// for drawing, never for slicing by byte offset.
fn shapeSliceable(font: Font, text: []const u8, opts: Font.TextSizeOptions) ?struct { size: Size, shaped: ?Font.ShapedText } {
    const cw = dvui.currentWindow();
    const res = (font.textSizeExShaped(cw.gpa, cw.arena(), text, opts) catch null) orelse return null;
    return .{ .size = res.size, .shaped = if (res.shaped.line.isMixedDirection()) null else res.shaped };
}

/// Bytes of `text` a shape can cover: shaping stops at the first hard break,
/// so a fragment ending in a newline is shaped that newline short.
fn shapeableLen(text: []const u8) usize {
    return if (Font.firstHardBreak(text)) |hb| hb.start else text.len;
}

fn emitFragment(self: *TextLayoutWidget, f: Fragment, index: usize) void {
    const cw = dvui.currentWindow();
    if (f.data.ellipsis) {
        const r: Rect = .{ .x = f.x, .y = f.y + (f.data.max_ascent - f.data.ascent), .w = f.w, .h = f.h };
        const text_col = f.data.options.color(.text).split();
        dvui.renderText(.{ .font = f.data.font, .text = f.text, .rs = self.screenRectScale(r), .color = text_col.color, .gradient = text_col.gradient }) catch |err| {
            dvui.logError(@src(), err, "Failed to render ellipsis", .{});
        };
        return;
    }
    var shaped = f.data.shaped;
    // leading glyphs of `shaped` that belong to `f.text` (RTL shapes that
    // overrun the fragment were already dropped in addTextEx)
    if (shaped) |*st| std.debug.assert(!st.line.buffer.isRtl() or st.line.byte_offsets[st.line.codepoints.len] == shapeableLen(f.text));
    const shaped_glyph_limit: ?usize = if (shaped) |*st| st.line.glyphLimitForByteOffset(f.text.len) else null;
    // see if selection needs to be updated

    // if the text changed our selection might be in the middle of utf8 chars, so fix it up
    while (self.selection.start >= f.byte and self.selection.start < f.byte + f.text.len and f.text[self.selection.start - f.byte] & 0xc0 == 0x80) {
        self.selection.start += 1;
    }

    while (self.selection.cursor >= f.byte and self.selection.cursor < f.byte + f.text.len and f.text[self.selection.cursor - f.byte] & 0xc0 == 0x80) {
        self.selection.cursor += 1;
    }

    while (self.selection.end >= f.byte and self.selection.end < f.byte + f.text.len and f.text[self.selection.end - f.byte] & 0xc0 == 0x80) {
        self.selection.end += 1;
    }

    if (f.data.action != .none) {
        if (self.cursor_pt) |p| {
            const rs = Rect{ .x = f.x, .y = f.y, .w = f.w, .h = f.h };
            if (p.x > rs.x and p.x < (rs.x + rs.w) and p.y > rs.y and p.y < (rs.y + rs.h)) {
                // point is in this text
                if (f.data.action == .click) {
                    dvui.cursorSet(.hand);
                } else if (f.data.action == .hover) {
                    self.recordHit(.hover, .{ .ordinal = f.data.action_ordinal, .event = self.cursor_event.?, .rect = rs });
                }
            }
        }

        if (self.click_pt) |p| {
            const rs = Rect{ .x = f.x, .y = f.y, .w = f.w, .h = f.h };
            if (p.x > rs.x and p.x < (rs.x + rs.w) and p.y > rs.y and p.y < (rs.y + rs.h)) {
                if (f.data.action == .click) {
                    self.recordHit(.click, .{ .ordinal = f.data.action_ordinal, .event = self.click_event.?, .rect = rs });
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
                    sel_bytes[i] = f.byte + f.text.len;
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
    if (self.selection.start >= f.byte and self.selection.start <= f.byte + f.text.len) {
        const off = self.selection.start -| f.byte;
        self.sel_start_r_new = .{ .x = f.caretX(fragment_shaping, off), .y = f.y, .w = 1, .h = f.h };
        self.sel_start_rtl_new = f.rtl;
    }

    // At a fragment boundary the end belongs to the fragment it closes: across
    // a level-run boundary the next fragment's offset 0 is drawn elsewhere.
    if (self.selection.end >= f.byte and self.selection.end <= f.byte + f.text.len and
        (self.selection.end > f.byte or self.sel_end_r_new == null))
    {
        const off = self.selection.end -| f.byte;
        self.sel_end_r_new = .{ .x = f.caretX(fragment_shaping, off), .y = f.y, .w = 1, .h = f.h };
        self.sel_end_rtl_new = f.rtl;
    }

    if (!self.cursor_seen and (self.selection.cursor < f.byte + f.text.len or (self.selection.cursor == f.byte + f.text.len and self.selection.affinity == .before))) {
        std.debug.assert(self.selection.cursor >= f.byte);
        const cursor_offset = self.selection.cursor - f.byte;
        const text_to_cursor = f.text[0..cursor_offset];
        self.cursor_rect = Rect{ .x = f.caretX(fragment_shaping, cursor_offset), .y = f.y, .w = 1, .h = f.h };
        self.state.cursor_rtl = f.rtl;

        self.selMoveText(text_to_cursor, f.byte);
        self.cursorSeen(); // might alter selection
        self.selMoveText(f.text[cursor_offset..], f.byte + cursor_offset);
    } else {
        self.selMoveText(f.text, f.byte);
    }

    const sel_piece = self.text_line.selected(fragment_shaping, index, self.line_selection);
    if (self.visual_build.basis != null) self.visual_build.lines.record(f.byte, sel_piece);

    { // Scope here is for deallocating rtxt before handling copying to clipboard on the arena
        const max_ascent = f.data.max_ascent;
        const y = f.y + (max_ascent - f.data.ascent);
        const r: Rect = .{ .x = f.x, .y = y, .w = f.w, .h = @min(f.h, self.data().contentRect().h - y) };
        const rs = self.screenRectScale(r);
        //std.debug.print("renderText: {} {s}\n", .{ rs.r, f.text });
        const rtxt = f.text;

        const textrun_info: ?AccessKit.TextRunOptions = info: {
            if (dvui.accesskit_enabled and cw.accesskit.text_run_parent != null) {
                if (cw.accesskit.nodes.get(cw.accesskit.text_run_parent.?)) |_| {
                    var text_run_widget = dvui.overlay(textRunSrc(), .{
                        .name = "Text Run",
                        .role = .text_run,
                        .id_extra = f.byte,
                        .rect = r,
                    });
                    defer text_run_widget.deinit();
                    // `pos` is an AccessKit character index into this run's
                    // own text, not a byte offset into the widget's.
                    self.textrun_last = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, rtxt.len) };
                    if (!self.selection.empty()) {
                        if (self.textrun_focus == null and self.selection.cursor >= f.byte and self.selection.cursor < f.byte + rtxt.len) {
                            self.textrun_focus = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, self.selection.cursor - f.byte) };
                        }
                        if (self.textrun_anchor == null) {
                            const anchor = self.selection.anchor().byte;
                            if (anchor >= f.byte and anchor < f.byte + rtxt.len) {
                                self.textrun_anchor = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, anchor - f.byte) };
                            }
                        }
                    }
                    if (self.textrun_cursor == null and self.selection.cursor >= f.byte and self.selection.cursor < f.byte + rtxt.len) {
                        self.textrun_cursor = .{ .node_id = text_run_widget.data().id, .pos = AccessKit.characterIndex(rtxt, self.selection.cursor - f.byte) };
                    }
                    break :info .{
                        .node_id = text_run_widget.data().id,
                        .node_parent_id = cw.accesskit.text_run_parent.?,
                        .controlling_widget_id = if (self.data().options.role.? == .none) cw.accesskit.text_run_parent.? else self.data().id,
                        .line = f.data.line,
                        .byte_offset = f.byte,
                        .rtl = f.rtl,
                    };
                }
            }
            break :info null;
        };

        // Reuse the shape in renderText. Rendering can be deferred (floating
        // windows), so copy the ShapedText header onto the arena.
        var render_glyph_limit = shaped_glyph_limit;
        const pre_shaped: ?*const Font.ShapedText = blk: {
            // The context shape covers exactly `f.text`, so it needs no
            // glyph limit, where `shaped` can still run past the fragment.
            const st = f.data.render_shaped orelse shaped orelse break :blk null;
            if (f.data.render_shaped != null) render_glyph_limit = st.line.buffer.info.items.len;
            const p = cw.arena().create(Font.ShapedText) catch break :blk null;
            p.* = st;
            break :blk p;
        };

        // gradient resets per run; set `gradient.anchor` for one continuous sweep
        const text_col = f.data.options.color(.text).split();
        dvui.renderText(.{
            .font = f.data.font,
            .text = rtxt,
            .rs = rs,
            .color = text_col.color,
            .gradient = text_col.gradient,
            // TODO: Should this take `f.data.options.background` into account?
            .background_color = if (f.data.options.color_fill) |cog| cog.toColor() else null,
            .sel_start = sel_piece[0],
            .sel_end = sel_piece[1],
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
        const frag_end = f.byte + f.text.len;
        if (sel.start < frag_end) {
            // A split selection copies its ranges joined in text order (TextKit).
            const split = sel.splitRanges();
            const ranges: []const [2]usize = if (split.len > 0) split else &.{.{ sel.start, sel.end }};
            for (ranges) |r| {
                const cstart = std.math.clamp(r[0], f.byte, frag_end) - f.byte;
                const cend = std.math.clamp(r[1], f.byte, frag_end) - f.byte;
                if (cstart >= cend) continue;

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
            }

            // push to clipboard if done
            if (sel.end <= frag_end) {
                dvui.clipboardTextSet(self.copy_slice orelse "");
                self.copy_sel = null;
                if (self.copy_slice) |cs| cw.arena().free(cs);
                self.copy_slice = null;
            }
        }
    }

    if (!self.cursor_seen) {
        // until we see the cursor, record the last position it could be
        // in, could be moving to a new line next iteration
        self.cursor_rect = Rect{ .x = f.caretX(fragment_shaping, f.text.len), .y = f.y, .w = 1, .h = f.h };
    }

    if (f.newline and (self.selection.start == f.byte + f.text.len)) {
        self.sel_start_r_new = .{ .x = f.data.newline_pt.x, .y = f.data.newline_pt.y, .w = 1, .h = f.h };
        self.sel_start_rtl_new = f.rtl;
    }

    if (f.newline and (self.selection.end == f.byte + f.text.len)) {
        self.sel_end_r_new = .{ .x = f.data.newline_pt.x, .y = f.data.newline_pt.y, .w = 1, .h = f.h };
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
        var bytes_expected = self.byte_heights[self.byte_heights.len - 1].byte;
        if (self.edit_added > 0) {
            bytes_expected += @intCast(self.edit_added);
        } else {
            bytes_expected -= @intCast(-self.edit_added);
        }
        std.debug.assert(bytes_expected == self.bytes_seen);

        var edit_height: f32 = undefined;
        if (self.byte_height_after_idx) |i| {
            // this is not the final one, always +dist
            const bh = &self.byte_heights[i];

            // we expected to end at bh.height without edits, this is the extra
            // height the edits gave (might be negative)
            edit_height = self.insert_pt.y - bh.dist;
            const edit_lines: i64 = @as(i64, @intCast(self.line)) - @as(i64, @intCast(bh.line));

            self.line += self.byte_heights[self.byte_heights.len - 1].line - bh.line;

            // this is the height we are skipping, last is always +dist
            const extra_height = self.byte_heights[self.byte_heights.len - 1].dist - bh.dist;

            // set min height
            const end_size = self.data().options.padSize(.{ .h = self.insert_pt.y + extra_height });
            self.data().min_size.h = @max(self.data().min_size.h, end_size.h);

            // fixup min width for section that was run
            bh.width = self.byte_height_width;

            // adjust for edits
            for (self.byte_heights[i..self.byte_heights.len]) |*bhh| {
                bhh.byte = self.addEdits(bhh.byte);

                if (edit_lines >= 0) {
                    bhh.line += @intCast(edit_lines);
                } else {
                    bhh.line -= @intCast(-edit_lines);
                }

                if (bhh.dist < 0) continue;

                bhh.dist += edit_height;
            }

            // copy all the BytePos we skipped, but not the final one
            self.byte_heights_new.appendSlice(dvui.currentWindow().arena(), self.byte_heights[i .. self.byte_heights.len - 1]) catch {};

            // update min width for skipped ones
            for (self.byte_heights[i..self.byte_heights.len]) |skipped| {
                if (skipped.dist < 0) continue;
                self.data().min_size.w = @max(self.data().min_size.w, skipped.width);
            }
            self.byte_height_width = self.byte_heights[self.byte_heights.len - 1].width; // for the new one we do below

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
            // use the final one, always +dist
            var bh = &self.byte_heights[self.byte_heights.len - 1];

            // we expected to end at bh.height without edits, this is the extra
            // height the edits gave (might be negative)
            const os = self.data().options;
            const contentMinSize = self.data().min_size.padNeg(os.paddingGet()).padNeg(os.borderGet()).padNeg(os.marginGet());
            edit_height = contentMinSize.h - bh.dist;

            // adjust previous height for sanity check below
            bh.dist += edit_height;
        }
        //std.debug.print("edit_height {d}\n", .{edit_height});
    }

    const os = self.data().options;
    const contentMinSize = self.data().min_size.padNeg(os.paddingGet()).padNeg(os.borderGet()).padNeg(os.marginGet());
    self.byte_heights_new.append(dvui.currentWindow().arena(), .{ .byte = self.bytes_seen, .dist = contentMinSize.h, .line = self.line, .width = self.byte_height_width }) catch {};

    if (self.cache_layout and self.byte_heights.len > 0) {
        // sanity check
        const old = self.byte_heights[self.byte_heights.len - 1].dist;
        const new = self.byte_heights_new.items[self.byte_heights_new.items.len - 1].dist;
        if (new < (old - 1.0) or new > (old + 1.0)) {
            dvui.logError(@src(), error.CacheLayoutError, "the height of the processed text changed by {d}, cache_layout should have been false this frame", .{new - old});
            self.byte_heights_new.clearAndFree(dvui.currentWindow().arena());
        }
    }
    //std.debug.print("final height: {d} at {d}\n", .{ contentMinSize.h, self.bytes_seen });

    if (cache_layout_debug) {
        const clip = dvui.clipGet();
        dvui.clipSet(dvui.windowRectPixels());
        defer dvui.clipSet(clip);
        const crs = self.data().contentRectScale();
        var last_y: f32 = 0;
        for (self.byte_heights_new.items) |bhn| {
            std.debug.print("bh: {d} - {d} {d} width {d}\n", .{ bhn.byte, bhn.line, bhn.dist, bhn.width });
            if (bhn.dist < 0) {
                const p: dvui.Path = .{ .points = &.{
                    crs.pointToPhysical(.{ .x = -bhn.dist, .y = bhn.width - 10 }),
                    crs.pointToPhysical(.{ .x = -bhn.dist, .y = bhn.width + 20 }),
                } };
                p.stroke(.{ .thickness = 1, .color = .red });
            } else {
                last_y = bhn.dist;
                const p: dvui.Path = .{ .points = &.{
                    crs.pointToPhysical(.{ .x = 0, .y = bhn.dist }),
                    crs.pointToPhysical(.{ .x = 100, .y = bhn.dist }),
                } };
                p.stroke(.{ .thickness = 1, .color = .red });
            }
        }
    }

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
                m.anchor = .{ .byte = self.bytes_seen, .affinity = .after };
                self.selection.moveCursor(self.bytes_seen, false);
                m.down_pt = null;
            }

            if (m.drag_pt) |_| {
                // Below the text: the last line already stood in this caret.
                const settled = self.selection.visualCurrent() and self.selection.cursor == self.bytes_seen;
                if (!settled) self.mouseDragTo(m.anchor.?, self.bytes_seen, self.selection.affinity);
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
        if (!self.state.sel_start_r.equals(start_r)) {
            dvui.refresh(null, @src(), self.data().id);
        }
        self.state.sel_start_r = start_r;
        self.state.sel_start_rtl = self.sel_start_rtl_new;
    }

    if (self.selection.start > self.bytes_seen or self.bytes_seen == 0) {
        self.state.sel_start_r = .{ .x = self.penX(), .y = self.insert_pt.y, .w = 1, .h = text_height };
        self.state.sel_start_rtl = self.baseDir() == .rtl;
        if (self.selection.start > self.bytes_seen) {
            dvui.refresh(null, @src(), self.data().id);
        }
    }

    if (self.sel_end_r_new) |end_r| {
        if (!self.state.sel_end_r.equals(end_r)) {
            dvui.refresh(null, @src(), self.data().id);
        }
        self.state.sel_end_r = end_r;
        self.state.sel_end_rtl = self.sel_end_rtl_new;
    }

    if (self.selection.end > self.bytes_seen or self.bytes_seen == 0) {
        self.state.sel_end_r = .{ .x = self.penX(), .y = self.insert_pt.y, .w = 1, .h = text_height };
        self.state.sel_end_rtl = self.baseDir() == .rtl;
        if (self.selection.end > self.bytes_seen) {
            dvui.refresh(null, @src(), self.data().id);
        }
    }

    self.visualFinish();

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
    if (self.state.touch_editing and self.state.te_show_context_menu and self.focus_at_start and self.data().visible()) {
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
    if (self.state.touch_editing and e.evt == .mouse and e.evt.mouse.action == .release and e.evt.mouse.button.touch()) {
        self.state.te_show_draggables = true;
        self.state.te_show_context_menu = true;
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
                    self.state.te_focus_on_touchdown = self.focus_at_start;
                    if (self.state.touch_editing) {
                        self.state.te_show_context_menu = false;

                        // need to refresh draggables
                        dvui.refresh(null, @src(), self.data().id);
                    }
                } else if (me.button.pointer()) {
                    // a click always sets sel_move - has the highest priority
                    const p = self.data().contentRectScale().pointFromPhysical(me.p);
                    self.sel_move = .{ .mouse = .{ .down_pt = p } };
                    self.scroll_to_cursor = true;

                    if (self.state.click_num == 1) {
                        // select word we touched
                        self.sel_move = .{ .expand_pt = .{ .which = .word, .pt = p } };
                    } else if (self.state.click_num == 2) {
                        // select line we touched
                        self.sel_move = .{ .expand_pt = .{ .which = .line, .pt = p } };
                    }
                }
            } else if (me.action == .release and (me.button.pointer() or me.button == .middle) and dvui.captured(self.data().id)) {
                e.handle(@src(), self.data());

                if (!self.state.touch_editing and dvui.dragging(me, null) == null) {
                    // click without drag
                    self.click_pt = self.data().contentRectScale().pointFromPhysical(me.p);
                    self.click_event = e.evt;

                    if (me.button.pointer()) {
                        self.state.click_num += 1;
                        self.state.click_num_pt = me.p;
                        if (self.state.click_num >= 3) {
                            self.state.click_num = 0;
                        }
                    }
                }

                if (me.button.touch()) {
                    // this was a touch-release without drag, which transitions
                    // us between touch editing
                    const p = self.data().contentRectScale().pointFromPhysical(me.p);

                    if (self.state.te_focus_on_touchdown) {
                        self.state.touch_editing = !self.state.touch_editing;
                        // move cursor to point
                        self.sel_move = .{ .mouse = .{ .down_pt = p } };
                        if (self.state.touch_editing) {
                            // select word we touched
                            self.sel_move = .{ .expand_pt = .{ .which = .word, .pt = p } };
                        }
                    } else {
                        if (self.touch_edit_just_focused) {
                            self.state.touch_editing = true;
                        }
                        if (self.state.te_first) {
                            // This is the very first time we are entering
                            // touch editing from not having focus, we want to
                            // position the cursor.
                            self.state.te_first = false;

                            // select word we touched
                            self.sel_move = .{ .expand_pt = .{ .which = .word, .pt = p } };
                        }
                    }
                    dvui.refresh(null, @src(), self.data().id);
                }

                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
            } else if (me.action == .motion and dvui.captured(self.data().id)) {
                if (dvui.dragging(me, null)) |_| {
                    self.state.click_num = 0;
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
                        dvui.dragEnd(me.button);
                    }
                }
            } else if (me.action == .motion) {
                if (self.state.click_num > 0) {
                    const dp = me.p.diff(self.state.click_num_pt).toNatural();
                    if (@abs(dp.x) > dvui.Dragging.threshold or @abs(dp.y) > dvui.Dragging.threshold) {
                        self.state.click_num = 0;
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

    self.state.deferred_click = self.deferred_click_new;
    self.state.deferred_hover = self.deferred_hover_new;
    dvui.dataSet(null, self.data().id, "_selection", self.selection.*);
    dvui.dataSetSlice(null, self.data().id, "__byte_pos", self.byte_heights_new.items);
    dvui.dataSetSlice(null, self.data().id, "__line_ascents", self.line_ascents_new.items);

    if (self.scroll_to_cursor_next_frame) {
        dvui.dataSet(null, self.data().id, "_scroll_to_cursor", true);
    }

    if (dvui.captured(self.data().id)) {
        if (self.sel_move == .mouse) {
            // once we figure out where the mousedown was, we need to save it
            // as long as we are dragging
            dvui.dataSet(null, self.data().id, "_sel_move_mouse_anchor", self.sel_move.mouse.anchor.?);
        } else if (self.sel_move == .expand_pt and (self.sel_move.expand_pt.which == .word or self.sel_move.expand_pt.which == .line)) {
            dvui.dataSet(null, self.data().id, "_sel_move_expand_pt_which", self.sel_move.expand_pt.which);
            dvui.dataSet(null, self.data().id, "_sel_move_expand_pt_bytes", self.sel_move.expand_pt.bytes);
        }
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

test "e2e: a clickable chunk reordered to the left edge answers a click there" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var clicks: usize = 0;
        var content: dvui.Rect.Physical = .{};

        fn frame() !dvui.App.Result {
            // No expand: the widget hugs the text, so the RTL line origin is
            // the content rect's left edge and this stays a reorder test.
            var tl = dvui.textLayout(@src(), .{}, .{});
            tl.addText("\u{05e9}\u{05dc}\u{05d5}\u{05dd} ", .{});
            if (tl.addTextClick("world", .{})) |_| clicks += 1;
            tl.addTextDone(.{});
            content = tl.data().contentRectScale().r;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // The link is logically last but visually first, so it sits at the left edge.
    const c = fns.content;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = c.x + 4, .y = c.y + 4 } });
    try dvui.testing.click(.left);
    try dvui.testing.settle(fns.frame);

    try std.testing.expectEqual(@as(usize, 1), fns.clicks);
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

test "e2e: a word that fits keeps its line when only the trailing space overflows" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        const word = "mmmmmmmmmmmmmm";
        var word_width: f32 = 0;
        var lines: usize = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .padding = .{}, .rect = .{ .w = word_width + 1, .h = 180 } });
            word_width = tl.data().options.fontGet().textSize(word).w;
            tl.addText(word ++ " " ++ word, .{});
            tl.addTextDone(.{});
            lines = tl.line + 1;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // The `end + 1` lookahead must see the break after the space, or the first
    // word is char-broken off.
    try std.testing.expectEqual(@as(usize, 2), fns.lines);
}

test "e2e: an RTL paragraph starts at the right edge" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var clicks: usize = 0;
        var content: dvui.Rect.Physical = .{};
        var hit: ?Rect = null;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal });
            // RLM first, so P2/P3 resolve the paragraph RTL even though the
            // only word here is Latin.
            tl.addText("\u{200f}", .{});
            if (tl.addTextClick("world", .{})) |_| clicks += 1;
            tl.addText(" \u{05e9}\u{05dc}\u{05d5}\u{05dd}", .{});
            tl.addTextDone(.{});
            content = tl.data().contentRectScale().r;
            hit = if (tl.state.deferred_click) |h| h.rect else null;
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
    // before the frame's single position event: one frame, two hits, two chunks.
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = click_pt });
    try dvui.testing.click(.left);
    _ = try cw.addEventMouseMotion(.{ .pt = hover_pt });
    try dvui.testing.settle(fns.frame);

    try std.testing.expectEqual(@as(usize, 1), fns.clicks);
    try std.testing.expectEqual(@as(usize, 1), fns.hovers);
}

test "State left at deinit comes back next frame" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var seen: State = undefined;

        fn frame() !dvui.App.Result {
            {
                var tl = dvui.textLayout(@src(), .{}, .{});
                seen = tl.state.*;
                tl.addText("a", .{});
                tl.state.click_num = 2;
                tl.state.click_num_pt = .{ .x = 5, .y = 6 };
                tl.state.te_focus_on_touchdown = true;
                tl.state.te_first = false;
                tl.deinit();
            }
            return .ok;
        }
    };

    _ = try dvui.testing.step(fns.frame);
    try std.testing.expectEqual(true, fns.seen.te_first);
    try std.testing.expectEqual(@as(u8, 0), fns.seen.click_num);
    try std.testing.expectEqual(false, fns.seen.te_focus_on_touchdown);

    _ = try dvui.testing.step(fns.frame);
    try std.testing.expectEqual(false, fns.seen.te_first);
    try std.testing.expectEqual(@as(u8, 2), fns.seen.click_num);
    try std.testing.expectEqual(dvui.Point.Physical{ .x = 5, .y = 6 }, fns.seen.click_num_pt);
    try std.testing.expectEqual(true, fns.seen.te_focus_on_touchdown);
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
            max_ascent = if (tl.text_line.pieces.items.len > 0) tl.text_line.pieces.items[0].data.max_ascent else -1;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.max_ascent > 0);
}

test "e2e: a click or drag lands in the run under it, not the logically-first one" {
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

        fn moveTo(x: f32) !void {
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = content.x + x * scale, .y = content.y + 4 } });
            try dvui.testing.settle(frame);
        }

        fn clickAt(x: f32) !void {
            try moveTo(x);
            try dvui.testing.click(.left);
            try dvui.testing.settle(frame);
        }

        fn button(action: enum { press, release }) !void {
            _ = try dvui.currentWindow().addEventMouseButton(.left, if (action == .press) .press else .release);
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

    // A drag between the same two points crosses the level-run boundary; the
    // selection it leaves is the logical range between the bytes, not the
    // visual sweep.
    try fns.moveTo(fns.total - fns.w_first_half);
    try fns.button(.press);
    try fns.moveTo(fns.total - fns.w_first - fns.w_second_half);
    try fns.button(.release);

    try std.testing.expectEqual(@as(usize, 4), fns.sel.start);
    try std.testing.expectEqual(fns.first.len + 4, fns.sel.end);
}

test "copy: a split selection copies its ranges joined in text order" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        // "abc" | Hebrew | "xyz" with "c" and the Hebrew's last letter selected.
        var sel: Selection = .{
            .cursor = 2,
            .start = 2,
            .end = 11,
            .visual = .{ .anchor = .{ .byte = 9, .affinity = .after }, .cursor = 2, .start = 2, .end = 11, .ranges = .{ .{ 2, 3 }, .{ 9, 11 } } ++ .{.{ 0, 0 }} ** (Selection.max_split_ranges - 2), .ranges_len = 2 },
        };
        var copy_next = false;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .selection = &sel }, .{});
            if (copy_next) tl.copy();
            copy_next = false;
            tl.addText("abc\u{05e9}\u{05dc}\u{05d5}\u{05dd}xyz", .{});
            tl.addTextDone(.{});
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqual(@as(usize, 2), fns.sel.splitRanges().len);
    fns.copy_next = true;
    try dvui.testing.settle(fns.frame);
    try std.testing.expectEqualStrings("c\u{05dd}", dvui.clipboardText());
}

test "e2e: a wrapping RTL fragment answers clicks by cluster and places its caret on the pen" {
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
        var caret_rect: Rect = .{};
        var font: Font = undefined;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .selection = &sel }, .{ .rect = .{ .w = 60, .h = 180 } });
            font = tl.data().options.fontGet();
            line_h = font.lineHeight();
            tl.addText(text, .{});
            tl.addTextDone(.{});
            const rs = tl.data().contentRectScale();
            content = rs.r;
            scale = rs.s;
            lines = tl.line + 1;
            caret_rect = tl.cursor_rect;
            tl.deinit();
            return .ok;
        }

        fn clickAt(x: f32, y: f32) !void {
            _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = content.x + x * scale, .y = content.y + y * scale } });
            try dvui.testing.click(.left);
            try dvui.testing.settle(frame);
        }

        fn caretAt(byte: usize, affinity: Selection.Affinity) !Rect {
            sel.cursor = byte;
            sel.start = byte;
            sel.end = byte;
            sel.affinity = affinity;
            try dvui.testing.settle(frame);
            return caret_rect;
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

    // The first line only has a shape to place a caret from because addTextEx
    // reshapes its own byte range. Walk it a codepoint at a time.
    var xs: [32]f32 = undefined;
    var stops: usize = 0;
    const first = try fns.caretAt(0, .after);
    var off: usize = 0;
    while (off < wrap) : (off += 2) {
        const c = try fns.caretAt(off, .after);
        try std.testing.expectEqual(first.y, c.y);
        xs[stops] = c.x;
        stops += 1;
    }

    // The line's left pen edge: every other caret on it is measured against
    // this, so the line's origin never enters the comparison.
    const left = (try fns.caretAt(wrap, .before)).x;

    var ref = (try fns.font.textSizeExShaped(dvui.currentWindow().gpa, std.testing.allocator, fns.text[0..wrap], .{})).?;
    defer ref.shaped.deinit();

    for (xs[0..stops], 0..) |x, k| {
        // An ink-width caret drifts by a different amount at every stop; a
        // pen one lands on the glyph boundary the renderer drew.
        try std.testing.expectApproxEqAbs(ref.shaped.caretOffset(k * 2), x - left, 0.5);
    }
}

test "text_align and base_direction: where byte 0's caret lands" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var text: []const u8 = "";
        var text_align: TextAlign = .start;
        var dir: opentype.unicode.Bidi.ParagraphDirection = .auto;
        var caret_x: f32 = 0;
        var avail: f32 = 0;
        var text_w: f32 = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .text_align = text_align, .base_direction = dir }, .{ .expand = .horizontal });
            tl.addText(text, .{});
            avail = tl.data().contentRect().w;
            text_w = tl.data().options.fontGet().textSize(text).w;
            tl.addTextDone(.{});
            caret_x = tl.cursor_rect.x;
            tl.deinit();
            return .ok;
        }
    };

    // expected x = avail_share * avail + text_share * text_w + shift
    const cases = [_]struct { text: []const u8, text_align: TextAlign, dir: opentype.unicode.Bidi.ParagraphDirection, avail_share: f32, text_share: f32, shift: f32 = 0 }{
        .{ .text = "abc", .text_align = .start, .dir = .auto, .avail_share = 0, .text_share = 0 },
        .{ .text = "abc", .text_align = .right, .dir = .auto, .avail_share = 1, .text_share = -1 },
        .{ .text = "abc", .text_align = .center, .dir = .auto, .avail_share = 0.5, .text_share = -0.5 },
        // end follows an RTL base to the left
        .{ .text = "abc", .text_align = .end, .dir = .rtl, .avail_share = 0, .text_share = 1 },
        // an RTL base right-aligns a line holding no RTL character
        .{ .text = "abc", .text_align = .start, .dir = .rtl, .avail_share = 1, .text_share = 0 },
        .{ .text = "", .text_align = .start, .dir = .auto, .avail_share = 0, .text_share = 0 },
        // an empty RTL paragraph keeps its caret inside the right edge
        .{ .text = "", .text_align = .start, .dir = .rtl, .avail_share = 1, .text_share = 0, .shift = -1 },
    };
    for (cases) |c| {
        fns.text = c.text;
        fns.text_align = c.text_align;
        fns.dir = c.dir;
        try dvui.testing.settle(fns.frame);
        try std.testing.expectApproxEqAbs(c.avail_share * fns.avail + c.text_share * fns.text_w + c.shift, fns.caret_x, 0.5);
    }
}

test "max_lines and height cap: lay out no further than the last whole line" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 400 } });
    defer t.deinit();

    const fns = struct {
        var max_lines: ?usize = null;
        var max_h: ?f32 = null;
        var height: f32 = 0;
        var cap_h: f32 = 0;
        var lines: usize = 0;
        var clamped = false;
        var bytes_seen: usize = 0;

        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .max_lines = max_lines }, .{
                .min_size_content = .width(120),
                .max_size_content = if (max_h) |h| .size(.{ .w = 120, .h = h }) else .width(120),
            });
            tl.addText("one two three four five six seven eight nine ten eleven twelve thirteen", .{});
            tl.addText(" fourteen", .{});
            tl.addTextDone(.{});
            height = tl.data().min_size.h;
            cap_h = tl.data().options.max_sizeGet().h;
            lines = tl.line + 1;
            clamped = tl.clamped;
            bytes_seen = tl.bytes_seen;
            tl.deinit();
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    const full_height = fns.height;
    const full_lines = fns.lines;
    try std.testing.expect(!fns.clamped);

    fns.max_lines = 2;
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.clamped);
    try std.testing.expect(fns.height < full_height);
    // Clamped text still counts toward byte offsets, so selection past it stays sane.
    try std.testing.expectEqual("one two three four five six seven eight nine ten eleven twelve thirteen fourteen".len, fns.bytes_seen);

    fns.max_lines = null;
    fns.max_h = 60;
    try dvui.testing.settle(fns.frame);
    try std.testing.expect(fns.clamped);
    try std.testing.expect(fns.lines < full_lines);
    // The cap is a content height, so the widget may still be that much plus
    // its own padding -- what must not happen is a line hanging past it.
    try std.testing.expect(fns.height <= fns.cap_h);
}

test "cache_layout: a long LTR line records horizontal BytePos, a reordered one drops them" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 400, .h = 200 } });
    defer t.deinit();

    const fns = struct {
        var id: dvui.Id = undefined;
        fn frame() !dvui.App.Result {
            var tl = dvui.textLayout(@src(), .{ .break_lines = false, .cache_layout = true }, .{ .expand = .horizontal });
            defer tl.deinit();
            id = tl.data().id;
            tl.addText("a" ** 2000 ++ "\n" ++ "\u{05e9}" ** 1000, .{});
            tl.addTextDone(.{});
            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);
    const bps = dvui.dataGetSlice(null, fns.id, "__byte_pos", []BytePos).?;
    var horizontal: [2]usize = .{ 0, 0 };
    for (bps) |bp| {
        if (bp.dist < 0) horizontal[bp.line] += 1;
    }
    try std.testing.expect(horizontal[0] > 0);
    try std.testing.expectEqual(@as(usize, 0), horizontal[1]);
}

test "fragment_shaping: a word split across chunks joins across the split" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const arena = dvui.currentWindow().arena();

    const font: Font = .find(.{ .family = "Vera", .size = 16 });
    // seen+lam | alef+meem, i.e. one Arabic word handed to addText twice.
    const word = "\u{0633}\u{0644}\u{0627}\u{0645}";
    var line: TextLine = .{};
    var widths: f32 = 0;
    for ([_][]const u8{ word[0..4], word[4..] }, [_]usize{ 0, 4 }) |text, byte| {
        const size = font.textSizeEx(text, .{});
        widths += size.w;
        try line.append(arena, .{ .text = text, .byte = byte, .x = 0, .y = 0, .w = size.w, .h = size.h, .newline = false, .data = std.mem.zeroInit(FragmentData, .{ .font = font }) });
    }
    var direction: opentype.unicode.Bidi.ParagraphDirection = .auto;
    _ = line.place(arena, fragment_shaping, &direction, .start, 0);

    const frags = line.pieces.items;
    try std.testing.expect(frags[0].data.render_shaped != null);
    try std.testing.expect(frags[1].data.render_shaped != null);

    var alone = (try font.textSizeExShaped(dvui.currentWindow().gpa, std.testing.allocator, frags[0].text, .{})).?;
    defer alone.shaped.deinit();
    if (alone.shaped.line.buffer.info.items[0].codepoint == 0) return error.SkipZigTest;

    // With the alef as context, seen+lam take joining forms: a different glyph
    // sequence than the same bytes shaped alone, and narrower.
    const ctx_glyphs = frags[0].data.render_shaped.?.line.buffer.info.items;
    const alone_glyphs = alone.shaped.line.buffer.info.items;
    var same = ctx_glyphs.len == alone_glyphs.len;
    if (same) {
        for (ctx_glyphs, alone_glyphs) |a, b| {
            if (a.codepoint != b.codepoint) same = false;
        }
    }
    try std.testing.expect(!same);
    try std.testing.expect(frags[0].w + frags[1].w < widths);
}

const LineSelection = opentype.line.Selection;

const VisualBuild = struct {
    /// The selection the build started from; a move during layout voids it.
    basis: ?Selection.Visual = null,
    lines: opentype.line.VisualSelection = .{},
};

/// Where the caret for `caret` is drawn on the placed line, or null when
/// another line owns it.
fn lineCaret(self: *TextLayoutWidget, caret: Selection.Caret) ?opentype.line.CaretStop {
    return self.text_line.caret(dvui.currentWindow().arena(), fragment_shaping, caret, self.add_text_done, self.baseDir() == .rtl);
}

/// How the placed line is selected. A keyboard-extended selection is
/// resolved visually on mixed-direction lines.
fn lineSelection(self: *TextLayoutWidget) LineSelection {
    const sel = self.selection;
    const logical: LineSelection = .{ .bytes = .{ sel.start, sel.end } };
    // ponytail: cached layout skips lines, so its selections stay logical.
    if (sel.empty() or !sel.visualCurrent() or self.cache_layout) return logical;
    const vb = &self.visual_build;
    if (vb.basis == null) vb.basis = sel.visual;
    return vb.lines.lineSelection(dvui.currentWindow().arena(), &self.text_line, fragment_shaping, sel.visual.anchor, .{ .byte = sel.cursor, .affinity = sel.affinity }, self.add_text_done, self.baseDir() == .rtl);
}

/// Makes this frame's visual ranges the selection's, unless the selection
/// moved during layout (the move already asked for another frame).
fn visualFinish(self: *TextLayoutWidget) void {
    const vb = self.visual_build;
    self.visual_build = .{};
    const basis = vb.basis orelse return;
    const sel = self.selection;
    if (!sel.visualCurrent() or sel.cursor != basis.cursor or sel.visual.anchor.byte != basis.anchor.byte) return;
    const result = vb.lines.finish(sel.visual.anchor, .{ .byte = sel.cursor, .affinity = sel.affinity }) orelse return;
    const start = result.ranges[0][0];
    const end = result.ranges[result.ranges.len - 1][1];
    if (start != sel.start or end != sel.end) dvui.refresh(null, @src(), self.data().id);
    sel.start = start;
    sel.end = end;
    sel.visual.start = start;
    sel.visual.end = end;
    sel.visual.ranges_len = @intCast(result.ranges.len);
    @memcpy(sel.visual.ranges[0..result.ranges.len], result.ranges);
    sel.visual.left = result.left;
    sel.visual.right = result.right;
}

/// Steps the caret across the placed line in visual order, consuming `clr`'s
/// count; what runs off the line's end is left as a logical count.
fn charVisualMove(self: *TextLayoutWidget, clr: *@FieldType(@TypeOf(self.sel_move), "char_left_right")) void {
    const step = self.text_line.stepVisual(dvui.currentWindow().arena(), fragment_shaping, .{ .byte = self.selection.cursor, .affinity = self.selection.affinity }, clr.count, self.baseDir() == .rtl);
    clr.count = step.logical;
    const to = step.to orelse return;
    self.selection.moveCursor(to.byte, clr.select);
    self.selection.affinity = to.affinity;
    self.scroll_to_cursor_next_frame = true;
    dvui.refresh(null, @src(), self.data().id);
}

/// The hit for `p` if the fragment at `index` is the one that owns it. The
/// whole line is rescanned per point per fragment; a line holds a handful of
/// fragments, so caching the answers is not worth the state.
fn hitHere(self: *TextLayoutWidget, p: Point, index: usize) ?Selection.Caret {
    const found = self.text_line.hit(fragment_shaping, p.x, p.y, self.line_end_byte orelse self.bytes_seen) orelse return null;
    return if (found.index == index) found.caret else null;
}
