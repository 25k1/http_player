const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const api = @import("api.zig");
const AudioEngine = @import("audio.zig").AudioEngine;
const Config = @import("config.zig").Config;
const log = @import("log.zig");
const platform = @import("platform.zig");
const result = @import("result.zig");

const Err = result.Err;
const Failure = result.Failure;

const head_buffer_size = 16 * 1024;
const write_buffer_size = 16 * 1024;
const body_buffer_size = 8 * 1024;
const max_body_size = 1 << 20;

pub const HttpServer = struct {
    gpa: Allocator,
    io: Io,
    config: Config,
    audio: *AudioEngine,
    listener: ?Io.net.Server = null,
    listening: std.atomic.Value(bool) = .init(false),
    next_connection_id: std.atomic.Value(u64) = .init(1),
    next_request_id: std.atomic.Value(u64) = .init(1),

    pub fn init(gpa: Allocator, io: Io, cfg: Config, audio: *AudioEngine) HttpServer {
        return .{ .gpa = gpa, .io = io, .config = cfg, .audio = audio };
    }

    pub fn bind(self: *HttpServer, e: *Err) Failure!void {
        const port = std.math.cast(u16, self.config.port) orelse
            return e.set("Failed to bind {s}:{d}", .{ self.config.host, self.config.port });

        const address = Io.net.IpAddress.parse(self.config.host, port) catch
            return e.set("Failed to bind {s}:{d}", .{ self.config.host, self.config.port });

        self.listener = address.listen(self.io, .{ .reuse_address = true }) catch
            return e.set("Failed to bind {s}:{d}", .{ self.config.host, self.config.port });

        self.listening.store(true, .seq_cst);
    }

    pub fn serve(self: *HttpServer) void {
        const listener = &(self.listener orelse return);

        while (true) {
            const stream = listener.accept(self.io) catch |err| {
                if (self.listening.load(.seq_cst)) {
                    log.err("accept failed: {s}; server stops", .{@errorName(err)});
                }
                break;
            };

            const conn = self.gpa.create(Connection) catch {
                log.err("out of memory for a connection", .{});
                stream.close(self.io);
                continue;
            };
            conn.* = .{
                .server = self,
                .stream = stream,
                .id = self.next_connection_id.fetchAdd(1, .monotonic),
            };

            const thread = std.Thread.spawn(.{}, Connection.run, .{conn}) catch |err| {
                log.err("conn {d}: cannot spawn thread: {s}", .{ conn.id, @errorName(err) });
                stream.close(self.io);
                self.gpa.destroy(conn);
                continue;
            };
            thread.detach();
        }
    }

    pub fn stop(self: *HttpServer) void {
        self.closeListener();
    }

    pub fn deinit(self: *HttpServer) void {
        self.closeListener();
        self.listener = null;
    }

    fn closeListener(self: *HttpServer) void {
        if (!self.listening.swap(false, .seq_cst)) return;

        const listener = &(self.listener orelse return);
        const stream: Io.net.Stream = .{ .socket = listener.socket };
        stream.shutdown(self.io, .both) catch {};
        listener.socket.close(self.io);
    }
};

const Connection = struct {
    server: *HttpServer,
    stream: Io.net.Stream,
    id: u64,

    fn run(conn: *Connection) void {
        const server = conn.server;
        const io = server.io;
        log.info("conn {d}: opened", .{conn.id});
        defer {
            log.info("conn {d}: closed", .{conn.id});
            conn.stream.close(io);
            server.gpa.destroy(conn);
        }

        var read_buffer: [head_buffer_size]u8 = undefined;
        var write_buffer: [write_buffer_size]u8 = undefined;
        var reader = conn.stream.reader(io, &read_buffer);
        var writer = conn.stream.writer(io, &write_buffer);

        var http: std.http.Server = .init(&reader.interface, &writer.interface);

        while (true) {
            var request = http.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    log.warn("conn {d}: cannot read request: {s}", .{ conn.id, @errorName(err) });
                }
                return;
            };
            conn.respond(&request) catch |err| {
                log.warn("conn {d}: cannot respond: {s}", .{ conn.id, @errorName(err) });
                return;
            };
        }
    }

    fn respond(conn: *Connection, request: *std.http.Server.Request) !void {
        const server = conn.server;

        var arena: std.heap.ArenaAllocator = .init(server.gpa);
        defer arena.deinit();
        const gpa = arena.allocator();

        const method = request.head.method;
        const target = try gpa.dupe(u8, request.head.target);
        const content_length = request.head.content_length;
        const transfer_encoding = request.head.transfer_encoding;

        const id = server.next_request_id.fetchAdd(1, .monotonic);
        const started = Io.Clock.awake.now(server.io);
        log.info("req {d} (conn {d}): {s} {s}", .{ id, conn.id, @tagName(method), target });

        var body_buffer: [body_buffer_size]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);

        const body = if (content_length != null or transfer_encoding == .chunked)
            body_reader.allocRemaining(gpa, .limited(max_body_size)) catch ""
        else
            "";

        const response = api.handle(
            gpa,
            .{
                .io = server.io,
                .sounds_dir = server.config.sounds_dir,
                .audio = server.audio,
            },
            method,
            target,
            body,
        );

        var headers: [2]std.http.Header = .{
            .{ .name = "content-type", .value = api.json_mime },
            undefined,
        };
        var header_count: usize = 1;
        if (response.allow) |allow| {
            headers[header_count] = .{ .name = "allow", .value = allow };
            header_count += 1;
        }

        try request.respond(response.body, .{
            .status = @enumFromInt(response.status),
            .extra_headers = headers[0..header_count],
        });

        const elapsed = log.elapsedMs(server.io, started);
        if (response.status >= 400) {
            log.warn("req {d}: {d} in {d} ms: {s}", .{ id, response.status, elapsed, response.body });
        } else {
            log.info("req {d}: {d} in {d} ms", .{ id, response.status, elapsed });
        }
    }
};
