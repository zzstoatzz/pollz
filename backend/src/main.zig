const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;
const db = @import("db.zig");
const http_server = @import("http.zig");
const tap = @import("tap.zig");

// max concurrent http connections (prevents resource exhaustion)
const MAX_HTTP_WORKERS = 16;

// socket timeout in seconds
const SOCKET_TIMEOUT_SECS = 30;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // init sqlite - use DATA_PATH env or default to /data/pollz.db
    const db_path = posix.getenv("DATA_PATH") orelse "/data/pollz.db";
    try db.init(db_path);
    defer db.close();

    // start tap consumer in background
    const tap_thread = try Thread.spawn(.{}, tap.consumer, .{allocator});
    defer tap_thread.join();

    // init thread pool for http connections
    var pool: Thread.Pool = undefined;
    try pool.init(.{
        .allocator = allocator,
        .n_jobs = MAX_HTTP_WORKERS,
    });
    defer pool.deinit();

    // start http server (bind to 0.0.0.0 for containerized deployments)
    const address = try net.Address.parseIp("0.0.0.0", 3000);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("pollz backend listening on http://127.0.0.1:3000 (max {} workers)\n", .{MAX_HTTP_WORKERS});

    while (true) {
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };

        // set socket timeouts to prevent slow client attacks
        setSocketTimeout(conn.stream.handle, SOCKET_TIMEOUT_SECS) catch |err| {
            std.debug.print("failed to set socket timeout: {}\n", .{err});
        };

        pool.spawn(http_server.handleConnection, .{conn}) catch |err| {
            std.debug.print("pool spawn error: {}\n", .{err});
            conn.stream.close();
        };
    }
}

fn setSocketTimeout(fd: posix.fd_t, secs: u32) !void {
    const timeout = std.mem.toBytes(posix.timeval{
        .sec = @intCast(secs),
        .usec = 0,
    });
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout);
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &timeout);
}
