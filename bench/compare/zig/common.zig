// Shared by the Zig harnesses: the measurement rule, input loading and the check line.
const std = @import("std");

pub const Measurement = struct { median_ns: f64, samples: usize, converged: bool };

/// The shared rule (see ../run.sh): warm up for at least 1 s, then time single runs until at least
/// `min_samples` were taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples.
/// (From KdlBeef's bench/compare/zig/bench.zig.)
pub fn measure(io: std.Io, gpa: std.mem.Allocator, min_samples: usize, context: anytype, comptime op: fn (@TypeOf(context)) void) !Measurement {
    const warm = std.Io.Timestamp.now(io, .awake);
    while (true) {
        op(context);
        if (warm.untilNow(io, .awake).nanoseconds >= std.time.ns_per_s) break;
    }
    var samples: std.ArrayList(f64) = .empty;
    defer samples.deinit(gpa);
    var sorted: std.ArrayList(f64) = .empty;
    defer sorted.deinit(gpa);
    const start = std.Io.Timestamp.now(io, .awake);
    while (true) {
        const t0 = std.Io.Timestamp.now(io, .awake);
        op(context);
        try samples.append(gpa, @floatFromInt(t0.untilNow(io, .awake).nanoseconds));
        sorted.clearRetainingCapacity();
        try sorted.appendSlice(gpa, samples.items);
        std.mem.sort(f64, sorted.items, {}, std.sort.asc(f64));
        const n = sorted.items.len;
        const median = if (n % 2 == 1) sorted.items[n / 2] else (sorted.items[n / 2 - 1] + sorted.items[n / 2]) / 2;
        if (n >= min_samples) {
            var within: usize = 0;
            for (samples.items) |s| {
                if (s >= median * 0.9 and s <= median * 1.1) within += 1;
            }
            if (@as(f64, @floatFromInt(within)) >= 0.6 * @as(f64, @floatFromInt(n)))
                return .{ .median_ns = median, .samples = n, .converged = true };
        }
        if (n >= 1000 or start.untilNow(io, .awake).nanoseconds >= 10 * std.time.ns_per_s)
            return .{ .median_ns = median, .samples = n, .converged = false };
    }
}

pub fn report(m: Measurement, total: usize) void {
    const ms = m.median_ns / 1e6;
    const mbps = @as(f64, @floatFromInt(total)) / 1048576.0 / (ms / 1000.0);
    std.debug.print("{d:.3} ms/op {d:.1} MB/s (n={d}, {s})\n", .{ ms, mbps, m.samples, if (m.converged) "converged" else "capped" });
}

/// elements, attributes (without namespace declarations), attribute value chars, text chars
pub const Check = struct {
    elements: u64 = 0,
    attributes: u64 = 0,
    attr_chars: u64 = 0,
    text_chars: u64 = 0,

    pub fn print(c: Check) void {
        std.debug.print("check: {d} {d} {d} {d}\n", .{ c.elements, c.attributes, c.attr_chars, c.text_chars });
    }
};

/// Length in code points when checking, in bytes when timing (the timed runs only need to touch it)
pub fn len(s: []const u8, exact: bool) u64 {
    if (!exact) return s.len;
    var n: u64 = 0;
    for (s) |b| n += @intFromBool(b & 0xC0 != 0x80);
    return n;
}

pub fn isXmlns(name: []const u8) bool {
    return std.mem.eql(u8, name, "xmlns") or std.mem.startsWith(u8, name, "xmlns:");
}

pub fn isUtf16(data: []const u8) bool {
    return data.len >= 2 and ((data[0] == 0xFF and data[1] == 0xFE) or (data[0] == 0xFE and data[1] == 0xFF));
}

pub const Inputs = struct {
    docs: std.ArrayList([]u8) = .empty,
    total: usize = 0,
};

/// A file, or every file under a directory (one run parses each once; the order does not matter)
pub fn readInputs(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Inputs {
    var in: Inputs = .{};
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const data = try cwd.readFileAlloc(io, path, gpa, .unlimited);
            try in.docs.append(gpa, data);
            in.total += data.len;
            return in;
        },
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try entry.dir.readFileAlloc(io, entry.basename, gpa, .unlimited);
        try in.docs.append(gpa, data);
        in.total += data.len;
    }
    return in;
}
