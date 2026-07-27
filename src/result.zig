const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Failure = error{Failed};

pub const Err = struct {
    gpa: Allocator,
    msg: []const u8 = "",

    pub fn init(gpa: Allocator) Err {
        return .{ .gpa = gpa };
    }

    pub fn set(e: *Err, comptime fmt: []const u8, args: anytype) Failure {
        e.msg = std.fmt.allocPrint(e.gpa, fmt, args) catch "out of memory";
        return error.Failed;
    }
};
