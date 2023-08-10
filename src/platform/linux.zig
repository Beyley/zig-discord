const std = @import("std");

pub fn getpid() std.os.pid_t {
    return std.os.linux.getpid();
}
