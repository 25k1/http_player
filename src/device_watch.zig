const std = @import("std");
const builtin = @import("builtin");

const log = @import("log.zig");

/// Raises a flag when the set of audio endpoints or the default playback device
/// changes. The audio engine reopens its device on the next sound instead of
/// letting miniaudio reroute inside the notification callback: re-initialising
/// WASAPI there can hang forever, and every later `ma_device_uninit` with it.
pub const DeviceWatcher = if (builtin.os.tag == .windows) WindowsWatcher else struct {
    pub fn start(_: *@This()) void {}
    pub fn stop(_: *@This()) void {}
    pub fn takeChange(_: *@This()) bool {
        return false;
    }
};

const WindowsWatcher = struct {
    client: Client = .{},
    enumerator: ?*Enumerator = null,
    com_initialized: bool = false,
    changed: std.atomic.Value(bool) = .init(false),

    pub fn start(self: *WindowsWatcher) void {
        const init_hr = CoInitializeEx(null, COINIT_MULTITHREADED);
        if (init_hr < 0) {
            log.warn("device watch: CoInitializeEx failed, HRESULT 0x{x}", .{hex(init_hr)});
            return;
        }
        self.com_initialized = true;

        var enumerator: ?*Enumerator = null;
        const create_hr = CoCreateInstance(
            &CLSID_MMDeviceEnumerator,
            null,
            CLSCTX_ALL,
            &IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        );
        const e = enumerator orelse {
            log.warn("device watch: cannot create device enumerator, HRESULT 0x{x}", .{hex(create_hr)});
            return;
        };

        const register_hr = e.vtbl.RegisterEndpointNotificationCallback(e, &self.client);
        if (register_hr < 0) {
            log.warn("device watch: cannot register for notifications, HRESULT 0x{x}", .{hex(register_hr)});
            _ = e.vtbl.Release(e);
            return;
        }
        self.enumerator = e;
        log.info("device watch: started", .{});
    }

    pub fn stop(self: *WindowsWatcher) void {
        if (self.enumerator) |e| {
            _ = e.vtbl.UnregisterEndpointNotificationCallback(e, &self.client);
            _ = e.vtbl.Release(e);
        }
        self.enumerator = null;

        if (self.com_initialized) CoUninitialize();
        self.com_initialized = false;
    }

    pub fn takeChange(self: *WindowsWatcher) bool {
        return self.changed.swap(false, .acq_rel);
    }

    fn markChanged(self: *WindowsWatcher) void {
        self.changed.store(true, .release);
    }
};

fn hex(hr: HRESULT) u32 {
    return @bitCast(hr);
}

const GUID = std.os.windows.GUID;
const HRESULT = i32;
const LPCWSTR = ?[*:0]const u16;

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const COINIT_MULTITHREADED = 0x0;
const CLSCTX_ALL = 0x17;
const eRender = 0;
const eConsole = 0;

const CLSID_MMDeviceEnumerator = GUID.parse("{BCDE0395-E52F-467C-8E3D-C4579291692E}");
const IID_IMMDeviceEnumerator = GUID.parse("{A95664D2-9614-4F35-A746-DE8DB63617E6}");
const IID_IMMNotificationClient = GUID.parse("{7991EEC9-7E89-4D85-8390-6C703CEC60C0}");
const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(
    clsid: *const GUID,
    outer: ?*anyopaque,
    context: u32,
    iid: *const GUID,
    out: *?*anyopaque,
) callconv(.winapi) HRESULT;

const PropertyKey = extern struct {
    fmtid: GUID,
    pid: u32,
};

const Enumerator = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const fn (*Enumerator) callconv(.winapi) u32,
        Release: *const fn (*Enumerator) callconv(.winapi) u32,
        EnumAudioEndpoints: *const anyopaque,
        GetDefaultAudioEndpoint: *const anyopaque,
        GetDevice: *const anyopaque,
        RegisterEndpointNotificationCallback: *const fn (*Enumerator, *Client) callconv(.winapi) HRESULT,
        UnregisterEndpointNotificationCallback: *const fn (*Enumerator, *Client) callconv(.winapi) HRESULT,
    },
};

/// IMMNotificationClient. It lives inside the watcher, so reference counting is
/// a formality. Callbacks only log and set a flag: Windows forbids blocking or
/// activating audio objects from them.
const Client = extern struct {
    vtbl: *const Vtbl = &client_vtbl,

    const Vtbl = extern struct {
        QueryInterface: *const fn (*Client, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*Client) callconv(.winapi) u32,
        Release: *const fn (*Client) callconv(.winapi) u32,
        OnDeviceStateChanged: *const fn (*Client, LPCWSTR, u32) callconv(.winapi) HRESULT,
        OnDeviceAdded: *const fn (*Client, LPCWSTR) callconv(.winapi) HRESULT,
        OnDeviceRemoved: *const fn (*Client, LPCWSTR) callconv(.winapi) HRESULT,
        OnDefaultDeviceChanged: *const fn (*Client, c_int, c_int, LPCWSTR) callconv(.winapi) HRESULT,
        OnPropertyValueChanged: *const fn (*Client, LPCWSTR, PropertyKey) callconv(.winapi) HRESULT,
    };

    const client_vtbl: Vtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .OnDeviceStateChanged = onDeviceStateChanged,
        .OnDeviceAdded = onDeviceAdded,
        .OnDeviceRemoved = onDeviceRemoved,
        .OnDefaultDeviceChanged = onDefaultDeviceChanged,
        .OnPropertyValueChanged = onPropertyValueChanged,
    };

    fn getWatcher(client: *Client) *WindowsWatcher {
        return @fieldParentPtr("client", client);
    }

    fn queryInterface(client: *Client, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (eqlGuid(iid, &IID_IUnknown) or eqlGuid(iid, &IID_IMMNotificationClient)) {
            out.* = client;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(_: *Client) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *Client) callconv(.winapi) u32 {
        return 1;
    }

    fn onDeviceStateChanged(client: *Client, id: LPCWSTR, state: u32) callconv(.winapi) HRESULT {
        log.info("device watch: {f} state {d}", .{ fmtId(id), state });
        client.getWatcher().markChanged();
        return S_OK;
    }

    fn onDeviceAdded(client: *Client, id: LPCWSTR) callconv(.winapi) HRESULT {
        log.info("device watch: {f} added", .{fmtId(id)});
        client.getWatcher().markChanged();
        return S_OK;
    }

    fn onDeviceRemoved(client: *Client, id: LPCWSTR) callconv(.winapi) HRESULT {
        log.info("device watch: {f} removed", .{fmtId(id)});
        client.getWatcher().markChanged();
        return S_OK;
    }

    fn onDefaultDeviceChanged(client: *Client, flow: c_int, role: c_int, id: LPCWSTR) callconv(.winapi) HRESULT {
        if (flow != eRender or role != eConsole) return S_OK;
        log.info("device watch: default playback device is now {f}", .{fmtId(id)});
        client.getWatcher().markChanged();
        return S_OK;
    }

    fn onPropertyValueChanged(_: *Client, _: LPCWSTR, _: PropertyKey) callconv(.winapi) HRESULT {
        return S_OK;
    }
};

fn eqlGuid(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

fn fmtId(id: LPCWSTR) @TypeOf(std.unicode.fmtUtf16Le(&.{})) {
    const none = std.unicode.utf8ToUtf16LeStringLiteral("(none)");
    return std.unicode.fmtUtf16Le(if (id) |p| std.mem.sliceTo(p, 0) else none);
}
