const std = @import("std");
const zua = @import("zua");

// This example is the embedder path: we create the Lua VM ourselves and
// register globals into it. This is one of the two ways to use zua;
// the other is the shared-library path (a dylib loaded via require()).
//
// Globals are defined as structs with ZUA_SHAPE = Shape.Fn. A Shape.Fn
// struct bundles a Zig impl function with its documentation metadata.
// When the struct is pushed to Lua (via addGlobals), zua reads the
// ZUA_SHAPE, pushes the function, and attaches the metadata. The same
// metadata feeds the Docs generator, so stubs stay in sync with the
// implementation without extra wiring.

const makeApp = @import("lib/config.zig").makeApp;

// docs is a struct-with-ZUA_SHAPE, same pattern as makeApp.
// The impl function calls Docs.generateGlobals which walks the
// types and bindings we pass and produces a complete ---@meta
// stub file. The caller (stubs.lua) writes that string to disk.
const docs = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Generate Lua stubs for the app-config module.",
    });
    fn impl(ctx: *zua.Context) ![]const u8 {
        return zua.Docs.generateGlobals(ctx.arena(), .{
            .makeApp = makeApp{},
            .docs = docs{},
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);

    // State.init creates a fresh Lua VM. This is the "I own the runtime"
    // path. The other approach (State.libState) attaches to an existing
    // VM from a host that calls require().
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    // addGlobals writes each field into Lua's global table.
    // After this, Lua code can call makeApp and docs.
    // Each value is an instance of a ZUA_SHAPE struct, so zua
    // knows to push them as Lua functions automatically.
    try state.addGlobals(&ctx, .{
        .makeApp = makeApp{},
        .docs = docs{},
    });

    if (args.len < 2) {
        std.debug.print("usage: app-config <file.lua>\n", .{});
        return;
    }

    var executor = zua.Executor{};
    executor.execute(&ctx, .{ .code = .{ .file = args[1] } }) catch {
        if (ctx.err) |msg| std.debug.print("{s}\n", .{msg});
    };
}
