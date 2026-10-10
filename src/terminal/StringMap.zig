/// A string along with the mapping of each individual byte in the string
/// to the point in the screen.
const StringMap = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const oni = @import("oniguruma");
const point = @import("point.zig");
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const Pin = @import("PageList.zig").Pin;
const Allocator = std.mem.Allocator;

// Retry budget for StringMap regex searches.
//
// Units are Oniguruma retry steps (internal backtracking/retry counter),
// not bytes/characters/time.
const oni_search_retry_limit = 100_000;

string: [:0]const u8,
map: []Pin,

pub fn deinit(self: StringMap, alloc: Allocator) void {
    alloc.free(self.string);
    alloc.free(self.map);
}

/// Returns an iterator that yields the next match of the given regex.
/// Requires Ghostty to be compiled with regex support.
pub const searchIterator = if (build_options.oniguruma)
    searchIteratorOni
else
    void;

fn searchIteratorOni(
    self: StringMap,
    regex: oni.Regex,
) SearchIterator {
    return .{ .map = self, .regex = regex };
}

/// Iterates over the regular expression matches of the string.
pub const SearchIterator = struct {
    map: StringMap,
    regex: oni.Regex,
    offset: usize = 0,

    /// Returns the next regular expression match or null if there are
    /// no more matches.
    pub fn next(self: *SearchIterator) !?Match {
        if (self.offset >= self.map.string.len) return null;

        // Use per-search match params so we can bound regex retry steps
        // (Oniguruma's internal backtracking work counter).
        var match_param = try oni.MatchParam.init();
        defer match_param.deinit();
        try match_param.setRetryLimitInSearch(oni_search_retry_limit);

        var region = self.regex.searchWithParam(
            self.map.string[self.offset..],
            .{},
            &match_param,
        ) catch |err| switch (err) {
            // Retry/stack-limit errors mean we hit our work budget and
            // aborted matching.
            // For iterator callers this is equivalent to "no further matches".
            error.Mismatch,
            error.RetryLimitInMatchOver,
            error.RetryLimitInSearchOver,
            error.MatchStackLimitOver,
            error.SubexpCallLimitInSearchOver,
            => {
                self.offset = self.map.string.len;
                return null;
            },

            else => return err,
        };
        errdefer region.deinit();

        // Increment our offset by the number of bytes in the match.
        // We defer this so that we can return the match before
        // modifying the offset.
        const end_idx: usize = @intCast(region.ends()[0]);
        defer self.offset += end_idx;

        return .{
            .map = self.map,
            .offset = self.offset,
            .region = region,
        };
    }
};

/// A single regular expression match.
pub const Match = struct {
    map: StringMap,
    offset: usize,
    region: oni.Region,

    pub fn deinit(self: *Match) void {
        self.region.deinit();
    }

    /// Returns the selection containing the full match.
    pub fn selection(self: Match) Selection {
        const start_idx: usize = @intCast(self.region.starts()[0]);
        const end_idx: usize = @intCast(self.region.ends()[0] - 1);
        const start_pt = self.map.map[self.offset + start_idx];
        const end_pt = self.map.map[self.offset + end_idx];
        return .init(start_pt, end_pt, false);
    }

    /// Whether `pin` lies within the matched text on its row: between the
    /// first and last cells the match maps to there. Unlike
    /// `selection().contains`, this excludes cells the string skipped
    /// between matched cells — the re-indentation of a row a TUI
    /// hard-wrapped, when the string was formatted with reflow.
    pub fn covers(self: Match, pin: Pin) bool {
        const start: usize = @intCast(self.region.starts()[0]);
        const end: usize = @intCast(self.region.ends()[0]);
        var min: ?usize = null;
        var max: usize = 0;
        for (self.map.map[self.offset + start .. self.offset + end]) |p| {
            if (p.node != pin.node or p.y != pin.y) continue;
            min = @min(min orelse p.x, p.x);

            // A wide character's spacer tail has no bytes of its own.
            const tail: usize = if (p.rowAndCell().cell.wide == .wide) 1 else 0;
            max = @max(max, p.x + tail);
        }
        const lo = min orelse return false;
        return pin.x >= lo and pin.x <= max;
    }
};

test "StringMap searchIterator" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        "[A-B]{2}",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen
    var s = try Screen.init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).?,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Get our iterator
    var it = map.searchIterator(re);
    {
        var match = (try it.next()).?;
        defer match.deinit();

        const sel = match.selection();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL detection" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(alloc, .{ .cols = 40, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com/path world");

    // Get the line
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 10,
            .y = 0,
        } }).?,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Search for URL match
    var it = map.searchIterator(re);
    {
        var match = (try it.next()).?;
        defer match.deinit();

        const sel = match.selection();
        // URL should start at x=6 ("https://example.com/path" starts after "hello ")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 6,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        // URL should end at x=29 (end of "/path")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 29,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL across a TUI hard wrap" {
    // Claude Code broke this URL mid-token across three rows and re-indented
    // each continuation (a real 100-column render). Hard-wrap line selection
    // plus reflow must see one URL, and the margins it skips are not part of
    // the link.
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");

    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    var s = try Screen.init(alloc, .{ .cols = 100, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString(
        \\  A very long URL that must wrap: https://github.com/dzearing/ghoztty/blob/main/src/terminal/formatt
        \\  er.zig?plain=1&query=this-is-a-deliberately-long-query-string-that-keeps-going-and-going-past-the-
        \\  right-edge-of-the-pane-for-testing#L1234-L1300 and some trailing text after it.
    );

    // Hover the middle row.
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{ .x = 50, .y = 1 } }).?,
        .whitespace = null,
        .hard_wraps = true,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .reflow = true,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    var it = map.searchIterator(re);
    var match = (try it.next()).?;
    defer match.deinit();

    const start: usize = @intCast(match.region.starts()[0]);
    const end: usize = @intCast(match.region.ends()[0]);
    try testing.expectEqualStrings(
        "https://github.com/dzearing/ghoztty/blob/main/src/terminal/formatter.zig?plain=1&query=this-is-a-deliberately-long-query-string-that-keeps-going-and-going-past-the-right-edge-of-the-pane-for-testing#L1234-L1300",
        map.string[match.offset + start .. match.offset + end],
    );

    const sel = match.selection();
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 34,
        .y = 0,
    } }, s.pages.pointFromPin(.screen, sel.start()).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 47,
        .y = 2,
    } }, s.pages.pointFromPin(.screen, sel.end()).?);

    // Text on every row is the link; a continuation's margin is not.
    for ([_]point.Coordinate{
        .{ .x = 60, .y = 0 },
        .{ .x = 2, .y = 1 },
        .{ .x = 99, .y = 1 },
        .{ .x = 2, .y = 2 },
    }) |c| try testing.expect(match.covers(s.pages.pin(.{ .active = c }).?));
    for ([_]point.Coordinate{
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 2 },
        .{ .x = 49, .y = 2 },
    }) |c| try testing.expect(!match.covers(s.pages.pin(.{ .active = c }).?));

    // The selection reformatted with reflow — what a click opens and what
    // copy-URL copies — is the whole URL.
    const opened = try s.selectionString(alloc, .{
        .sel = sel,
        .trim = false,
        .reflow = true,
    });
    defer alloc.free(opened);
    try testing.expectEqualStrings("https://github.com/dzearing/ghoztty/blob/main/src/terminal/formatter.zig?plain=1&query=this-is-a-deliberately-long-query-string-that-keeps-going-and-going-past-the-right-edge-of-the-pane-for-testing#L1234-L1300", opened);
}

test "StringMap searchIterator URL with click position" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(alloc, .{ .cols = 40, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com world");

    // Simulate clicking on "example" (x=14)
    const click_pin = s.pages.pin(.{ .active = .{
        .x = 14,
        .y = 0,
    } }).?;

    // Get the line
    const line = s.selectLine(.{
        .pin = click_pin,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Search for URL match and verify click position is within URL
    var it = map.searchIterator(re);
    var found_url = false;
    while (true) {
        var match = (try it.next()) orelse break;
        defer match.deinit();

        const sel = match.selection();
        if (sel.contains(&s, click_pin)) {
            found_url = true;
            // Verify URL bounds
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 6,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 24,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
            break;
        }
    }
    try testing.expect(found_url);
}
