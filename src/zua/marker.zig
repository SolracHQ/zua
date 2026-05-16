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
};

/// Returns the set of markers declared on `T`.
///
/// Only struct, union, enum, and opaque types can carry markers.
/// All other types return an empty set.
///
/// Arguments:
/// - T: The type to inspect.
///
/// Returns:
/// - `std.EnumSet(Marker)`: The set of markers attached to `T`.
///
/// Example:
/// ```zig
/// if (markerOf(MyType).contains(.table_view)) { ... }
/// ```
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
///
/// Arguments:
/// - markers: A comptime slice of `Marker` values.
///
/// Returns:
/// - `std.EnumSet(Marker)`: A set containing all the given markers.
///
/// Example:
/// ```zig
/// const set = Marker.new(&.{ .table_view, .userdata_wrapper });
/// ```
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

/// Returns `true` when `T` carries all the given markers.
///
/// Arguments:
/// - T: The type to inspect.
/// - markers: A comptime slice of `Marker` values to check.
///
/// Returns:
/// - `bool`: `true` when every marker in `markers` is present on `T`.
///
/// Example:
/// ```zig
/// if (Marker.all(T, &.{.table_view, .userdata_wrapper})) { ... }
/// ```
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
///
/// Arguments:
/// - T: The type to inspect.
/// - markers: A comptime slice of `Marker` values to check.
///
/// Returns:
/// - `bool`: `true` when any marker in `markers` is present on `T`.
///
/// Example:
/// ```zig
/// if (Marker.any(T, &.{.table_view, .userdata_wrapper})) { ... }
/// ```
pub fn any(comptime T: type, comptime markers: []const Marker) bool {
    comptime {
        const set = markerOf(T);
        for (markers) |m| {
            if (set.contains(m)) return true;
        }
        return false;
    }
}

test {
    std.testing.refAllDecls(@This());
}
