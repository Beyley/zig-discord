const std = @import("std");
const rpc = @import("rpc");

pub fn main() !void {
    var rpc_client = try rpc.init(std.heap.c_allocator, &ready);
    defer rpc_client.deinit();

    var thread = try std.Thread.spawn(.{}, run_rpc, .{rpc_client});
    defer thread.join();

    var buf: [1000]u8 = undefined;
    _ = try std.io.getStdIn().read(&buf);

    const presence: rpc.Packet.Presence = rpc.Packet.Presence{
        .assets = .{
            .large_image = rpc.Packet.ArrayString(256).create("ptyping-mode-icon"),
            .large_text = rpc.Packet.ArrayString(128).create("waaa"),
            .small_image = rpc.Packet.ArrayString(256).create("ptyping-mode-icon"),
            .small_text = rpc.Packet.ArrayString(128).create("WAAAAAA"),
        },
        .buttons = null,
        .details = rpc.Packet.ArrayString(128).create("what the FUCK IS A YARD"),
        .party = null,
        .secrets = null,
        .state = rpc.Packet.ArrayString(128).create("i got"),
        .timestamps = .{
            .start = null,
            .end = null,
        },
    };
    rpc_client.setPresence(presence);

    _ = try std.io.getStdIn().read(&buf);

    rpc_client.stop();
    std.debug.print("stopping other thread.\n", .{});
}

fn ready(rpc_client: *rpc) anyerror!void {
    const presence: rpc.Packet.Presence = rpc.Packet.Presence{
        .assets = .{
            .large_image = rpc.Packet.ArrayString(256).create("ptyping-mode-icon"),
            .large_text = rpc.Packet.ArrayString(128).create("waaa"),
            // .small_image = rpc.Packet.ArrayString(256).create("ptyping-mode-icon"),
            .small_image = null,
            .small_text = null,
            // .small_text = rpc.Packet.ArrayString(128).create("WAAAAAA"),
        },
        .buttons = null,
        .details = rpc.Packet.ArrayString(128).create("what the FUCK IS A KILOMETER"),
        .party = null,
        .secrets = null,
        .state = rpc.Packet.ArrayString(128).create("i got ziggy with it :)"),
        .timestamps = .{
            .start = null,
            .end = null,
        },
    };
    rpc_client.setPresence(presence);
}

fn run_rpc(rpc_client: *rpc) void {
    rpc_client.run(.{
        .client_id = "908631391934222366",
    }) catch unreachable;
}
