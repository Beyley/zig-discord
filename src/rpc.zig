const std = @import("std");
const builtin = @import("builtin");

pub const Packet = @import("packets/packet.zig");
const Platform = @import("platform/platform.zig");

const PipeIndex = u3;

const Self = @This();

pub const BufferedWriter = std.io.BufferedWriter(4096, Platform.Stream.Writer);
pub const BufferedReader = std.io.BufferedReader(4096, Platform.Stream.Reader);
pub const Writer = BufferedWriter.Writer;
pub const Reader = BufferedReader.Reader;

const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
};

state: ConnectionState,
thread_pool: std.Thread.Pool,
nonce: usize,
run_loop: std.atomic.Atomic(bool),
allocator: std.mem.Allocator,
writer: BufferedWriter,
reader: BufferedReader,
pid: std.os.pid_t,
ready_callback: *const fn (*Self) anyerror!void,

const RichPresenceErrors = error{EnvNotFound};

fn getPipeName(idx: PipeIndex) []const u8 {
    return switch (idx) {
        0 => "discord-ipc-0",
        1 => "discord-ipc-1",
        2 => "discord-ipc-2",
        3 => "discord-ipc-3",
        4 => "discord-ipc-4",
        5 => "discord-ipc-5",
        6 => "discord-ipc-6",
        7 => "discord-ipc-7",
    };
}

///Caller owns returned memory
fn getPipePath(allocator: std.mem.Allocator, idx: PipeIndex) ![]const u8 {
    var str = std.ArrayList(u8).init(allocator);

    switch (builtin.os.tag) {
        .linux => {
            const temp_dir = std.os.getenv("XDG_RUNTIME_DIR") orelse
                std.os.getenv("TMPDIR") orelse
                std.os.getenv("TMP") orelse
                std.os.getenv("TEMP") orelse
                "/tmp";
            try str.appendSlice(temp_dir);
            if (temp_dir[temp_dir.len - 1] != '/') {
                try str.append('/');
            }
            try str.appendSlice(getPipeName(idx));
        },
        .macos => {
            try str.appendSlice(std.os.getenv("TMPDIR") orelse return RichPresenceErrors.EnvNotFound);
            try str.appendSlice(getPipeName(idx));
        },
        .windows => {
            try str.appendSlice("\\\\.\\pipe\\");
            try str.appendSlice(getPipeName(idx));
        },
        else => @compileError("unknown os"),
    }

    return str.toOwnedSlice();
}

pub fn init(allocator: std.mem.Allocator, ready_callback: *const fn (*Self) anyerror!void) !*Self {
    var self = try allocator.create(Self);
    self.* = Self{
        .state = .disconnected,
        .thread_pool = undefined,
        .run_loop = std.atomic.Atomic(bool).init(false),
        .allocator = allocator,
        .nonce = 0,
        .reader = undefined,
        .writer = undefined,
        .pid = Platform.getpid(),
        .ready_callback = ready_callback,
    };

    //NOTE: we only create one job here because the packet sending function is not actually thread safe (non-atomic integer incrementing + no write lock)
    ////    its only on a thread pool to simplify "fire and forget" for sending packets "asynchronously"
    try self.thread_pool.init(.{
        .allocator = allocator,
        .n_jobs = 1,
    });

    return self;
}

///Deinits all the data
pub fn deinit(self: *Self) void {
    //If we arent disconnected, stop the connection
    if (self.state != .disconnected) {
        self.stop();
    }

    self.state = .disconnected;
    self.thread_pool.deinit();

    const allocator = self.allocator;

    allocator.destroy(self);
}

pub const Options = struct {
    client_id: []const u8,
};

/// Runs the main loop of the RPC, recieving packets, and doing the initial handshake
/// NOTE: will hang the caller, spin up another thread to do this!
pub fn run(self: *Self, options: Options) !void {

    //Assert we arent already connected, which may imply we trying to connect while already connected
    std.debug.assert(self.state == .disconnected);
    //Assert that we arent already running somewhere else
    std.debug.assert(!self.run_loop.load(.SeqCst));

    //Mark that we are starting looping
    self.run_loop.store(true, .SeqCst);

    var pipe_path = try getPipePath(self.allocator, 0);
    defer self.allocator.free(pipe_path);

    var sock = if (builtin.os.tag == .windows) try std.fs.openFileAbsolute(pipe_path, .{ .mode = .read_write }) else try std.net.connectUnixSocket(pipe_path);
    defer sock.close();

    self.state = .connecting;
    defer self.state = .disconnected;

    defer {
        //TODO: disconnect properly here if no error condition
        self.state = .disconnected;

        std.debug.print("closing...\n", .{});
    }

    self.writer = std.io.bufferedWriter(sock.writer());
    self.reader = std.io.bufferedReader(sock.reader());
    var reader = self.reader.reader();

    std.debug.print("writing handshake\n", .{});
    try self.thread_pool.spawn(sendPacket, .{
        self,
        Packet.Handshake{
            .data = .{
                .nonce = undefined,
                .v = 1,
                .client_id = options.client_id,
            },
        },
    });

    var buf: [10000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var buf2: [10000]u8 = undefined;
    var parsing_fba = std.heap.FixedBufferAllocator.init(&buf2);

    std.debug.print("starting read loop\n", .{});
    while (self.run_loop.load(.SeqCst)) {
        defer std.time.sleep(std.time.ns_per_s * 0.25);

        defer fba.reset();
        defer parsing_fba.reset();

        const parse_options: std.json.ParseOptions = .{
            .ignore_unknown_fields = true,
        };

        //If theres no data,
        if (!try Platform.peek(sock)) {
            // std.debug.print("no data\n", .{});
            //Skip
            continue;
        } else {
            // std.debug.print("has data\n", .{});
        }

        var op: Packet.Opcode = try reader.readEnum(Packet.Opcode, .Little);
        var len = try reader.readIntLittle(u32);

        var data = try fba.allocator().alloc(u8, len);
        std.debug.assert(try reader.readAll(data) == len);

        std.debug.print("got data {s}\n", .{data});

        switch (op) {
            .handshake => {
                @panic("t");
            },
            .frame => {
                var first_pass = try std.json.parseFromSliceLeaky(Packet.PacketData, parsing_fba.allocator(), data, parse_options);
                const command = first_pass.cmd;
                const server_event = first_pass.evt;
                parsing_fba.reset();

                switch (command) {
                    .DISPATCH => if (self.state == .connecting) {
                        std.debug.assert(server_event.? == .READY);

                        var parsed = try std.json.parseFromSliceLeaky(Packet.ServerPacket(Packet.ReadyEventData), parsing_fba.allocator(), data, parse_options);
                        defer parsing_fba.reset();

                        std.debug.print("connected as user {s}\n", .{parsed.data.user.username});

                        self.state = .connected;

                        try self.ready_callback(self);
                    } else {},
                    .SET_ACTIVITY => {
                        std.debug.assert(self.state == .connected);
                    },
                    .SUBSCRIBE => {
                        std.debug.assert(self.state == .connected);
                    },
                    .UNSUBSCRIBE => {
                        std.debug.assert(self.state == .connected);
                    },
                    .SEND_ACTIVITY_JOIN_INVITE => {
                        std.debug.assert(self.state == .connected);
                    },
                    .CLOSE_ACTIVITY_JOIN_REQUEST => {
                        std.debug.assert(self.state == .connected);
                    },
                }
            },
            .close => {
                @panic("tt");
            },
            else => @panic("TTT"),
        }
    }
}

pub fn setPresence(self: *Self, presence: Packet.Presence) !void {
    try self.thread_pool.spawn(
        sendPacket,
        .{
            self,
            Packet.PresencePacket{
                .data = .{
                    .cmd = .SET_ACTIVITY,
                    .nonce = undefined,
                    .args = .{
                        .activity = presence,
                        .pid = if (builtin.os.tag == .windows) @intCast(@intFromPtr(self.pid)) else self.pid,
                    },
                },
            },
        },
    );
}

pub fn stop(self: *Self) void {
    self.run_loop.store(false, .SeqCst);
}

fn sendPacket(
    self: *Self,
    packet: anytype,
) void {
    //Dont do anything if we are disconnected, packets are only valid to be send during handshake and connected
    if (self.state == .disconnected) {
        return;
    }

    var nonce_str: [10]u8 = undefined;
    var nonce_writer = std.io.fixedBufferStream(&nonce_str);
    std.fmt.formatInt(self.nonce, 10, .upper, .{}, nonce_writer.writer()) catch unreachable;

    // Disable runtime safety so that the int rolls over,
    // probably not a good thing if it does, but at least we wont crash?
    @setRuntimeSafety(false);
    self.nonce += 1;
    @setRuntimeSafety(true);

    var packet_to_send = packet;
    packet_to_send.data.nonce = nonce_str[0..nonce_writer.pos];

    packet_to_send.serialize(self.writer.writer()) catch unreachable;
    self.writer.flush() catch unreachable;
    std.debug.print("written packet\n", .{});
}
