const std = @import("std");
const net = std.net;
const Thread = std.Thread;
const db = @import("db.zig");
const http_server = @import("http.zig");
const jetstream = @import("jetstream.zig");
const backfill = @import("backfill.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // init sqlite - use DATA_PATH env or default to /data/pollz.db
    const db_path = std.posix.getenv("DATA_PATH") orelse "/data/pollz.db";
    try db.init(db_path);
    defer db.close();

    // backfill existing records from known repos at startup
    backfill.run(allocator);

    // start jetstream consumer in background
    const jetstream_thread = try Thread.spawn(.{}, jetstream.consumer, .{allocator});
    defer jetstream_thread.join();

    // start http server (bind to 0.0.0.0 for containerized deployments)
    const address = try net.Address.parseIp("0.0.0.0", 3000);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("pollz backend listening on http://127.0.0.1:3000\n", .{});

    while (true) {
        const conn = try server.accept();
        _ = try Thread.spawn(.{}, http_server.handleConnection, .{conn});
    }
}
