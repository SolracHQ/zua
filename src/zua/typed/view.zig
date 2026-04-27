//! Typed table-backed views for decoding Lua tables into mutable Zig values.
//!
//! `TableView(T)` stores a raw `Table` handle alongside a heap-allocated typed
//! mirror of the table contents. This lets callbacks receive a typed view of a
//! Lua table, mutate `ref` directly, and optionally synchronize those changes
//! back into the underlying Lua value.
//!
//! The view is intended for use with table-strategy types where the table itself
//! is the Lua representation and a typed copy is convenient for mutation.

const Context = @import("../state/context.zig");
const Decoder = @import("../mapper/decode.zig").Decoder;
const Primitive = @import("../mapper/mapper.zig").Decoder.Primitive;
const Mapper = @import("../mapper/mapper.zig");
const Table = @import("../handlers/table.zig").Table;
const Meta = @import("../meta.zig");

/// Typed view over a Lua table for mutable Zig table-backed values.
///
/// `TableView(T)` decodes a Lua table into a heap-allocated typed copy of
/// `T` while preserving the raw table handle. Callers may mutate `ref` directly
/// and either return the view or call `sync()` to flush changes back into Lua.
pub fn TableView(comptime T: type) type {
    return struct {
        pub const ZUA_META = Meta.Table(@This(), .{}).withDecode(decode).withEncode(Table, encode);
        pub const __ZUA_TABLE_VIEW = @This();

        /// Underlying raw Lua table handle.
        handle: Table,

        /// Heap-backed typed mirror of the table contents.
        ref: *T,

        /// Decodes a Lua table primitive into a typed view.
        ///
        /// The decoded value is copied into the current `Context` arena and
        /// remains valid until the callback returns. The view holds the raw
        /// table handle so it can later synchronize the typed copy back into
        /// Lua.
        pub fn decode(ctx: *Context, primitive: Primitive) !?@This() {
            const table = switch (primitive) {
                .table => |tbl| tbl,
                else => return ctx.failWithFmtTyped(?@This(), "expected table but got {s}", .{@tagName(primitive)}),
            };

            const ptr = ctx.arena().create(T) catch return ctx.failTyped(?@This(), "out of memory");
            const index = switch (table.handle) {
                inline else => |idx| idx,
            };
            const value = try Decoder.decodeAt(ctx, index, T);
            ptr.* = value;
            return .{ .handle = table, .ref = ptr };
        }

        /// Encodes the view back into Lua by synchronizing its typed copy.
        ///
        /// This is automatically called when the view is returned from a
        /// callback, so callers only need to call `sync()` explicitly when the
        /// handle is mutated but not returned.
        pub fn encode(ctx: *Context, self: @This()) !?Table {
            try self.sync(ctx);
            return self.handle;
        }

        /// Writes the typed copy back into the underlying Lua table.
        ///
        /// This is useful for cases where the view is modified and the callback
        /// continues using the same Lua table before returning.
        pub fn sync(self: @This(), ctx: *Context) !void {
            try Mapper.Encoder.fillTable(ctx, self.handle, self.ref.*);
        }

        /// Creates a new view wrapper owning the same underlying Lua table handle.
        ///
        /// The returned view duplicates the table handle and shares the same typed
        /// mirror for the current callback frame.
        pub fn owned(self: @This()) @This() {
            return .{ .handle = self.handle.owned(), .ref = self.ref };
        }

        /// Converts the view's table handle to registry ownership.
        ///
        /// The typed mirror is copied into the state allocator so the view can
        /// outlive the current callback frame.
        pub fn takeOwnership(self: @This()) !@This() {
            const ref = self.handle.state.allocator.create(T) catch return error.OutOfMemory;
            ref.* = self.ref.*;
            return .{ .handle = self.handle.takeOwnership(), .ref = ref };
        }

        /// Releases the view and its resources.
        ///
        /// If the handle was registry-owned, the typed mirror is destroyed from
        /// the state allocator and the table handle is released.
        pub fn release(self: @This()) void {
            switch (self.handle.handle) {
                .registry_owned => self.handle.state.allocator.destroy(self.ref),
                else => {},
            }
            self.handle.release();
        }
    };
}

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
