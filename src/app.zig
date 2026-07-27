const build_options = @import("build_options");

pub const app_name = "http-player";
pub const app_version = build_options.version;
pub const config_file_name = "config.json";
pub const sounds_dir_name = "sounds";
pub const default_host = "127.0.0.1";

pub const default_port: i64 = 57919;
pub const min_port: i64 = 1;
pub const max_port: i64 = 65535;

pub const ExitCode = enum(u8) {
    ok = 0,
    err = 1,
    usage = 2,
    already_running = 3,
};
