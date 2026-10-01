// zig-xml (ianprime0509) benchmark: zig-xml <file-or-dir> <min-samples>
// A pull reader: one run reads every node (namespace-aware, its default), every attribute value
// (attributeValue: references expanded, whitespace normalized) and every text and CDATA node
// (text/cdata: newlines normalized); character and entity references are nodes of their own (one
// character each: zig-xml knows only the five predefined entities, as it does not support DTDs).
// UTF-8 input uses xml.Reader.Static over the buffer; a UTF-16 input (by its BOM) uses
// xml.Reader.Streaming over a fixed std.Io.Reader, the reader that decodes UTF-16. Built with
// -O ReleaseFast. Prints the check line (see ../run.sh) first, to stderr like the timing.
const std = @import("std");
const xml = @import("xml");
const common = @import("common.zig");

const Context = struct { gpa: std.mem.Allocator, docs: []const []u8, check: common.Check = .{}, failed: bool = false };

fn readAll(r: *xml.Reader, c: *common.Check, exact: bool) !void {
    var depth: usize = 0;
    while (true) {
        switch (try r.read()) {
            .eof => break,
            .element_start => {
                c.elements += 1;
                depth += 1;
                for (0..r.attributeCount()) |i| {
                    if (common.isXmlns(r.attributeName(i))) continue;
                    c.attributes += 1;
                    c.attr_chars += common.len(try r.attributeValue(i), exact);
                }
            },
            .element_end => depth -= 1,
            .text => if (depth > 0) {
                c.text_chars += common.len(try r.text(), exact);
            },
            .cdata => if (depth > 0) {
                c.text_chars += common.len(try r.cdata(), exact);
            },
            .character_reference, .entity_reference => if (depth > 0) {
                c.text_chars += 1;
            },
            else => {},
        }
    }
}

fn parseOne(gpa: std.mem.Allocator, data: []const u8, c: *common.Check, exact: bool) !void {
    if (common.isUtf16(data)) {
        var in: std.Io.Reader = .fixed(data);
        var reader: xml.Reader.Streaming = .init(gpa, &in, .{});
        defer reader.deinit();
        readAll(&reader.interface, c, exact) catch |err| {
            if (err == error.MalformedXml) std.debug.print("parse error: {t}\n", .{reader.interface.errorCode()});
            return err;
        };
    } else {
        var reader: xml.Reader.Static = .init(gpa, data, .{});
        defer reader.deinit();
        readAll(&reader.interface, c, exact) catch |err| {
            if (err == error.MalformedXml) std.debug.print("parse error: {t}\n", .{reader.interface.errorCode()});
            return err;
        };
    }
}

fn parseAll(ctx: *Context) void {
    var c: common.Check = .{};
    for (ctx.docs) |d| {
        parseOne(ctx.gpa, d, &c, false) catch {
            ctx.failed = true;
            return;
        };
    }
    ctx.check = c;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: zig-xml <file-or-dir> <min-samples>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const gpa = init.gpa;
    const in = try common.readInputs(io, gpa, args[1]);
    const min_samples = try std.fmt.parseInt(usize, args[2], 10);

    var check: common.Check = .{};
    for (in.docs.items) |d| {
        parseOne(gpa, d, &check, true) catch std.process.exit(1);
    }
    check.print();
    var ctx: Context = .{ .gpa = gpa, .docs = in.docs.items };
    const m = try common.measure(io, gpa, min_samples, &ctx, parseAll);
    if (ctx.failed) std.process.exit(1);
    common.report(m, in.total);
}
