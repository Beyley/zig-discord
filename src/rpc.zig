const std = @import("std");
const builtin = @import("builtin");

const Packet = @import("packets/packet.zig");
const Platform = @import("platform/platform.zig");

const PipeIndex = u3;

const Self = @This();

pub const BufferedWriter = std.io.BufferedWriter(4096, std.net.Stream.Writer);
pub const BufferedReader = std.io.BufferedReader(4096, std.net.Stream.Reader);
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
            try str.appendSlice("/run/user/1000/");
            try str.appendSlice(getPipeName(idx));
        },
        else => @compileError("unknown os"),
    }

    return str.toOwnedSlice();
}

pub fn init(allocator: std.mem.Allocator) !*Self {
    var self = try allocator.create(Self);
    self.* = Self{
        .state = .disconnected,
        .thread_pool = undefined,
        .run_loop = std.atomic.Atomic(bool).init(false),
        .allocator = allocator,
        .nonce = 0,
        .reader = undefined,
        .writer = undefined,
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

    self.* = undefined;
}

pub const Options = struct {
    client_id: []const u8,
};

/// Runs the main loop of the RPC, recieving packets, and doing the initial handshake
/// NOTE: will hang the caller, spin up another thread to do this!
pub fn run(self: *Self, options: Options) !void {
    const pid = Platform.getpid();

    //Assert we arent already connected, which may imply we trying to connect while already connected
    std.debug.assert(self.state == .disconnected);
    //Assert that we arent already running somewhere else
    std.debug.assert(!self.run_loop.load(.SeqCst));

    //Mark that we are starting looping
    self.run_loop.store(true, .SeqCst);

    var pipe_path = try getPipePath(self.allocator, 0);
    defer self.allocator.free(pipe_path);

    var sock = try std.net.connectUnixSocket(pipe_path);
    defer sock.close();

    self.state = .connecting;

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
        defer fba.reset();
        defer parsing_fba.reset();

        const parse_options: std.json.ParseOptions = .{
            .ignore_unknown_fields = true,
        };

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

                        var presence: Packet.Presence = Packet.Presence{
                            .assets = .{
                                .large_image = Packet.ArrayString(256).create("ptyping-mode-icon"),
                                .large_text = Packet.ArrayString(128).create("waaa"),
                                .small_image = Packet.ArrayString(256).create("ptyping-mode-icon"),
                                .small_text = Packet.ArrayString(128).create("WAAAAAA"),
                            },
                            .buttons = null,
                            .details = Packet.ArrayString(128).create("what the FUCK IS A KILOMETER"),
                            .party = null,
                            .secrets = null,
                            .state = Packet.ArrayString(128).create("i got ziggy with it :)"),
                            .timestamps = .{
                                .start = null,
                                .end = null,
                            },
                        };

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
                                            .pid = pid,
                                        },
                                    },
                                },
                            },
                        );
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

        std.time.sleep(std.time.ns_per_s * 0.25);
    }
}

pub fn stop(self: *Self) void {
    self.run_loop.store(false, .SeqCst);
}

fn sendPacket(
    self: *Self,
    packet: anytype,
) void {
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
