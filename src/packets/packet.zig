const std = @import("std");

const Rpc = @import("../rpc.zig");

fn enumIntJsonStringify(val: anytype, stringify: *std.json.Stringify) std.json.Stringify.Error!void {
    return stringify.write(@intFromEnum(val.*));
}

pub fn Packet(comptime op: Opcode, comptime DataType: type) type {
    return struct {
        const Self = @This();

        data: DataType,

        pub fn serialize(self: Self, writer: *std.io.Writer) !void {
            const stringify_options: std.json.Stringify.Options = .{
                .emit_null_optional_fields = false,
            };

            var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
            try std.json.fmt(self.data, stringify_options).format(&discarding_writer.writer);
            const size: u32 = @intCast(discarding_writer.count);

            // var buf: [4096]u8 = undefined;
            // var debug_writer = std.fs.File.stderr().writer(&buf);
            // try std.json.fmt(self.data, stringify_options).format(&debug_writer.interface);
            // try debug_writer.interface.flush();

            try writer.writeInt(u32, @intFromEnum(op), .little);
            try writer.writeInt(u32, size, .little);
            try std.json.fmt(self.data, stringify_options).format(writer);
        }
    };
}

pub const Opcode = enum(u32) {
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
    _,
};

pub const Command = enum(u8) {
    DISPATCH,
    SET_ACTIVITY,
    SUBSCRIBE,
    UNSUBSCRIBE,
    SEND_ACTIVITY_JOIN_INVITE,
    CLOSE_ACTIVITY_JOIN_REQUEST,
    _,
};

pub const ServerEvent = enum(u8) {
    READY,
    ERROR,
    ACTIVITY_JOIN,
    ACTIVITY_SPECTATE,
    ACTIVITY_JOIN_REQUEST,
    _,
};

pub const PacketData = ServerPacket(?struct {});

pub fn ServerPacket(comptime DataType: type) type {
    return struct {
        cmd: Command,
        evt: ?ServerEvent,
        nonce: ?[]const u8 = null,
        data: DataType,
    };
}

pub fn ArrayString(comptime len: comptime_int) type {
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

        pub fn createNullable(str: ?[]const u8) ?Self {
            return if (str) create(str) else null;
        }

        pub fn createFromFormat(comptime fmt: []const u8, args: anytype) !Self {
            var self: Self = undefined;

            var writer = std.Io.Writer.fixed(&self.buf);
            try writer.print(fmt, args);
            self.len = writer.end;

            return self;
        }
    };
}

pub const Handshake = Packet(.handshake, struct {
    v: i32,
    nonce: []const u8,
    client_id: []const u8,
});

pub const PresencePacket = Packet(.frame, struct {
    cmd: Command,
    nonce: []const u8,
    args: PresenceCommand,
});

pub const ReadyEventData = struct {
    v: i32,
    config: Configuration,
    user: User,
};

pub const PresenceCommand = struct {
    pid: i32,
    activity: ?Presence,
};

pub const Configuration = struct {
    api_endpoint: []const u8,
    cdn_host: []const u8,
    environment: []const u8,
};

pub const User = struct {
    pub const AvatarFormat = enum(u8) {
        PNG,
        JPEG,
        WebP,
        GIF,
        _,
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
        _,

        pub const jsonStringify = enumIntJsonStringify;
    };

    pub const Flags = i32;

    pub const PremiumType = enum(i32) {
        none = 0,
        nitro_classic = 1,
        nitro = 2,
        nitro_basic = 3,
        _,

        pub const jsonStringify = enumIntJsonStringify;
    };

    id: u64 = 0,
    username: []const u8 = "",
    discriminator: u16 = 0,
    global_name: []const u8 = "",
    avatar: []const u8 = "",
    flags: Flags = 0,
    premium_type: PremiumType = .none,
};

pub const Presence = struct {
    pub const Button = struct {
        label: ArrayString(31),
        url: ArrayString(512),
    };

    //all in unix epoch
    pub const Timestamps = struct {
        start: ?u64,
        end: ?u64,
    };

    pub const Assets = struct {
        large_image: ?ArrayString(256),
        large_text: ?ArrayString(128),
        large_url: ?ArrayString(256),
        small_image: ?ArrayString(256),
        small_text: ?ArrayString(128),
        small_url: ?ArrayString(256),
    };

    pub const Party = struct {
        pub const Privacy = enum(i32) {
            private = 0,
            public = 1,
            _,

            pub const jsonStringify = enumIntJsonStringify;
        };

        id: ArrayString(128),
        privacy: Privacy,
        ///Element 0 is size, element 1 is max
        size: []const i32,
    };

    pub const Secrets = struct {
        join: ArrayString(128),
    };

    pub const ActivityType = enum(i32) {
        playing = 0,
        listening = 2,
        watching = 3,
        competing = 5,
        _,

        pub const jsonStringify = enumIntJsonStringify;
    };

    pub const StatusDisplayType = enum(i32) {
        name = 0,
        state = 1,
        details = 2,

        pub const jsonStringify = enumIntJsonStringify;
    };

    buttons: ?[]const Button,
    state: ?ArrayString(128),
    state_url: ?ArrayString(256),
    name: ?ArrayString(256),
    details: ?ArrayString(128),
    details_url: ?ArrayString(256),
    timestamps: ?Timestamps,
    assets: ?Assets,
    party: ?Party,
    secrets: ?Secrets,
    type: ?ActivityType,
    status_display_type: ?StatusDisplayType,
};
