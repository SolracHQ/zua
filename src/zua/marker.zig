//! Compile-time markers that selectively activate internal zua code paths.
//! Types tag themselves with `__ZUA_MARKER` to opt into specific behavior
//! (e.g. transparent wrapper unwrapping, closure vs cfunction encoding).

const std = @import("std");

pub const Marker = enum {
    /// `TableView(T)` transparent wrapper over a table-strategy type.
    /// Handlers and docs treat it as a transparent typed wrapper.
    table_view,
    /// `Object(T)` transparent wrapper over a userdata-strategy type.
    /// Docs unwrap it to reveal the underlying userdata type.
    userdata_wrapper,
    /// `MetaData` fallback wrapper that distinguishes explicit `ZUA_SHAPE` declarations from default metadata.
    default_guard,
    /// `Field(T, opts)` Readable and writable object field.
    object_field,
    /// `Value(T, opts)` Read-only object field.
    object_value,
    /// `Closure(T)` typed wrapper over a closure upvalue.
    closure_wrapper,
    /// Opaque handler type that should be skipped by the docs generator.
    /// Used on raw Lua value handles (Table, Function, Userdata, Handle).
    docs_ignore,
    /// Raw Lua handle type (Table, Function, Userdata, UpValue).
    /// Used to detect handler types in generic code.
    raw_handle,

    /// Returns the set of markers declared on `T`.
    pub fn markerOf(comptime T: type) std.EnumSet(Marker) {
        comptime {
            var result: std.EnumSet(Marker) = .initEmpty();
            switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => {
                    if (@hasDecl(T, "__ZUA_MARKER")) {
                        const marker = T.__ZUA_MARKER;
                        if (@TypeOf(marker) == Marker) {
                            result.insert(marker);
                        } else if (@TypeOf(marker) == std.EnumSet(Marker)) {
                            return marker;
                        }
                    }
                },
                else => {},
            }
            return result;
        }
    }

    /// Constructs an `EnumSet(Marker)` from a comptime slice of markers.
    pub fn new(comptime markers: []const Marker) std.EnumSet(Marker) {
        comptime {
            var set: std.EnumSet(Marker) = .initEmpty();
            for (markers) |m| {
                set.insert(m);
            }
            return set;
        }
    }

    /// Returns `true` if `T` has the `table_view` marker.
    pub fn isTableView(comptime T: type) bool {
        return comptime markerOf(T).contains(.table_view);
    }

    /// Returns `true` if `T` has the `userdata_wrapper` marker.
    pub fn isUserdataWrapper(comptime T: type) bool {
        return comptime markerOf(T).contains(.userdata_wrapper);
    }

    /// Returns `true` if `T` has the `default_guard` marker.
    pub fn isDefaultGuard(comptime T: type) bool {
        return comptime markerOf(T).contains(.default_guard);
    }

    /// Returns `true` if `T` has the `closure_wrapper` marker.
    pub fn isClosureWrapper(comptime T: type) bool {
        return comptime markerOf(T).contains(.closure_wrapper);
    }

    /// Returns `true` when `T` carries all the given markers.
    pub fn all(comptime T: type, comptime markers: []const Marker) bool {
        comptime {
            const set = markerOf(T);
            for (markers) |m| {
                if (!set.contains(m)) return false;
            }
            return true;
        }
    }

    /// Returns `true` when `T` carries at least one of the given markers.
    pub fn any(comptime T: type, comptime markers: []const Marker) bool {
        comptime {
            const set = markerOf(T);
            for (markers) |m| {
                if (set.contains(m)) return true;
            }
            return false;
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
