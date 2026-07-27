const std = @import("std");

const app = @import("app.zig");
const cli = @import("cli.zig");
const commands = @import("commands.zig");
const platform = @import("platform.zig");

pub fn main(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = init.minimal.args.toSlice(arena) catch
        return @intFromEnum(app.ExitCode.err);

    const argv0: []const u8 = if (args.len > 0) args[0] else app.app_name;

    var argv: std.ArrayList([]const u8) = .empty;
    for (args[@min(1, args.len)..]) |arg| {
        argv.append(arena, arg) catch return @intFromEnum(app.ExitCode.err);
    }

    const opts = cli.parseArgs(arena, argv.items);

    platform.initConsole();

    if (opts.show_version) {
        const text = cli.versionText(arena) catch return @intFromEnum(app.ExitCode.err);
        platform.showInfo(io, text);
        return @intFromEnum(app.ExitCode.ok);
    }
    if (opts.show_help) {
        const text = cli.helpText(arena, argv0) catch return @intFromEnum(app.ExitCode.err);
        platform.showInfo(io, text);
        return @intFromEnum(app.ExitCode.ok);
    }
    if (opts.err) |message| {
        const help = cli.helpText(arena, argv0) catch "";
        const text = std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ message, help }) catch message;
        platform.showError(io, text);
        return @intFromEnum(app.ExitCode.usage);
    }

    const exe_path = platform.executablePath(arena, io, argv0);
    const exe_dir = std.fs.path.dirname(exe_path) orelse "";

    return @intFromEnum(commands.run(gpa, arena, io, opts, exe_dir));
}
