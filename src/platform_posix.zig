const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const platform = @import("platform.zig");
const StopResult = platform.StopResult;

extern "c" fn flock(fd: c_int, operation: c_int) c_int;
extern "c" fn localtime_r(time: *const std.c.time_t, result: *Tm) ?*Tm;

/// Leading fields of `struct tm`, common to glibc, musl and Darwin.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

const LOCK_EX = 2;
const LOCK_NB = 4;

fn lockFilePath(buf: []u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "/tmp/http-player-{d}.lock", .{std.c.getuid()}) catch
        unreachable;
}

pub fn hasConsole() bool {
    return true;
}

pub fn showWithoutConsole(_: []const u8, _: bool) void {}

pub fn consoleNeedsLeadingNewline() bool {
    return false;
}

pub fn localTime(io: Io) platform.LocalTime {
    const ns = Io.Clock.real.now(io).toNanoseconds();
    const seconds: std.c.time_t = @intCast(@divFloor(ns, std.time.ns_per_s));

    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return .{};
    return .{
        .year = @intCast(tm.year + 1900),
        .month = @intCast(tm.mon + 1),
        .day = @intCast(tm.mday),
        .hour = @intCast(tm.hour),
        .minute = @intCast(tm.min),
        .second = @intCast(tm.sec),
        .millisecond = @intCast(@mod(@divFloor(ns, std.time.ns_per_ms), 1000)),
    };
}

pub fn initConsole() void {}

pub fn releaseConsole() void {}

pub fn nativeExecutablePath(arena: Allocator, io: Io) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = Io.Dir.cwd().readLink(io, "/proc/self/exe", &buf) catch return null;
    return arena.dupe(u8, buf[0..len]) catch null;
}

pub const SingleInstanceGuard = struct {
    fd: c_int = -1,

    pub fn acquire(self: *SingleInstanceGuard) bool {
        var path_buf: [64]u8 = undefined;
        const path = lockFilePath(&path_buf);

        const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return false;

        if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
            _ = std.c.close(fd);
            return false;
        }
        self.fd = fd;

        var pid_buf: [32]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buf, "{d}\n", .{std.c.getpid()}) catch return true;
        if (std.c.ftruncate(fd, 0) == 0) {
            _ = std.c.pwrite(fd, pid.ptr, pid.len, 0);
        }
        return true;
    }

    pub fn deinit(self: *SingleInstanceGuard) void {
        if (self.fd >= 0) _ = std.c.close(self.fd);
        self.fd = -1;
    }
};

pub fn requestStop(_: Io) StopResult {
    var path_buf: [64]u8 = undefined;
    const path = lockFilePath(&path_buf);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return .not_running;
    defer _ = std.c.close(fd);

    var buf: [32]u8 = std.mem.zeroes([32]u8);
    const count = std.c.read(fd, &buf, buf.len - 1);
    if (count <= 0) return .not_running;

    const text = std.mem.trim(u8, buf[0..@intCast(count)], " \t\r\n\x00");
    const pid = std.fmt.parseInt(std.c.pid_t, text, 10) catch return .not_running;
    if (pid <= 0) return .not_running;

    if (std.c.kill(pid, @enumFromInt(0)) != 0) return .not_running;
    return if (std.c.kill(pid, .TERM) == 0) .signalled else .failed;
}

var stop_requested = std.atomic.Value(bool).init(false);

fn handleStopSignal(_: std.posix.SIG) callconv(.c) void {
    stop_requested.store(true, .seq_cst);
}

pub const StopListener = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(true),
    io: ?Io = null,
    context: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque) void = null,

    pub fn start(
        self: *StopListener,
        io: Io,
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque) void,
    ) void {
        self.io = io;
        self.context = context;
        self.callback = callback;
        stop_requested.store(false, .seq_cst);

        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = handleStopSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
        std.posix.sigaction(.TERM, &action, null);

        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch null;
    }

    fn worker(self: *StopListener) void {
        while (self.running.load(.seq_cst)) {
            if (stop_requested.load(.seq_cst)) {
                if (self.callback) |cb| cb(self.context);
                return;
            }
            if (self.io) |io| io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
    }

    pub fn deinit(self: *StopListener) void {
        std.posix.sigaction(.INT, &.{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);
        std.posix.sigaction(.TERM, &.{
            .handler = .{ .handler = std.posix.SIG.DFL },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        }, null);

        self.running.store(false, .seq_cst);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
};
