const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const is_windows = builtin.os.tag == .windows;

pub const detail = if (is_windows)
    @import("platform_windows.zig")
else
    @import("platform_posix.zig");

pub const StopResult = enum { signalled, not_running, failed };

pub const LocalTime = struct {
    year: u16 = 0,
    month: u8 = 0,
    day: u8 = 0,
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
    millisecond: u16 = 0,
};

pub const localTime = detail.localTime;
pub const requestStop = detail.requestStop;
pub const initConsole = detail.initConsole;
pub const releaseConsole = detail.releaseConsole;
pub const StopListener = detail.StopListener;
pub const SingleInstanceGuard = detail.SingleInstanceGuard;

var first_write = true;

fn show(io: Io, text: []const u8, is_error: bool) void {
    if (!detail.hasConsole()) {
        detail.showWithoutConsole(text, is_error);
        return;
    }

    const file = if (is_error) Io.File.stderr() else Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;

    if (first_write) {
        first_write = false;
        if (detail.consoleNeedsLeadingNewline()) w.writeAll("\n") catch {};
    }
    w.print("{s}\n", .{text}) catch {};
    w.flush() catch {};
}

pub fn showInfo(io: Io, text: []const u8) void {
    show(io, text, false);
}

pub fn showError(io: Io, text: []const u8) void {
    show(io, text, true);
}

pub fn executablePath(arena: Allocator, io: Io, argv0: []const u8) []const u8 {
    if (detail.nativeExecutablePath(arena, io)) |self| return self;
    return realpath(arena, io, argv0) orelse argv0;
}

fn realpath(arena: Allocator, io: Io, path: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = Io.Dir.cwd().realPathFile(io, path, &buf) catch return null;
    return arena.dupe(u8, buf[0..len]) catch null;
}
