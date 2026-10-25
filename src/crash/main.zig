//! The crash package contains all the logic around crash handling,
//! whether that's setting up the system to catch crashes (Sentry client),
//! introspecting crash reports, writing crash reports to disk, etc.

const std = @import("std");
const builtin = @import("builtin");
const dir = @import("dir.zig");
const sentry_envelope = @import("sentry_envelope.zig");

pub const sentry = @import("sentry.zig");
/// Windows crash capture (T1355). Sentry's native SDK does not build for
/// Windows, so that target writes its own minidump and text report into the
/// same crash dir instead.
pub const windows = if (builtin.os.tag == .windows) @import("windows.zig") else struct {};
pub const windows_report = @import("windows_report.zig");
pub const Envelope = sentry_envelope.Envelope;
pub const defaultDir = dir.defaultDir;
pub const Dir = dir.Dir;
pub const ReportIterator = dir.ReportIterator;
pub const Report = dir.Report;

// The main init/deinit functions for global state.
pub fn init(gpa: std.mem.Allocator) !void {
    if (comptime builtin.os.tag == .windows) return windows.init(gpa);
    return sentry.init(gpa);
}

pub fn deinit() void {
    if (comptime builtin.os.tag == .windows) return windows.deinit();
    sentry.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
