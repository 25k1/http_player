const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const AudioEngine = @import("audio.zig").AudioEngine;
const jsonu = @import("json_util.zig");
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
        \\<name> is a file inside the sounds directory.
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
    volume_percent: f64 = default_volume_percent,

    fn gain(r: PlayRequest) f32 {
        return @floatCast(r.volume_percent / 100.0);
    }
};

fn isSafeFileName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (is_windows and name.len >= 2 and name[1] == ':') return false;
    return true;
}

fn parsePlayRequest(gpa: Allocator, body: []const u8, e: *Err) Failure!PlayRequest {
    const doc = try jsonu.parseObject(gpa, body, "invalid JSON", e);
    const reader = jsonu.Reader.init(doc.value, "");

    var request: PlayRequest = .{};
    try reader.requiredString("file_name", &request.file_name, e);
    if (!isSafeFileName(request.file_name)) return e.set("invalid file_name", .{});

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

    const path = std.fs.path.join(gpa, &.{ ctx.sounds_dir, request.file_name }) catch
        return sendError(gpa, 500, "failed to play file");

    if (!isRegularFile(ctx.io, path)) {
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
