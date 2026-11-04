//! The Windows "Select Folder" dialog (T2681) - the counterpart of Mac's
//! `NSOpenPanel` with `canChooseDirectories` in Settings' "Start new windows
//! in" row (`FolderControl.choose`).
//!
//! The modern Common Item Dialog (`IFileOpenDialog` with `FOS_PICKFOLDERS`),
//! not `SHBrowseForFolder`'s tree: it is the picker every current Windows app
//! shows for a folder, with the address bar, Quick access and search. Only
//! the vtable slots it calls are typed; the rest are placeholders so the
//! offsets stay right.
const std = @import("std");
const w32 = @import("win32.zig");
const com = @import("com.zig");

const GUID = com.GUID;
const HRESULT = com.HRESULT;

const CLSID_FileOpenDialog: GUID = .{ .Data1 = 0xDC1C5A9C, .Data2 = 0xE88A, .Data3 = 0x4DDE, .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
const IID_IFileOpenDialog: GUID = .{ .Data1 = 0xD57C7288, .Data2 = 0xD4AD, .Data3 = 0x4768, .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };
const IID_IShellItem: GUID = .{ .Data1 = 0x43826D1E, .Data2 = 0xE718, .Data3 = 0x42EE, .Data4 = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };

const FOS_PICKFOLDERS: u32 = 0x20;
const FOS_FORCEFILESYSTEM: u32 = 0x40;
const FOS_PATHMUSTEXIST: u32 = 0x800;
const SIGDN_FILESYSPATH: u32 = 0x80058000;

const Slot = *const anyopaque;

const IShellItem = extern struct {
    vtable: *const extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IShellItem) callconv(.winapi) u32,
        BindToHandler: Slot,
        GetParent: Slot,
        GetDisplayName: *const fn (*IShellItem, u32, *?[*:0]u16) callconv(.winapi) HRESULT,
    },
};

const IFileOpenDialog = extern struct {
    vtable: *const extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IFileOpenDialog) callconv(.winapi) u32,
        Show: *const fn (*IFileOpenDialog, ?w32.HWND) callconv(.winapi) HRESULT,
        SetFileTypes: Slot,
        SetFileTypeIndex: Slot,
        GetFileTypeIndex: Slot,
        Advise: Slot,
        Unadvise: Slot,
        SetOptions: *const fn (*IFileOpenDialog, u32) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*IFileOpenDialog, *u32) callconv(.winapi) HRESULT,
        SetDefaultFolder: Slot,
        SetFolder: *const fn (*IFileOpenDialog, *IShellItem) callconv(.winapi) HRESULT,
        GetFolder: Slot,
        GetCurrentSelection: Slot,
        SetFileName: Slot,
        GetFileName: Slot,
        SetTitle: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.winapi) HRESULT,
        SetOkButtonLabel: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.winapi) HRESULT,
        SetFileNameLabel: Slot,
        GetResult: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(.winapi) HRESULT,
    },
};

extern "shell32" fn SHCreateItemFromParsingName(pszPath: [*:0]const u16, pbc: ?*anyopaque, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;

/// Ask for a folder, starting in `start` when it names one. Returns the
/// chosen path (caller frees), or null on cancel or failure. Modal on
/// `owner`; COM is initialized on the UI thread by the app already, and an
/// extra apartment-threaded init is harmless (`S_FALSE`).
pub fn pick(alloc: std.mem.Allocator, owner: ?w32.HWND, start: ?[]const u8) ?[]u8 {
    _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    var raw: ?*anyopaque = null;
    if (com.failed(w32.CoCreateInstance(&CLSID_FileOpenDialog, null, w32.CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &raw)) or raw == null) return null;
    const dlg: *IFileOpenDialog = @ptrCast(@alignCast(raw.?));
    defer _ = dlg.vtable.Release(dlg);

    var opts: u32 = 0;
    _ = dlg.vtable.GetOptions(dlg, &opts);
    _ = dlg.vtable.SetOptions(dlg, opts | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
    _ = dlg.vtable.SetTitle(dlg, std.unicode.utf8ToUtf16LeStringLiteral("Start new windows in"));
    // Mac's panel prompt.
    _ = dlg.vtable.SetOkButtonLabel(dlg, std.unicode.utf8ToUtf16LeStringLiteral("Choose"));
    if (start) |s| if (s.len > 0) {
        if (std.unicode.wtf8ToWtf16LeAllocZ(alloc, s)) |ws| {
            defer alloc.free(ws);
            var item_raw: ?*anyopaque = null;
            if (!com.failed(SHCreateItemFromParsingName(ws.ptr, null, &IID_IShellItem, &item_raw)) and item_raw != null) {
                const item: *IShellItem = @ptrCast(@alignCast(item_raw.?));
                _ = dlg.vtable.SetFolder(dlg, item);
                _ = item.vtable.Release(item);
            }
        } else |_| {}
    };

    // Cancel is HRESULT_FROM_WIN32(ERROR_CANCELLED); any failure is "no
    // folder".
    if (com.failed(dlg.vtable.Show(dlg, owner))) return null;
    var result: ?*IShellItem = null;
    if (com.failed(dlg.vtable.GetResult(dlg, &result)) or result == null) return null;
    const item = result.?;
    defer _ = item.vtable.Release(item);
    var wpath: ?[*:0]u16 = null;
    if (com.failed(item.vtable.GetDisplayName(item, SIGDN_FILESYSPATH, &wpath)) or wpath == null) return null;
    defer w32.CoTaskMemFree(wpath);
    return std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.sliceTo(wpath.?, 0)) catch null;
}
