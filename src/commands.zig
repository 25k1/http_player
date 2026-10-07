const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const app = @import("app.zig");
const AudioEngine = @import("audio.zig").AudioEngine;
const cli = @import("cli.zig");
const config = @import("config.zig");
const HttpServer = @import("http_server.zig").HttpServer;
const log = @import("log.zig");
const platform = @import("platform.zig");
const result = @import("result.zig");
const startup = @import("startup.zig");

const Err = result.Err;
const ExitCode = app.ExitCode;

const is_windows = builtin.os.tag == .windows;

pub fn run(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: cli.Options,
    exe_dir: []const u8,
) ExitCode {
    return switch (opts.command) {
        .generate_config => generateConfig(arena, io, opts, exe_dir),
        .stop => stop(io),
        .register => if (is_windows) registerApp(arena, io, opts.overrides) else unreachable,
        .unregister => if (is_windows) unregisterApp(arena, io) else unreachable,
        .none => serve(gpa, arena, io, opts, exe_dir),
    };
}

fn fail(io: Io, message: []const u8) ExitCode {
    platform.showError(io, message);
    return .err;
}

fn registerApp(arena: Allocator, io: Io, overrides: config.ConfigOverrides) ExitCode {
    var e = Err.init(arena);
    const message = startup.registerApp(arena, io, overrides, &e) catch return fail(io, e.msg);
    platform.showInfo(io, message);
    return .ok;
}

fn unregisterApp(arena: Allocator, io: Io) ExitCode {
    var e = Err.init(arena);
    const message = startup.unregisterApp(arena, io, &e) catch return fail(io, e.msg);
    platform.showInfo(io, message);
    return .ok;
}

fn generateConfig(arena: Allocator, io: Io, opts: cli.Options, exe_dir: []const u8) ExitCode {
    var e = Err.init(arena);

    const target = opts.overrides.config_path orelse
        std.fs.path.join(arena, &.{ exe_dir, app.config_file_name }) catch
        return fail(io, "out of memory");

    config.writeConfigFile(
        arena,
        io,
        target,
        config.configFromOverrides(opts.overrides),
        &e,
    ) catch return fail(io, e.msg);

    const message = std.fmt.allocPrint(arena, "Wrote config: {s}", .{target}) catch
        return fail(io, "out of memory");
    platform.showInfo(io, message);
    return .ok;
}

fn stop(io: Io) ExitCode {
    switch (platform.requestStop(io)) {
        .signalled => {
            platform.showInfo(io, "Stop requested.");
            return .ok;
        },
        .not_running => {
            platform.showInfo(io, app.app_name ++ " is not running.");
            return .ok;
        },
        .failed => {},
    }
    return fail(io, "Failed to signal the running instance.");
}

fn serve(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    opts: cli.Options,
    exe_dir: []const u8,
) ExitCode {
    var e = Err.init(arena);

    const cfg = config.resolveConfig(arena, io, opts.overrides, exe_dir, &e) catch {
        platform.showError(io, e.msg);
        return .usage;
    };

    var instance: platform.SingleInstanceGuard = .{};
    if (!instance.acquire()) {
        platform.showError(io, app.app_name ++ " is already running.");
        return .already_running;
    }
    defer instance.deinit();

    const log_opened = log.open(io, cfg.log_path);
    defer log.close();
    defer log.info("exited", .{});
    log.info("{s} {s} starting; sounds: {s}; listening on {s}:{d}", .{
        app.app_name, app.app_version, cfg.sounds_dir, cfg.host, cfg.port,
    });

    var audio: AudioEngine = .init(gpa, io);
    defer audio.deinit();
    if (!audio.start()) return failLogged(io, "Failed to initialise the audio engine.");

    var server: HttpServer = .init(gpa, io, cfg, &audio);
    defer server.deinit();
    server.bind(&e) catch return failLogged(io, e.msg);

    if (!opts.quiet) {
        const log_line = if (log_opened)
            std.fmt.allocPrint(arena, "Log: {s}", .{cfg.log_path})
        else
            std.fmt.allocPrint(arena, "Log: disabled, cannot open {s}", .{cfg.log_path});
        const banner = std.fmt.allocPrint(
            arena,
            "Serving sounds from: {s}\nListening on http://{s}:{d}\n{s}",
            .{ cfg.sounds_dir, cfg.host, cfg.port, log_line catch "" },
        ) catch return fail(io, "out of memory");
        platform.showInfo(io, banner);
    }

    platform.releaseConsole();

    var stopper: platform.StopListener = .{};
    stopper.start(io, &server, onStop);
    defer stopper.deinit();

    server.serve();
    log.info("shutting down", .{});
    return .ok;
}

fn failLogged(io: Io, message: []const u8) ExitCode {
    log.err("{s}", .{message});
    return fail(io, message);
}

fn onStop(context: ?*anyopaque) void {
    log.info("stop requested", .{});
    const server: *HttpServer = @ptrCast(@alignCast(context.?));
    server.stop();
}
