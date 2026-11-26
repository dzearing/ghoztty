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

// An adopted popup (T3447): WebKit's `create` must be answered with a web view
// built RELATED to the opener (`related-view`, construct-only in 6.0, which
// dropped `webkit_web_view_new_with_related_view`), so `window.opener` and
// `window.close()` survive. The size the page asked for is on its window
// properties by `ready-to-show`.
pub const WindowProperties = opaque {};
pub extern fn webkit_web_view_get_type() usize;
pub extern fn g_object_new(object_type: usize, first_property_name: ?[*:0]const u8, ...) ?*anyopaque;
pub extern fn g_object_ref_sink(obj: *anyopaque) *anyopaque;
pub extern fn webkit_web_view_get_window_properties(view: *WebView) *WindowProperties;
pub extern fn webkit_window_properties_get_geometry(props: *WindowProperties, geometry: *GdkRectangle) void;
pub extern fn webkit_web_view_get_context(view: *WebView) *WebContext;
pub extern fn webkit_web_view_load_uri(view: *WebView, uri: [*:0]const u8) void;
pub extern fn webkit_web_view_get_uri(view: *WebView) ?[*:0]const u8;
pub extern fn webkit_web_view_get_settings(view: *WebView) *Settings;
/// What the view paints under the page (T3622): transparent over a glass
/// pane's sheet for our own template pages, white otherwise.
pub extern fn webkit_web_view_set_background_color(view: *WebView, rgba: *const GdkRGBA) void;
pub extern fn webkit_settings_set_javascript_can_open_windows_automatically(settings: *Settings, enabled: c_int) void;
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

// The feedback composer's page (T3544): a document handed over as a string,
// and the page's own title for the report.
pub extern fn webkit_web_view_load_html(view: *WebView, content: [*:0]const u8, base_uri: ?[*:0]const u8) void;
pub extern fn webkit_web_view_get_title(view: *WebView) ?[*:0]const u8;

// History, reload and zoom (the nav bar and pane keys, T3412).
pub extern fn webkit_web_view_go_back(view: *WebView) void;
pub extern fn webkit_web_view_go_forward(view: *WebView) void;
pub extern fn webkit_web_view_can_go_back(view: *WebView) c_int;
pub extern fn webkit_web_view_can_go_forward(view: *WebView) c_int;
pub extern fn webkit_web_view_reload(view: *WebView) void;
pub extern fn webkit_web_view_reload_bypass_cache(view: *WebView) void;
pub extern fn webkit_web_view_get_zoom_level(view: *WebView) f64;
pub extern fn webkit_web_view_set_zoom_level(view: *WebView, level: f64) void;

// A dead web process (T3413).
pub extern fn webkit_web_view_terminate_web_process(view: *WebView) void;
pub extern fn webkit_web_view_load_alternate_html(
    view: *WebView,
    content: [*:0]const u8,
    content_uri: [*:0]const u8,
    base_uri: ?[*:0]const u8,
) void;

// --- User scripts and script messages (find in page, T3414) ---------------
//
// Mac's `WKUserScript` + `WKScriptMessageHandler`, in WebKitGTK's spelling:
// a script added to the view's own content manager runs in every document the
// view loads from then on, and `postMessage` to a registered handler name
// arrives as `script-message-received::<name>` carrying a `JSCValue`.

pub const UserContentManager = opaque {};
pub const UserScript = opaque {};
/// A popup's own content manager (T3447): a related view would otherwise
/// SHARE the opener's, and its messages would reach the opener's handlers.
pub extern fn webkit_user_content_manager_new() *UserContentManager;

/// `WebKitUserContentInjectedFrames`.
pub const inject_all_frames: c_int = 0;
pub const inject_top_frame: c_int = 1;
/// `WebKitUserScriptInjectionTime`.
pub const inject_at_document_start: c_int = 0;
pub const inject_at_document_end: c_int = 1;

pub extern fn webkit_web_view_get_user_content_manager(view: *WebView) *UserContentManager;
pub extern fn webkit_user_script_new(
    source: [*:0]const u8,
    injected_frames: c_int,
    injection_time: c_int,
    allow_list: ?*const anyopaque,
    block_list: ?*const anyopaque,
) *UserScript;
/// A script in a named (private) world (T3554): page scripts cannot see it,
/// nor any message handler registered in the same world.
pub extern fn webkit_user_script_new_for_world(
    source: [*:0]const u8,
    injected_frames: c_int,
    injection_time: c_int,
    world_name: [*:0]const u8,
    allow_list: ?*const anyopaque,
    block_list: ?*const anyopaque,
) *UserScript;
pub extern fn webkit_user_script_unref(script: *UserScript) void;
pub extern fn webkit_user_content_manager_add_script(manager: *UserContentManager, script: *UserScript) void;
pub extern fn webkit_user_content_manager_register_script_message_handler(
    manager: *UserContentManager,
    name: [*:0]const u8,
    world_name: ?[*:0]const u8,
) c_int;
pub extern fn webkit_user_content_manager_unregister_script_message_handler(
    manager: *UserContentManager,
    name: [*:0]const u8,
    world_name: ?[*:0]const u8,
) void;

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
/// The value as JSON text (a posted message object). Caller frees with `g_free`.
pub extern fn jsc_value_to_json(value: *JSCValue, indent: c_uint) ?[*:0]u8;

// --- GLib / GIO / GObject / GTK, the few calls this file's users need ----

pub extern fn g_memory_input_stream_new_from_data(data: ?*const anyopaque, len: isize, destroy: ?GDestroyNotify) *GInputStream;
pub extern fn g_io_error_quark() u32;
pub extern fn g_error_new_literal(domain: u32, code: c_int, message: [*:0]const u8) *GError;
pub extern fn g_error_free(err: *GError) void;
pub extern fn g_free(mem: ?*anyopaque) void;
pub extern fn g_object_unref(obj: *anyopaque) void;
pub extern fn g_object_ref(obj: *anyopaque) *anyopaque;
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
pub extern fn gtk_button_set_has_frame(button: *GtkWidget, has_frame: c_int) void;
pub extern fn gtk_entry_new() *GtkWidget;
pub extern fn gtk_entry_set_placeholder_text(entry: *GtkWidget, text: ?[*:0]const u8) void;
pub extern fn gtk_editable_get_text(editable: *GtkWidget) [*:0]const u8;
pub extern fn gtk_editable_set_text(editable: *GtkWidget, text: [*:0]const u8) void;
pub extern fn gtk_editable_select_region(editable: *GtkWidget, start: c_int, end: c_int) void;
pub extern fn gtk_editable_get_selection_bounds(editable: *GtkWidget, start: ?*c_int, end: ?*c_int) c_int;
pub extern fn gtk_widget_set_tooltip_text(widget: *GtkWidget, text: ?[*:0]const u8) void;
pub extern fn gtk_widget_get_tooltip_text(widget: *GtkWidget) ?[*:0]const u8;
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
pub extern fn g_signal_emit_by_name(instance: *anyopaque, signal: [*:0]const u8, ...) void;
pub extern fn g_idle_add(function: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
pub extern fn g_timeout_add(interval_ms: c_uint, function: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
pub extern fn g_source_remove(id: c_uint) c_int;

// --- The find card (T3414) -------------------------------------------------

/// `GtkAlign`.
pub const align_start: c_int = 1;
pub const align_end: c_int = 2;

pub extern fn gtk_overlay_new() *GtkWidget;
pub extern fn gtk_overlay_set_child(overlay: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_overlay_add_overlay(overlay: *GtkWidget, widget: *GtkWidget) void;
pub extern fn gtk_label_new(text: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_set_text(label: *GtkWidget, text: [*:0]const u8) void;
pub extern fn gtk_label_get_text(label: *GtkWidget) [*:0]const u8;
pub extern fn gtk_label_set_xalign(label: *GtkWidget, xalign: f32) void;
pub extern fn gtk_editable_set_width_chars(editable: *GtkWidget, n_chars: c_int) void;
pub extern fn gtk_widget_set_halign(widget: *GtkWidget, a: c_int) void;
pub extern fn gtk_widget_set_valign(widget: *GtkWidget, a: c_int) void;

// --- File monitoring, for live reload (T3413) ------------------------------

pub const GFileMonitor = opaque {};
pub extern fn g_file_monitor_file(file: *GFile, flags: c_uint, cancellable: ?*anyopaque, err: *?*GError) ?*GFileMonitor;
pub extern fn g_file_monitor_cancel(monitor: *GFileMonitor) c_int;
pub extern fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;
pub extern fn gtk_widget_get_mapped(widget: *GtkWidget) c_int;

// --- The style the composer follows (T3552) ---------------------------------

pub const AdwStyleManager = opaque {};
pub extern fn adw_style_manager_get_default() *AdwStyleManager;
pub extern fn adw_style_manager_get_dark(manager: *AdwStyleManager) c_int;
pub extern fn adw_style_manager_set_color_scheme(manager: *AdwStyleManager, scheme: c_int) void;
/// `AdwColorScheme`.
pub const adw_color_scheme_default: c_int = 0;
pub const adw_color_scheme_force_light: c_int = 1;
pub const adw_color_scheme_force_dark: c_int = 4;
pub const GdkRGBA = extern struct { red: f32, green: f32, blue: f32, alpha: f32 };
pub const GtkStyleContext = opaque {};
/// Deprecated since GTK 4.10 but present for all of GTK 4: the only way to
/// read a theme's named colour (`@card_bg_color`, `@accent_bg_color`).
pub extern fn gtk_widget_get_style_context(widget: *GtkWidget) *GtkStyleContext;
pub extern fn gtk_style_context_lookup_color(ctx: *GtkStyleContext, name: [*:0]const u8, color: *GdkRGBA) c_int;

/// `G_IO_ERROR_NOT_FOUND`.
pub const io_error_not_found: c_int = 1;

// --- Link routing, popups and the link menu (T3415) -------------------------

pub const PolicyDecision = opaque {};
pub const NavigationAction = opaque {};
pub const URIRequest = opaque {};
pub const GtkUriLauncher = opaque {};
pub const GdkClipboard = opaque {};
pub const GMenu = opaque {};
pub const GSimpleAction = opaque {};
pub const GSimpleActionGroup = opaque {};

/// `WebKitPolicyDecisionType`.
pub const policy_navigation_action: c_int = 0;
pub const policy_new_window_action: c_int = 1;

pub extern fn webkit_policy_decision_ignore(decision: *PolicyDecision) void;
pub extern fn webkit_policy_decision_use(decision: *PolicyDecision) void;
pub extern fn webkit_navigation_policy_decision_get_navigation_action(decision: *PolicyDecision) ?*NavigationAction;
pub extern fn webkit_navigation_action_get_navigation_type(action: *NavigationAction) c_int;
pub extern fn webkit_navigation_action_get_modifiers(action: *NavigationAction) c_uint;
pub extern fn webkit_navigation_action_is_user_gesture(action: *NavigationAction) c_int;
pub extern fn webkit_navigation_action_is_redirect(action: *NavigationAction) c_int;
pub extern fn webkit_navigation_action_get_request(action: *NavigationAction) ?*URIRequest;
pub extern fn webkit_uri_request_get_uri(request: *URIRequest) ?[*:0]const u8;

pub extern fn gtk_uri_launcher_new(uri: ?[*:0]const u8) *GtkUriLauncher;
pub extern fn gtk_uri_launcher_launch(
    launcher: *GtkUriLauncher,
    parent: ?*GtkWidget,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    data: ?*anyopaque,
) void;
pub extern fn gtk_uri_launcher_launch_finish(launcher: *GtkUriLauncher, result: *GAsyncResult, err: *?*GError) c_int;

pub extern fn gtk_widget_get_clipboard(widget: *GtkWidget) *GdkClipboard;
pub extern fn gdk_clipboard_set_text(clipboard: *GdkClipboard, text: [*:0]const u8) void;

// --- An image pane's copy (T3534) --------------------------------------------
//
// The picture as a typed GdkTexture provider (GDK's serializers offer it as
// image/png and the rest), unioned with the file as raw-bytes providers.
pub const GdkContentProvider = opaque {};
pub const GdkContentFormats = opaque {};
pub const GType = usize;
pub extern fn gdk_texture_get_type() GType;
pub extern fn gdk_texture_get_width(texture: *GdkTexture) c_int;
pub extern fn gdk_texture_get_height(texture: *GdkTexture) c_int;
pub extern fn gdk_content_provider_new_typed(gtype: GType, ...) *GdkContentProvider;
pub extern fn gdk_content_provider_new_for_bytes(mime_type: [*:0]const u8, bytes: *GBytes) *GdkContentProvider;
pub extern fn gdk_content_provider_new_union(providers: [*]const *GdkContentProvider, n_providers: usize) *GdkContentProvider;
pub extern fn gdk_clipboard_set_content(clipboard: *GdkClipboard, provider: ?*GdkContentProvider) c_int;
pub extern fn gdk_clipboard_get_formats(clipboard: *GdkClipboard) *GdkContentFormats;
pub extern fn gdk_clipboard_is_local(clipboard: *GdkClipboard) c_int;
pub extern fn gdk_content_formats_to_string(formats: *GdkContentFormats) [*:0]u8;
pub extern fn gdk_content_provider_ref_formats(provider: *GdkContentProvider) *GdkContentFormats;
pub extern fn gdk_content_formats_unref(formats: *GdkContentFormats) void;
pub extern fn gdk_clipboard_read_texture_async(
    clipboard: *GdkClipboard,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    data: ?*anyopaque,
) void;
pub extern fn gdk_clipboard_read_texture_finish(clipboard: *GdkClipboard, result: *GAsyncResult, err: *?*GError) ?*GdkTexture;
pub extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: *?*GError) ?[*:0]u8;

pub extern fn g_menu_new() *GMenu;
pub extern fn g_menu_append(menu: *GMenu, label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) void;
pub extern fn g_menu_append_section(menu: *GMenu, label: ?[*:0]const u8, section: *GMenu) void;
pub extern fn g_simple_action_group_new() *GSimpleActionGroup;
pub extern fn g_simple_action_new(name: [*:0]const u8, parameter_type: ?*anyopaque) *GSimpleAction;
pub extern fn g_action_map_add_action(map: *anyopaque, action: *anyopaque) void;
pub extern fn g_action_get_name(action: *anyopaque) [*:0]const u8;
pub extern fn gtk_widget_insert_action_group(widget: *GtkWidget, name: [*:0]const u8, group: ?*anyopaque) void;
pub extern fn gtk_popover_menu_new_from_model(model: ?*anyopaque) *GtkWidget;
pub extern fn gtk_widget_set_parent(widget: *GtkWidget, parent: *GtkWidget) void;
pub extern fn gtk_widget_unparent(widget: *GtkWidget) void;
pub extern fn gtk_popover_set_pointing_to(popover: *GtkWidget, rect: *const GdkRectangle) void;
pub extern fn gtk_popover_set_has_arrow(popover: *GtkWidget, has_arrow: c_int) void;
pub extern fn gtk_popover_popup(popover: *GtkWidget) void;
pub extern fn gtk_event_controller_motion_new() *GtkEventController;
// The pane sidebar's window menu and its in-place group field (T3608).
pub extern fn g_menu_append_submenu(menu: *GMenu, label: ?[*:0]const u8, submenu: *GMenu) void;
pub extern fn gtk_popover_popdown(popover: *GtkWidget) void;
pub extern fn gtk_event_controller_focus_new() *GtkEventController;
pub extern fn gtk_editable_set_position(editable: *GtkWidget, position: c_int) void;

pub const GdkRectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };

// --- Image panes (T3416) -----------------------------------------------------
//
// A picture WebKit draws is streamed straight off disk (`g_file_read`); one it
// cannot draw (TIFF, HEIF) is decoded on a worker thread by GDK - its own
// loaders, then gdk-pixbuf's - and served as PNG. GTK documents
// `gdk_texture_new_from_filename` as thread-safe for exactly that use.

pub const GdkTexture = opaque {};
pub const GBytes = opaque {};

pub extern fn g_file_read(file: *GFile, cancellable: ?*anyopaque, err: *?*GError) ?*GInputStream;
pub extern fn gdk_texture_new_from_filename(path: [*:0]const u8, err: *?*GError) ?*GdkTexture;
pub extern fn gdk_texture_save_to_png_bytes(texture: *GdkTexture) *GBytes;
/// The texture's pixels as `GDK_MEMORY_B8G8R8A8_PREMULTIPLIED` (cairo's
/// ARGB32 on a little-endian host), `stride` bytes a row.
pub extern fn gdk_texture_download(texture: *GdkTexture, data: [*]u8, stride: usize) void;
pub extern fn g_bytes_get_size(bytes: *GBytes) usize;
pub extern fn g_bytes_unref(bytes: *GBytes) void;
pub extern fn g_memory_input_stream_new_from_bytes(bytes: *GBytes) *GInputStream;

// --- Git diff panes: the changed-files panel (T3417) ------------------------
//
// The panel is a `GtkPaned`'s start child beside the page: a header, a search
// entry for the filter, and a `GtkListBox` of the file tree's rows.

pub extern fn gtk_paned_new(orientation: c_int) *GtkWidget;
pub extern fn gtk_paned_set_start_child(paned: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_paned_set_end_child(paned: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_paned_set_resize_start_child(paned: *GtkWidget, resize: c_int) void;
pub extern fn gtk_paned_set_shrink_start_child(paned: *GtkWidget, shrink: c_int) void;
pub extern fn gtk_paned_set_shrink_end_child(paned: *GtkWidget, shrink: c_int) void;
pub extern fn gtk_paned_set_position(paned: *GtkWidget, position: c_int) void;
pub extern fn gtk_paned_get_position(paned: *GtkWidget) c_int;
pub extern fn gtk_scrolled_window_new() *GtkWidget;
pub extern fn gtk_scrolled_window_set_child(sw: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_scrolled_window_set_policy(sw: *GtkWidget, h: c_int, v: c_int) void;
pub extern fn gtk_list_box_new() *GtkWidget;
pub extern fn gtk_list_box_append(box: *GtkWidget, child: *GtkWidget) void;
pub extern fn gtk_list_box_remove_all(box: *GtkWidget) void;
pub extern fn gtk_list_box_get_row_at_index(box: *GtkWidget, index: c_int) ?*GtkWidget;
pub extern fn gtk_list_box_select_row(box: *GtkWidget, row: ?*GtkWidget) void;
pub extern fn gtk_list_box_get_selected_row(box: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_list_box_row_get_index(row: *GtkWidget) c_int;
pub extern fn gtk_list_box_row_set_activatable(row: *GtkWidget, activatable: c_int) void;
pub extern fn gtk_list_box_row_set_selectable(row: *GtkWidget, selectable: c_int) void;
pub extern fn gtk_search_entry_new() *GtkWidget;
pub extern fn gtk_search_entry_set_search_delay(entry: *GtkWidget, delay: c_uint) void;
pub extern fn gtk_search_entry_set_placeholder_text(entry: *GtkWidget, text: ?[*:0]const u8) void;
pub extern fn gtk_button_set_icon_name(button: *GtkWidget, icon: [*:0]const u8) void;
pub extern fn gtk_widget_remove_css_class(widget: *GtkWidget, class: [*:0]const u8) void;
pub extern fn gtk_widget_set_size_request(widget: *GtkWidget, width: c_int, height: c_int) void;
pub extern fn gtk_label_set_ellipsize(label: *GtkWidget, mode: c_int) void;

// --- The table-of-contents card (T3418) -------------------------------------

pub const GtkAdjustment = opaque {};
/// `graphene_rect_t`.
pub const GrapheneRect = extern struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };

pub extern fn gtk_box_prepend(box: *GtkWidget, child: *GtkWidget) void;
/// The feedback composer's web view comes and goes with the composer (T3544).
pub extern fn gtk_box_remove(box: *GtkWidget, child: *GtkWidget) void;
pub extern fn gtk_drawing_area_new() *GtkWidget;
pub extern fn gtk_widget_set_can_target(widget: *GtkWidget, can_target: c_int) void;
pub extern fn gtk_widget_get_width(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_set_cursor_from_name(widget: *GtkWidget, name: ?[*:0]const u8) void;
pub extern fn gtk_widget_set_overflow(widget: *GtkWidget, overflow: c_int) void;
pub extern fn gtk_widget_compute_bounds(widget: *GtkWidget, target: *GtkWidget, out: *GrapheneRect) c_int;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(sw: *GtkWidget, propagate: c_int) void;
pub extern fn gtk_scrolled_window_set_max_content_height(sw: *GtkWidget, height: c_int) void;
pub extern fn gtk_widget_get_last_child(widget: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_scrolled_window_set_propagate_natural_width(sw: *GtkWidget, propagate: c_int) void;
pub extern fn gtk_scrolled_window_set_max_content_width(sw: *GtkWidget, width: c_int) void;
pub extern fn gtk_scrolled_window_get_vadjustment(sw: *GtkWidget) *GtkAdjustment;
pub extern fn gtk_adjustment_get_value(adj: *GtkAdjustment) f64;
pub extern fn gtk_adjustment_get_page_size(adj: *GtkAdjustment) f64;
pub extern fn gtk_adjustment_set_value(adj: *GtkAdjustment, value: f64) void;
pub extern fn gtk_label_set_wrap(label: *GtkWidget, wrap: c_int) void;
pub extern fn gtk_label_set_wrap_mode(label: *GtkWidget, mode: c_int) void;
pub extern fn gtk_label_set_lines(label: *GtkWidget, lines: c_int) void;
pub extern fn gtk_label_set_max_width_chars(label: *GtkWidget, n_chars: c_int) void;
pub extern fn gtk_gesture_drag_new() *GtkEventController;
pub extern fn gtk_list_box_set_activate_on_single_click(box: *GtkWidget, single: c_int) void;

/// `GtkOverflow`.
pub const overflow_hidden: c_int = 1;
/// `PangoEllipsizeMode` / `PangoWrapMode`.
pub const ellipsize_end: c_int = 3;
pub const wrap_word_char: c_int = 2;

/// `GtkPolicyType`.
pub const policy_never: c_int = 2;
pub const policy_automatic: c_int = 1;
/// `PangoEllipsizeMode`.
pub const ellipsize_middle: c_int = 2;

/// The web view as the GTK widget it is.
pub fn asWidget(view: *WebView) *GtkWidget {
    return @ptrCast(view);
}

/// The widget `webkit_web_view_new` returned, as the web view it is.
pub fn asWebView(widget: *GtkWidget) *WebView {
    return @ptrCast(widget);
}

// --- Pictures in the feedback composer (T3546) -------------------------------
//
// Wayland (and the headless Weston the tests run in) has no global capture, so
// a screenshot is the app's OWN render: the widget's paintable snapshotted to
// a render node, rendered to a texture by the window's GSK renderer, saved as
// PNG. The thumbnail strip decodes the stored PNGs back into textures.

pub const GdkPaintable = opaque {};
pub const GtkSnapshot = opaque {};
pub const GskRenderNode = opaque {};
pub const GskRenderer = opaque {};
pub const GtkNative = opaque {};

pub extern fn gtk_widget_paintable_new(widget: ?*GtkWidget) *GdkPaintable;
pub extern fn gtk_snapshot_new() *GtkSnapshot;
pub extern fn gtk_snapshot_scale(snapshot: *GtkSnapshot, x: f32, y: f32) void;
pub extern fn gtk_snapshot_free_to_node(snapshot: *GtkSnapshot) ?*GskRenderNode;
pub extern fn gdk_paintable_snapshot(paintable: *GdkPaintable, snapshot: *GtkSnapshot, width: f64, height: f64) void;
pub extern fn gsk_render_node_unref(node: *GskRenderNode) void;
pub extern fn gtk_widget_get_native(widget: *GtkWidget) ?*GtkNative;
pub extern fn gtk_native_get_renderer(native: *GtkNative) ?*GskRenderer;
pub extern fn gsk_renderer_render_texture(renderer: *GskRenderer, root: *GskRenderNode, viewport: ?*const GrapheneRect) ?*GdkTexture;
pub extern fn gtk_widget_get_scale_factor(widget: *GtkWidget) c_int;
pub extern fn g_bytes_new(data: ?*const anyopaque, size: usize) *GBytes;
pub extern fn g_bytes_get_data(bytes: *GBytes, size: ?*usize) ?[*]const u8;
pub extern fn gdk_texture_new_from_bytes(bytes: *GBytes, err: *?*GError) ?*GdkTexture;

// The pane style's gradient desk (T3566): a small texture of the shared
// gradient, stretched under a split tree's cards. Format 0 is
// GDK_MEMORY_B8G8R8A8_PREMULTIPLIED.
pub const GDK_MEMORY_B8G8R8A8_PREMULTIPLIED: c_int = 0;
pub extern fn gdk_memory_texture_new(width: c_int, height: c_int, format: c_int, bytes: *GBytes, stride: usize) ?*GdkTexture;
pub extern fn gtk_snapshot_append_scaled_texture(snapshot: *GtkSnapshot, texture: *GdkTexture, filter: c_int, bounds: *const GrapheneRect) void;
pub const GSK_SCALING_FILTER_LINEAR: c_int = 0;
pub extern fn gtk_picture_new_for_paintable(paintable: ?*anyopaque) *GtkWidget;
pub extern fn gtk_picture_set_content_fit(picture: *GtkWidget, fit: c_int) void;
pub extern fn gtk_picture_set_can_shrink(picture: *GtkWidget, can_shrink: c_int) void;
pub extern fn gtk_button_set_child(button: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_scrolled_window_get_child(sw: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_viewport_scroll_to(viewport: *GtkWidget, descendant: *GtkWidget, scroll: ?*anyopaque) void;

/// `GtkContentFit`.
pub const content_fit_contain: c_int = 1;
pub extern fn gtk_button_new() *GtkWidget;
pub extern fn gtk_image_new_from_icon_name(icon: [*:0]const u8) *GtkWidget;

// --- The pane banner's widgets (T3339) --------------------------------------

pub extern fn gtk_label_set_markup(label: *GtkWidget, markup: [*:0]const u8) void;
pub extern fn gtk_grid_new() *GtkWidget;
pub extern fn gtk_grid_attach(grid: *GtkWidget, child: *GtkWidget, column: c_int, row: c_int, width: c_int, height: c_int) void;
pub extern fn gtk_grid_set_column_spacing(grid: *GtkWidget, spacing: c_uint) void;
pub extern fn gtk_grid_set_row_spacing(grid: *GtkWidget, spacing: c_uint) void;
pub extern fn gtk_separator_new(orientation: c_int) *GtkWidget;
pub extern fn gtk_check_button_new() *GtkWidget;
pub extern fn gtk_check_button_set_active(button: *GtkWidget, active: c_int) void;
pub extern fn gtk_widget_get_first_child(widget: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_widget_set_focusable(widget: *GtkWidget, focusable: c_int) void;
pub extern fn gtk_orientable_set_orientation(orientable: *GtkWidget, orientation: c_int) void;
pub extern fn gtk_gesture_click_new() *GtkEventController;
pub extern fn gtk_event_controller_get_current_event_state(controller: *GtkEventController) c_uint;
// The banner link menu (T3561): a right-click gesture on a banner label that
// claims the press over the label's own Copy Link menu.
pub extern fn gtk_gesture_single_set_button(gesture: *GtkEventController, button: c_uint) void;
pub extern fn gtk_gesture_set_state(gesture: *GtkEventController, state: c_int) c_int;
pub extern fn gtk_event_controller_get_widget(controller: *GtkEventController) *GtkWidget;
pub extern fn gtk_label_get_current_uri(label: *GtkWidget) ?[*:0]const u8;
pub extern fn gtk_widget_translate_coordinates(src: *GtkWidget, dest: *GtkWidget, src_x: f64, src_y: f64, dest_x: *f64, dest_y: *f64) c_int;

// --- The Set Pane Banner editor (T3559) -------------------------------------

/// `GtkTextIter`: a stack struct GTK fills in. 80 bytes on every 64-bit
/// target (14 pointer/int fields, padded); never read field by field.
pub const GtkTextIter = extern struct { opaque_bytes: [10]u64 = [_]u64{0} ** 10 };
pub const GtkTextBuffer = opaque {};
pub extern fn gtk_text_view_new() *GtkWidget;
pub extern fn gtk_text_view_get_buffer(view: *GtkWidget) *GtkTextBuffer;
pub extern fn gtk_text_view_set_wrap_mode(view: *GtkWidget, mode: c_int) void;
pub extern fn gtk_text_view_set_monospace(view: *GtkWidget, monospace: c_int) void;
pub extern fn gtk_text_view_set_accepts_tab(view: *GtkWidget, accepts: c_int) void;
pub extern fn gtk_text_buffer_set_text(buffer: *GtkTextBuffer, text: [*]const u8, len: c_int) void;
pub extern fn gtk_text_buffer_get_bounds(buffer: *GtkTextBuffer, start: *GtkTextIter, end: *GtkTextIter) void;
pub extern fn gtk_text_buffer_get_text(buffer: *GtkTextBuffer, start: *const GtkTextIter, end: *const GtkTextIter, include_hidden: c_int) [*:0]u8;
pub extern fn gtk_text_buffer_select_range(buffer: *GtkTextBuffer, ins: *const GtkTextIter, bound: *const GtkTextIter) void;
/// `GtkWrapMode` `GTK_WRAP_WORD_CHAR` (not Pango's, above).
pub const text_wrap_word_char: c_int = 3;
pub extern fn adw_alert_dialog_new(heading: ?[*:0]const u8, body: ?[*:0]const u8) *GtkWidget;
pub extern fn adw_alert_dialog_add_response(dialog: *GtkWidget, id: [*:0]const u8, label: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_response_appearance(dialog: *GtkWidget, id: [*:0]const u8, appearance: c_int) void;
pub extern fn adw_alert_dialog_set_default_response(dialog: *GtkWidget, id: ?[*:0]const u8) void;
pub extern fn adw_alert_dialog_set_close_response(dialog: *GtkWidget, id: [*:0]const u8) void;
pub extern fn adw_alert_dialog_set_extra_child(dialog: *GtkWidget, child: ?*GtkWidget) void;
/// `ADW_RESPONSE_SUGGESTED`.
pub const adw_response_suggested: c_int = 1;
pub extern fn adw_dialog_present(dialog: *GtkWidget, parent: ?*GtkWidget) void;
pub extern fn adw_dialog_force_close(dialog: *GtkWidget) void;

// --- Pane rearrange mode and pane drag-and-drop (T3564) ----------------------

pub const GdkDrop = opaque {};
pub const GdkDrag = opaque {};
/// `GdkDragAction` `GDK_ACTION_MOVE`.
pub const gdk_action_move: c_int = 1 << 1;
pub extern fn gtk_drag_source_new() *GtkEventController;
pub extern fn gtk_drag_source_set_content(source: *GtkEventController, content: ?*GdkContentProvider) void;
pub extern fn gtk_drag_source_set_actions(source: *GtkEventController, actions: c_int) void;
pub extern fn gtk_drop_target_async_new(formats: ?*GdkContentFormats, actions: c_int) *GtkEventController;
pub extern fn gdk_content_formats_new(mime_types: ?[*]const [*:0]const u8, n_mime_types: c_uint) *GdkContentFormats;
pub extern fn gdk_drop_finish(drop: *GdkDrop, action: c_int) void;
pub extern fn gtk_box_reorder_child_after(box: *GtkWidget, child: *GtkWidget, sibling: ?*GtkWidget) void;
pub extern fn gtk_box_insert_child_after(box: *GtkWidget, child: *GtkWidget, sibling: ?*GtkWidget) void;
pub extern fn gtk_widget_get_parent(widget: *GtkWidget) ?*GtkWidget;

// The ghost card a pane drag carries (T3617): drawn with GtkSnapshot, rendered
// to a texture by the window's renderer, set as the drag's icon.
/// `graphene_size_t`.
pub const GrapheneSize = extern struct { width: f32 = 0, height: f32 = 0 };
/// `GskRoundedRect`: bounds, then the top-left, top-right, bottom-right and
/// bottom-left corner radii.
pub const GskRoundedRect = extern struct { bounds: GrapheneRect = .{}, corner: [4]GrapheneSize = .{ .{}, .{}, .{}, .{} } };
pub const PangoLayout = opaque {};
pub const PangoFontDescription = opaque {};
/// `PANGO_SCALE`, `PANGO_ELLIPSIZE_END`.
pub const pango_scale: c_int = 1024;
pub const pango_ellipsize_end: c_int = 3;
pub extern fn gsk_rounded_rect_init_from_rect(self: *GskRoundedRect, bounds: *const GrapheneRect, radius: f32) *GskRoundedRect;
pub extern fn gtk_snapshot_push_rounded_clip(snapshot: *GtkSnapshot, bounds: *const GskRoundedRect) void;
pub extern fn gtk_snapshot_push_clip(snapshot: *GtkSnapshot, bounds: *const GrapheneRect) void;
pub extern fn gtk_snapshot_pop(snapshot: *GtkSnapshot) void;
// The single-window shade crossfade (T3651): the old desk over the new.
pub extern fn gtk_snapshot_push_opacity(snapshot: *GtkSnapshot, opacity: f64) void;
pub extern fn gtk_snapshot_save(snapshot: *GtkSnapshot) void;
pub extern fn gtk_snapshot_restore(snapshot: *GtkSnapshot) void;
pub extern fn gtk_snapshot_translate(snapshot: *GtkSnapshot, point: *const GraphenePoint) void;
pub extern fn gtk_snapshot_append_color(snapshot: *GtkSnapshot, color: *const GdkRGBA, bounds: *const GrapheneRect) void;
pub extern fn gtk_snapshot_append_outset_shadow(snapshot: *GtkSnapshot, outline: *const GskRoundedRect, color: *const GdkRGBA, dx: f32, dy: f32, spread: f32, blur_radius: f32) void;
pub extern fn gtk_snapshot_append_border(snapshot: *GtkSnapshot, outline: *const GskRoundedRect, border_width: *const [4]f32, border_color: *const [4]GdkRGBA) void;
pub extern fn gtk_snapshot_append_layout(snapshot: *GtkSnapshot, layout: *PangoLayout, color: *const GdkRGBA) void;
pub extern fn gtk_snapshot_append_texture(snapshot: *GtkSnapshot, texture: *GdkTexture, bounds: *const GrapheneRect) void;
pub extern fn gtk_snapshot_free_to_paintable(snapshot: *GtkSnapshot, size: ?*const GrapheneSize) ?*GdkPaintable;
pub extern fn gtk_drag_source_set_icon(source: *GtkEventController, paintable: ?*GdkPaintable, hot_x: c_int, hot_y: c_int) void;
pub extern fn gtk_widget_create_pango_layout(widget: *GtkWidget, text: ?[*:0]const u8) *PangoLayout;
pub extern fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: c_int) void;
pub extern fn pango_layout_set_font_description(layout: *PangoLayout, desc: ?*const PangoFontDescription) void;
pub extern fn pango_layout_get_pixel_size(layout: *PangoLayout, width: ?*c_int, height: ?*c_int) void;
pub extern fn pango_font_description_from_string(str: [*:0]const u8) *PangoFontDescription;
pub extern fn pango_font_description_set_absolute_size(desc: *PangoFontDescription, size: f64) void;
pub extern fn pango_font_description_free(desc: *PangoFontDescription) void;

// --- Stacked panes: the stage the shared layout places (T3567) ---------------

pub const GtkLayoutManager = opaque {};
pub const GskTransform = opaque {};
/// `graphene_point_t`.
pub const GraphenePoint = extern struct { x: f32 = 0, y: f32 = 0 };
pub const CustomMeasureFn = *const fn (widget: *GtkWidget, orientation: c_int, for_size: c_int, minimum: *c_int, natural: *c_int, minimum_baseline: *c_int, natural_baseline: *c_int) callconv(.c) void;
pub const CustomAllocateFn = *const fn (widget: *GtkWidget, width: c_int, height: c_int, baseline: c_int) callconv(.c) void;
pub extern fn gtk_custom_layout_new(request_mode: ?*const anyopaque, measure: CustomMeasureFn, allocate: CustomAllocateFn) *GtkLayoutManager;
pub extern fn gtk_widget_set_layout_manager(widget: *GtkWidget, layout_manager: ?*GtkLayoutManager) void;
pub extern fn gtk_widget_allocate(widget: *GtkWidget, width: c_int, height: c_int, baseline: c_int, transform: ?*GskTransform) void;
pub extern fn gtk_widget_measure(widget: *GtkWidget, orientation: c_int, for_size: c_int, minimum: ?*c_int, natural: ?*c_int, minimum_baseline: ?*c_int, natural_baseline: ?*c_int) void;
pub extern fn gsk_transform_translate(next: ?*GskTransform, point: *const GraphenePoint) ?*GskTransform;
pub extern fn gsk_transform_rotate(next: ?*GskTransform, angle: f32) ?*GskTransform;
pub extern fn gtk_widget_set_child_visible(widget: *GtkWidget, child_visible: c_int) void;
pub extern fn gtk_widget_get_child_visible(widget: *GtkWidget) c_int;
pub extern fn gtk_widget_queue_allocate(widget: *GtkWidget) void;
// Stacked-pane glides (T3625): the stage steps a glide on the frame clock,
// fades a card's content and strip face, and paints by elevation.
pub const GdkFrameClock = opaque {};
pub const TickCallbackFn = *const fn (widget: *GtkWidget, clock: *GdkFrameClock, user_data: ?*anyopaque) callconv(.c) c_int;
pub extern fn gtk_widget_add_tick_callback(widget: *GtkWidget, callback: TickCallbackFn, user_data: ?*anyopaque, notify: ?*const anyopaque) c_uint;
pub extern fn gtk_widget_remove_tick_callback(widget: *GtkWidget, id: c_uint) void;
pub extern fn gdk_frame_clock_get_frame_time(clock: *GdkFrameClock) i64;
pub extern fn g_get_monotonic_time() i64;
pub extern fn gtk_widget_set_opacity(widget: *GtkWidget, opacity: f64) void;
pub extern fn gtk_widget_insert_before(widget: *GtkWidget, parent: *GtkWidget, next_sibling: ?*GtkWidget) void;
pub extern fn gtk_widget_get_next_sibling(widget: *GtkWidget) ?*GtkWidget;
pub extern fn adw_get_enable_animations(widget: *GtkWidget) c_int;
// The Settings window (T3569).
pub extern fn gtk_window_destroy(window: *GtkWidget) void;
pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_list_box_set_selection_mode(box: *GtkWidget, mode: c_int) void;
// The keyboard shortcut guide (T3570).
pub extern fn gtk_check_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_check_button_get_active(button: *GtkWidget) c_int;
pub extern fn gtk_list_box_row_new() *GtkWidget;
pub extern fn gtk_list_box_row_set_child(row: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_list_box_unselect_all(box: *GtkWidget) void;
pub extern fn gtk_widget_compute_point(widget: *GtkWidget, target: *GtkWidget, point: *const GraphenePoint, out_point: *GraphenePoint) c_int;
// The Settings window's curated pages (T3631): libadwaita preference rows.
// AdwSwitchRow and AdwSpinRow are libadwaita 1.4 (Ubuntu 24.04 has 1.5).
pub const GListModel = opaque {};
pub extern fn adw_preferences_page_new() *GtkWidget;
pub extern fn adw_preferences_page_add(page: *GtkWidget, group: *GtkWidget) void;
pub extern fn adw_preferences_group_new() *GtkWidget;
pub extern fn adw_preferences_group_set_title(group: *GtkWidget, title: [*:0]const u8) void;
pub extern fn adw_preferences_group_set_description(group: *GtkWidget, description: ?[*:0]const u8) void;
pub extern fn adw_preferences_group_add(group: *GtkWidget, child: *GtkWidget) void;
pub extern fn adw_preferences_row_set_title(row: *GtkWidget, title: [*:0]const u8) void;
pub extern fn adw_preferences_row_set_use_markup(row: *GtkWidget, use_markup: c_int) void;
pub extern fn adw_action_row_new() *GtkWidget;
pub extern fn adw_action_row_set_subtitle(row: *GtkWidget, subtitle: [*:0]const u8) void;
pub extern fn adw_action_row_get_subtitle(row: *GtkWidget) ?[*:0]const u8;
pub extern fn adw_action_row_add_prefix(row: *GtkWidget, widget: *GtkWidget) void;
pub extern fn adw_action_row_add_suffix(row: *GtkWidget, widget: *GtkWidget) void;
pub extern fn adw_switch_row_new() *GtkWidget;
pub extern fn adw_switch_row_get_active(row: *GtkWidget) c_int;
pub extern fn adw_switch_row_set_active(row: *GtkWidget, active: c_int) void;
pub extern fn adw_combo_row_new() *GtkWidget;
pub extern fn adw_combo_row_set_model(row: *GtkWidget, model: ?*GListModel) void;
pub extern fn adw_combo_row_get_selected(row: *GtkWidget) c_uint;
pub extern fn adw_combo_row_set_selected(row: *GtkWidget, position: c_uint) void;
pub extern fn adw_spin_row_new_with_range(min: f64, max: f64, step: f64) *GtkWidget;
pub extern fn adw_spin_row_get_value(row: *GtkWidget) f64;
pub extern fn adw_spin_row_set_value(row: *GtkWidget, value: f64) void;
pub extern fn adw_spin_row_set_digits(row: *GtkWidget, digits: c_uint) void;
pub extern fn adw_expander_row_new() *GtkWidget;
pub extern fn adw_expander_row_add_row(row: *GtkWidget, child: *GtkWidget) void;
pub extern fn adw_expander_row_add_prefix(row: *GtkWidget, widget: *GtkWidget) void;
pub extern fn adw_expander_row_add_suffix(row: *GtkWidget, widget: *GtkWidget) void;
pub extern fn adw_expander_row_set_subtitle(row: *GtkWidget, subtitle: [*:0]const u8) void;
pub extern fn adw_expander_row_get_subtitle(row: *GtkWidget) ?[*:0]const u8;
pub extern fn gtk_string_list_new(strings: ?[*]const ?[*:0]const u8) *GListModel;
pub extern fn gtk_drop_down_new_from_strings(strings: [*]const ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_drop_down_get_selected(dropdown: *GtkWidget) c_uint;
pub extern fn gtk_drop_down_set_selected(dropdown: *GtkWidget, position: c_uint) void;
pub extern fn gtk_scale_new_with_range(orientation: c_int, min: f64, max: f64, step: f64) *GtkWidget;
pub extern fn gtk_scale_set_draw_value(scale: *GtkWidget, draw: c_int) void;
pub const ScaleFormatFn = *const fn (scale: *GtkWidget, value: f64, user_data: ?*anyopaque) callconv(.c) [*:0]u8;
pub extern fn gtk_scale_set_format_value_func(scale: *GtkWidget, func: ?ScaleFormatFn, user_data: ?*anyopaque, destroy: ?*const anyopaque) void;
pub extern fn gtk_range_get_value(range: *GtkWidget) f64;
pub extern fn gtk_range_set_value(range: *GtkWidget, value: f64) void;
pub extern fn gtk_stack_new() *GtkWidget;
pub extern fn gtk_stack_add_named(stack: *GtkWidget, child: *GtkWidget, name: [*:0]const u8) ?*anyopaque;
pub extern fn gtk_stack_set_visible_child_name(stack: *GtkWidget, name: [*:0]const u8) void;
pub extern fn gtk_stack_get_visible_child_name(stack: *GtkWidget) ?[*:0]const u8;
pub extern fn g_strdup(str: [*:0]const u8) [*:0]u8;
pub extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;
pub extern fn gtk_label_get_type() usize;
/// `GTK_INVALID_LIST_POSITION`.
pub const invalid_list_position: c_uint = 0xFFFF_FFFF;
// Settings > Advanced's Config file section and the change toast (T3633).
pub extern fn gtk_revealer_new() *GtkWidget;
pub extern fn gtk_revealer_set_child(revealer: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_revealer_set_reveal_child(revealer: *GtkWidget, reveal: c_int) void;
pub extern fn gtk_revealer_get_reveal_child(revealer: *GtkWidget) c_int;
pub extern fn gtk_revealer_set_transition_type(revealer: *GtkWidget, transition: c_int) void;
pub extern fn gtk_revealer_set_transition_duration(revealer: *GtkWidget, duration: c_uint) void;
/// `GTK_REVEALER_TRANSITION_TYPE_SLIDE_UP`: hiding drops the child down
/// through the revealer's bottom edge.
pub const revealer_slide_up: c_int = 4;
pub extern fn gtk_menu_button_new() *GtkWidget;
pub extern fn gtk_menu_button_set_label(button: *GtkWidget, label: [*:0]const u8) void;
pub extern fn gtk_menu_button_set_popover(button: *GtkWidget, popover: ?*GtkWidget) void;
pub extern fn gtk_menu_button_popup(button: *GtkWidget) void;
pub extern fn gtk_menu_button_popdown(button: *GtkWidget) void;
pub extern fn gtk_popover_new() *GtkWidget;
pub extern fn gtk_popover_set_child(popover: *GtkWidget, child: ?*GtkWidget) void;
pub extern fn gtk_label_set_selectable(label: *GtkWidget, selectable: c_int) void;
pub extern fn gtk_button_get_label(button: *GtkWidget) ?[*:0]const u8;
pub extern fn gtk_button_set_label(button: *GtkWidget, label: [*:0]const u8) void;
pub extern fn adw_expander_row_set_expanded(row: *GtkWidget, expanded: c_int) void;
pub extern fn adw_expander_row_get_expanded(row: *GtkWidget) c_int;
pub extern fn adw_preferences_group_remove(group: *GtkWidget, child: *GtkWidget) void;
/// `ADW_RESPONSE_DESTRUCTIVE`.
pub const adw_response_destructive: c_int = 2;
pub extern fn adw_alert_dialog_get_heading(dialog: *GtkWidget) ?[*:0]const u8;
pub extern fn adw_alert_dialog_get_body(dialog: *GtkWidget) ?[*:0]const u8;
// Settings > Sessions & Agent / Remote Machines and Host Settings (T3635).
pub extern fn gtk_menu_button_set_icon_name(button: *GtkWidget, icon: [*:0]const u8) void;
pub extern fn gtk_menu_button_get_popover(button: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_popover_get_child(popover: *GtkWidget) ?*GtkWidget;
pub extern fn gtk_widget_has_css_class(widget: *GtkWidget, class: [*:0]const u8) c_int;
pub extern fn adw_preferences_row_get_title(row: *GtkWidget) ?[*:0]const u8;

/// `GtkEventSequenceState`.
pub const sequence_claimed: c_int = 1;
pub const sequence_denied: c_int = 2;

// Settings > Appearance: the theme picker and the live preview (T3636).
pub const GtkCssProvider = opaque {};
/// `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION`.
pub const style_provider_priority_application: c_uint = 600;
pub extern fn gtk_css_provider_new() *GtkCssProvider;
pub extern fn gtk_css_provider_load_from_string(provider: *GtkCssProvider, string: [*:0]const u8) void;
pub extern fn gtk_style_context_add_provider_for_display(display: *GdkDisplay, provider: *GtkCssProvider, priority: c_uint) void;
pub extern fn gtk_style_context_remove_provider_for_display(display: *GdkDisplay, provider: *GtkCssProvider) void;
pub extern fn gtk_widget_get_display(widget: *GtkWidget) *GdkDisplay;
pub extern fn gtk_toggle_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_toggle_button_set_group(button: *GtkWidget, group: ?*GtkWidget) void;
pub extern fn gtk_toggle_button_set_active(button: *GtkWidget, active: c_int) void;
pub extern fn gtk_toggle_button_get_active(button: *GtkWidget) c_int;
pub extern fn gtk_flow_box_new() *GtkWidget;
pub extern fn gtk_flow_box_append(box: *GtkWidget, child: *GtkWidget) void;
pub extern fn gtk_flow_box_remove_all(box: *GtkWidget) void;
pub extern fn gtk_flow_box_set_selection_mode(box: *GtkWidget, mode: c_int) void;
pub extern fn gtk_flow_box_set_homogeneous(box: *GtkWidget, homogeneous: c_int) void;
pub extern fn gtk_flow_box_set_min_children_per_line(box: *GtkWidget, n: c_uint) void;
pub extern fn gtk_flow_box_set_max_children_per_line(box: *GtkWidget, n: c_uint) void;
pub extern fn gtk_flow_box_set_column_spacing(box: *GtkWidget, spacing: c_uint) void;
pub extern fn gtk_flow_box_set_row_spacing(box: *GtkWidget, spacing: c_uint) void;
pub extern fn gtk_label_get_label(label: *GtkWidget) [*:0]const u8;
pub extern fn gtk_widget_get_margin_start(widget: *GtkWidget) c_int;
