//! flecs C declarations for runtime-typed values.
//!
//! One module per area of flecs, matching the sections this file was split
//! from and the wrapper modules in `src/` that consume them. `src/c.zig`
//! lists every one and is what the ABI cross-check and the export manifest
//! walk — a module missing from that list is a module neither covers.

const std = @import("std");
const options = @import("zecs_options");
const core = @import("core.zig");

// Re-exported so a caller of this module sees one namespace rather than
// having to know which area a shared declaration came from.
pub const ecs_entity_t = core.ecs_entity_t;
pub const ecs_type_info_t = core.ecs_type_info_t;
pub const ecs_world_t = core.ecs_world_t;

/// Construct a value in existing storage, which must be large enough for the type.
/// Nonzero when `type` is not a type. The `_w_type_info` variants of these operations
/// take the type info directly and skip the lookup.
pub extern fn ecs_value_init(world: *const ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) c_int;

pub extern fn ecs_value_init_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, ptr: *anyopaque) c_int;

/// Allocate storage and construct a value in it. Null on failure. Release it with
/// `ecs_value_free`, which is the only thing that frees this allocation correctly.
pub extern fn ecs_value_new(world: *ecs_world_t, @"type": ecs_entity_t) ?*anyopaque;

pub extern fn ecs_value_new_w_type_info(world: *ecs_world_t, ti: *const ecs_type_info_t) ?*anyopaque;

pub extern fn ecs_value_fini_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, ptr: *anyopaque) c_int;

/// Destruct a value, leaving its storage alone.
pub extern fn ecs_value_fini(world: *const ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) c_int;

/// Destruct a value and release the storage `ecs_value_new` allocated for it.
pub extern fn ecs_value_free(world: *ecs_world_t, @"type": ecs_entity_t, ptr: *anyopaque) c_int;

pub extern fn ecs_value_copy_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, dst: *anyopaque, src: *const anyopaque) c_int;

/// Copy a value into constructed storage.
pub extern fn ecs_value_copy(world: *const ecs_world_t, @"type": ecs_entity_t, dst: *anyopaque, src: *const anyopaque) c_int;

pub extern fn ecs_value_move_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, dst: *anyopaque, src: *anyopaque) c_int;

/// Move a value into constructed storage, leaving the source constructed but empty.
pub extern fn ecs_value_move(world: *const ecs_world_t, @"type": ecs_entity_t, dst: *anyopaque, src: *anyopaque) c_int;

pub extern fn ecs_value_move_ctor_w_type_info(world: *const ecs_world_t, ti: *const ecs_type_info_t, dst: *anyopaque, src: *anyopaque) c_int;

/// Move a value into unconstructed storage.
pub extern fn ecs_value_move_ctor(world: *const ecs_world_t, @"type": ecs_entity_t, dst: *anyopaque, src: *anyopaque) c_int;
