const std = @import("std");
const mem = std.mem;
const json = std.json;
const posix = std.posix;
const Allocator = mem.Allocator;
const websocket = @import("websocket");
const db = @import("db.zig");

const POLL_COLLECTION = "tech.waow.poll";
const VOTE_COLLECTION = "tech.waow.vote";

// tap url from env or default to fly.io internal network
fn getTapHost() []const u8 {
    return std.posix.getenv("TAP_HOST") orelse "pollz-tap.fly.dev";
}

fn getTapPort() u16 {
    const port_str = std.posix.getenv("TAP_PORT") orelse "443";
    return std.fmt.parseInt(u16, port_str, 10) catch 443;
}

fn useTls() bool {
    const port = getTapPort();
    return port == 443;
}

pub fn consumer(allocator: Allocator) void {
    // exponential backoff: 1s -> 2s -> 4s -> ... -> 60s cap
    var backoff: u64 = 1;
    const max_backoff: u64 = 60;

    while (true) {
        connect(allocator) catch |err| {
            std.debug.print("tap error: {}, reconnecting in {}s...\n", .{ err, backoff });
        };
        posix.nanosleep(backoff, 0);
        backoff = @min(backoff * 2, max_backoff);
    }
}

const Handler = struct {
    allocator: Allocator,
    msg_count: usize = 0,

    pub fn serverMessage(self: *Handler, data: []const u8) !void {
        self.msg_count += 1;
        if (self.msg_count % 100 == 1) {
            std.debug.print("tap: received {} messages\n", .{self.msg_count});
        }
        processMessage(self.allocator, data) catch |err| {
            std.debug.print("message processing error: {}\n", .{err});
        };
    }

    pub fn close(_: *Handler) void {
        std.debug.print("tap connection closed\n", .{});
    }
};

fn connect(allocator: Allocator) !void {
    const host = getTapHost();
    const port = getTapPort();
    const tls = useTls();

    const path = "/channel";

    std.debug.print("connecting to {s}://{s}:{d}{s}\n", .{ if (tls) "wss" else "ws", host, port, path });

    var client = websocket.Client.init(allocator, .{
        .host = host,
        .port = port,
        .tls = tls,
    }) catch |err| {
        std.debug.print("websocket client init failed: {}\n", .{err});
        return err;
    };
    defer client.deinit();

    std.debug.print("tcp connected, starting handshake...\n", .{});

    var host_header_buf: [256]u8 = undefined;
    const host_header = std.fmt.bufPrint(&host_header_buf, "Host: {s}\r\n", .{host}) catch "Host: pollz-tap.fly.dev\r\n";

    client.handshake(path, .{ .headers = host_header }) catch |err| {
        std.debug.print("websocket handshake failed: {}\n", .{err});
        return err;
    };

    std.debug.print("tap connected!\n", .{});

    var handler = Handler{ .allocator = allocator };
    client.readLoop(&handler) catch |err| {
        std.debug.print("websocket read loop error: {}\n", .{err});
        return err;
    };
}

fn processMessage(allocator: Allocator, payload: []const u8) !void {
    // parse tap event
    const parsed = json.parseFromSlice(json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();

    const root = parsed.value.object;

    // tap format: { "id": 123, "type": "record", "record": { ... } }
    const msg_type = root.get("type") orelse return;
    if (msg_type != .string) return;

    if (!mem.eql(u8, msg_type.string, "record")) return;

    const record_wrapper = root.get("record") orelse return;
    if (record_wrapper != .object) return;

    const rec = record_wrapper.object;

    const collection = rec.get("collection") orelse return;
    if (collection != .string) return;

    const action = rec.get("action") orelse return;
    if (action != .string) return;

    const did = rec.get("did") orelse return;
    if (did != .string) return;

    const rkey = rec.get("rkey") orelse return;
    if (rkey != .string) return;

    const uri_str = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ did.string, collection.string, rkey.string });
    defer allocator.free(uri_str);

    if (mem.eql(u8, action.string, "create") or mem.eql(u8, action.string, "update")) {
        const record = rec.get("record") orelse return;
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
    } else if (mem.eql(u8, action.string, "delete")) {
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
