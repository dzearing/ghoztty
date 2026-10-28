//! Planted one-frame defects for the T2373 frame lab's positive controls
//! (T2383).
//!
//! The lab photographs every frame DWM composes during a scripted resize and
//! scores it for bleeding (`test\win32\lib\FrameScore.ps1`). A scorer that has
//! only ever said "clean" is indistinguishable from one that cannot say
//! anything else, so before its verdict on a real drag means anything it has
//! to catch a defect that is KNOWN to be on screen. These are those defects,
//! one per bleed class the controls exercise:
//!
//!   erase      the pane presents ONE frame of solid magenta instead of its
//!              content (B1 background flash). Magenta is in the scorer's
//!              Flash list and in no theme or test card.
//!   stale      the pane presents ONE frame at its previous size while its
//!              window already has the new one (B2 stale size) - exactly what
//!              a late renderer looks like during a drag.
//!   overlay    the unfocused pane's dim wash (a layered popup) stays where it
//!              was through one whole display refresh while its pane moves on
//!              (B5 overlay lag).
//!
//! Armed by `GHOZTTY_LAB_PLANT`, a comma list of `<kind>@<n>`, where `n` is
//! the 1-based EVENT the defect fires on: for `erase`/`stale` the n-th
//! renderer frame that found its pane at a new size, per pane; for `overlay`
//! the n-th time a dim wash moved, per wash. Each fires once. For example
//! `GHOZTTY_LAB_PLANT=erase@12` puts one magenta frame into every pane's
//! twelfth resize frame - mid-drag for any drag longer than that.
//!
//! Every fire prints one line, so the lab can find the frame it planted
//! instead of trusting that it happened:
//!
//!     lab plant fired kind=erase n=12 qpc=123456789
//!
//! `qpc` is QueryPerformanceCounter - the clock the capture timestamps are on
//! (`SystemRelativeTime`), so the planted frame is the first composed frame
//! at or after it.
//!
//! In every build, not just Debug, on purpose: the controls are only evidence
//! about the build they ran on, and the lab measures smoothness on release
//! builds. Cost with the variable absent: one load of an all-zero plan per
//! resize frame and per wash move. Same shape as `GHOZTTY_PRESENT_LAG_MS`.
//!
//! The parsing and the "does this event fire" rule are pure and unit tested
//! in every app-runtime lane; the three hooks are in `renderer/generic.zig`
//! (`erase`, `stale`), `renderer/OpenGL.zig` (the magenta present) and
//! `DimOverlay.zig` (`overlay`).

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.lab_plant);

pub const env_name = "GHOZTTY_LAB_PLANT";

/// The erase colour, as the renderer clears with it. The scorer's Flash
/// colour is 0xFF00FF, which this is exactly at any blending mode: 1.0 and
/// 0.0 survive every transfer function.
pub const magenta = [3]f32{ 1.0, 0.0, 1.0 };

/// How many frame-clock ticks a held wash waits before it catches up. The
/// first tick can land just after the hold began, inside the same refresh,
/// so releasing on it could leave the lag on screen for no composed frame at
/// all; releasing on the second means at least one whole refresh showed it.
pub const overlay_hold_ticks: u8 = 2;

pub const Kind = enum {
    erase,
    stale,
    overlay,

    pub fn name(self: Kind) []const u8 {
        return @tagName(self);
    }
};

/// What a renderer frame that found its pane at a new size should do.
pub const FrameFire = enum { none, erase, stale };

/// The armed defects: for each kind, the 1-based event it fires on, 0 = off.
pub const Plan = struct {
    erase: u32 = 0,
    stale: u32 = 0,
    overlay: u32 = 0,

    pub const ParseError = error{ BadEntry, UnknownKind, BadIndex, Duplicate };

    /// `erase@12,overlay@5`. Whitespace around entries is ignored; an empty
    /// spec is an empty plan. Anything malformed is an error rather than a
    /// silently disarmed control - a control that quietly did not fire would
    /// read as the scorer missing it.
    pub fn parse(spec: []const u8) ParseError!Plan {
        var out: Plan = .{};
        var it = std.mem.splitScalar(u8, spec, ',');
        while (it.next()) |raw| {
            const entry = std.mem.trim(u8, raw, " \t");
            if (entry.len == 0) continue;
            const sep = std.mem.indexOfScalar(u8, entry, '@') orelse return error.BadEntry;
            const kind = std.meta.stringToEnum(Kind, entry[0..sep]) orelse return error.UnknownKind;
            const n = std.fmt.parseInt(u32, entry[sep + 1 ..], 10) catch return error.BadIndex;
            if (n == 0) return error.BadIndex;
            const field = out.slot(kind);
            if (field.* != 0) return error.Duplicate;
            field.* = n;
        }
        return out;
    }

    fn slot(self: *Plan, kind: Kind) *u32 {
        return switch (kind) {
            .erase => &self.erase,
            .stale => &self.stale,
            .overlay => &self.overlay,
        };
    }

    pub fn at(self: Plan, kind: Kind) u32 {
        return switch (kind) {
            .erase => self.erase,
            .stale => self.stale,
            .overlay => self.overlay,
        };
    }

    pub fn armed(self: Plan) bool {
        return self.erase != 0 or self.stale != 0 or self.overlay != 0;
    }

    /// Does event `n` of `kind` fire?
    pub fn fires(self: Plan, kind: Kind, n: u32) bool {
        const want = self.at(kind);
        return want != 0 and n == want;
    }

    /// The `n`-th resize frame of a pane. A plan arming both on the same
    /// frame gets the erase: a frame cannot be both, and the magenta frame is
    /// the one that proves a present happened at all.
    pub fn frameFire(self: Plan, n: u32) FrameFire {
        if (self.fires(.erase, n)) return .erase;
        if (self.fires(.stale, n)) return .stale;
        return .none;
    }
};

/// The process's plan. Written once by `load` on the UI thread during app
/// startup, before any renderer thread exists (thread spawn orders it before
/// their reads), and never again.
var plan_global: Plan = .{};

pub fn plan() Plan {
    return plan_global;
}

/// Unit tests only: arm a plan without the environment.
pub fn setPlanForTest(p: Plan) void {
    if (comptime !builtin.is_test) @compileError("setPlanForTest is for tests");
    plan_global = p;
}

/// Read `GHOZTTY_LAB_PLANT` into the process plan. A malformed value is
/// logged at error level and arms nothing.
pub fn load() void {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const spec = std.process.getEnvVarOwned(fba.allocator(), env_name) catch return;
    plan_global = Plan.parse(spec) catch |err| {
        log.err("lab plant ignored: {s}={s} is malformed ({s})", .{ env_name, spec, @errorName(err) });
        return;
    };
    if (plan_global.armed()) log.warn("lab plant armed erase={} stale={} overlay={}", .{
        plan_global.erase,
        plan_global.stale,
        plan_global.overlay,
    });
}

/// Say that a planted defect fired, on the capture's clock.
pub fn noteFired(kind: Kind, n: u32) void {
    const qpc: u64 = if (comptime builtin.os.tag == .windows)
        std.os.windows.QueryPerformanceCounter()
    else
        0;
    log.warn("lab plant fired kind={s} n={} qpc={}", .{ kind.name(), n, qpc });
}

const testing = std.testing;

test "lab_plant: an empty spec arms nothing" {
    const p = try Plan.parse("");
    try testing.expect(!p.armed());
    try testing.expectEqual(FrameFire.none, p.frameFire(1));
    try testing.expect(!p.fires(.overlay, 1));
}

test "lab_plant: each kind parses, with whitespace, and fires on exactly its event" {
    const p = try Plan.parse(" erase@12 , stale@3,overlay@7 ");
    try testing.expectEqual(@as(u32, 12), p.erase);
    try testing.expectEqual(@as(u32, 3), p.stale);
    try testing.expectEqual(@as(u32, 7), p.overlay);
    try testing.expect(p.armed());

    try testing.expectEqual(FrameFire.none, p.frameFire(1));
    try testing.expectEqual(FrameFire.stale, p.frameFire(3));
    try testing.expectEqual(FrameFire.none, p.frameFire(4));
    try testing.expectEqual(FrameFire.erase, p.frameFire(12));
    try testing.expectEqual(FrameFire.none, p.frameFire(13));

    try testing.expect(!p.fires(.overlay, 6));
    try testing.expect(p.fires(.overlay, 7));
    try testing.expect(!p.fires(.overlay, 8));
}

test "lab_plant: erase wins a frame both kinds claim" {
    const p = try Plan.parse("stale@5,erase@5");
    try testing.expectEqual(FrameFire.erase, p.frameFire(5));
}

test "lab_plant: a malformed spec is an error, never a quietly disarmed control" {
    try testing.expectError(error.BadEntry, Plan.parse("erase"));
    try testing.expectError(error.UnknownKind, Plan.parse("smear@3"));
    try testing.expectError(error.BadIndex, Plan.parse("erase@"));
    try testing.expectError(error.BadIndex, Plan.parse("erase@x"));
    try testing.expectError(error.BadIndex, Plan.parse("erase@0"));
    try testing.expectError(error.BadIndex, Plan.parse("erase@-1"));
    try testing.expectError(error.Duplicate, Plan.parse("erase@3,erase@4"));
}

test "lab_plant: the erase colour is exactly the scorer's magenta" {
    const r: u32 = @intFromFloat(magenta[0] * 255.0);
    const g: u32 = @intFromFloat(magenta[1] * 255.0);
    const b: u32 = @intFromFloat(magenta[2] * 255.0);
    try testing.expectEqual(@as(u32, 0xFF00FF), (r << 16) | (g << 8) | b);
}

test "lab_plant: a hold outlasts the refresh it started in" {
    try testing.expect(overlay_hold_ticks >= 2);
}
