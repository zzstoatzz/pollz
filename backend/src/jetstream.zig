const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const db = @import("db.zig");

const POLL_COLLECTION = "tech.waow.poll";
const VOTE_COLLECTION = "tech.waow.vote";

pub fn consumer(allocator: Allocator) void {
    while (true) {
        connect(allocator) catch |err| {
            std.debug.print("jetstream error: {}, reconnecting in 3s...\n", .{err});
        };
        posix.nanosleep(3, 0);
    }
}

const Handler = struct {
    allocator: Allocator,
    msg_count: usize = 0,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 100 == 1) {
            std.debug.print("jetstream: received {} messages\n", .{self.msg_count});
        }
        processMessage(self.allocator, data) catch |err| {
            std.debug.print("message processing error: {}\n", .{err});
        };
    }

    pub fn close(_: *Handler) void {
        std.debug.print("jetstream connection closed\n", .{});
    }
};

fn connect(allocator: Allocator) !void {
    const host = "jetstream1.us-east.bsky.network";

    var path_buf: [512]u8 = undefined;

    // only use saved cursor if we have one (for resuming after disconnect)
    // otherwise start from NOW - UFOs handles backfill, Jetstream is for live events only
    const path = if (db.getCursor()) |cursor|
        std.fmt.bufPrint(&path_buf, "/subscribe?wantedCollections={s}&wantedCollections={s}&cursor={d}", .{ POLL_COLLECTION, VOTE_COLLECTION, cursor }) catch "/subscribe"
    else
        std.fmt.bufPrint(&path_buf, "/subscribe?wantedCollections={s}&wantedCollections={s}", .{ POLL_COLLECTION, VOTE_COLLECTION }) catch "/subscribe";

    std.debug.print("connecting to wss://{s}{s}\n", .{ host, path });

    var client = websocket.Client.init(allocator, .{
        .host = host,
        .port = 443,
        .tls = true,
    }) catch |err| {
        std.debug.print("websocket client init failed: {}\n", .{err});
        return err;
    };
    defer client.deinit();

    std.debug.print("tcp+tls connected, starting handshake...\n", .{});

    // add Host header which is required for websocket handshake
    var host_header_buf: [128]u8 = undefined;
    const host_header = std.fmt.bufPrint(&host_header_buf, "Host: {s}\r\n", .{host}) catch "Host: jetstream1.us-east.bsky.network\r\n";

    client.handshake(path, .{ .headers = host_header }) catch |err| {
        std.debug.print("websocket handshake failed: {}\n", .{err});
        return err;
    };

    std.debug.print("jetstream connected!\n", .{});

    var handler = Handler{ .allocator = allocator };
    client.readLoop(&handler) catch |err| {
        std.debug.print("websocket read loop error: {}\n", .{err});
        return err;
    };
}

fn processMessage(allocator: Allocator, payload: []const u8) !void {
    // parse jetstream event
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;

    // save cursor from event timestamp
    if (root.get("time_us")) |time_us_val| {
        if (time_us_val == .integer) {
            db.saveCursor(time_us_val.integer);
        }
    }

    const kind = root.get("kind") orelse return;
    if (kind != .string) return;

    if (!mem.eql(u8, kind.string, "commit")) return;

    const commit = root.get("commit") orelse return;
    if (commit != .object) return;

    const collection = commit.object.get("collection") orelse return;
    if (collection != .string) return;

    const operation = commit.object.get("operation") orelse return;
    if (operation != .string) return;

    const did = root.get("did") orelse return;
    if (did != .string) return;

    const rkey = commit.object.get("rkey") orelse return;
    if (rkey != .string) return;

    const uri_str = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ did.string, collection.string, rkey.string });
    defer allocator.free(uri_str);

    if (mem.eql(u8, operation.string, "create")) {
        const record = commit.object.get("record") orelse return;
        if (record != .object) return;

        if (mem.eql(u8, collection.string, POLL_COLLECTION)) {
            processPoll(allocator, uri_str, did.string, rkey.string, record.object) catch |err| {
                std.debug.print("poll processing error: {}\n", .{err});
            };
        } else if (mem.eql(u8, collection.string, VOTE_COLLECTION)) {
            processVote(uri_str, did.string, record.object) catch |err| {
                std.debug.print("vote processing error: {}\n", .{err});
            };
        }
    } else if (mem.eql(u8, operation.string, "delete")) {
        if (mem.eql(u8, collection.string, POLL_COLLECTION)) {
            db.deletePoll(uri_str);
            std.debug.print("deleted poll: {s}\n", .{uri_str});
        } else if (mem.eql(u8, collection.string, VOTE_COLLECTION)) {
            db.deleteVote(uri_str);
            std.debug.print("deleted vote: {s}\n", .{uri_str});
        }
    }
}

pub fn processPoll(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const text_val = record.get("text") orelse return;
    if (text_val != .string) return;

    const options_val = record.get("options") orelse return;
    if (options_val != .array) return;

    const created_at_val = record.get("createdAt") orelse return;
    if (created_at_val != .string) return;

    // serialize options as json
    var options_buf: std.ArrayList(u8) = .{};
    defer options_buf.deinit(allocator);
    try options_buf.print(allocator, "{f}", .{json.fmt(options_val, .{})});

    // serialize text as json (to escape quotes properly)
    var text_buf: std.ArrayList(u8) = .{};
    defer text_buf.deinit(allocator);
    try text_buf.print(allocator, "{f}", .{json.fmt(text_val, .{})});

    try db.insertPoll(uri, did, rkey, text_buf.items, options_buf.items, created_at_val.string);
    std.debug.print("indexed poll: {s}\n", .{uri});
}

pub fn processVote(uri: []const u8, did: []const u8, record: json.ObjectMap) !void {
    const subject_val = record.get("subject") orelse return;
    if (subject_val != .string) return;

    const option_val = record.get("option") orelse return;
    if (option_val != .integer) return;

    const created_at: ?[]const u8 = if (record.get("createdAt")) |v| (if (v == .string) v.string else null) else null;

    try db.insertVote(uri, subject_val.string, @as(i32, @intCast(option_val.integer)), did, created_at);
    std.debug.print("indexed vote: {s} -> {s}\n", .{ uri, subject_val.string });
}
