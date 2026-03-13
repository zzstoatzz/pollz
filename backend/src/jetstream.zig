const std = @import("std");
const mem = std.mem;
const json = std.json;
const Allocator = mem.Allocator;
const zat = @import("zat");
const db = @import("db.zig");

const POLL_COLLECTION = "tech.waow.pollz.poll";
const VOTE_COLLECTION = "tech.waow.pollz.vote";

const Handler = struct {
    allocator: Allocator,
    msg_count: usize = 0,

    pub fn onEvent(self: *Handler, event: zat.JetstreamEvent) void {
        self.msg_count += 1;
        if (self.msg_count % 100 == 1) {
            std.debug.print("jetstream: processed {} events\n", .{self.msg_count});
        }

        switch (event) {
            .commit => |commit| processCommit(self.allocator, commit) catch |err| {
                std.debug.print("commit processing error: {}\n", .{err});
            },
            else => {},
        }
    }

    pub fn onConnect(_: *Handler, host: []const u8) void {
        std.debug.print("jetstream connected to {s}\n", .{host});
    }

    pub fn onError(_: *Handler, err: anyerror) void {
        std.debug.print("jetstream error: {s}\n", .{@errorName(err)});
    }
};

fn processCommit(allocator: Allocator, commit: zat.jetstream.CommitEvent) !void {
    const collection = commit.collection;
    const is_poll = mem.eql(u8, collection, POLL_COLLECTION);
    const is_vote = mem.eql(u8, collection, VOTE_COLLECTION);
    if (!is_poll and !is_vote) return;

    const uri = try std.fmt.allocPrint(allocator, "at://{s}/{s}/{s}", .{ commit.did, collection, commit.rkey });
    defer allocator.free(uri);

    switch (commit.operation) {
        .create, .update => {
            const record = commit.record orelse return;
            if (record != .object) return;

            if (is_poll) {
                try processPoll(allocator, uri, commit.did, commit.rkey, record.object);
            } else {
                try processVote(uri, commit.did, record.object);
            }
        },
        .delete => {
            if (is_poll) {
                db.deletePoll(uri);
                std.debug.print("deleted poll: {s}\n", .{uri});
            } else {
                db.deleteVote(uri);
                std.debug.print("deleted vote: {s}\n", .{uri});
            }
        },
    }
}

fn processPoll(allocator: Allocator, uri: []const u8, did: []const u8, rkey: []const u8, record: json.ObjectMap) !void {
    const text_val = record.get("text") orelse return;
    if (text_val != .string) return;

    const options_val = record.get("options") orelse return;
    if (options_val != .array) return;

    const created_at_val = record.get("createdAt") orelse return;
    if (created_at_val != .string) return;

    var options_buf: std.ArrayList(u8) = .{};
    defer options_buf.deinit(allocator);
    try options_buf.print(allocator, "{f}", .{json.fmt(options_val, .{})});

    var text_buf: std.ArrayList(u8) = .{};
    defer text_buf.deinit(allocator);
    try text_buf.print(allocator, "{f}", .{json.fmt(text_val, .{})});

    try db.insertPoll(uri, did, rkey, text_buf.items, options_buf.items, created_at_val.string);
    std.debug.print("indexed poll: {s}\n", .{uri});
}

fn processVote(uri: []const u8, did: []const u8, record: json.ObjectMap) !void {
    const subject_val = record.get("subject") orelse return;
    if (subject_val != .string) return;

    const option_val = record.get("option") orelse return;
    if (option_val != .integer) return;

    const created_at: ?[]const u8 = if (record.get("createdAt")) |v| (if (v == .string) v.string else null) else null;

    try db.insertVote(uri, subject_val.string, @as(i32, @intCast(option_val.integer)), did, created_at);
    std.debug.print("indexed vote: {s} -> {s}\n", .{ uri, subject_val.string });
}

pub fn start(allocator: Allocator) void {
    var client = zat.JetstreamClient.init(allocator, .{
        .wanted_collections = &.{ POLL_COLLECTION, VOTE_COLLECTION },
    });
    defer client.deinit();

    var handler = Handler{ .allocator = allocator };
    client.subscribe(&handler);
}
