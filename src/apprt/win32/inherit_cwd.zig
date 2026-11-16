//! Where a new tab or split in an agent-backed window takes its working
//! directory from (T3135, Mac e76f7d380).
//!
//! The parent pane's cwd has up to three answers, and they differ in what they
//! cost on the GUI thread:
//!
//!   * `live`: a process read of the parent's shell (`Surface.livePwd`, the
//!     PEB). It is local and costs well under a millisecond. It exists only for
//!     a shell running on THIS box that does not report OSC 7, since `livePwd`
//!     stands down for a shell that does.
//!   * `reported`: the shell's own OSC 7 report (the core's pwd). It is free,
//!     and live by construction for a shell that reports one.
//!   * the agent's GET_CWD: a round trip to the agent that owns the session,
//!     bounded at 1.5 s. It is the only answer for a pane on ANOTHER machine,
//!     because a local path means nothing there.
//!
//! Before this, every tab and split in a LOCAL session-persistence window took
//! the round trip even though the shell runs on this box and its directory was
//! already known here. On Mac the same round trip made Cmd-N lag the key. The
//! rule, stated once here, is that a local agent pane answers from what is
//! known and asks the agent only when neither local answer exists. A
//! cross-machine pane always asks.

const std = @import("std");

/// Which answer to use.
pub const Source = enum {
    /// The process read of the local shell.
    live,
    /// The shell's own OSC 7 report.
    reported,
    /// Ask the agent (GET_CWD).
    agent,
};

/// What is known about the parent pane at the moment of the split.
pub const Known = struct {
    /// The pane's shell runs under THIS box's session-persistence agent.
    local_agent: bool,
    /// The process read answered (non-empty).
    live: bool = false,
    /// The shell has reported its directory with OSC 7, and the core holds
    /// that report (non-empty).
    reported: bool = false,
};

pub fn choose(k: Known) Source {
    // Another machine: a local path is not a directory over there.
    if (!k.local_agent) return .agent;
    if (k.live) return .live;
    if (k.reported) return .reported;
    return .agent;
}

const testing = std.testing;

test "a cross-machine pane always asks its agent, whatever is known here" {
    try testing.expectEqual(Source.agent, choose(.{ .local_agent = false }));
    try testing.expectEqual(Source.agent, choose(.{ .local_agent = false, .live = true }));
    try testing.expectEqual(Source.agent, choose(.{ .local_agent = false, .reported = true }));
    try testing.expectEqual(Source.agent, choose(.{ .local_agent = false, .live = true, .reported = true }));
}

test "a local agent pane answers from the shell's own directory with no round trip" {
    try testing.expectEqual(Source.live, choose(.{ .local_agent = true, .live = true }));
    try testing.expectEqual(Source.reported, choose(.{ .local_agent = true, .reported = true }));
}

test "the process read wins over a report when both answer" {
    // `livePwd` stands down for a shell that reports OSC 7, so in practice both
    // never answer at once; if they do, the OS read is the one that cannot be
    // stale.
    try testing.expectEqual(Source.live, choose(.{ .local_agent = true, .live = true, .reported = true }));
}

test "a local agent pane with nothing known still asks the agent" {
    try testing.expectEqual(Source.agent, choose(.{ .local_agent = true }));
}
