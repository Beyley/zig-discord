const std = @import("std");

pub fn getpid() std.posix.pid_t {
    return std.os.linux.getpid();
}

pub const Stream = std.net.Stream;

pub fn peek(stream: Stream) !bool {
    var bytes_available: i32 = undefined;
    //TODO: clean once https://github.com/ziglang/zig/issues/16197 is closed
    const ret: std.os.linux.E = @enumFromInt(std.c.ioctl(stream.handle, std.os.linux.T.FIONREAD, @as(usize, @intFromPtr(&bytes_available))));
    switch (ret) {
        .BADF => return error.BadFileDescriptor,
        .FAULT => unreachable,
        .INVAL => return error.InvalidRequest,
        .NOTTY => unreachable,
        .SUCCESS => {},
        else => unreachable,
    }
    return bytes_available != 0;
}
