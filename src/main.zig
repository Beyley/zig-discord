const std = @import("std");
const rpc = @import("rpc");

pub fn main() !void {
    var rpc_client = try rpc.init(std.heap.c_allocator);
    defer rpc_client.deinit();

    try rpc_client.run(.{
        .client_id = "908631391934222366",
    });
}
