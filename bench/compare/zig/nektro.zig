// nektro/zig-xml benchmark: nektro-zig-xml <file-or-dir> <min-samples>
// xml.parse into its Document (a compact node table with interned strings; references and CDATA are
// folded into text, comments dropped). It trims spaces and newlines from both ends of every run of
// character data, so its text figure is not compared ("-"). It reads through zig-nio's AnyReadable, supplied here over the
// in-memory buffer (shim/nio.zig); its tracer calls go to a no-op (shim/tracer.zig), as they do in the
// real library without a tracing backend. It expects UTF-8: a UTF-16 input exits 3 (n/a). Built with
// -O ReleaseFast. Prints the check line (see ../run.sh) first, to stderr like the timing.
const std = @import("std");
const xml = @import("xml");
const nio = @import("nio");
const common = @import("common.zig");

/// The in-memory input, as the reader xml.parse takes
const Slice = struct {
    data: []const u8,
    pos: usize = 0,

    pub const ReadError = error{};

    pub fn anyReadable(self: *Slice) nio.AnyReadable {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const self: *Slice = @ptrCast(@alignCast(context));
        const n = @min(buffer.len, self.data.len - self.pos);
        @memcpy(buffer[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

const Context = struct { gpa: std.mem.Allocator, docs: []const []u8, failed: bool = false };

fn walk(element: xml.Element, doc: *const xml.Document, c: *common.Check) void {
    c.elements += 1;
    if (element.attributes != .empty) {
        const handle = doc.data[@intFromEnum(element.attributes)..];
        const count = handle[0] / 2;
        for (0..count) |i| {
            const attr: xml.Attribute = @bitCast(handle[1..][2 * i ..][0..2].*);
            if (common.isXmlns(attr.name.slice())) continue;
            c.attributes += 1;
            c.attr_chars += common.len(attr.value.slice(), true);
        }
    }
    for (element.children()) |child| {
        switch (child.v()) {
            .element => |e| walk(e, doc, c),
            .text => |t| c.text_chars += common.len(t.slice(), true),
            .pi => {},
        }
    }
}

fn parseOne(gpa: std.mem.Allocator, data: []const u8, c: ?*common.Check) !void {
    var input: Slice = .{ .data = data };
    var doc = try xml.parse(gpa, "", &input);
    defer doc.deinit();
    if (c) |check| {
        doc.acquire();
        defer doc.release();
        walk(doc.root, &doc, check);
    }
}

fn parseAll(ctx: *Context) void {
    for (ctx.docs) |d| {
        parseOne(ctx.gpa, d, null) catch {
            ctx.failed = true;
            return;
        };
    }
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: nektro-zig-xml <file-or-dir> <min-samples>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const gpa = init.gpa;
    const in = try common.readInputs(io, gpa, args[1]);
    const min_samples = try std.fmt.parseInt(usize, args[2], 10);
    for (in.docs.items) |d| {
        if (common.isUtf16(d)) {
            std.debug.print("nektro/zig-xml expects UTF-8\n", .{});
            std.process.exit(3);
        }
    }

    var check: common.Check = .{};
    for (in.docs.items) |d| {
        parseOne(gpa, d, &check) catch |err| {
            std.debug.print("parse error: {t}\n", .{err});
            std.process.exit(1);
        };
    }
    // Text is not compared: zig-xml trims spaces and newlines from both ends of every run of
    // character data (addOpStringToList), so whitespace-only text vanishes and mixed content
    // loses the spaces around child elements and references
    std.debug.print("check: {d} {d} {d} -\n", .{ check.elements, check.attributes, check.attr_chars });
    var ctx: Context = .{ .gpa = gpa, .docs = in.docs.items };
    const m = try common.measure(io, gpa, min_samples, &ctx, parseAll);
    if (ctx.failed) std.process.exit(1);
    common.report(m, in.total);
}
