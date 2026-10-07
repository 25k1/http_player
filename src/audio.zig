const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const c = @import("c");

const DeviceWatcher = @import("device_watch.zig").DeviceWatcher;
const log = @import("log.zig");

const format = c.ma_format_f32;
const channels = 2;
const sample_rate = 48000;
const max_voices = 32;
const chunk_frames = 256;

const stall_timeout_ms = 2000;
const device_lock_timeout_ms = 5000;

const Voice = struct {
    decoder: c.ma_decoder = undefined,
    gain: f32 = 1.0,
    initialized: bool = false,
    finished: bool = false,

    fn open(v: *Voice, gpa: Allocator, path: []const u8, volume: f32) bool {
        v.gain = volume;

        const cfg = c.ma_decoder_config_init(format, channels, sample_rate);
        const status = switch (builtin.os.tag) {
            .windows => blk: {
                const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return false;
                defer gpa.free(wide);
                break :blk c.ma_decoder_init_file_w(wide.ptr, &cfg, &v.decoder);
            },
            else => blk: {
                const zpath = gpa.dupeZ(u8, path) catch return false;
                defer gpa.free(zpath);
                break :blk c.ma_decoder_init_file(zpath.ptr, &cfg, &v.decoder);
            },
        };

        v.initialized = status == c.MA_SUCCESS;
        if (!v.initialized) log.warn("audio: cannot decode {s}: {s}", .{ path, describe(status) });
        return v.initialized;
    }

    fn deinit(v: *Voice) void {
        if (v.initialized) _ = c.ma_decoder_uninit(&v.decoder);
        v.initialized = false;
    }

    fn render(v: *Voice, out_frames: []f32) void {
        var out = out_frames;
        while (out.len != 0) {
            const want: u64 = @min(out.len / channels, chunk_frames);
            var chunk: [chunk_frames * channels]f32 = undefined;

            var read: u64 = 0;
            const status = c.ma_decoder_read_pcm_frames(&v.decoder, &chunk, want, &read);

            const samples: usize = @intCast(read * channels);
            for (out[0..samples], chunk[0..samples]) |*dst, src| dst.* += src * v.gain;
            out = out[samples..];

            if (status != c.MA_SUCCESS or read < want) {
                v.finished = true;
                return;
            }
        }
    }
};

pub const AudioEngine = struct {
    gpa: Allocator,
    io: Io,
    device: c.ma_device = undefined,
    device_ready: bool = false,
    ma_log: c.ma_log = undefined,
    ma_log_ready: bool = false,
    watcher: DeviceWatcher = .{},
    device_mutex: Io.Mutex = .init,
    callbacks: std.atomic.Value(u64) = .init(0),
    seen_callbacks: u64 = 0,
    seen_at: Io.Timestamp = .zero,
    mutex: Io.Mutex = .init,
    voices: std.ArrayList(*Voice) = .empty,

    pub fn init(gpa: Allocator, io: Io) AudioEngine {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn start(self: *AudioEngine) bool {
        if (c.ma_log_init(null, &self.ma_log) == c.MA_SUCCESS) {
            _ = c.ma_log_register_callback(&self.ma_log, c.ma_log_callback_init(onMiniaudioLog, null));
            self.ma_log_ready = true;
        }
        self.watcher.start();

        self.device_mutex.lockUncancelable(self.io);
        defer self.device_mutex.unlock(self.io);
        return self.openDevice();
    }

    fn openDevice(self: *AudioEngine) bool {
        var cfg = c.ma_device_config_init(c.ma_device_type_playback);
        cfg.playback.format = format;
        cfg.playback.channels = channels;
        cfg.sampleRate = sample_rate;
        cfg.dataCallback = dataCallback;
        cfg.notificationCallback = onNotification;
        cfg.pUserData = self;
        // DeviceWatcher handles device changes; see there why miniaudio must not.
        cfg.wasapi.noAutoStreamRouting = c.MA_TRUE;

        var context_cfg = c.ma_context_config_init();
        if (self.ma_log_ready) context_cfg.pLog = &self.ma_log;

        log.info("audio: opening device", .{});
        const init_status = c.ma_device_init_ex(null, 0, &context_cfg, &cfg, &self.device);
        if (init_status != c.MA_SUCCESS) {
            log.err("audio: cannot open device: {s}", .{describe(init_status)});
            return false;
        }

        log.info("audio: starting device '{s}'", .{std.mem.sliceTo(&self.device.playback.name, 0)});
        const start_status = c.ma_device_start(&self.device);
        if (start_status != c.MA_SUCCESS) {
            log.err("audio: cannot start device: {s}", .{describe(start_status)});
            c.ma_device_uninit(&self.device);
            return false;
        }
        log.info("audio: device started", .{});

        self.device_ready = true;
        self.seen_callbacks = self.callbacks.load(.monotonic);
        self.seen_at = Io.Clock.awake.now(self.io);
        return true;
    }

    fn closeDevice(self: *AudioEngine) void {
        if (self.device_ready) {
            log.info("audio: closing device", .{});
            c.ma_device_uninit(&self.device);
            log.info("audio: device closed", .{});
        }
        self.device_ready = false;
    }

    fn ensureDevice(self: *AudioEngine) bool {
        // A hung device call must not hang every later request as well.
        if (!log.lockMutexTimeout(&self.device_mutex, self.io, "audio device", device_lock_timeout_ms)) {
            return false;
        }
        defer self.device_mutex.unlock(self.io);

        if (!self.device_ready) {
            log.warn("audio: no open device", .{});
        } else if (self.watcher.takeChange()) {
            log.info("audio: audio devices changed, reopening", .{});
        } else if (self.deviceHealthy()) {
            return true;
        }

        self.closeDevice();
        self.dropVoices();
        return self.openDevice();
    }

    fn deviceHealthy(self: *AudioEngine) bool {
        const state = c.ma_device_get_state(&self.device);
        if (state != c.ma_device_state_started) {
            log.warn("audio: device is not running (state {d})", .{state});
            return false;
        }

        const now = Io.Clock.awake.now(self.io);
        const count = self.callbacks.load(.monotonic);
        if (count != self.seen_callbacks) {
            self.seen_callbacks = count;
            self.seen_at = now;
            return true;
        }

        const silent_ms = self.seen_at.durationTo(now).toMilliseconds();
        if (silent_ms < stall_timeout_ms) return true;
        log.warn("audio: device stalled, no callbacks for {d} ms", .{silent_ms});
        return false;
    }

    fn dropVoices(self: *AudioEngine) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.voices.items) |voice| {
            voice.deinit();
            self.gpa.destroy(voice);
        }
        self.voices.clearRetainingCapacity();
    }

    pub fn deinit(self: *AudioEngine) void {
        self.watcher.stop();
        self.closeDevice();

        for (self.voices.items) |voice| {
            voice.deinit();
            self.gpa.destroy(voice);
        }
        self.voices.deinit(self.gpa);

        if (self.ma_log_ready) c.ma_log_uninit(&self.ma_log);
        self.ma_log_ready = false;
    }

    pub fn play(self: *AudioEngine, path: []const u8, volume: f32) bool {
        if (!self.ensureDevice()) return false;

        const voice = self.gpa.create(Voice) catch return false;
        voice.* = .{};
        if (!voice.open(self.gpa, path, volume)) {
            self.gpa.destroy(voice);
            return false;
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.reapFinished();
        if (self.voices.items.len >= max_voices) {
            log.warn("audio: {d} sounds already playing, rejecting", .{max_voices});
            voice.deinit();
            self.gpa.destroy(voice);
            return false;
        }

        self.voices.append(self.gpa, voice) catch {
            voice.deinit();
            self.gpa.destroy(voice);
            return false;
        };
        return true;
    }

    fn reapFinished(self: *AudioEngine) void {
        var i: usize = 0;
        while (i < self.voices.items.len) {
            const voice = self.voices.items[i];
            if (voice.finished) {
                _ = self.voices.orderedRemove(i);
                voice.deinit();
                self.gpa.destroy(voice);
            } else {
                i += 1;
            }
        }
    }

    fn mix(self: *AudioEngine, out: []f32) void {
        @memset(out, 0.0);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.voices.items) |voice| {
            if (!voice.finished) voice.render(out);
        }
        for (out) |*sample| sample.* = std.math.clamp(sample.*, -1.0, 1.0);
    }

    fn dataCallback(
        device: [*c]c.ma_device,
        output: ?*anyopaque,
        _: ?*const anyopaque,
        frame_count: c.ma_uint32,
    ) callconv(.c) void {
        const self: *AudioEngine = @ptrCast(@alignCast(device.*.pUserData.?));
        _ = self.callbacks.fetchAdd(1, .monotonic);
        const samples: [*]f32 = @ptrCast(@alignCast(output.?));
        self.mix(samples[0 .. @as(usize, frame_count) * channels]);
    }

    fn onNotification(notification: [*c]const c.ma_device_notification) callconv(.c) void {
        const name = switch (notification.*.type) {
            c.ma_device_notification_type_started => "started",
            c.ma_device_notification_type_stopped => "stopped",
            c.ma_device_notification_type_rerouted => "rerouted",
            c.ma_device_notification_type_interruption_began => "interruption began",
            c.ma_device_notification_type_interruption_ended => "interruption ended",
            c.ma_device_notification_type_unlocked => "unlocked",
            else => "unknown",
        };
        log.info("audio: device notification: {s}", .{name});
    }

    fn onMiniaudioLog(_: ?*anyopaque, level: c.ma_uint32, message: [*c]const u8) callconv(.c) void {
        const text = std.mem.trimEnd(u8, std.mem.sliceTo(message, 0), "\r\n");
        const level_name = std.mem.sliceTo(c.ma_log_level_to_string(level), 0);
        switch (level) {
            c.MA_LOG_LEVEL_ERROR => log.err("miniaudio {s}: {s}", .{ level_name, text }),
            c.MA_LOG_LEVEL_WARNING => log.warn("miniaudio {s}: {s}", .{ level_name, text }),
            else => log.info("miniaudio {s}: {s}", .{ level_name, text }),
        }
    }
};

fn describe(status: c.ma_result) []const u8 {
    return std.mem.sliceTo(c.ma_result_description(status), 0);
}
