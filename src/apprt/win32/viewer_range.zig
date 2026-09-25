//! HTTP byte ranges for the viewer's page host (T1580).
//!
//! A `<video>` or `<audio>` element in a rendered `.html` pane seeks by asking
//! for a byte range (`Range: bytes=1048576-`) and expecting a `206 Partial
//! Content` back. A host that answers every request with the whole file and a
//! `200` gives the engine nothing to seek with: a long clip buffers from the
//! start and the scrubber does nothing. This module is the COM-free half of
//! the fix — which bytes to send and which headers describe them — so the
//! rules can be unit tested in the `none` lane; `ViewerPane.servePageResource`
//! reads the header, asks `plan`, and reads only that slice off disk.
//!
//! Deliberately narrow, per RFC 9110 §14:
//!   * one range only. A multi-range request (`bytes=0-1,5-9`) is answered
//!     with the whole file, which the RFC allows and no media engine sends;
//!   * a Range the parser does not understand — another unit, bad syntax, a
//!     last byte before the first — is IGNORED (whole file, `200`), never a
//!     `416`: the RFC reserves that for a well-formed range that misses;
//!   * an open-ended or oversized range is capped at `max_chunk` bytes. A
//!     short `206` is legal, and the engine simply asks again from where it
//!     stopped, which is what lets a clip far larger than the viewer's
//!     whole-file ceiling play and seek without ever being read in full.

const std = @import("std");

/// The most one `206` carries. Large enough that a clip streams in a handful
/// of requests; small enough that one request never allocates a whole film.
pub const max_chunk: u64 = 8 * 1024 * 1024;

/// What to answer.
pub const Plan = union(enum) {
    /// No usable Range: `200` with the whole file, as before T1580.
    whole,
    /// `206` with bytes `start..end` inclusive.
    partial: Span,
    /// A well-formed range the file cannot satisfy: `416`.
    unsatisfiable,
};

pub const Span = struct {
    start: u64,
    /// Inclusive, as the header writes it.
    end: u64,

    pub fn len(self: Span) u64 {
        return self.end - self.start + 1;
    }
};

/// Decide how to answer a request carrying `header` (the `Range` value, or
/// null when there was none) for a file of `size` bytes.
pub fn plan(header: ?[]const u8, size: u64, chunk: u64) Plan {
    const raw = header orelse return .whole;
    const value = std.mem.trim(u8, raw, " \t");
    const eq = std.mem.indexOfScalar(u8, value, '=') orelse return .whole;
    const unit = std.mem.trim(u8, value[0..eq], " \t");
    if (!std.ascii.eqlIgnoreCase(unit, "bytes")) return .whole;
    const spec = std.mem.trim(u8, value[eq + 1 ..], " \t");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .whole;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .whole;
    const first_text = std.mem.trim(u8, spec[0..dash], " \t");
    const last_text = std.mem.trim(u8, spec[dash + 1 ..], " \t");

    var span: Span = undefined;
    if (first_text.len == 0) {
        // `bytes=-N`: the final N bytes.
        const suffix = parseNumber(last_text) orelse return .whole;
        if (suffix == 0 or size == 0) return .unsatisfiable;
        span = .{ .start = size - @min(suffix, size), .end = size - 1 };
    } else {
        const first = parseNumber(first_text) orelse return .whole;
        var last: u64 = undefined;
        if (last_text.len == 0) {
            last = std.math.maxInt(u64);
        } else {
            last = parseNumber(last_text) orelse return .whole;
            if (last < first) return .whole;
        }
        if (first >= size) return .unsatisfiable;
        span = .{ .start = first, .end = @min(last, size - 1) };
    }

    const cap = @max(chunk, 1);
    if (span.len() > cap) span.end = span.start + cap - 1;
    return .{ .partial = span };
}

/// Digits only: no sign, no whitespace inside, no overflow.
fn parseNumber(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// The extra response headers for `p`, CRLF-joined and each led by CRLF so the
/// result appends straight onto a `Content-Type:` line. Every answer names
/// `Accept-Ranges: bytes` — that is what tells the engine seeking is worth
/// trying at all. Caller owns the result.
pub fn headers(alloc: std.mem.Allocator, p: Plan, size: u64) std.mem.Allocator.Error![]u8 {
    return switch (p) {
        .whole => alloc.dupe(u8, "\r\nAccept-Ranges: bytes"),
        .partial => |s| std.fmt.allocPrint(
            alloc,
            "\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {d}-{d}/{d}\r\nContent-Length: {d}",
            .{ s.start, s.end, size, s.len() },
        ),
        .unsatisfiable => std.fmt.allocPrint(
            alloc,
            "\r\nAccept-Ranges: bytes\r\nContent-Range: bytes */{d}",
            .{size},
        ),
    };
}

// -------------------------------------------------------------------------

const testing = std.testing;

fn expectSpan(p: Plan, start: u64, end: u64) !void {
    switch (p) {
        .partial => |s| {
            try testing.expectEqual(start, s.start);
            try testing.expectEqual(end, s.end);
        },
        else => return error.TestExpectedPartial,
    }
}

test "no Range is the whole file, as before" {
    try testing.expectEqual(Plan.whole, plan(null, 100, max_chunk));
}

test "the three single-range shapes a media engine sends" {
    // Closed.
    try expectSpan(plan("bytes=10-19", 100, max_chunk), 10, 19);
    // Open-ended: the first request every <video> makes, and every seek.
    try expectSpan(plan("bytes=0-", 100, max_chunk), 0, 99);
    try expectSpan(plan("bytes=40-", 100, max_chunk), 40, 99);
    // Suffix: the last N bytes (an MP4 whose index sits at the end).
    try expectSpan(plan("bytes=-10", 100, max_chunk), 90, 99);
}

test "a last byte past the end is clipped to the file" {
    try expectSpan(plan("bytes=90-500", 100, max_chunk), 90, 99);
    try expectSpan(plan("bytes=-500", 100, max_chunk), 0, 99);
}

test "a long range is capped, so a huge clip is never read whole" {
    const size: u64 = 3 * max_chunk + 5;
    try expectSpan(plan("bytes=0-", size, max_chunk), 0, max_chunk - 1);
    try expectSpan(plan("bytes=100-", size, max_chunk), 100, 100 + max_chunk - 1);
    // The cap is what the caller passes, so it is testable small.
    try expectSpan(plan("bytes=5-", 100, 10), 5, 14);
    // A span already under the cap is untouched.
    try expectSpan(plan("bytes=5-9", 100, 10), 5, 9);
}

test "a well-formed range that misses the file is a 416" {
    try testing.expectEqual(Plan.unsatisfiable, plan("bytes=100-", 100, max_chunk));
    try testing.expectEqual(Plan.unsatisfiable, plan("bytes=200-300", 100, max_chunk));
    try testing.expectEqual(Plan.unsatisfiable, plan("bytes=-0", 100, max_chunk));
    // An empty file has no bytes for any range to name.
    try testing.expectEqual(Plan.unsatisfiable, plan("bytes=0-", 0, max_chunk));
    try testing.expectEqual(Plan.unsatisfiable, plan("bytes=-5", 0, max_chunk));
}

test "a Range we do not understand is ignored, never a 416" {
    for ([_][]const u8{
        "",
        "bytes",
        "bytes=",
        "bytes=-",
        "items=0-5",
        "bytes=5-2",
        "bytes=a-5",
        "bytes=+1-5",
        "bytes=1 0-20",
        "bytes=0-5,10-20",
        "bytes=99999999999999999999999-",
    }) |h| {
        testing.expectEqual(Plan.whole, plan(h, 100, max_chunk)) catch |e| {
            std.debug.print("header: \"{s}\"\n", .{h});
            return e;
        };
    }
}

test "the unit is case-insensitive and whitespace around parts is tolerated" {
    try expectSpan(plan("Bytes=1-2", 100, max_chunk), 1, 2);
    try expectSpan(plan(" bytes = 1 - 2 ", 100, max_chunk), 1, 2);
}

test "headers: every answer offers ranges, and a 206 says which bytes" {
    const alloc = testing.allocator;

    const whole = try headers(alloc, .whole, 100);
    defer alloc.free(whole);
    try testing.expectEqualStrings("\r\nAccept-Ranges: bytes", whole);

    const part = try headers(alloc, .{ .partial = .{ .start = 10, .end = 19 } }, 100);
    defer alloc.free(part);
    try testing.expectEqualStrings(
        "\r\nAccept-Ranges: bytes\r\nContent-Range: bytes 10-19/100\r\nContent-Length: 10",
        part,
    );

    const miss = try headers(alloc, .unsatisfiable, 100);
    defer alloc.free(miss);
    try testing.expectEqualStrings("\r\nAccept-Ranges: bytes\r\nContent-Range: bytes */100", miss);
}
