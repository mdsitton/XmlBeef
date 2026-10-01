// Stand-in for nektro/zig-nio's AnyReadable, the only part of it nektro's zig-xml uses (Parser.zig
// pulls page-sized chunks with readAll). Keeps zig-nio's dependency tree (zig-sys-linux, zig-sys-darwin,
// ...) out of the benchmark build.
pub const AnyReadable = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, buffer: []u8) anyerror!usize,

    /// Reads until `buffer` is full or the input ends; returns the bytes read
    pub fn readAll(self: AnyReadable, buffer: []u8) anyerror!usize {
        var n: usize = 0;
        while (n < buffer.len) {
            const got = try self.readFn(self.context, buffer[n..]);
            if (got == 0) break;
            n += got;
        }
        return n;
    }
};
