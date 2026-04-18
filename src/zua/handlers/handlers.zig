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

    pub fn owned(self: Handle, state: *State) Handle {
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
                return .{ .registry_owned = ref };
            },
        };
    }

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

    pub fn release(self: Handle, state: *State) void {
        switch (self) {
            .borrowed => {},
            .stack_owned => |idx| lua.remove(state.luaState, idx),
            .registry_owned => |ref| lua.unref(state.luaState, lua.REGISTRY_INDEX, ref),
        }
    }
};

pub const Table = @import("table.zig");
pub const Function = @import("function.zig");
pub const Userdata = @import("userdata.zig");

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
    const isHandler = T == Table or T == Function or T == Userdata;
    if (comptime !isHandler and @typeInfo(T) == .@"struct") {
        return @hasDecl(T, "__ZUA_TABLE_VIEW");
    }
    return isHandler;
}
