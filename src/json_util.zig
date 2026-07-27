const std = @import("std");
const Allocator = std.mem.Allocator;

const result = @import("result.zig");
const Err = result.Err;
const Failure = result.Failure;

const must_not_be_empty = "must not be empty";

pub const Parsed = std.json.Parsed(std.json.Value);

pub fn parseObject(gpa: Allocator, text: []const u8, what: []const u8, e: *Err) Failure!Parsed {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| {
        return e.set("{s}: {s}", .{ what, @errorName(err) });
    };
    if (parsed.value != .object) {
        parsed.deinit();
        return e.set("{s}: expected a JSON object", .{what});
    }
    return parsed;
}

pub const Reader = struct {
    obj: std.json.ObjectMap,
    label: []const u8 = "",

    pub fn init(value: std.json.Value, label: []const u8) Reader {
        return .{ .obj = value.object, .label = label };
    }

    fn message(r: Reader, key: []const u8, what: []const u8, e: *Err) Failure {
        return e.set("{s}'{s}' {s}", .{ r.label, key, what });
    }

    pub fn string(r: Reader, key: []const u8, out: *[]const u8, e: *Err) Failure!void {
        const value = r.obj.get(key) orelse return;
        if (value != .string) return r.message(key, "must be a string", e);
        if (value.string.len == 0) return r.message(key, must_not_be_empty, e);
        out.* = value.string;
    }

    pub fn integer(r: Reader, key: []const u8, out: *i64, min: i64, max: i64, e: *Err) Failure!void {
        const value = r.obj.get(key) orelse return;
        if (value != .integer) return r.message(key, "must be an integer", e);

        const found = value.integer;
        if (found < min or found > max) {
            const what = try allocFmt(e, "out of range ({d}-{d}): {d}", .{ min, max, found });
            return r.message(key, what, e);
        }
        out.* = found;
    }

    pub fn number(r: Reader, key: []const u8, out: *f64, min: f64, max: f64, e: *Err) Failure!void {
        const value = r.obj.get(key) orelse return;
        const parsed: f64 = switch (value) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return r.message(key, "must be a number", e),
        };

        if (!(parsed >= min and parsed <= max)) {
            var min_buf: [32]u8 = undefined;
            var max_buf: [32]u8 = undefined;
            var got_buf: [32]u8 = undefined;
            const what = try allocFmt(e, "out of range ({s}-{s}): {s}", .{
                formatDouble(&min_buf, min),
                formatDouble(&max_buf, max),
                formatDouble(&got_buf, parsed),
            });
            return r.message(key, what, e);
        }
        out.* = parsed;
    }

    pub fn requiredString(r: Reader, key: []const u8, out: *[]const u8, e: *Err) Failure!void {
        const value = r.obj.get(key) orelse
            return e.set("{s}missing string field '{s}'", .{ r.label, key });
        if (value != .string) return e.set("{s}missing string field '{s}'", .{ r.label, key });
        if (value.string.len == 0) return r.message(key, must_not_be_empty, e);
        out.* = value.string;
    }
};

fn allocFmt(e: *Err, comptime fmt: []const u8, args: anytype) Failure![]const u8 {
    return std.fmt.allocPrint(e.gpa, fmt, args) catch return e.set("out of memory", .{});
}

fn formatDouble(buf: []u8, value: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch "?";
}

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    double: f64,
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

pub fn dumpObject(gpa: Allocator, fields: []Field, indent: usize) Allocator.Error![]u8 {
    std.mem.sort(Field, fields, {}, struct {
        fn lessThan(_: void, a: Field, b: Field) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    const pretty = indent > 0;
    w.writeByte('{') catch return error.OutOfMemory;
    for (fields, 0..) |field, i| {
        if (i != 0) w.writeByte(',') catch return error.OutOfMemory;
        if (pretty) {
            w.writeByte('\n') catch return error.OutOfMemory;
            w.splatByteAll(' ', indent) catch return error.OutOfMemory;
        }
        writeString(w, field.key) catch return error.OutOfMemory;
        w.writeAll(if (pretty) ": " else ":") catch return error.OutOfMemory;
        writeValue(w, field.value) catch return error.OutOfMemory;
    }
    if (pretty and fields.len != 0) w.writeByte('\n') catch return error.OutOfMemory;
    w.writeByte('}') catch return error.OutOfMemory;

    return out.toOwnedSlice();
}

fn writeValue(w: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .string => |s| try writeString(w, s),
        .integer => |i| try w.print("{d}", .{i}),
        .double => |d| try writeDouble(w, d),
    }
}

fn writeDouble(w: *std.Io.Writer, value: f64) !void {
    if (std.math.isNan(value) or std.math.isInf(value)) return w.writeAll("null");

    var buf: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try w.writeAll(text);
    if (std.mem.indexOfAny(u8, text, ".eE") == null) try w.writeAll(".0");
}

fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}
