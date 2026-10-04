const std = @import("std");
const Io = std.Io;

const platform = @import("platform.zig");

const max_file_size = 4 * 1024 * 1024;
const max_line_size = 2048;
const truncation_mark = "...\n";
const backup_suffix = ".1";

const Level = enum {
    info,
    warn,
    err,

    fn label(level: Level) []const u8 {
        return switch (level) {
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }
};

var io: Io = undefined;
var mutex: Io.Mutex = .init;
var file: ?Io.File = null;
var offset: u64 = 0;
var path_buf: [std.fs.max_path_bytes]u8 = undefined;
var path: []const u8 = "";
var backup_path_buf: [std.fs.max_path_bytes + backup_suffix.len]u8 = undefined;
var backup_path: []const u8 = "";

/// Appends to `log_path`; when the file outgrows `max_file_size` it is moved to
/// `<log_path>.1` and a new one is started. Every line goes straight to the file
/// with no buffering, so the log stays complete if the process hangs or is killed.
pub fn open(log_io: Io, log_path: []const u8) bool {
    if (log_path.len == 0 or log_path.len > path_buf.len) return false;

    io = log_io;
    @memcpy(path_buf[0..log_path.len], log_path);
    path = path_buf[0..log_path.len];
    backup_path = std.fmt.bufPrint(&backup_path_buf, "{s}" ++ backup_suffix, .{path}) catch
        unreachable;

    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return false;
    offset = f.length(io) catch 0;
    file = f;
    return true;
}

pub fn close() void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (file) |f| f.close(io);
    file = null;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    write(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    write(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    write(.err, fmt, args);
}

/// Locks `m`, logging when it has to wait: a hang then shows up in the log as
/// "waiting" without a matching "acquired".
pub fn lockMutex(m: *Io.Mutex, lock_io: Io, name: []const u8) void {
    if (m.tryLock()) return;

    warn("{s} lock is busy, waiting", .{name});
    const started = Io.Clock.awake.now(lock_io);
    m.lockUncancelable(lock_io);
    info("{s} lock acquired after {d} ms", .{ name, elapsedMs(lock_io, started) });
}

/// Like `lockMutex`, but gives up after `timeout_ms`.
pub fn lockMutexTimeout(m: *Io.Mutex, lock_io: Io, name: []const u8, timeout_ms: i64) bool {
    if (m.tryLock()) return true;

    warn("{s} lock is busy, waiting", .{name});
    const started = Io.Clock.awake.now(lock_io);
    while (!m.tryLock()) {
        if (elapsedMs(lock_io, started) >= timeout_ms) {
            err("{s} lock not acquired in {d} ms, giving up", .{ name, timeout_ms });
            return false;
        }
        lock_io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    info("{s} lock acquired after {d} ms", .{ name, elapsedMs(lock_io, started) });
    return true;
}

pub fn elapsedMs(clock_io: Io, since: Io.Timestamp) i64 {
    return since.durationTo(Io.Clock.awake.now(clock_io)).toMilliseconds();
}

fn write(level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [max_line_size]u8 = undefined;
    var w: Io.Writer = .fixed(buf[0 .. buf.len - truncation_mark.len]);

    const t = platform.localTime(io);
    w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} ", .{
        t.year, t.month, t.day, t.hour, t.minute, t.second, t.millisecond,
    }) catch {};
    w.print("[{d}] {s} ", .{ std.Thread.getCurrentId(), level.label() }) catch {};

    const end = if (w.print(fmt, args)) |_| "\n" else |_| truncation_mark;
    const len = w.end;
    @memcpy(buf[len..][0..end.len], end);
    const line = buf[0 .. len + end.len];

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (file == null) return;
    if (offset + line.len > max_file_size) rotate();
    const f = file orelse return;

    f.writePositionalAll(io, line, offset) catch return;
    offset += line.len;
}

fn rotate() void {
    if (file) |f| f.close(io);
    file = null;

    Io.Dir.cwd().rename(path, .cwd(), backup_path, io) catch {};
    file = Io.Dir.cwd().createFile(io, path, .{}) catch null;
    offset = 0;
}
