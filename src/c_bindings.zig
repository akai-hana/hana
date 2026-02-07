//! Manual C bindings for Cairo and Pango
//! This avoids @cImport translation issues with GLib macros

const defs = @import("defs");

// Re-export XCB types from defs (which uses @cImport successfully)
pub const xcb_connection_t = defs.xcb.xcb_connection_t;
pub const xcb_drawable_t = u32;
pub const xcb_visualtype_t = defs.xcb.xcb_visualtype_t;
pub const xcb_screen_t = defs.xcb.xcb_screen_t;
pub const xcb_screen_iterator_t = defs.xcb.xcb_screen_iterator_t;
pub const xcb_depth_iterator_t = defs.xcb.xcb_depth_iterator_t;
pub const xcb_visualtype_iterator_t = defs.xcb.xcb_visualtype_iterator_t;

// Re-export XCB functions from defs
pub const xcb_get_setup = defs.xcb.xcb_get_setup;
pub const xcb_setup_roots_iterator = defs.xcb.xcb_setup_roots_iterator;
pub const xcb_screen_allowed_depths_iterator = defs.xcb.xcb_screen_allowed_depths_iterator;
pub const xcb_depth_visuals_iterator = defs.xcb.xcb_depth_visuals_iterator;
pub const xcb_visualtype_next = defs.xcb.xcb_visualtype_next;
pub const xcb_depth_next = defs.xcb.xcb_depth_next;
pub const xcb_screen_next = defs.xcb.xcb_screen_next;

// Cairo types
pub const cairo_surface_t = opaque {};
pub const cairo_t = opaque {};

// Pango types  
pub const PangoLayout = opaque {};
pub const PangoFontDescription = opaque {};
pub const PangoContext = opaque {};
pub const PangoFontMetrics = opaque {};
pub const PangoEllipsizeMode = enum(c_int) {
    NONE = 0,
    START = 1,
    MIDDLE = 2,
    END = 3,
};

// GLib types
pub const gpointer = ?*anyopaque;

// Pango constants
pub const PANGO_SCALE: c_int = 1024;
pub const PANGO_ELLIPSIZE_NONE = PangoEllipsizeMode.NONE;
pub const PANGO_ELLIPSIZE_START = PangoEllipsizeMode.START;
pub const PANGO_ELLIPSIZE_MIDDLE = PangoEllipsizeMode.MIDDLE;
pub const PANGO_ELLIPSIZE_END = PangoEllipsizeMode.END;

// Cairo functions
pub extern "cairo" fn cairo_xcb_surface_create(
    connection: *xcb_connection_t,
    drawable: xcb_drawable_t,
    visual: *xcb_visualtype_t,
    width: c_int,
    height: c_int,
) ?*cairo_surface_t;

pub extern "cairo" fn cairo_surface_destroy(surface: *cairo_surface_t) void;
pub extern "cairo" fn cairo_surface_flush(surface: *cairo_surface_t) void;

pub extern "cairo" fn cairo_create(target: *cairo_surface_t) ?*cairo_t;
pub extern "cairo" fn cairo_destroy(cr: *cairo_t) void;

pub extern "cairo" fn cairo_set_source_rgba(cr: *cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern "cairo" fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern "cairo" fn cairo_fill(cr: *cairo_t) void;
pub extern "cairo" fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;

// Pango functions
pub extern "pangocairo-1.0" fn pango_cairo_create_layout(cr: *cairo_t) ?*PangoLayout;
pub extern "pangocairo-1.0" fn pango_cairo_show_layout(cr: *cairo_t, layout: *PangoLayout) void;
pub extern "pangocairo-1.0" fn pango_cairo_context_set_resolution(context: *PangoContext, dpi: f64) void;

pub extern "pango-1.0" fn pango_font_description_from_string(str: [*:0]const u8) ?*PangoFontDescription;
pub extern "pango-1.0" fn pango_font_description_free(desc: *PangoFontDescription) void;

pub extern "pango-1.0" fn pango_layout_set_font_description(layout: *PangoLayout, desc: ?*PangoFontDescription) void;
pub extern "pango-1.0" fn pango_layout_set_text(layout: *PangoLayout, text: [*]const u8, length: c_int) void;
pub extern "pango-1.0" fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern "pango-1.0" fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: PangoEllipsizeMode) void;
pub extern "pango-1.0" fn pango_layout_get_pixel_size(layout: *PangoLayout, width: *c_int, height: *c_int) void;
pub extern "pango-1.0" fn pango_layout_get_context(layout: *PangoLayout) *PangoContext;

pub extern "pango-1.0" fn pango_context_get_metrics(
    context: *PangoContext,
    desc: ?*PangoFontDescription,
    language: ?*anyopaque,
) *PangoFontMetrics;

pub extern "pango-1.0" fn pango_font_metrics_get_ascent(metrics: *PangoFontMetrics) c_int;
pub extern "pango-1.0" fn pango_font_metrics_get_descent(metrics: *PangoFontMetrics) c_int;
pub extern "pango-1.0" fn pango_font_metrics_unref(metrics: *PangoFontMetrics) void;

// GLib functions
pub extern "gobject-2.0" fn g_object_unref(object: gpointer) void;
