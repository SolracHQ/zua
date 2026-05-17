comptime {
    _ = @import("core/executor.zig");
    _ = @import("core/state.zig");
    _ = @import("core/context.zig");
    _ = @import("handlers/any/function.zig");
    _ = @import("handlers/any/table.zig");
    _ = @import("handlers/any/userdata.zig");
    _ = @import("handlers/typed/fn.zig");
    _ = @import("handlers/typed/object.zig");
    _ = @import("handlers/typed/table_view.zig");
    _ = @import("mapper/decode/errors.zig");
    _ = @import("mapper/decode/primitives.zig");
    _ = @import("mapper/decode/varargs.zig");
    _ = @import("mapper/decode/pop.zig");
    _ = @import("shape/fn.zig");
    _ = @import("shape/closure.zig");
    _ = @import("shape/table.zig");
    _ = @import("shape/object.zig");
    _ = @import("shape/ptr.zig");
    _ = @import("shape/list.zig");
    _ = @import("shape/alias.zig");
    _ = @import("shape/modifier.zig");
    _ = @import("handlers/ownership.zig");
    _ = @import("docs/generate.zig");
}
