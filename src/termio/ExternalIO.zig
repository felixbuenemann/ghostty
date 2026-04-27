//! ExternalIO implements a termio backend that routes I/O through
//! embedder-provided callbacks instead of a pty + subprocess. This is
//! used by libghostty embedders that manage their own transport (e.g.
//! an SSH client that wants to render remote output in a ghostty
//! terminal surface).
//!
//! Input path (remote → terminal):
//!   Embedder calls `ghostty_surface_write_to_terminal(surface, bytes, len)`
//!   which directly calls `Termio.processOutput(bytes)`, feeding data
//!   through the VT parser into the terminal state machine.
//!
//! Output path (terminal → remote):
//!   When the user types, the surface enqueues write messages via the
//!   mailbox. The IO thread drains the mailbox and calls
//!   `ExternalIO.queueWrite()`, which invokes the embedder's write
//!   callback with the bytes that should be sent to the remote.
const ExternalIO = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

const log = std.log.scoped(.io_external);

/// The callback invoked when the terminal wants to write bytes back
/// to the transport (user keystrokes, terminal query responses, etc.).
/// `userdata` is the opaque pointer set via the C API.
/// `data` is the byte slice to send. The callback must copy the bytes
/// if it needs them beyond the call.
pub const WriteFn = *const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void;

/// Configuration for the external I/O backend.
pub const Config = struct {
    /// Callback invoked when the terminal wants to write bytes out.
    /// If null, writes are silently dropped.
    write_fn: ?WriteFn = null,

    /// Opaque pointer passed as the first argument to write_fn.
    write_fn_ud: ?*anyopaque = null,

    /// Initial size hint. Optional — terminal defaults are fine.
    initial_columns: u16 = 0,
    initial_rows: u16 = 0,
};

/// The write callback and its userdata, set at init time.
write_fn: ?WriteFn,
write_fn_ud: ?*anyopaque,

pub fn init(
    _: Allocator,
    cfg: Config,
) !ExternalIO {
    return .{
        .write_fn = cfg.write_fn,
        .write_fn_ud = cfg.write_fn_ud,
    };
}

pub fn deinit(self: *ExternalIO) void {
    _ = self;
}

pub fn initTerminal(self: *ExternalIO, t: *terminal.Terminal) void {
    _ = self;
    _ = t;
    // No initial pwd or pty size to set — the embedder controls sizing
    // via the existing `ghostty_surface_set_size` API.
}

pub fn threadEnter(
    self: *ExternalIO,
    _: Allocator,
    _: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    // No subprocess to start, no read thread to spawn.
    // Just mark our thread data.
    td.backend = .{ .external_io = .{} };
    _ = self;
}

pub fn threadExit(self: *ExternalIO, td: *termio.Termio.ThreadData) void {
    _ = self;
    _ = td;
    // Nothing to clean up — no subprocess, no threads.
}

pub fn focusGained(
    self: *ExternalIO,
    _: *termio.Termio.ThreadData,
    _: bool,
) !void {
    _ = self;
}

pub fn resize(
    self: *ExternalIO,
    _: renderer.GridSize,
    _: renderer.ScreenSize,
) !void {
    _ = self;
    // The embedder is responsible for telling the remote side about
    // size changes (e.g. via SSH window-change requests). We don't
    // need to do anything here since there's no pty to resize.
}

pub fn queueWrite(
    self: *ExternalIO,
    _: Allocator,
    _: *termio.Termio.ThreadData,
    data: []const u8,
    _: bool,
) !void {
    // Route the bytes to the embedder's callback. This is called
    // on the IO thread when the user types or the terminal emits
    // a query response.
    if (self.write_fn) |wfn| {
        wfn(self.write_fn_ud, data.ptr, data.len);
    }
}

pub fn childExitedAbnormally(
    self: *ExternalIO,
    _: Allocator,
    _: *terminal.Terminal,
    _: u32,
    _: u64,
) !void {
    _ = self;
    // No child process — this should never be called.
}

pub fn getProcessInfo(self: *ExternalIO, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
    _ = self;
    return null;
}

/// Thread-local data for ExternalIO. Minimal — no pty, no streams.
pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, _: Allocator) void {
        _ = self;
    }
};
