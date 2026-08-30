//! Layout config mapping (stateless).
//!
//! The historical closed layout enum (types.Layout / layout_table) and the
//! name lookups it powered (layoutFromString / defaultLayout / config-side
//! canonicalLayout) were replaced by registry-name resolution: config layout
//! names resolve to `tiling_modules` registry indices at seed time in the
//! tiling layer (engine.layoutByName). This facade no longer carries a layout
//! type; it exists only to keep the module list stable.
