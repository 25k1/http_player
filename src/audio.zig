const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const c = @import("c");

const format = c.ma_format_f32;
const channels = 2;
const sample_rate = 48000;
const max_voices = 32;
const chunk_frames = 256;

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
    mutex: Io.Mutex = .init,
    voices: std.ArrayList(*Voice) = .empty,

    pub fn init(gpa: Allocator, io: Io) AudioEngine {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn start(self: *AudioEngine) bool {
        var cfg = c.ma_device_config_init(c.ma_device_type_playback);
        cfg.playback.format = format;
        cfg.playback.channels = channels;
        cfg.sampleRate = sample_rate;
        cfg.dataCallback = dataCallback;
        cfg.pUserData = self;

        if (c.ma_device_init(null, &cfg, &self.device) != c.MA_SUCCESS) return false;
        if (c.ma_device_start(&self.device) != c.MA_SUCCESS) {
            c.ma_device_uninit(&self.device);
            return false;
        }
        self.device_ready = true;
        return true;
    }

    pub fn deinit(self: *AudioEngine) void {
        if (self.device_ready) c.ma_device_uninit(&self.device);
        self.device_ready = false;

        for (self.voices.items) |voice| {
            voice.deinit();
            self.gpa.destroy(voice);
        }
        self.voices.deinit(self.gpa);
    }

    pub fn play(self: *AudioEngine, path: []const u8, volume: f32) bool {
        if (!self.device_ready) return false;

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
        const samples: [*]f32 = @ptrCast(@alignCast(output.?));
        self.mix(samples[0 .. @as(usize, frame_count) * channels]);
    }
};
