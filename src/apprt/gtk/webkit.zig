//! A hand-written binding to the slice of WebKitGTK 6.0 (the GTK4 build,
//! `webkitgtk-6.0`) the viewer panes use (T3410, Linux L9a).
//!
//! The zig-gobject package the rest of the GTK apprt imports is generated
//! from GObject introspection data and ships no WebKit module, so these are
//! plain C externs against the library `addGtkNg` links. Every type is opaque:
//! a web view is handed to GTK as a `GtkWidget` by pointer cast, and nothing
//! here reaches into a struct layout, so the binding cannot drift from the
//! headers on a field it never names.
//!
//! Signatures are from the 6.0 headers (Ubuntu 24.04's 2.52 build at the time
//! of writing). Add a function when a viewer feature needs it, not before.

/// `WebKitWebView` - also a `GtkWidget`.
pub const WebView = opaque {};
pub const WebContext = opaque {};
pub const SecurityManager = opaque {};
pub const URISchemeRequest = opaque {};
pub const Settings = opaque {};
/// `JSCValue`, the result of an evaluated script.
pub const JSCValue = opaque {};

pub const GtkWidget = opaque {};
pub const GInputStream = opaque {};
pub const GAsyncResult = opaque {};
pub const GObject = opaque {};

pub const GError = extern struct {
    domain: u32,
    code: c_int,
    message: ?[*:0]const u8,
};

/// `WebKitLoadEvent`.
pub const LoadEvent = enum(c_int) {
    started = 0,
    redirected = 1,
    committed = 2,
    finished = 3,
    _,
};

pub const URISchemeRequestCallback = *const fn (*URISchemeRequest, ?*anyopaque) callconv(.c) void;
pub const GDestroyNotify = *const fn (?*anyopaque) callconv(.c) void;
pub const GAsyncReadyCallback = *const fn (?*GObject, *GAsyncResult, ?*anyopaque) callconv(.c) void;

// --- WebKitWebView -------------------------------------------------------

pub extern fn webkit_web_view_new() *GtkWidget;
pub extern fn webkit_web_view_get_context(view: *WebView) *WebContext;
pub extern fn webkit_web_view_load_uri(view: *WebView, uri: [*:0]const u8) void;
pub extern fn webkit_web_view_get_uri(view: *WebView) ?[*:0]const u8;
pub extern fn webkit_web_view_get_settings(view: *WebView) *Settings;
pub extern fn webkit_web_view_evaluate_javascript(
    view: *WebView,
    script: [*]const u8,
    length: isize,
    world_name: ?[*:0]const u8,
    source_uri: ?[*:0]const u8,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn webkit_web_view_evaluate_javascript_finish(
    view: *WebView,
    result: *GAsyncResult,
    err: *?*GError,
) ?*JSCValue;

// History, reload and zoom (the nav bar and pane keys, T3412).
pub extern fn webkit_web_view_go_back(view: *WebView) void;
pub extern fn webkit_web_view_go_forward(view: *WebView) void;
pub extern fn webkit_web_view_can_go_back(view: *WebView) c_int;
pub extern fn webkit_web_view_can_go_forward(view: *WebView) c_int;
pub extern fn webkit_web_view_reload(view: *WebView) void;
pub extern fn webkit_web_view_reload_bypass_cache(view: *WebView) void;
pub extern fn webkit_web_view_get_zoom_level(view: *WebView) f64;
pub extern fn webkit_web_view_set_zoom_level(view: *WebView, level: f64) void;

// --- WebKitWebContext / security -----------------------------------------

pub extern fn webkit_web_context_get_default() *WebContext;
pub extern fn webkit_web_context_register_uri_scheme(
    ctx: *WebContext,
    scheme: [*:0]const u8,
    callback: URISchemeRequestCallback,
    user_data: ?*anyopaque,
    destroy: ?GDestroyNotify,
) void;
pub extern fn webkit_web_context_get_security_manager(ctx: *WebContext) *SecurityManager;
pub extern fn webkit_security_manager_register_uri_scheme_as_local(sm: *SecurityManager, scheme: [*:0]const u8) void;
pub extern fn webkit_security_manager_register_uri_scheme_as_secure(sm: *SecurityManager, scheme: [*:0]const u8) void;

// --- WebKitURISchemeRequest ----------------------------------------------

pub extern fn webkit_uri_scheme_request_get_uri(req: *URISchemeRequest) [*:0]const u8;
pub extern fn webkit_uri_scheme_request_get_web_view(req: *URISchemeRequest) *WebView;
pub extern fn webkit_uri_scheme_request_finish(
    req: *URISchemeRequest,
    stream: *GInputStream,
    length: i64,
    content_type: ?[*:0]const u8,
) void;
pub extern fn webkit_uri_scheme_request_finish_error(req: *URISchemeRequest, err: *GError) void;

// --- JavaScriptCore ------------------------------------------------------

/// Caller frees with `g_free`.
pub extern fn jsc_value_to_string(value: *JSCValue) ?[*:0]u8;

// --- GLib / GIO / GObject / GTK, the few calls this file's users need ----

pub extern fn g_memory_input_stream_new_from_data(data: ?*const anyopaque, len: isize, destroy: ?GDestroyNotify) *GInputStream;
pub extern fn g_io_error_quark() u32;
pub extern fn g_error_new_literal(domain: u32, code: c_int, message: [*:0]const u8) *GError;
pub extern fn g_error_free(err: *GError) void;
pub extern fn g_free(mem: ?*anyopaque) void;
pub extern fn g_object_unref(obj: *anyopaque) void;
pub extern fn g_object_set_data(obj: *anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
pub extern fn g_object_get_data(obj: *anyopaque, key: [*:0]const u8) ?*anyopaque;
pub extern fn g_signal_connect_data(
    instance: *anyopaque,
    signal: [*:0]const u8,
    handler: *const anyopaque,
    data: ?*anyopaque,
    destroy_data: ?*const anyopaque,
    flags: c_uint,
) c_ulong;
pub const GdkDisplay = opaque {};
pub extern fn gdk_display_get_default() ?*GdkDisplay;
pub extern fn gdk_display_prepare_gl(display: *GdkDisplay, err: *?*GError) c_int;
pub extern fn gtk_window_new() *GtkWidget;
pub extern fn gtk_window_set_child(window: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_window_set_title(window: *GtkWidget, title: [*:0]const u8) void;
pub extern fn gtk_window_set_default_size(window: *GtkWidget, w: c_int, h: c_int) void;
pub extern fn gtk_window_present(window: *GtkWidget) void;

// --- The nav bar's widgets (T3412) ----------------------------------------
//
// Plain GTK4 C calls rather than the zig-gobject classes: the viewer is a
// handful of stock widgets, and keeping it on one binding style keeps it
// readable next to the WebKit calls above.

pub const GtkEventController = opaque {};
pub const GFile = opaque {};
pub const GtkFileLauncher = opaque {};

/// `GtkOrientation`.
pub const orientation_horizontal: c_int = 0;
pub const orientation_vertical: c_int = 1;
/// `GtkPropagationPhase`.
pub const phase_capture: c_int = 1;

pub extern fn gtk_box_new(orientation: c_int, spacing: c_int) *GtkWidget;
pub extern fn gtk_box_append(box: *GtkWidget, child: *GtkWidget) void;
pub extern fn gtk_button_new_from_icon_name(icon: [*:0]const u8) *GtkWidget;
pub extern fn gtk_entry_new() *GtkWidget;
pub extern fn gtk_entry_set_placeholder_text(entry: *GtkWidget, text: ?[*:0]const u8) void;
pub extern fn gtk_editable_get_text(editable: *GtkWidget) [*:0]const u8;
pub extern fn gtk_editable_set_text(editable: *GtkWidget, text: [*:0]const u8) void;
pub extern fn gtk_editable_select_region(editable: *GtkWidget, start: c_int, end: c_int) void;
pub extern fn gtk_editable_get_selection_bounds(editable: *GtkWidget, start: ?*c_int, end: ?*c_int) c_int;
pub extern fn gtk_widget_set_tooltip_text(widget: *GtkWidget, text: ?[*:0]const u8) void;
pub extern fn gtk_widget_set_sensitive(widget: *GtkWidget, sensitive: c_int) void;
pub extern fn gtk_widget_get_sensitive(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_set_visible(widget: *GtkWidget, visible: c_int) void;
pub extern fn gtk_widget_get_visible(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_set_hexpand(widget: *GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_vexpand(widget: *GtkWidget, expand: c_int) void;
pub extern fn gtk_widget_set_focus_on_click(widget: *GtkWidget, focus: c_int) void;
pub extern fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: c_int) void;
pub extern fn gtk_widget_add_css_class(widget: *GtkWidget, class: [*:0]const u8) void;
pub extern fn gtk_widget_grab_focus(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_has_focus(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_is_ancestor(widget: *GtkWidget, ancestor: *GtkWidget) c_int;
pub extern fn gtk_widget_get_root(widget: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_widget_get_height(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_add_controller(widget: *GtkWidget, controller: *GtkEventController) void;
pub extern fn gtk_widget_activate(widget: *GtkWidget) c_int;
pub extern fn gtk_root_get_focus(root: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_event_controller_key_new() *GtkEventController;
pub extern fn gtk_event_controller_set_propagation_phase(controller: *GtkEventController, phase: c_int) void;
pub extern fn gtk_accelerator_parse(accel: [*:0]const u8, keyval: ?*c_uint, mods: ?*c_uint) c_int;
pub extern fn g_file_new_for_path(path: [*:0]const u8) *GFile;
pub extern fn gtk_file_launcher_new(file: ?*GFile) *GtkFileLauncher;
pub extern fn gtk_file_launcher_launch(
    launcher: *GtkFileLauncher,
    parent: ?*GtkWidget,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_launcher_open_containing_folder(
    launcher: *GtkFileLauncher,
    parent: ?*GtkWidget,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern fn gtk_file_launcher_launch_finish(launcher: *GtkFileLauncher, result: *GAsyncResult, err: *?*GError) c_int;
pub extern fn gtk_file_launcher_open_containing_folder_finish(launcher: *GtkFileLauncher, result: *GAsyncResult, err: *?*GError) c_int;
pub extern fn g_idle_add(function: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
pub extern fn g_timeout_add(interval_ms: c_uint, function: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;

/// `G_IO_ERROR_NOT_FOUND`.
pub const io_error_not_found: c_int = 1;

/// The web view as the GTK widget it is.
pub fn asWidget(view: *WebView) *GtkWidget {
    return @ptrCast(view);
}

/// The widget `webkit_web_view_new` returned, as the web view it is.
pub fn asWebView(widget: *GtkWidget) *WebView {
    return @ptrCast(widget);
}
