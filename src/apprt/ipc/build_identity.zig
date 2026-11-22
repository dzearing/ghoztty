//! Which build this process is, as far as the binary itself knows (T52's
//! comptime half, shared since T3361): the version, commit, optimize mode and
//! frontend baked in by build.zig/GitVersion. Every Zig frontend's `+version`
//! and `+list --json` build block read these, so two frontends cannot spell
//! the same build two ways. The runtime half (which exe, when it started,
//! whether a newer one is installed) is each frontend's own - win32's is
//! `win32/provenance.zig`.
const build_config = @import("../../build_config.zig");

pub const version: []const u8 = build_config.version_string;
pub const commit: []const u8 = build_config.version.build orelse "unknown";
pub const mode: []const u8 = mode: {
    // mode_string is ".Debug"/".ReleaseFast"; drop the leading dot.
    const m = build_config.mode_string;
    break :mode if (m.len > 0 and m[0] == '.') m[1..] else m;
};
pub const runtime: []const u8 = @tagName(build_config.app_runtime);
