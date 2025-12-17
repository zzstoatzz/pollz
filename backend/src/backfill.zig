const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const db = @import("db.zig");
const jetstream = @import("jetstream.zig");

pub fn run(allocator: Allocator) void {
    std.debug.print("starting backfill from ufos-api.microcosm.blue...\n", .{});

    backfillCollection(allocator, "tech.waow.poll");
    backfillCollection(allocator, "tech.waow.vote");

    std.debug.print("backfill complete\n", .{});
}

fn backfillCollection(allocator: Allocator, collection: []const u8) void {
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "https://ufos-api.microcosm.blue/records?collection={s}", .{collection}) catch return;

    std.debug.print("backfill: fetching {s} from ufos\n", .{collection});

    // make https request
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return;

    var req = client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch |err| {
        std.debug.print("backfill: http request error: {}\n", .{err});
        return;
    };
    defer req.deinit();

    req.sendBodiless() catch |err| {
        std.debug.print("backfill: http send error: {}\n", .{err});
        return;
    };

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        std.debug.print("backfill: http receive error: {}\n", .{err});
        return;
    };

    if (response.head.status != .ok) {
        std.debug.print("backfill: http status {}\n", .{response.head.status});
        return;
    }

    // read response body
    var reader = response.reader(&.{});
    const body = reader.allocRemaining(allocator, std.Io.Limit.limited(65536)) catch |err| {
        std.debug.print("backfill: http read error: {}\n", .{err});
        return;
    };
    defer allocator.free(body);

    // parse json response - UFOs returns array of {did, collection, rkey, record}
    const parsed = json.parseFromSlice(json.Value, allocator, body, .{}) catch |err| {
        std.debug.print("backfill: json parse error: {}\n", .{err});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .array) return;

    var count: usize = 0;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;

        const did = item.object.get("did") orelse continue;
        if (did != .string) continue;

        const rkey = item.object.get("rkey") orelse continue;
        if (rkey != .string) continue;

        const record = item.object.get("record") orelse continue;
        if (record != .object) continue;

        // construct record uri
        const record_uri = std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ did.string, collection, rkey.string }) catch continue;
        defer allocator.free(record_uri);

        if (mem.eql(u8, collection, "tech.waow.poll")) {
            jetstream.processPoll(allocator, record_uri, did.string, rkey.string, record.object) catch continue;
            count += 1;
        } else if (mem.eql(u8, collection, "tech.waow.vote")) {
            jetstream.processVote(record_uri, did.string, record.object) catch continue;
            count += 1;
        }
    }

    std.debug.print("backfill: indexed {d} {s} records\n", .{ count, collection });
}
