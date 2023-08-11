const std = @import("std");
const rpc = @import("rpc");

pub fn main() !void {
    var rpc_client = try rpc.init(std.heap.c_allocator);
    defer rpc_client.deinit();

    var thread = try std.Thread.spawn(.{}, run_rpc, .{rpc_client});
    defer thread.join();

    std.time.sleep(std.time.ns_per_s * 10);

    rpc_client.stop();
    std.debug.print("stopping other thread.\n", .{});
}

fn run_rpc(rpc_client: *rpc) void {
    rpc_client.run(.{
        .client_id = "908631391934222366",
    }) catch unreachable;
}
