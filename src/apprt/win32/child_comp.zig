//! A composition tree for a GDI child window (T2765, composition step 5d-5a).
//!
//! The pane sidebar is a `WS_CHILD` that paints with GDI, and its motions -
//! the busy sheen, the list transitions, the row reorder, the column glide -
//! step on the frame clock, so a busy UI thread stutters every one of them.
//! Every compositor animation so far hangs on a tree somebody else owns: a
//! pane's (`comp_overlay.Slot`, published by the pane's presenter) or the
//! window's chrome host (`chrome_comp`, opt-in). The sidebar has neither, so
//! this gives a child window one of its own:
//!
//!   - a D3D11 device (hardware, then WARP - a Remote Desktop session or a
//!     machine with no GPU still composes), multithread-protected like the
//!     pane presenter's, because `comp_overlay.Layer` uploads through its
//!     immediate context;
//!   - a DirectComposition device over it, a TOPMOST target on the child's
//!     window - so a visual hung here composes OVER the child's own GDI
//!     pixels - and an empty root visual (nothing on screen changes until a
//!     motion attaches a layer);
//!   - published into a `comp_overlay.Slot` the OWNER keeps, so the motions
//!     use `comp_overlay.Layer` exactly as the hover tint and the scrollbar
//!     do, generation and all. The slot outlives any one tree: a rebuild
//!     after device loss publishes into the same slot, and every layer
//!     notices the new generation on its next `sync` and re-uploads.
//!
//! Built lazily (`Host.ensure`): a sidebar that never animates pays for no
//! device. A failed build backs off (`Policy`) rather than being retried on
//! every frame, and gives up for the window's life after a few - the motion
//! then steps on the frame clock as it always did, which is the same picture.
//!
//! Debug seams (Debug/ReleaseSafe only), for test\win32\sidebar-comp.ps1:
//!   - `GHOZTTY_DEBUG_SIDEBAR_COMP_FILL=1`: the sidebar builds its tree when
//!     it is placed and hangs one cover layer on it, so the tree is exercised
//!     end to end (device, target, root, a layer's surface and upload).
//!   - `GHOZTTY_DEBUG_SIDEBAR_COMP_LOSS=1`: the first device check after a
//!     build reports the device lost, so the rebuild and the layer's re-sync
//!     onto the new generation can be watched happening.
//!
//! Vtable slots are from the 10.0.26100 SDK headers (d3d11.h, dxgi.h,
//! dcomp.h, d3d10misc.h), the same numbers `chrome_comp.zig` and
//! `gl_comp_present.zig` use.
const std = @import("std");
const builtin = @import("builtin");
const comp_overlay = @import("../../renderer/comp_overlay.zig");

const log = std.log.scoped(.child_comp);

const GUID = std.os.windows.GUID;
const HRESULT = std.os.windows.HRESULT;
const HWND = std.os.windows.HWND;
const Obj = comp_overlay.Obj;
const slot = comp_overlay.slot;

pub const Error = error{ Unavailable, ComFailed };

// --- the build policy (pure) -------------------------------------------------

/// When a tree may be (re)built. A build that fails is not retried on the
/// next frame: it waits out a growing back-off, and after `max_failures` in a
/// row the window keeps its frame-clock motion for good. A good build resets
/// the count, so one transient failure (a driver mid-update) costs a little
/// while, not the window's life.
pub const Policy = struct {
    failures: u32 = 0,
    /// The earliest `now_ms` at which another build may be tried.
    not_before_ms: u64 = 0,

    /// Back-off after the 1st, 2nd, 3rd failure in a row.
    pub const backoff_ms = [_]u64{ 1_000, 5_000, 30_000 };
    pub const max_failures: u32 = backoff_ms.len + 1;

    pub fn mayTry(self: *const Policy, now_ms: u64) bool {
        if (self.failures >= max_failures) return false;
        return now_ms >= self.not_before_ms;
    }

    pub fn gaveUp(self: *const Policy) bool {
        return self.failures >= max_failures;
    }

    pub fn failed(self: *Policy, now_ms: u64) void {
        self.failures +|= 1;
        const i = @min(self.failures - 1, backoff_ms.len - 1);
        self.not_before_ms = now_ms +| backoff_ms[i];
    }

    pub fn built(self: *Policy) void {
        self.* = .{};
    }
};

test "Policy: a fresh host may build at once" {
    const p: Policy = .{};
    try std.testing.expect(p.mayTry(0));
    try std.testing.expect(!p.gaveUp());
}

test "Policy: a failure backs off, growing, then gives up for good" {
    var p: Policy = .{};
    p.failed(100);
    try std.testing.expect(!p.mayTry(100));
    try std.testing.expect(!p.mayTry(1_099));
    try std.testing.expect(p.mayTry(1_100));
    p.failed(2_000);
    try std.testing.expect(!p.mayTry(6_999));
    try std.testing.expect(p.mayTry(7_000));
    p.failed(10_000);
    try std.testing.expect(!p.mayTry(39_999));
    try std.testing.expect(p.mayTry(40_000));
    p.failed(50_000);
    try std.testing.expect(p.gaveUp());
    // Given up: no amount of waiting brings it back.
    try std.testing.expect(!p.mayTry(std.math.maxInt(u64)));
}

test "Policy: a good build forgives earlier failures" {
    var p: Policy = .{};
    p.failed(0);
    p.failed(1_000);
    p.built();
    try std.testing.expect(p.mayTry(1_000));
    p.failed(2_000);
    // Back to the first rung, not the third.
    try std.testing.expect(p.mayTry(3_000));
}

// --- COM ----------------------------------------------------------------------

extern "kernel32" fn LoadLibraryW([*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3D11CreateDeviceFn = *const fn (?Obj, u32, ?*anyopaque, u32, ?*const u32, u32, u32, *?Obj, ?*u32, *?Obj) callconv(.winapi) HRESULT;
const DCompCreateDeviceFn = *const fn (?Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT;

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_CREATE_DEVICE_BGRA_SUPPORT: u32 = 0x20;
const D3D11_SDK_VERSION: u32 = 7;

fn guid(comptime s: []const u8) GUID {
    return GUID.parse("{" ++ s ++ "}");
}
const IID_IDXGIDevice = guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
const IID_IDCompositionDevice = guid("c37ea93a-e7aa-450d-b16f-9746cb0407f3");

const slot_unknown_query = 0;
const slot_unknown_release = 2;
const slot_d3d11_device_get_removed_reason = 39;
const slot_dcomp_device_commit = 3;
const slot_dcomp_device_create_target = 6;
const slot_dcomp_device_create_visual = 7;
const slot_dcomp_device_check_state = 26;
const slot_dcomp_target_set_root = 3;

fn release(obj: Obj) void {
    _ = slot(*const fn (Obj) callconv(.winapi) u32, obj, slot_unknown_release)(obj);
}

fn query(obj: Obj, iid: *const GUID) Error!Obj {
    var out: ?Obj = null;
    try check(slot(*const fn (Obj, *const GUID, *?Obj) callconv(.winapi) HRESULT, obj, slot_unknown_query)(obj, iid, &out));
    return out orelse error.ComFailed;
}

/// The step `Tree.init` was on and the HRESULT it failed with, for the log.
var stage: []const u8 = "";
var last_hr: HRESULT = 0;

fn check(hr: HRESULT) Error!void {
    if (hr < 0) {
        last_hr = hr;
        return error.ComFailed;
    }
}

fn hex(hr: HRESULT) u32 {
    return @bitCast(hr);
}

/// Why `Tree.lostReason` said the device is gone.
pub const Loss = enum {
    d3d_removed,
    dcomp_invalid,
    simulated,

    pub fn label(self: Loss) []const u8 {
        return switch (self) {
            .d3d_removed => "d3d11 device removed",
            .dcomp_invalid => "dcomp device invalid",
            .simulated => "simulated (debug seam)",
        };
    }
};

/// One built tree: the devices, the target on the child window and its empty
/// root visual. Window thread only.
pub const Tree = struct {
    device: Obj,
    context: Obj,
    dcomp: Obj,
    target: Obj,
    root: Obj,
    warp: bool,

    pub fn init(hwnd: HWND) Error!Tree {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;
        last_hr = 0;

        stage = "load-libraries";
        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse return error.Unavailable;
        const dcomp_lib = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dcomp.dll")) orelse return error.Unavailable;
        const d3d11_create: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse return error.Unavailable);
        const dcomp_create: DCompCreateDeviceFn = @ptrCast(GetProcAddress(dcomp_lib, "DCompositionCreateDevice") orelse return error.Unavailable);

        stage = "d3d11-device";
        var device: ?Obj = null;
        var context: ?Obj = null;
        var warp = false;
        if (d3d11_create(null, D3D_DRIVER_TYPE_HARDWARE, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context) < 0) {
            warp = true;
            try check(d3d11_create(null, D3D_DRIVER_TYPE_WARP, null, D3D11_CREATE_DEVICE_BGRA_SUPPORT, null, 0, D3D11_SDK_VERSION, &device, null, &context));
        }
        const dev = device orelse return error.ComFailed;
        errdefer release(dev);
        const ctx = context orelse return error.ComFailed;
        errdefer release(ctx);

        // A layer uploads through the immediate context (`Layer.setPixels`);
        // protect it the way the pane presenter does before it publishes.
        stage = "multithread";
        const mt = try query(dev, &comp_overlay.IID_ID3D10Multithread);
        _ = slot(*const fn (Obj, i32) callconv(.winapi) i32, mt, comp_overlay.slot_multithread_set_protected)(mt, 1);
        release(mt);

        stage = "dxgi-device";
        const dxgi_device = try query(dev, &IID_IDXGIDevice);
        defer release(dxgi_device);

        stage = "dcomp-device";
        var dcomp: ?Obj = null;
        try check(dcomp_create(dxgi_device, &IID_IDCompositionDevice, &dcomp));
        const dc = dcomp orelse return error.ComFailed;
        errdefer release(dc);

        stage = "dcomp-target";
        var target: ?Obj = null;
        // topmost=TRUE: the tree composes over the window's own GDI pixels.
        try check(slot(*const fn (Obj, HWND, i32, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_target)(dc, hwnd, 1, &target));
        const tg = target orelse return error.ComFailed;
        errdefer release(tg);

        stage = "root-visual";
        var visual: ?Obj = null;
        try check(slot(*const fn (Obj, *?Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_create_visual)(dc, &visual));
        const root = visual orelse return error.ComFailed;
        errdefer release(root);
        try check(slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, tg, slot_dcomp_target_set_root)(tg, root));
        try check(slot(*const fn (Obj) callconv(.winapi) HRESULT, dc, slot_dcomp_device_commit)(dc));

        stage = "";
        return .{ .device = dev, .context = ctx, .dcomp = dc, .target = tg, .root = root, .warp = warp };
    }

    pub fn adapter(self: *const Tree) []const u8 {
        return if (self.warp) "warp" else "hardware";
    }

    /// What a layer borrows (`comp_overlay.Slot.publish` takes its own refs).
    pub fn shared(self: *const Tree) comp_overlay.Shared {
        return .{ .dcomp = self.dcomp, .context = self.context, .root = self.root };
    }

    /// Whether the device under this tree is gone. Two vtable calls.
    pub fn lostReason(self: *const Tree) ?Loss {
        const removed = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.device, slot_d3d11_device_get_removed_reason)(self.device);
        if (removed < 0) return .d3d_removed;
        var valid: i32 = 1;
        const hr = slot(*const fn (Obj, *i32) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_check_state)(self.dcomp, &valid);
        if (hr < 0 or valid == 0) return .dcomp_invalid;
        return null;
    }

    pub fn deinit(self: *Tree) void {
        // Off the window in the same commit the root goes, so the child's own
        // pixels are what shows next.
        _ = slot(*const fn (Obj, ?Obj) callconv(.winapi) HRESULT, self.target, slot_dcomp_target_set_root)(self.target, null);
        release(self.root);
        release(self.target);
        // DComp destroys a released object at the device's next commit
        // (T2606/T2772): commit after the releases, then let the device go.
        _ = slot(*const fn (Obj) callconv(.winapi) HRESULT, self.dcomp, slot_dcomp_device_commit)(self.dcomp);
        release(self.dcomp);
        release(self.context);
        release(self.device);
        self.* = undefined;
    }
};

// --- the host a child window keeps -------------------------------------------

/// A child window's composition tree, built when first asked for. The owner
/// keeps one `Host` for the window's life and `deinit`s it before the window
/// is destroyed; layers hang on `slot`.
pub const Host = struct {
    hwnd: HWND,
    /// What the log calls this host ("sidebar").
    name: []const u8,
    /// Layers sync on this; it outlives any one tree.
    slot: comp_overlay.Slot = .{},
    tree: ?Tree = null,
    policy: Policy = .{},
    /// Trees built so far (a rebuild after loss counts).
    builds: u32 = 0,
    /// The loss seam fires once.
    force_loss: bool = false,

    pub fn init(hwnd: HWND, name: []const u8) Host {
        return .{ .hwnd = hwnd, .name = name, .force_loss = debugKnob("GHOZTTY_DEBUG_SIDEBAR_COMP_LOSS") };
    }

    pub fn live(self: *const Host) bool {
        return self.tree != null;
    }

    /// The slot with a live tree behind it, building one if there is none
    /// and the policy allows; null means "step it on the frame clock".
    /// `why` names the motion that asked, for the log.
    pub fn ensure(self: *Host, now_ms: u64, why: []const u8) ?*comp_overlay.Slot {
        if (comptime builtin.os.tag != .windows) return null;
        if (self.tree != null) return &self.slot;
        if (!self.policy.mayTry(now_ms)) return null;
        const t = Tree.init(self.hwnd) catch |err| {
            self.policy.failed(now_ms);
            log.warn("{s} composition tree failed for={s} at {s}: {s} hr=0x{x:0>8} failures={d} gave_up={}", .{ self.name, why, stage, @errorName(err), hex(last_hr), self.policy.failures, self.policy.gaveUp() });
            return null;
        };
        self.tree = t;
        self.policy.built();
        self.builds += 1;
        self.slot.publish(t.shared(), comp_overlay.RefOps.com);
        log.info("{s} composition tree up for={s} adapter={s} build={d} generation={d}", .{ self.name, why, t.adapter(), self.builds, self.slot.generation });
        return &self.slot;
    }

    /// Notice a lost device (call it where the owner paints: it is cheap) and
    /// drop the tree, so the next `ensure` builds a fresh one and every layer
    /// re-syncs onto it. True when the tree was dropped.
    pub fn checkLost(self: *Host) bool {
        const t = &(self.tree orelse return false);
        const why: Loss = if (self.force_loss) .simulated else (t.lostReason() orelse return false);
        self.force_loss = false;
        log.warn("{s} composition tree lost: {s}; dropped, the next motion rebuilds it", .{ self.name, why.label() });
        self.dropTree();
        return true;
    }

    fn dropTree(self: *Host) void {
        var t = self.tree orelse return;
        // Layers hold their own refs; the retract bumps the generation so each
        // one lets go of the old tree on its next `sync`.
        _ = self.slot.retract(comp_overlay.RefOps.com);
        t.deinit();
        self.tree = null;
    }

    pub fn deinit(self: *Host) void {
        self.dropTree();
    }
};

fn debugKnob(comptime name: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return false;
    if (comptime !(builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) return false;
    return std.process.hasNonEmptyEnvVarConstant(name);
}

/// The fill seam (`GHOZTTY_DEBUG_SIDEBAR_COMP_FILL`), read by the owner.
pub fn fillSeam() bool {
    return debugKnob("GHOZTTY_DEBUG_SIDEBAR_COMP_FILL");
}
