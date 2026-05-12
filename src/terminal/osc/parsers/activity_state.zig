const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 7777: activity state reporting
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const value = data[0 .. data.len - 1 :0];

    const state: Command.ActivityState = if (std.mem.eql(u8, value, "idle"))
        .idle
    else if (std.mem.eql(u8, value, "busy"))
        .busy
    else if (std.mem.eql(u8, value, "needs_input"))
        .needs_input
    else {
        parser.state = .invalid;
        return null;
    };

    parser.command = .{ .activity_state = state };
    return &parser.command;
}

test "OSC 7777: activity state idle" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7777;idle";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .activity_state);
    try testing.expect(cmd.activity_state == .idle);
}

test "OSC 7777: activity state busy" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7777;busy";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .activity_state);
    try testing.expect(cmd.activity_state == .busy);
}

test "OSC 7777: activity state needs_input" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7777;needs_input";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .activity_state);
    try testing.expect(cmd.activity_state == .needs_input);
}

test "OSC 7777: invalid state" {
    const testing = std.testing;
    var p: Parser = .init(null);
    const input = "7777;unknown";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}
