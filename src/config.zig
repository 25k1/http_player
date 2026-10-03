const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const app = @import("app.zig");
const jsonu = @import("json_util.zig");
const result = @import("result.zig");

const Err = result.Err;
const Failure = result.Failure;

pub const ConfigOverrides = struct {
    host: ?[]const u8 = null,
    port: ?i64 = null,
    sounds_dir: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
};

pub const Config = struct {
    host: []const u8 = app.default_host,
    port: i64 = app.default_port,
    sounds_dir: []const u8 = "",
    log_path: []const u8 = "",
};

fn loadConfigFile(
    arena: Allocator,
    io: Io,
    path: []const u8,
    cfg: *Config,
    e: *Err,
) Failure!void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch
        return e.set("Cannot open config file: {s}", .{path});

    const what = std.fmt.allocPrint(arena, "Invalid config JSON ({s})", .{path}) catch
        return e.set("out of memory", .{});

    const doc = try jsonu.parseObject(arena, text, what, e);
    const reader = jsonu.Reader.init(doc.value, "config ");

    try reader.string("host", &cfg.host, e);
    try reader.integer("port", &cfg.port, app.min_port, app.max_port, e);

    var sounds: []const u8 = "";
    try reader.string("sounds", &sounds, e);
    if (sounds.len != 0) {
        cfg.sounds_dir = relativeToFile(arena, path, sounds) catch
            return e.set("out of memory", .{});
    }

    var log: []const u8 = "";
    try reader.string("log", &log, e);
    if (log.len != 0) {
        cfg.log_path = relativeToFile(arena, path, log) catch
            return e.set("out of memory", .{});
    }
}

fn relativeToFile(arena: Allocator, file: []const u8, target: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(target)) return target;
    return join(arena, std.fs.path.dirname(file) orelse "", target);
}

fn applyOverrides(cfg: *Config, overrides: ConfigOverrides) void {
    if (overrides.host) |host| cfg.host = host;
    if (overrides.port) |port| cfg.port = port;
    if (overrides.sounds_dir) |dir| cfg.sounds_dir = dir;
    if (overrides.log_path) |log| cfg.log_path = log;
}

const ConfigSource = struct {
    path: []const u8 = "",
    required: bool = false,
};

fn configSource(arena: Allocator, io: Io, overrides: ConfigOverrides, exe_dir: []const u8) ConfigSource {
    if (overrides.config_path) |path| return .{ .path = path, .required = true };

    const implicit = join(arena, exe_dir, app.config_file_name) catch return .{};
    if (!exists(io, implicit)) return .{};
    return .{ .path = implicit, .required = false };
}

pub fn resolveConfig(
    arena: Allocator,
    io: Io,
    overrides: ConfigOverrides,
    exe_dir: []const u8,
    e: *Err,
) Failure!Config {
    var cfg: Config = .{};

    const source = configSource(arena, io, overrides, exe_dir);
    if (source.path.len != 0) {
        if (source.required and !exists(io, source.path)) {
            return e.set("Config file not found: {s}", .{source.path});
        }
        try loadConfigFile(arena, io, source.path, &cfg, e);
    }

    applyOverrides(&cfg, overrides);
    if (cfg.sounds_dir.len == 0) {
        cfg.sounds_dir = join(arena, exe_dir, app.sounds_dir_name) catch
            return e.set("out of memory", .{});
    }
    if (cfg.log_path.len == 0) {
        cfg.log_path = join(arena, exe_dir, app.log_file_name) catch
            return e.set("out of memory", .{});
    }
    return cfg;
}

pub fn configFromOverrides(overrides: ConfigOverrides) Config {
    var cfg: Config = .{};
    applyOverrides(&cfg, overrides);
    if (cfg.sounds_dir.len == 0) cfg.sounds_dir = app.sounds_dir_name;
    return cfg;
}

pub fn writeConfigFile(
    arena: Allocator,
    io: Io,
    path: []const u8,
    cfg: Config,
    e: *Err,
) Failure!void {
    if (exists(io, path)) {
        return e.set("File already exists (not overwritten): {s}", .{path});
    }

    var fields = [_]jsonu.Field{
        .{ .key = "host", .value = .{ .string = cfg.host } },
        .{ .key = "port", .value = .{ .integer = cfg.port } },
        .{ .key = "sounds", .value = .{ .string = genericPath(arena, cfg.sounds_dir) } },
    };
    const text = jsonu.dumpObject(arena, &fields, 2) catch
        return e.set("out of memory", .{});

    const body = std.fmt.allocPrint(arena, "{s}\n", .{text}) catch
        return e.set("out of memory", .{});

    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch
        return e.set("Cannot write config file: {s}", .{path});
}

fn genericPath(arena: Allocator, path: []const u8) []const u8 {
    if (builtin.os.tag != .windows) return path;

    const copy = arena.dupe(u8, path) catch return path;
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

fn join(arena: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (dir.len == 0) return name;
    return std.fs.path.join(arena, &.{ dir, name });
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
