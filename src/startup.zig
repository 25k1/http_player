const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const ConfigOverrides = @import("config.zig").ConfigOverrides;
const result = @import("result.zig");

const Err = result.Err;
const Failure = result.Failure;

const is_windows = builtin.os.tag == .windows;

pub fn registerApp(
    gpa: Allocator,
    io: std.Io,
    overrides: ConfigOverrides,
    e: *Err,
) Failure![]const u8 {
    if (!is_windows) return e.set("Not supported on this platform.", .{});
    return win.registerApp(gpa, io, overrides, e);
}

pub fn unregisterApp(gpa: Allocator, io: std.Io, e: *Err) Failure![]const u8 {
    if (!is_windows) return e.set("Not supported on this platform.", .{});
    return win.unregisterApp(gpa, io, e);
}

const win = if (is_windows) struct {
    const windows = std.os.windows;
    const HKEY = windows.HKEY;
    const LSTATUS = windows.LSTATUS;

    const run_key = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    const value_name = "HttpPlayer";

    const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
    const KEY_SET_VALUE = 0x0002;
    const REG_SZ = 1;
    const ERROR_SUCCESS = 0;
    const ERROR_FILE_NOT_FOUND = 2;

    extern "advapi32" fn RegCreateKeyExA(
        key: HKEY,
        sub_key: [*:0]const u8,
        reserved: u32,
        class: ?[*:0]const u8,
        options: u32,
        desired: u32,
        security: ?*anyopaque,
        out_key: *HKEY,
        disposition: ?*u32,
    ) callconv(.winapi) LSTATUS;

    extern "advapi32" fn RegOpenKeyExA(
        key: HKEY,
        sub_key: [*:0]const u8,
        options: u32,
        desired: u32,
        out_key: *HKEY,
    ) callconv(.winapi) LSTATUS;

    extern "advapi32" fn RegSetValueExA(
        key: HKEY,
        value_name: [*:0]const u8,
        reserved: u32,
        value_type: u32,
        data: [*]const u8,
        data_size: u32,
    ) callconv(.winapi) LSTATUS;

    extern "advapi32" fn RegDeleteValueA(
        key: HKEY,
        value_name: [*:0]const u8,
    ) callconv(.winapi) LSTATUS;

    extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) LSTATUS;

    extern "kernel32" fn GetModuleFileNameA(
        module: ?windows.HMODULE,
        filename: [*]u8,
        size: u32,
    ) callconv(.winapi) u32;

    fn quotedAbsolute(gpa: Allocator, io: std.Io, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) {
            return std.fmt.allocPrint(gpa, "\"{s}\"", .{path});
        }

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.process.currentPath(io, &buf) catch
            return std.fmt.allocPrint(gpa, "\"{s}\"", .{path});

        const absolute = try std.fs.path.join(gpa, &.{ buf[0..len], path });
        return std.fmt.allocPrint(gpa, "\"{s}\"", .{absolute});
    }

    fn buildCommand(gpa: Allocator, io: std.Io, overrides: ConfigOverrides) ![]const u8 {
        var exe: [windows.MAX_PATH]u8 = undefined;
        const len = GetModuleFileNameA(null, &exe, exe.len);

        var command: std.ArrayList(u8) = .empty;
        errdefer command.deinit(gpa);

        try command.print(gpa, "\"{s}\" --quiet", .{exe[0..len]});
        if (overrides.host) |host| try command.print(gpa, " --host {s}", .{host});
        if (overrides.port) |port| try command.print(gpa, " --port {d}", .{port});
        if (overrides.sounds_dir) |dir| {
            try command.print(gpa, " --sounds {s}", .{try quotedAbsolute(gpa, io, dir)});
        }
        if (overrides.config_path) |path| {
            try command.print(gpa, " --config {s}", .{try quotedAbsolute(gpa, io, path)});
        }
        if (overrides.log_path) |path| {
            try command.print(gpa, " --log {s}", .{try quotedAbsolute(gpa, io, path)});
        }
        return command.toOwnedSlice(gpa);
    }

    fn registerApp(
        gpa: Allocator,
        io: std.Io,
        overrides: ConfigOverrides,
        e: *Err,
    ) Failure![]const u8 {
        const command = buildCommand(gpa, io, overrides) catch
            return e.set("out of memory", .{});
        const command_z = gpa.dupeZ(u8, command) catch return e.set("out of memory", .{});

        var key: HKEY = undefined;
        const opened = RegCreateKeyExA(
            HKEY_CURRENT_USER,
            run_key,
            0,
            null,
            0,
            KEY_SET_VALUE,
            null,
            &key,
            null,
        );
        if (opened != ERROR_SUCCESS) {
            return e.set("Failed to open Run key. Code {d}", .{opened});
        }
        defer _ = RegCloseKey(key);

        const written = RegSetValueExA(
            key,
            value_name,
            0,
            REG_SZ,
            command_z.ptr,
            @intCast(command_z.len + 1),
        );
        if (written != ERROR_SUCCESS) {
            return e.set("Failed to write startup entry. Code {d}", .{written});
        }

        return std.fmt.allocPrint(gpa, "Registered to run at logon:\n{s}", .{command}) catch
            return e.set("out of memory", .{});
    }

    fn unregisterApp(_: Allocator, _: std.Io, e: *Err) Failure![]const u8 {
        var key: HKEY = undefined;
        const opened = RegOpenKeyExA(HKEY_CURRENT_USER, run_key, 0, KEY_SET_VALUE, &key);
        if (opened != ERROR_SUCCESS) {
            return e.set("Failed to open Run key. Code {d}", .{opened});
        }
        defer _ = RegCloseKey(key);

        const deleted = RegDeleteValueA(key, value_name);
        if (deleted == ERROR_FILE_NOT_FOUND) return "Not registered; nothing to remove.";
        if (deleted != ERROR_SUCCESS) {
            return e.set("Failed to remove startup entry. Code {d}", .{deleted});
        }
        return "Unregistered from logon startup.";
    }
} else struct {};
