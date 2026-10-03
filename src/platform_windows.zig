const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const windows = std.os.windows;

const app = @import("app.zig");
const platform = @import("platform.zig");
const StopResult = platform.StopResult;

const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;

const instance_mutex_name = "Local\\HttpPlayer.SingleInstance";
const stop_event_name = "Local\\HttpPlayer.Stop";

const ERROR_ALREADY_EXISTS = 183;
const ERROR_FILE_NOT_FOUND = 2;
const EVENT_MODIFY_STATE = 0x0002;
const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF;
const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));
const MB_OK = 0x0;
const MB_ICONERROR = 0x10;
const MB_ICONINFORMATION = 0x40;
const WAIT_OBJECT_0 = 0;
const INFINITE: DWORD = 0xFFFFFFFF;
const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const FILE_SHARE_READ: DWORD = 0x1;
const FILE_SHARE_WRITE: DWORD = 0x2;
const OPEN_EXISTING: DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;

extern "kernel32" fn AttachConsole(process_id: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetStdHandle(std_handle: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetStdHandle(std_handle: DWORD, handle: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(
    console: HANDLE,
    info: *ConsoleScreenBufferInfo,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreateMutexA(
    attributes: ?*anyopaque,
    initial_owner: BOOL,
    name: [*:0]const u8,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateEventA(
    attributes: ?*anyopaque,
    manual_reset: BOOL,
    initial_state: BOOL,
    name: ?[*:0]const u8,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn OpenEventA(
    desired_access: DWORD,
    inherit_handle: BOOL,
    name: [*:0]const u8,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForMultipleObjects(
    count: DWORD,
    handles: [*]const HANDLE,
    wait_all: BOOL,
    milliseconds: DWORD,
) callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(
    filename: [*:0]const u16,
    desired_access: DWORD,
    share_mode: DWORD,
    security: ?*anyopaque,
    creation_disposition: DWORD,
    flags: DWORD,
    template: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn GetModuleFileNameW(
    module: ?windows.HMODULE,
    filename: [*]u16,
    size: DWORD,
) callconv(.winapi) DWORD;
extern "kernel32" fn GetLocalTime(time: *SystemTime) callconv(.winapi) void;
extern "user32" fn MessageBoxA(
    owner: ?HANDLE,
    text: [*:0]const u8,
    caption: [*:0]const u8,
    type: u32,
) callconv(.winapi) c_int;

const Coord = extern struct { x: i16, y: i16 };
const SmallRect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
const ConsoleScreenBufferInfo = extern struct {
    size: Coord,
    cursor_position: Coord,
    attributes: u16,
    window: SmallRect,
    maximum_window_size: Coord,
};
const SystemTime = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};

pub fn localTime(_: Io) platform.LocalTime {
    var t: SystemTime = undefined;
    GetLocalTime(&t);
    return .{
        .year = t.year,
        .month = @intCast(t.month),
        .day = @intCast(t.day),
        .hour = @intCast(t.hour),
        .minute = @intCast(t.minute),
        .second = @intCast(t.second),
        .millisecond = t.milliseconds,
    };
}

var has_console_flag = false;
var console_released = false;
var conout_handle: ?HANDLE = null;
var inherited_stdout: ?HANDLE = null;
var inherited_stderr: ?HANDLE = null;

pub fn hasConsole() bool {
    return has_console_flag;
}

pub fn releaseConsole() void {
    if (!has_console_flag) return;

    const stdin_handle = GetStdHandle(STD_INPUT_HANDLE);
    _ = SetStdHandle(STD_INPUT_HANDLE, null);
    _ = SetStdHandle(STD_OUTPUT_HANDLE, null);
    _ = SetStdHandle(STD_ERROR_HANDLE, null);

    closeHandle(conout_handle);
    closeHandle(stdin_handle);
    closeHandle(inherited_stdout);
    closeHandle(inherited_stderr);
    conout_handle = null;
    inherited_stdout = null;
    inherited_stderr = null;

    _ = FreeConsole();

    has_console_flag = false;
    console_released = true;
}

fn closeHandle(handle: ?HANDLE) void {
    const h = handle orelse return;
    if (h == windows.INVALID_HANDLE_VALUE) return;
    _ = CloseHandle(h);
}

pub fn showWithoutConsole(text: []const u8, is_error: bool) void {
    if (console_released) return;

    var buf: [16384]u8 = undefined;
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;

    const icon: u32 = if (is_error) MB_ICONERROR else MB_ICONINFORMATION;
    _ = MessageBoxA(null, buf[0..len :0].ptr, app.app_name, MB_OK | icon);
}

pub fn consoleNeedsLeadingNewline() bool {
    return !consoleAtLineStart();
}

fn consoleAtLineStart() bool {
    const console = GetStdHandle(STD_OUTPUT_HANDLE) orelse return true;
    if (console == windows.INVALID_HANDLE_VALUE) return true;

    var info: ConsoleScreenBufferInfo = undefined;
    if (!GetConsoleScreenBufferInfo(console, &info).toBool()) return true;
    return info.cursor_position.x == 0;
}

pub fn initConsole() void {
    if (has_console_flag) return;
    if (!AttachConsole(ATTACH_PARENT_PROCESS).toBool()) return;

    inherited_stdout = GetStdHandle(STD_OUTPUT_HANDLE);
    inherited_stderr = GetStdHandle(STD_ERROR_HANDLE);

    const conout = CreateFileW(
        std.unicode.utf8ToUtf16LeStringLiteral("CONOUT$"),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (conout != windows.INVALID_HANDLE_VALUE) {
        conout_handle = conout;
        _ = SetStdHandle(STD_OUTPUT_HANDLE, conout);
        _ = SetStdHandle(STD_ERROR_HANDLE, conout);
    }
    has_console_flag = true;
}

pub fn nativeExecutablePath(arena: Allocator, _: Io) ?[]const u8 {
    var buf: [windows.MAX_PATH]u16 = undefined;
    const len = GetModuleFileNameW(null, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..len]) catch null;
}

pub const SingleInstanceGuard = struct {
    mutex: ?HANDLE = null,

    pub fn acquire(self: *SingleInstanceGuard) bool {
        const handle = CreateMutexA(null, .TRUE, instance_mutex_name);
        const err = windows.GetLastError();

        if (handle == null or @intFromEnum(err) == ERROR_ALREADY_EXISTS) {
            if (handle) |h| windows.CloseHandle(h);
            return false;
        }
        self.mutex = handle;
        return true;
    }

    pub fn deinit(self: *SingleInstanceGuard) void {
        if (self.mutex) |h| windows.CloseHandle(h);
        self.mutex = null;
    }
};

pub fn requestStop(_: Io) StopResult {
    const event = OpenEventA(EVENT_MODIFY_STATE, .FALSE, stop_event_name) orelse {
        return if (@intFromEnum(windows.GetLastError()) == ERROR_FILE_NOT_FOUND)
            .not_running
        else
            .failed;
    };
    defer windows.CloseHandle(event);

    return if (SetEvent(event).toBool()) .signalled else .failed;
}

pub const StopListener = struct {
    stop_event: ?HANDLE = null,
    quit_event: ?HANDLE = null,
    thread: ?std.Thread = null,
    context: ?*anyopaque = null,
    callback: ?*const fn (?*anyopaque) void = null,

    pub fn start(
        self: *StopListener,
        _: Io,
        context: ?*anyopaque,
        callback: *const fn (?*anyopaque) void,
    ) void {
        self.context = context;
        self.callback = callback;
        self.stop_event = CreateEventA(null, .TRUE, .FALSE, stop_event_name);
        self.quit_event = CreateEventA(null, .TRUE, .FALSE, null);
        if (self.stop_event == null or self.quit_event == null) return;

        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch null;
    }

    fn worker(self: *StopListener) void {
        const handles = [_]HANDLE{ self.stop_event.?, self.quit_event.? };
        if (WaitForMultipleObjects(2, &handles, .FALSE, INFINITE) == WAIT_OBJECT_0) {
            if (self.callback) |cb| cb(self.context);
        }
    }

    pub fn deinit(self: *StopListener) void {
        if (self.quit_event) |h| _ = SetEvent(h);
        if (self.thread) |thread| thread.join();
        self.thread = null;

        if (self.stop_event) |h| windows.CloseHandle(h);
        if (self.quit_event) |h| windows.CloseHandle(h);
        self.stop_event = null;
        self.quit_event = null;
    }
};
