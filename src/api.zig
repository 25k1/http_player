const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const AudioEngine = @import("audio.zig").AudioEngine;
const jsonu = @import("json_util.zig");
const log = @import("log.zig");
const nvda = @import("nvda.zig");
const result = @import("result.zig");

const Err = result.Err;
const Failure = result.Failure;

const is_windows = builtin.os.tag == .windows;

const default_volume_percent = 100.0;
const min_volume_percent = 0.0;
const max_volume_percent = 100.0;

pub const json_mime = "application/json";

pub const Endpoint = struct {
    name: []const u8,
    description: []const u8,
};

pub const endpoints: []const Endpoint = &([_]Endpoint{
    .{
        .name = "POST /play",
        .description =
        \\Play a sound. Body: {"file_name": "<name>"}
        \\<name> is a path relative to the sounds directory, e.g.
        \\"done.wav" or "alerts/done.wav". Absolute paths and ".."
        \\are rejected.
        \\Optional "volume": 0-100 percent (default 100).
        ,
    },
} ++ (if (is_windows) [_]Endpoint{
    .{
        .name = "POST /speak",
        .description =
        \\Speak text through NVDA. Body: {"text": "<text>"}
        \\Requires NVDA to be running.
        ,
    },
} else [_]Endpoint{}));

pub const Context = struct {
    io: Io,
    sounds_dir: []const u8,
    audio: *AudioEngine,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    allow: ?[]const u8 = null,
};

const Route = struct {
    path: []const u8,
    method: std.http.Method,
    handler: *const fn (Allocator, Context, []const u8) Response,
};

const routes: []const Route = &([_]Route{
    .{ .path = "/play", .method = .POST, .handler = handlePlay },
} ++ (if (is_windows) [_]Route{
    .{ .path = "/speak", .method = .POST, .handler = handleSpeak },
} else [_]Route{}));

pub fn handle(
    gpa: Allocator,
    ctx: Context,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
) Response {
    const path = pathOf(target);

    var path_exists = false;
    for (routes) |route| {
        if (!std.mem.eql(u8, route.path, path)) continue;
        if (route.method == method) return route.handler(gpa, ctx, body);
        path_exists = true;
    }

    if (path_exists) return methodNotAllowed(gpa, method, path);
    return routeNotFound(gpa, method, path);
}

fn allowedMethods(gpa: Allocator, path: []const u8) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (routes) |route| {
        if (!std.mem.eql(u8, route.path, path)) continue;
        if (list.items.len != 0) list.appendSlice(gpa, ", ") catch return list.items;
        list.appendSlice(gpa, @tagName(route.method)) catch return list.items;
    }
    return list.items;
}

fn methodNotAllowed(gpa: Allocator, method: std.http.Method, path: []const u8) Response {
    const allow = allowedMethods(gpa, path);
    const message = std.fmt.allocPrint(gpa, "method not allowed: {s} {s} (allowed: {s})", .{
        @tagName(method), path, allow,
    }) catch "method not allowed";

    var response = sendError(gpa, 405, message);
    response.allow = allow;
    return response;
}

fn routeNotFound(gpa: Allocator, method: std.http.Method, path: []const u8) Response {
    const message = std.fmt.allocPrint(gpa, "route not found: {s} {s}", .{
        @tagName(method), path,
    }) catch "route not found";
    return sendError(gpa, 404, message);
}

fn pathOf(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return target[0..end];
}

const PlayRequest = struct {
    file_name: []const u8 = "",
    relative_path: []const u8 = "",
    volume_percent: f64 = default_volume_percent,

    fn gain(r: PlayRequest) f32 {
        return @floatCast(r.volume_percent / 100.0);
    }
};

fn relativeSoundPath(gpa: Allocator, name: []const u8) ?[]const u8 {
    if (name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return null;
    if (name[0] == '/' or name[0] == '\\') return null;
    if (is_windows and std.mem.indexOfScalar(u8, name, ':') != null) return null;

    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, name, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return null;
        if (is_windows and (part[part.len - 1] == '.' or part[part.len - 1] == ' ')) return null;
        parts.append(gpa, part) catch return null;
    }
    if (parts.items.len == 0) return null;

    return std.mem.join(gpa, std.fs.path.sep_str, parts.items) catch null;
}

fn parsePlayRequest(gpa: Allocator, body: []const u8, e: *Err) Failure!PlayRequest {
    const doc = try jsonu.parseObject(gpa, body, "invalid JSON", e);
    const reader = jsonu.Reader.init(doc.value, "");

    var request: PlayRequest = .{};
    try reader.requiredString("file_name", &request.file_name, e);
    request.relative_path = relativeSoundPath(gpa, request.file_name) orelse
        return e.set("invalid file_name", .{});

    try reader.number(
        "volume",
        &request.volume_percent,
        min_volume_percent,
        max_volume_percent,
        e,
    );
    return request;
}

fn handlePlay(gpa: Allocator, ctx: Context, body: []const u8) Response {
    var e = Err.init(gpa);

    const request = parsePlayRequest(gpa, body, &e) catch
        return sendError(gpa, 400, e.msg);
    log.info("play: {s}, volume {d}", .{ request.file_name, request.volume_percent });

    const path = std.fs.path.join(gpa, &.{ ctx.sounds_dir, request.relative_path }) catch
        return sendError(gpa, 500, "failed to play file");

    if (!isRegularFile(ctx.io, path) or !isInsideDir(ctx.io, ctx.sounds_dir, path)) {
        const message = std.fmt.allocPrint(gpa, "file not found: {s}", .{request.file_name}) catch
            return sendError(gpa, 404, "file not found");
        return sendError(gpa, 404, message);
    }
    if (!ctx.audio.play(path, request.gain())) {
        return sendError(gpa, 500, "failed to play file");
    }

    var fields = [_]jsonu.Field{
        .{ .key = "status", .value = .{ .string = "ok" } },
        .{ .key = "playing", .value = .{ .string = request.file_name } },
        .{ .key = "volume", .value = .{ .double = request.volume_percent } },
    };
    return sendJson(gpa, 200, &fields);
}

fn handleSpeak(gpa: Allocator, ctx: Context, body: []const u8) Response {
    var e = Err.init(gpa);

    const doc = jsonu.parseObject(gpa, body, "invalid JSON", &e) catch
        return sendError(gpa, 400, e.msg);

    var text: []const u8 = "";
    jsonu.Reader.init(doc.value, "").requiredString("text", &text, &e) catch
        return sendError(gpa, 400, e.msg);
    log.info("speak: {d} bytes of text", .{text.len});

    return switch (nvda.speak(gpa, ctx.io, text)) {
        .ok => blk: {
            var fields = [_]jsonu.Field{.{ .key = "status", .value = .{ .string = "ok" } }};
            break :blk sendJson(gpa, 200, &fields);
        },
        .not_running => sendError(gpa, 503, "NVDA is not running"),
        .failed => sendError(gpa, 502, "NVDA rejected the request"),
    };
}

fn isRegularFile(io: Io, path: []const u8) bool {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn isInsideDir(io: Io, dir: []const u8, path: []const u8) bool {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    const dir_len = Io.Dir.cwd().realPathFile(io, dir, &dir_buf) catch return false;
    const path_len = Io.Dir.cwd().realPathFile(io, path, &path_buf) catch return false;
    const real_dir = dir_buf[0..dir_len];
    const real_path = path_buf[0..path_len];

    if (real_dir.len == 0 or !std.mem.startsWith(u8, real_path, real_dir)) return false;
    if (std.fs.path.isSep(real_dir[real_dir.len - 1])) return real_path.len > real_dir.len;
    return real_path.len > real_dir.len + 1 and std.fs.path.isSep(real_path[real_dir.len]);
}

fn sendJson(gpa: Allocator, status: u16, fields: []jsonu.Field) Response {
    const body = jsonu.dumpObject(gpa, fields, 0) catch
        return .{ .status = 500, .body = "" };
    return .{ .status = status, .body = body };
}

fn sendError(gpa: Allocator, status: u16, message: []const u8) Response {
    var fields = [_]jsonu.Field{
        .{ .key = "status", .value = .{ .string = "error" } },
        .{ .key = "message", .value = .{ .string = message } },
    };
    return sendJson(gpa, status, &fields);
}
