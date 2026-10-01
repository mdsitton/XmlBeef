// Stand-in for nektro/zig-tracer, which nektro's zig-xml calls on entry to every parse function. The
// real library does nothing either unless a tracing backend is configured; this keeps its dependency
// tree (zig-sys-linux, zig-nfs, zig-nio, zig-time, ...) out of the benchmark build.
pub const Ctx = struct {
    pub inline fn end(_: Ctx) void {}
};

pub inline fn trace(comptime src: @import("std").builtin.SourceLocation, comptime fmt: []const u8, args: anytype) Ctx {
    _ = src;
    _ = fmt;
    _ = args;
    return .{};
}
