//! Handler utilities for Lua values.
//!
//! This module defines the normalized ownership model used by typed Lua
//! handles such as `Table` and `Function`. Handlers are lightweight wrappers
//! around Lua values that preserve stack and registry lifetime semantics while
//! exposing a small API for safe interaction from Zig.

pub const Handlers = @This();

/// Ownership mode used when decoding Lua values into handle types.
///
/// This enum distinguishes borrowed stack references from owned handles that
/// must be cleaned up explicitly. It is used by the `Table`, `Function`, and
/// `Userdata` handler implementations to manage lifetime correctly across the
/// Lua API.
const lua = @import("../../lua/lua.zig");
const State = @import("../state/state.zig");
const Mapper = @import("../mapper/mapper.zig");
const Marker = @import("../marker.zig");

pub const Handle = union(enum) {
    /// The handle references a Lua value on the current stack frame.
    /// No cleanup is required because the caller owns the stack slot.
    borrowed: lua.StackIndex,

    /// The handle owns a stack slot and must be released when no longer needed.
    /// This is typically used for values created by a helper function that pushes
    /// a new Lua value onto the stack.
    stack_owned: lua.StackIndex,

    /// The handle owns a registry reference and must call `release()` to free it.
    /// This mode is used for values that need to survive beyond the current
    /// Lua stack frame.
    registry_owned: c_int,

    /// Creates a registry-owned copy of this handle.
    ///
    /// Regardless of the handle's current ownership mode, the returned handle
    /// always uses `registry_owned`. The original handle is not consumed and
    /// must still be released separately.
    ///
    /// Arguments:
    /// - state: The Zua state whose Lua registry receives the copy.
    ///
    /// Returns:
    /// - Handle: A new registry-owned handle pointing to the same Lua value.
    pub fn owned(self: Handle, state: *State) Handle {
        return switch (self) {
            .registry_owned => |ref| {
                _ = lua.rawGetI(state.luaState, lua.REGISTRY_INDEX, ref);
                const new_ref = lua.ref(state.luaState, lua.REGISTRY_INDEX);
                return .{ .registry_owned = new_ref };
            },
            .borrowed => |idx| {
                lua.pushValue(state.luaState, idx);
                const ref = lua.ref(state.luaState, lua.REGISTRY_INDEX);
                return .{ .registry_owned = ref };
            },
            .stack_owned => |idx| {
                lua.pushValue(state.luaState, idx);
                const ref = lua.ref(state.luaState, lua.REGISTRY_INDEX);
                return .{ .registry_owned = ref };
            },
        };
    }

    /// Converts this handle to registry ownership, consuming the original.
    ///
    /// After this call the caller should use the returned handle and stop
    /// using `self`. For `stack_owned` handles the stack slot is removed;
    /// for `borrowed` handles the value is copied into the registry.
    ///
    /// Arguments:
    /// - state: The Zua state whose Lua registry takes ownership.
    ///
    /// Returns:
    /// - Handle: A registry-owned handle. Pass-through when already registry-owned.
    pub fn takeOwnership(self: Handle, state: *State) Handle {
        return switch (self) {
            .registry_owned => self,
            .borrowed => |idx| {
                lua.pushValue(state.luaState, idx);
                const ref = lua.ref(state.luaState, lua.REGISTRY_INDEX);
                return .{ .registry_owned = ref };
            },
            .stack_owned => |idx| {
                lua.pushValue(state.luaState, idx);
                const ref = lua.ref(state.luaState, lua.REGISTRY_INDEX);
                lua.remove(state.luaState, idx);
                return .{ .registry_owned = ref };
            },
        };
    }

    /// Releases the resources held by this handle.
    ///
    /// - `registry_owned`: unrefs the Lua registry reference.
    /// - `stack_owned`: removes the value from the Lua stack.
    /// - `borrowed`: no-op, the caller owns the stack slot.
    ///
    /// Arguments:
    /// - state: The Zua state whose Lua resources are released.
    pub fn release(self: Handle, state: *State) void {
        switch (self) {
            .borrowed => {},
            .stack_owned => |idx| lua.remove(state.luaState, idx),
            .registry_owned => |ref| lua.unref(state.luaState, lua.REGISTRY_INDEX, ref),
        }
    }
};

/// Unbound Lua value handles. `Any.Table` works with any Lua table, `Any.Function` with any
/// Lua function, `Any.Userdata` with any Lua userdata. They provide typed operations (get/set/call)
/// but are not bound to a specific Zig type like the wrappers in `Typed`.
///
/// > NOTE: even though `get` and `set` accept any type at the call site, the decode and encode
/// > paths are comptime-generated from the requested type. There is no runtime dispatch, no boxing,
/// > and no overhead compared to calling the encoder or decoder directly.
pub const Any = struct {
    pub const Table = @import("any/table.zig");
    pub const Function = @import("any/function.zig");
    pub const Userdata = @import("any/userdata.zig");
};

/// Typed wrappers over Lua values that are bound to a specific Zig type.
/// `Typed.Fn(ins, outs)` wraps a Lua function with typed arguments and returns.
/// `Typed.Object(T)` wraps a Lua userdata containing a `T` payload.
/// `Typed.TableView(T)` wraps a Lua table as a typed mutable view of `T`.
pub const Typed = struct {
    pub const Fn = @import("typed/fn.zig").Fn;
    pub const Object = @import("typed/object.zig").Object;
    pub const TableView = @import("typed/table_view.zig").TableView;
};

/// Recursively takes ownership of any handler values within `value`.
///
/// - `Table`, `Function`, `Userdata`, and `TableView(T)` handlers are converted to registry-
///   owned values via their `takeOwnership()` methods.
/// - Struct fields are processed recursively.
/// - Tagged union branches are processed recursively.
/// - All other values are returned unchanged.
pub fn takeOwnership(value: anytype) void {
    const T = @TypeOf(value.*);

    if (comptime Mapper.isOptional(T)) {
        if (value.*) |inner| takeOwnership(&inner);
        return;
    }

    if (comptime isHandlerType(T)) {
        value.* = value.*.takeOwnership();
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                takeOwnership(&@field(value.*, field.name));
            }
        },
        .@"union" => {
            switch (value.*) {
                inline else => |branch| {
                    takeOwnership(&branch);
                },
            }
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (comptime Mapper.isStringValueType(T)) return;
                const slice = value.*;
                for (0..slice.len) |i| {
                    takeOwnership(&slice[i]);
                }
            }
        },
        .array => |array_info| {
            inline for (0..array_info.len) |i| {
                takeOwnership(&value.*[i]);
            }
        },
        else => {},
    }
}

/// Recursively releases any handler values within `value`.
///
/// - `Table`, `Function`, `Userdata`, and `TableView(T)` handlers are released via their
///   `release()` methods.
/// - Struct fields are processed recursively.
/// - Tagged union branches are processed recursively.
/// - All other values are ignored.
pub fn release(comptime T: type, value: T) void {
    if (comptime Mapper.isOptional(T)) {
        if (value) |inner| release(Mapper.optionalChild(T), inner);
        return;
    }

    if (comptime isHandlerType(T)) {
        value.release();
        return;
    }

    switch (@typeInfo(T)) {
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                release(@TypeOf(@field(value, field.name)), @field(value, field.name));
            }
        },
        .@"union" => {
            switch (value) {
                inline else => |branch| release(@TypeOf(branch), branch),
            }
        },
        .pointer => |ptr_info| {
            if (ptr_info.size == .slice) {
                if (comptime Mapper.isStringValueType(T)) return;
                for (value) |item| release(@TypeOf(item), item);
                return;
            }
            return;
        },
        .array => {
            for (value) |item| release(@TypeOf(item), item);
        },
        else => {},
    }
}

fn isHandlerType(comptime T: type) bool {
    return T == Any.Table or T == Any.Function or T == Any.Userdata or Marker.isTableView(T);
}

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
