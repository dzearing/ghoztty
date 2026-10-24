//! `apprt.action.OpenUrl.Kind`, in a leaf file of its own (T1331): `os/open.zig`
//! needs this one type, and importing `apprt.zig` for it put the whole app in
//! every test binary that opens a URL.
const lib = @import("../lib/main.zig");

/// The type of the data at the URL to open. This is used as a hint to
/// potentially open the URL in a different way.
///
/// Sync with: ghostty_action_open_url_kind_e
pub const Kind = enum(c_int) {
    /// The type is unknown. This is the default and apprts should
    /// open the URL in the most generic way possible. For example,
    /// on macOS this would be the equivalent of `open` or on Linux
    /// this would be `xdg-open`.
    unknown,

    /// The URL is known to be a text file. In this case, the apprt
    /// should try to open the URL in a text editor or viewer or
    /// some equivalent, if possible.
    text,

    /// The URL is known to contain HTML content.
    html,

    test "ghostty.h OpenUrl.Kind" {
        try lib.checkGhosttyHEnum(Kind, "GHOSTTY_ACTION_OPEN_URL_KIND_");
    }
};
