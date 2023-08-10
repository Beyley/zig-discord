const std = @import("std");

const Platform = @import("platform/platform.zig");

var nonce: u32 = 0;

pub fn main() !void {
    const pid = Platform.getpid();

    const pipe_path = "/run/user/1000/discord-ipc-0";

    var sock = try std.net.connectUnixSocket(pipe_path);
    defer sock.close();

    var buffered_writer = std.io.bufferedWriter(sock.writer());
    var writer = buffered_writer.writer();
    _ = writer;

    var buffered_reader = std.io.bufferedReader(sock.reader());
    var reader = buffered_reader.reader();

    var state: ConnectionState = .connecting;

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = 1, .allocator = std.heap.c_allocator });
    defer pool.deinit();

    std.debug.print("writing handshake\n", .{});
    try pool.spawn(sendPacket, .{
        Handshake{
            .data = .{
                .nonce = undefined,
                .v = 1,
                .client_id = "908631391934222366",
            },
        },
        &buffered_writer,
    });

    state = .connecting;

    var buf: [10000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);

    var buf2: [10000]u8 = undefined;
    var parsing_fba = std.heap.FixedBufferAllocator.init(&buf2);

    while (true) {
        defer fba.reset();
        defer parsing_fba.reset();

        const parse_options: std.json.ParseOptions = .{
            .ignore_unknown_fields = true,
        };

        var op: Opcode = try reader.readEnum(Opcode, .Little);
        var len = try reader.readIntLittle(u32);

        var data = try fba.allocator().alloc(u8, len);
        std.debug.assert(try reader.readAll(data) == len);

        std.debug.print("got data {s}\n", .{data});

        switch (op) {
            .handshake => {
                @panic("t");
            },
            .frame => {
                var first_pass = try std.json.parseFromSliceLeaky(PacketData, parsing_fba.allocator(), data, parse_options);
                const command = first_pass.cmd;
                const server_event = first_pass.evt;
                parsing_fba.reset();

                switch (command) {
                    .DISPATCH => if (state == .connecting) {
                        std.debug.assert(server_event.? == .READY);

                        var parsed = try std.json.parseFromSliceLeaky(ServerPacket(ReadyEventData), parsing_fba.allocator(), data, parse_options);
                        defer parsing_fba.reset();

                        std.debug.print("connected as user {s}\n", .{parsed.data.user.username});

                        state = .connected;

                        var presence: Presence = Presence{
                            .assets = .{
                                .large_image = ArrayString(256).create("ptyping-mode-icon"),
                                .large_text = ArrayString(128).create("waaa"),
                                .small_image = ArrayString(256).create("ptyping-mode-icon"),
                                .small_text = ArrayString(128).create("WAAAAAA"),
                            },
                            .buttons = null,
                            .details = ArrayString(128).create("what the FUCK IS A KILOMETER"),
                            .party = null,
                            .secrets = null,
                            .state = ArrayString(128).create("i got ziggy with it :)"),
                            .timestamps = .{
                                .start = null,
                                .end = null,
                            },
                        };

                        try pool.spawn(
                            sendPacket,
                            .{
                                PresencePacket{
                                    .data = .{
                                        .cmd = .SET_ACTIVITY,
                                        .nonce = undefined,
                                        .args = .{
                                            .activity = presence,
                                            .pid = pid,
                                        },
                                    },
                                },
                                &buffered_writer,
                            },
                        );
                    } else {},
                    .SET_ACTIVITY => {
                        std.debug.assert(state == .connected);
                    },
                    .SUBSCRIBE => {
                        std.debug.assert(state == .connected);
                    },
                    .UNSUBSCRIBE => {
                        std.debug.assert(state == .connected);
                    },
                    .SEND_ACTIVITY_JOIN_INVITE => {
                        std.debug.assert(state == .connected);
                    },
                    .CLOSE_ACTIVITY_JOIN_REQUEST => {
                        std.debug.assert(state == .connected);
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

const Command = enum {
    DISPATCH,
    SET_ACTIVITY,
    SUBSCRIBE,
    UNSUBSCRIBE,
    SEND_ACTIVITY_JOIN_INVITE,
    CLOSE_ACTIVITY_JOIN_REQUEST,
};

const ServerEvent = enum {
    READY,
    ERROR,
    ACTIVITY_JOIN,
    ACTIVITY_SPECTATE,
    ACTIVITY_JOIN_REQUEST,
};

const Configuration = struct {
    api_endpoint: []const u8,
    cdn_host: []const u8,
    environment: []const u8,
};

const User = struct {
    pub const AvatarFormat = enum {
        PNG,
        JPEG,
        WebP,
        GIF,
    };

    pub const AvatarSize = enum(i32) {
        x16 = 16,
        x32 = 32,
        x64 = 64,
        x128 = 128,
        x256 = 256,
        x512 = 512,
        x1024 = 1024,
        x2048 = 2048,
    };

    // pub const Flags = packed struct(i32) {
    //     employee: bool = false,
    //     partner: bool = false,
    //     hype_squad: bool = false,
    //     bug_hunter: bool = false,
    //     unknown_1: bool = false,
    //     unknown_2: bool = false,
    //     house_of_bravery: bool = false,
    //     house_of_brilliance: bool = false,
    //     house_of_balance: bool = false,
    //     early_supporter: bool = false,
    //     team_user: bool = false,
    //     padding: u21,
    // };
    pub const Flags = i32;

    pub const PremiumType = enum(i32) {
        none = 0,
        nitro_classic = 1,
        nitro = 2,
    };

    id: u64,
    username: []const u8,
    discriminator: u16,
    global_name: []const u8,
    avatar: []const u8,
    flags: Flags,
    premium_type: PremiumType,
};

const ReadyEventData = struct {
    v: i32,
    config: Configuration,
    user: User,
};

const PacketData = ServerPacket(?struct {});

fn ServerPacket(comptime DataType: type) type {
    return struct {
        cmd: Command,
        evt: ?ServerEvent,
        nonce: ?[]const u8,
        data: DataType,
    };
}

const ConnectionState = enum {
    disconnected,
    connecting,
    connected,
};

const BufferedWriter = std.io.BufferedWriter(4096, std.net.Stream.Writer);
const Writer = BufferedWriter.Writer;
const Reader = std.io.BufferedReader(4096, std.net.Stream.Reader).Reader;

const Handshake = Packet(.handshake, struct {
    v: i32,
    nonce: []const u8,
    client_id: []const u8,
});

const PresencePacket = Packet(.frame, struct {
    cmd: Command,
    nonce: []const u8,
    args: PresenceCommand,
});

fn Packet(comptime op: Opcode, comptime DataType: type) type {
    return struct {
        const Self = @This();

        data: DataType,

        pub fn serialize(self: Self, writer: Writer) !void {
            const stringify_options = std.json.StringifyOptions{
                .emit_null_optional_fields = false,
            };

            var counter = std.io.countingWriter(std.io.null_writer);
            try std.json.stringify(self.data, stringify_options, counter.writer());
            const size: u32 = @intCast(counter.bytes_written);

            try writer.writeIntLittle(u32, @intFromEnum(op));
            try writer.writeIntLittle(u32, size);
            try std.json.stringify(self.data, stringify_options, writer);
        }
    };
}

const Opcode = enum(u32) {
    ///Initial handshake
    handshake = 0,
    ///Generic message frame
    frame = 1,
    ///Discord has closed the connection
    close = 2,
    ///Ping, unused
    ping = 3,
    ///Pong, unused
    pong = 4,
};

fn sendPacket(
    packet: anytype,
    buffered_writer: *BufferedWriter,
) void {
    var nonce_str: [10]u8 = undefined;
    var nonce_writer = std.io.fixedBufferStream(&nonce_str);
    var used = std.fmt.formatInt(nonce, 10, .upper, .{}, nonce_writer.writer()) catch unreachable;
    _ = used;

    nonce += 1;

    var packet_to_send = packet;
    packet_to_send.data.nonce = nonce_str[0..nonce_writer.pos];

    var writer = buffered_writer.writer();
    packet_to_send.serialize(writer) catch unreachable;
    buffered_writer.flush() catch unreachable;
}

fn ArrayString(comptime len: comptime_int) type {
    return struct {
        const Self = @This();

        buf: [len]u8,
        len: usize,

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn jsonStringify(self: *const Self, jw: anytype) !void {
            try jw.write(self.slice());
        }

        pub fn create(str: []const u8) Self {
            var self = Self{
                .buf = undefined,
                .len = str.len,
            };
            @memcpy(self.buf[0..self.len], str);

            return self;
        }
    };
}

const Presence = struct {
    pub const Button = struct {
        label: []const u8,
        url: []const u8,
    };

    //all in unix epoch
    pub const Timestamps = struct {
        start: ?u64,
        end: ?u64,
    };

    pub const Assets = struct {
        large_image: ArrayString(256),
        large_text: ArrayString(128),
        small_image: ArrayString(256),
        small_text: ArrayString(128),
    };

    pub const Party = struct {
        pub const Privacy = enum(i32) {
            private = 0,
            public = 1,
        };

        id: ArrayString(128),
        privacy: Privacy,
        ///Element 0 is size, element 1 is max
        size: []const i32,
    };

    pub const Secrets = struct {
        join: ArrayString(128),
        spectate: ArrayString(128),
    };

    buttons: ?[]const Button,
    state: ArrayString(128),
    details: ArrayString(128),
    timestamps: Timestamps,
    assets: Assets,
    party: ?Party,
    secrets: ?Secrets,
};

const PresenceCommand = struct {
    pid: i32,
    activity: Presence,
};

fn setPresence(buffered_writer: *BufferedWriter) void {
    _ = buffered_writer;
}
