const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const log = @import("log.zig");

const is_windows = builtin.os.tag == .windows;

pub const SpeakResult = enum { ok, not_running, failed };

pub fn speak(gpa: Allocator, io: std.Io, utf8_text: []const u8) SpeakResult {
    if (!is_windows) return .failed;
    return win.speak(gpa, io, utf8_text);
}

const win = if (is_windows) struct {
    comptime {
        if (builtin.cpu.arch != .x86_64) {
            @compileError("NVDA RPC marshalling tables here are x64-only; regenerate for this arch.");
        }
    }

    fn fcShort(comptime v: u16) [2]u8 {
        return .{ @truncate(v), @truncate(v >> 8) };
    }

    fn fcLong(comptime v: u32) [4]u8 {
        return .{ @truncate(v), @truncate(v >> 8), @truncate(v >> 16), @truncate(v >> 24) };
    }

    fn nullaryProc(comptime opnum: u16) [32]u8 {
        return [_]u8{ 0x32, 0x68 } ++ fcLong(0x0) ++ fcShort(opnum) ++ fcShort(0x8) ++
            fcShort(0x0) ++ fcShort(0x8) ++ [_]u8{ 0x44, 0x1, 0xa, 0x1 } ++
            fcShort(0x0) ++ fcShort(0x0) ++ fcShort(0x0) ++ fcShort(0x0) ++
            fcShort(0x70) ++ fcShort(0x0) ++ [_]u8{ 0x10, 0x0 };
    }

    fn stringProc(comptime opnum: u16) [38]u8 {
        return [_]u8{ 0x32, 0x68 } ++ fcLong(0x0) ++ fcShort(opnum) ++ fcShort(0x10) ++
            fcShort(0x0) ++ fcShort(0x8) ++ [_]u8{ 0x46, 0x2, 0xa, 0x1 } ++
            fcShort(0x0) ++ fcShort(0x0) ++ fcShort(0x0) ++ fcShort(0x0) ++
            fcShort(0x10b) ++ fcShort(0x0) ++ fcShort(0x4) ++ fcShort(0x70) ++
            fcShort(0x8) ++ [_]u8{ 0x10, 0x0 };
    }

    const proc_format align(2) = nullaryProc(0) ++ stringProc(1) ++
        nullaryProc(2) ++ stringProc(3) ++ [_]u8{0x0};

    const type_format align(2) = fcShort(0x0) ++ [_]u8{ 0x11, 0x8, 0x25, 0x5c, 0x0 };

    const test_if_running_offset = 0;
    const speak_text_offset = 32;

    comptime {
        std.debug.assert(proc_format.len == 141);
        std.debug.assert(type_format.len == 7);
    }

    const GUID = extern struct {
        data1: u32,
        data2: u16,
        data3: u16,
        data4: [8]u8,
    };

    const RpcVersion = extern struct { major: u16, minor: u16 };

    const RpcSyntaxIdentifier = extern struct {
        syntax_guid: GUID,
        syntax_version: RpcVersion,
    };

    const RpcClientInterface = extern struct {
        length: u32,
        interface_id: RpcSyntaxIdentifier,
        transfer_syntax: RpcSyntaxIdentifier,
        dispatch_table: ?*anyopaque,
        rpc_protseq_endpoint_count: u32,
        rpc_protseq_endpoint: ?*anyopaque,
        reserved: usize,
        interpreter_info: ?*const anyopaque,
        flags: u32,
    };

    const CommFaultOffsets = extern struct { comm_offset: i16, fault_offset: i16 };

    const MidlStubDesc = extern struct {
        rpc_interface_information: ?*const anyopaque,
        pfn_allocate: *const fn (usize) callconv(.c) ?*anyopaque,
        pfn_free: *const fn (?*anyopaque) callconv(.c) void,
        implicit_handle_info: ?*anyopaque,
        apfn_ndr_rundown_routines: ?*const anyopaque,
        a_generic_binding_routine_pairs: ?*const anyopaque,
        apfn_expr_eval: ?*const anyopaque,
        a_xmit_quintuple: ?*const anyopaque,
        p_format_types: [*]const u8,
        f_check_bounds: c_int,
        version: c_ulong,
        p_malloc_free_struct: ?*anyopaque,
        midl_version: c_long,
        comm_fault_offsets: ?*const CommFaultOffsets,
        a_user_marshal_quadruple: ?*const anyopaque,
        notify_routine_table: ?*const anyopaque,
        m_flags: usize,
        cs_routine_tables: ?*const anyopaque,
        proxy_server_info: ?*anyopaque,
        p_expr_info: ?*const anyopaque,
    };

    export fn MIDL_user_allocate(size: usize) callconv(.c) ?*anyopaque {
        return std.c.malloc(size);
    }

    export fn MIDL_user_free(p: ?*anyopaque) callconv(.c) void {
        std.c.free(p);
    }

    extern "rpcrt4" fn RpcBindingFromStringBindingW(
        string_binding: [*:0]const u16,
        binding: *?*anyopaque,
    ) callconv(.winapi) c_long;

    extern "rpcrt4" fn NdrClientCall2(
        stub_descriptor: *const MidlStubDesc,
        format: [*]const u8,
        ...,
    ) callconv(.c) isize;

    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn ProcessIdToSessionId(process_id: u32, session_id: *u32) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
    extern "user32" fn GetThreadDesktop(thread_id: u32) callconv(.winapi) ?*anyopaque;
    extern "user32" fn GetUserObjectInformationW(
        obj: ?*anyopaque,
        index: c_int,
        info: ?*anyopaque,
        length: u32,
        length_needed: *u32,
    ) callconv(.winapi) i32;

    const UOI_NAME = 2;

    const interface_id: RpcClientInterface = .{
        .length = @sizeOf(RpcClientInterface),
        .interface_id = .{
            .syntax_guid = .{
                .data1 = 0xDFF50B99,
                .data2 = 0xF7FD,
                .data3 = 0x4CA7,
                .data4 = .{ 0xA8, 0x2C, 0xDA, 0xEB, 0x3E, 0x02, 0x52, 0x95 },
            },
            .syntax_version = .{ .major = 1, .minor = 0 },
        },
        .transfer_syntax = .{
            .syntax_guid = .{
                .data1 = 0x8A885D04,
                .data2 = 0x1CEB,
                .data3 = 0x11C9,
                .data4 = .{ 0x9F, 0xE8, 0x08, 0x00, 0x2B, 0x10, 0x48, 0x60 },
            },
            .syntax_version = .{ .major = 2, .minor = 0 },
        },
        .dispatch_table = null,
        .rpc_protseq_endpoint_count = 0,
        .rpc_protseq_endpoint = null,
        .reserved = 0,
        .interpreter_info = null,
        .flags = 0,
    };

    const comm_fault_offsets = [_]CommFaultOffsets{
        .{ .comm_offset = -1, .fault_offset = -1 },
    } ** 4;

    var binding: ?*anyopaque = null;

    const stub_desc: MidlStubDesc = .{
        .rpc_interface_information = &interface_id,
        .pfn_allocate = &MIDL_user_allocate,
        .pfn_free = &MIDL_user_free,
        .implicit_handle_info = @ptrCast(&binding),
        .apfn_ndr_rundown_routines = null,
        .a_generic_binding_routine_pairs = null,
        .apfn_expr_eval = null,
        .a_xmit_quintuple = null,
        .p_format_types = &type_format,
        .f_check_bounds = 1,
        .version = 0x50002,
        .p_malloc_free_struct = null,
        .midl_version = 0x8010274,
        .comm_fault_offsets = &comm_fault_offsets[0],
        .a_user_marshal_quadruple = null,
        .notify_routine_table = null,
        .m_flags = 0x1,
        .cs_routine_tables = null,
        .proxy_server_info = null,
        .p_expr_info = null,
    };

    fn call(comptime proc_offset: usize, arg: ?[*:0]const u16) isize {
        return NdrClientCall2(&stub_desc, proc_format[proc_offset..].ptr, arg);
    }

    fn connect(endpoint: [:0]const u16) bool {
        if (binding != null) return true;

        log.info("nvda: binding to {f}", .{std.unicode.fmtUtf16Le(endpoint)});
        const status = RpcBindingFromStringBindingW(endpoint.ptr, &binding);
        if (status != 0) log.warn("nvda: binding failed, RPC status {d}", .{status});
        return status == 0;
    }

    fn endpointName(buf: []u16) ?[:0]const u16 {
        var session: u32 = 0;
        _ = ProcessIdToSessionId(GetCurrentProcessId(), &session);

        var desktop = std.mem.zeroes([64]u16);
        var needed: u32 = 0;
        if (GetThreadDesktop(GetCurrentThreadId())) |handle| {
            _ = GetUserObjectInformationW(handle, UOI_NAME, &desktop, @sizeOf(@TypeOf(desktop)), &needed);
        }
        const desktop_name = std.mem.sliceTo(&desktop, 0);

        var stack: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&stack);
        writer.print("ncalrpc:[NvdaCtlr.{d}.", .{session}) catch return null;
        const prefix = writer.buffered();

        var len: usize = 0;
        for (prefix) |ch| {
            if (len >= buf.len) return null;
            buf[len] = ch;
            len += 1;
        }
        for (desktop_name) |unit| {
            if (len >= buf.len) return null;
            buf[len] = unit;
            len += 1;
        }
        if (len + 2 > buf.len) return null;
        buf[len] = ']';
        len += 1;
        buf[len] = 0;
        return buf[0..len :0];
    }

    var mutex: std.Io.Mutex = .init;

    fn speak(gpa: Allocator, io: std.Io, utf8_text: []const u8) SpeakResult {
        if (utf8_text.len == 0) return .failed;

        const text = std.unicode.wtf8ToWtf16LeAllocZ(gpa, utf8_text) catch return .failed;
        defer gpa.free(text);

        var endpoint_buf: [512]u16 = undefined;
        const endpoint = endpointName(&endpoint_buf) orelse return .failed;

        log.lockMutex(&mutex, io, "nvda");
        defer mutex.unlock(io);

        if (!connect(endpoint)) return .not_running;

        log.info("nvda: calling TestIfRunning", .{});
        const running = call(test_if_running_offset, null);
        log.info("nvda: TestIfRunning returned {d}", .{running});
        if (running != 0) return .not_running;

        log.info("nvda: calling SpeakText", .{});
        const spoken = call(speak_text_offset, text.ptr);
        log.info("nvda: SpeakText returned {d}", .{spoken});
        return if (spoken == 0) .ok else .failed;
    }
} else struct {};
