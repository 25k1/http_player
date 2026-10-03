const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const api = @import("api.zig");
const app = @import("app.zig");
const config = @import("config.zig");
const result = @import("result.zig");

const Err = result.Err;
const Failure = result.Failure;

const is_windows = builtin.os.tag == .windows;

pub const Command = enum {
    none,
    generate_config,
    stop,
    register,
    unregister,
};

pub const Options = struct {
    overrides: config.ConfigOverrides = .{},
    command: Command = .none,
    show_help: bool = false,
    show_version: bool = false,
    quiet: bool = false,
    err: ?[]const u8 = null,
};

const CommandSpec = struct {
    name: []const u8,
    description: []const u8,
    command: Command,
};

const commands: []const CommandSpec = &([_]CommandSpec{
    .{
        .name = "generate-config",
        .description =
        \\Write a starter {config} and exit. Values come from
        \\--port/--sounds if given, otherwise the defaults.
        \\An existing file is never overwritten.
        ,
        .command = .generate_config,
    },
    .{ .name = "stop", .description = "Stop the running instance and exit.", .command = .stop },
} ++ (if (is_windows) [_]CommandSpec{
    .{
        .name = "register",
        .description = "Start automatically at every logon (current user only).",
        .command = .register,
    },
    .{
        .name = "unregister",
        .description = "Remove the logon entry and exit.",
        .command = .unregister,
    },
} else [_]CommandSpec{}));

const ApplyFn = *const fn (*Options, []const u8, *Err) Failure!void;

const OptionSpec = struct {
    long_name: []const u8,
    short_name: []const u8,
    value_name: []const u8,
    description: []const u8,
    apply: ApplyFn,

    fn takesValue(o: OptionSpec) bool {
        return o.value_name.len != 0;
    }
};

fn applyHost(opts: *Options, value: []const u8, e: *Err) Failure!void {
    if (value.len == 0) return e.set("Host must not be empty", .{});
    opts.overrides.host = value;
}

fn applyPort(opts: *Options, value: []const u8, e: *Err) Failure!void {
    const port = std.fmt.parseInt(i64, value, 10) catch
        return e.set("Invalid port: {s}", .{value});
    if (port < app.min_port or port > app.max_port) {
        return e.set("Invalid port: {s}", .{value});
    }
    opts.overrides.port = port;
}

fn applySounds(opts: *Options, value: []const u8, _: *Err) Failure!void {
    opts.overrides.sounds_dir = value;
}

fn applyConfig(opts: *Options, value: []const u8, _: *Err) Failure!void {
    opts.overrides.config_path = value;
}

fn applyLog(opts: *Options, value: []const u8, e: *Err) Failure!void {
    if (value.len == 0) return e.set("Log file must not be empty", .{});
    opts.overrides.log_path = value;
}

fn applyQuiet(opts: *Options, _: []const u8, _: *Err) Failure!void {
    opts.quiet = true;
}

fn applyHelp(opts: *Options, _: []const u8, _: *Err) Failure!void {
    opts.show_help = true;
}

fn applyVersion(opts: *Options, _: []const u8, _: *Err) Failure!void {
    opts.show_version = true;
}

const options: []const OptionSpec = &.{
    .{
        .long_name = "--host",
        .short_name = "",
        .value_name = "<addr>",
        .description =
        \\Address to bind to (default {host}). Use 0.0.0.0 to
        \\accept connections from other machines.
        ,
        .apply = applyHost,
    },
    .{
        .long_name = "--port",
        .short_name = "",
        .value_name = "<n>",
        .description = "Port to listen on (default {port}).",
        .apply = applyPort,
    },
    .{
        .long_name = "--sounds",
        .short_name = "",
        .value_name = "<dir>",
        .description =
        \\Directory to play sound files from
        \\(default: '{sounds}' next to the executable).
        ,
        .apply = applySounds,
    },
    .{
        .long_name = "--config",
        .short_name = "-c",
        .value_name = "<file>",
        .description =
        \\Load settings from a JSON config file (default:
        \\'{config}' next to the executable, if present).
        \\Command-line options override config values.
        ,
        .apply = applyConfig,
    },
    .{
        .long_name = "--log",
        .short_name = "",
        .value_name = "<file>",
        .description = "Log file (default: '{log}' next to the executable).",
        .apply = applyLog,
    },
    .{
        .long_name = "--quiet",
        .short_name = "-q",
        .value_name = "",
        .description =
        \\Don't show the startup banner. Errors are still
        \\shown. Added automatically by 'register'.
        ,
        .apply = applyQuiet,
    },
    .{
        .long_name = "--version",
        .short_name = "-v",
        .value_name = "",
        .description = "Show version and exit.",
        .apply = applyVersion,
    },
    .{
        .long_name = "--help",
        .short_name = "-h",
        .value_name = "",
        .description = "Show this help and exit.",
        .apply = applyHelp,
    },
};

pub fn parseArgs(gpa: Allocator, argv: []const []const u8) Options {
    var opts: Options = .{};
    var e = Err.init(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (!std.mem.startsWith(u8, arg, "-")) {
            const found = for (commands) |spec| {
                if (std.mem.eql(u8, spec.name, arg)) break spec;
            } else {
                _ = e.set("Unknown command: {s}", .{arg}) catch {};
                opts.err = e.msg;
                return opts;
            };
            if (opts.command != .none) {
                opts.err = "Only one command may be given";
                return opts;
            }
            opts.command = found.command;
            continue;
        }

        var option: ?OptionSpec = null;
        var value: ?[]const u8 = null;
        for (options) |candidate| {
            if (std.mem.eql(u8, arg, candidate.long_name) or
                (candidate.short_name.len != 0 and std.mem.eql(u8, arg, candidate.short_name)))
            {
                option = candidate;
                break;
            }
            if (inlineValue(arg, candidate.long_name)) |inlined| {
                option = candidate;
                value = inlined;
                break;
            }
        }

        const spec = option orelse {
            _ = e.set("Unknown option: {s}", .{arg}) catch {};
            opts.err = e.msg;
            return opts;
        };

        if (spec.takesValue() and value == null) {
            if (i + 1 >= argv.len) {
                _ = e.set("Missing value for {s}", .{arg}) catch {};
                opts.err = e.msg;
                return opts;
            }
            i += 1;
            value = argv[i];
        }
        if (!spec.takesValue() and value != null) {
            _ = e.set("{s} does not take a value", .{spec.long_name}) catch {};
            opts.err = e.msg;
            return opts;
        }

        spec.apply(&opts, value orelse "", &e) catch {
            opts.err = e.msg;
            return opts;
        };

        if (opts.show_help or opts.show_version) return opts;
    }
    return opts;
}

fn inlineValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg.len <= name.len or arg[name.len] != '=') return null;
    return arg[name.len + 1 ..];
}

const Row = struct {
    label: []const u8,
    description: []const u8,
};

const indent = 2;
const gap = 2;

fn expand(gpa: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var port_buf: [24]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{app.default_port}) catch unreachable;

    const tokens = [_]struct { []const u8, []const u8 }{
        .{ "{app}", app.app_name },
        .{ "{port}", port_text },
        .{ "{sounds}", app.sounds_dir_name },
        .{ "{config}", app.config_file_name },
        .{ "{log}", app.log_file_name },
        .{ "{host}", app.default_host },
    };

    var out: []const u8 = try gpa.dupe(u8, text);
    for (tokens) |token| {
        const needle, const value = token;
        if (std.mem.indexOf(u8, out, needle) == null) continue;

        const size = std.mem.replacementSize(u8, out, needle, value);
        const replaced = try gpa.alloc(u8, size);
        _ = std.mem.replace(u8, out, needle, value, replaced);
        gpa.free(out);
        out = replaced;
    }
    return out;
}

fn optionLabel(gpa: Allocator, option: OptionSpec) Allocator.Error![]const u8 {
    var label: std.ArrayList(u8) = .empty;
    errdefer label.deinit(gpa);

    if (option.short_name.len != 0) {
        try label.appendSlice(gpa, option.short_name);
        try label.appendSlice(gpa, ", ");
    }
    try label.appendSlice(gpa, option.long_name);
    if (option.takesValue()) {
        try label.append(gpa, ' ');
        try label.appendSlice(gpa, option.value_name);
    }
    return label.toOwnedSlice(gpa);
}

fn appendSection(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    title: []const u8,
    rows: []const Row,
    width: usize,
) Allocator.Error!void {
    if (rows.len == 0) return;

    try out.append(gpa, '\n');
    try out.appendSlice(gpa, title);
    try out.append(gpa, '\n');

    for (rows) |row| {
        try out.appendNTimes(gpa, ' ', indent);
        try out.appendSlice(gpa, row.label);
        try out.appendNTimes(gpa, ' ', width + gap - row.label.len);

        var lines = std.mem.splitScalar(u8, row.description, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try out.appendNTimes(gpa, ' ', indent + width + gap);
            try out.appendSlice(gpa, line);
            try out.append(gpa, '\n');
            first = false;
        }
    }
}

pub fn helpText(gpa: Allocator, argv0: []const u8) Allocator.Error![]const u8 {
    const exe = std.fs.path.basename(argv0);

    var command_rows: std.ArrayList(Row) = .empty;
    defer command_rows.deinit(gpa);
    for (commands) |spec| {
        try command_rows.append(gpa, .{
            .label = spec.name,
            .description = try expand(gpa, spec.description),
        });
    }

    var option_rows: std.ArrayList(Row) = .empty;
    defer option_rows.deinit(gpa);
    for (options) |spec| {
        try option_rows.append(gpa, .{
            .label = try optionLabel(gpa, spec),
            .description = try expand(gpa, spec.description),
        });
    }

    var endpoint_rows: std.ArrayList(Row) = .empty;
    defer endpoint_rows.deinit(gpa);
    for (api.endpoints) |spec| {
        try endpoint_rows.append(gpa, .{
            .label = spec.name,
            .description = try expand(gpa, spec.description),
        });
    }

    var width: usize = 0;
    for ([_][]const Row{ command_rows.items, option_rows.items, endpoint_rows.items }) |rows| {
        for (rows) |row| width = @max(width, row.label.len);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(gpa, "{s} {s} - HTTP-controlled sound player\n\n" ++
        "Usage: {s} [command] [options]\n\n" ++
        "Runs an HTTP server that plays sound files from a local directory.\n", .{
        app.app_name, app.app_version, exe,
    });

    try appendSection(gpa, &out, "Commands:", command_rows.items, width);
    try appendSection(gpa, &out, "Options:", option_rows.items, width);
    try appendSection(gpa, &out, "Endpoints:", endpoint_rows.items, width);
    return out.toOwnedSlice(gpa);
}

pub fn versionText(gpa: Allocator) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(gpa, "{s} {s}", .{ app.app_name, app.app_version });
}
