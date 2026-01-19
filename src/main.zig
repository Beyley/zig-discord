const std = @import("std");

const rpc = @import("rpc");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("LEAK");
    const allocator = gpa.allocator();

    var rpc_client = try rpc.init(allocator, &ready);
    defer rpc_client.deinit();

    var thread = try std.Thread.spawn(.{}, run_rpc, .{rpc_client});
    defer thread.join();

    var buf: [1000]u8 = undefined;
    _ = try std.fs.File.stdin().read(&buf);

    const now = std.time.milliTimestamp();

    const presence: rpc.Packet.Presence = .{
        .assets = .{
            .large_image = .create("https://f4.bcbits.com/img/a2465504892_16.jpg"),
            .large_text = .create("Album"),
            .large_url = .create("https://example.com/album_link"),
            .small_image = .create("https://f4.bcbits.com/img/0026738552_21.jpg"),
            .small_text = .create("Artist"),
            .small_url = .create("https://exmaple.com/artist_link"),
        },
        .buttons = &.{
            .{
                .label = .create("Listen"),
                .url = .create("https://example.com/listen_to_track"),
            },
            .{
                .label = .create("Lyrics"),
                .url = .create("https://example.com/track_lyrics"),
            },
        },
        .name = .create("Artist"),
        .state = .create("Lyrics"),
        .state_url = null,
        .details = .create("Song Name"),
        .details_url = .create("https://example.com/song_link"),
        .party = null,
        .secrets = null,
        .status_display_type = .name,
        .type = .listening,
        .timestamps = .{
            .start = @intCast(now - std.time.ms_per_s * 30),
            .end = @intCast(now + std.time.ms_per_s * 30),
        },
    };
    try rpc_client.setPresence(presence);

    _ = try std.fs.File.stdin().read(&buf);

    rpc_client.stop();
    std.log.info("stopping other thread.", .{});
}

fn ready(rpc_client: *rpc) anyerror!void {
    const presence: rpc.Packet.Presence = .{
        .assets = .{
            .large_image = try .createFromFormat("{s}", .{"aa"}),
            .large_text = null,
            .large_url = null,
            .small_image = null,
            .small_text = null,
            .small_url = null,
        },
        .buttons = null,
        .details = .create("awjajajajaaawawawaa"),
        .party = null,
        .name = null,
        .state_url = null,
        .details_url = null,
        .type = .listening,
        .status_display_type = null,
        .secrets = null,
        .state = .create("buguguabubguu"),
        .timestamps = .{
            .start = null,
            .end = null,
        },
    };
    try rpc_client.setPresence(presence);
}

fn run_rpc(rpc_client: *rpc) void {
    rpc_client.run(.{
        .client_id = "1414803839789301802",
    }) catch unreachable;
}
