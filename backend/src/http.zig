const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const json = std.json;
const db = @import("db.zig");

pub fn handleConnection(conn: net.Server.Connection) void {
    defer conn.stream.close();

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    var reader = conn.stream.reader(&read_buffer);
    var writer = conn.stream.writer(&write_buffer);

    var server = http.Server.init(reader.interface(), &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| {
            // this is expected for idle connections
            if (err != error.HttpConnectionClosing and err != error.EndOfStream) {
                std.debug.print("http receive error: {}\n", .{err});
            }
            return;
        };
        handleRequest(&server, &request) catch |err| {
            std.debug.print("request error: {}\n", .{err});
            return;
        };
        if (!request.head.keep_alive) return;
    }
}

fn handleRequest(server: *http.Server, request: *http.Server.Request) !void {
    _ = server;
    const target = request.head.target;

    // cors preflight
    if (request.head.method == .OPTIONS) {
        try sendCorsHeaders(request, "");
        return;
    }

    if (mem.startsWith(u8, target, "/api/polls")) {
        if (mem.eql(u8, target, "/api/polls")) {
            try handleGetPolls(request);
        } else if (mem.indexOf(u8, target, "/votes")) |votes_idx| {
            // /api/polls/:uri/votes
            const uri_encoded = target["/api/polls/".len..votes_idx];
            try handleGetVotes(request, uri_encoded);
        } else if (mem.startsWith(u8, target, "/api/polls/")) {
            const uri_encoded = target["/api/polls/".len..];
            try handleGetPoll(request, uri_encoded);
        }
    } else if (mem.eql(u8, target, "/health")) {
        try sendJson(request, "{\"status\":\"ok\"}");
    } else {
        try sendNotFound(request);
    }
}

fn handleGetPolls(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    db.mutex.lock();
    defer db.mutex.unlock();

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(alloc);

    try response.appendSlice(alloc, "[");

    var rows = db.conn.rows(
        "SELECT uri, repo, rkey, text, options, created_at FROM polls ORDER BY created_at DESC",
        .{},
    ) catch {
        try sendJson(request, "[]");
        return;
    };
    defer rows.deinit();

    var first = true;
    while (rows.next()) |row| {
        if (!first) try response.appendSlice(alloc, ",");
        first = false;

        const uri = row.text(0);
        const repo = row.text(1);
        const rkey = row.text(2);
        const text_json = row.text(3);
        const options_json = row.text(4);
        const created_at = row.text(5);

        // count votes for this poll
        const vote_count: i64 = blk: {
            const vrow = db.conn.row("SELECT COUNT(*) FROM votes WHERE subject = ?", .{uri}) catch break :blk 0;
            if (vrow) |r| {
                defer r.deinit();
                break :blk r.int(0);
            }
            break :blk 0;
        };

        try response.print(alloc,
            \\{{"uri":"{s}","repo":"{s}","rkey":"{s}","text":{s},"options":{s},"createdAt":"{s}","voteCount":{d}}}
        , .{ uri, repo, rkey, text_json, options_json, created_at, vote_count });
    }

    if (rows.err) |err| {
        std.debug.print("rows error: {}\n", .{err});
    }

    try response.appendSlice(alloc, "]");
    try sendJson(request, response.items);
}

fn handleGetPoll(request: *http.Server.Request, uri_encoded: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // decode uri
    const uri_buf = try alloc.dupe(u8, uri_encoded);
    const uri = std.Uri.percentDecodeInPlace(uri_buf);

    db.mutex.lock();
    defer db.mutex.unlock();

    const row = db.conn.row("SELECT uri, repo, rkey, text, options, created_at FROM polls WHERE uri = ?", .{uri}) catch {
        try sendNotFound(request);
        return;
    };
    if (row == null) {
        try sendNotFound(request);
        return;
    }
    defer row.?.deinit();

    const poll_uri = row.?.text(0);
    const repo = row.?.text(1);
    const rkey = row.?.text(2);
    const text_json = row.?.text(3);
    const options_json = row.?.text(4);
    const created_at = row.?.text(5);

    // parse options array to get count
    const parsed = json.parseFromSlice(json.Value, alloc, options_json, .{}) catch {
        try sendNotFound(request);
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .array) {
        try sendNotFound(request);
        return;
    }

    const options = parsed.value.array.items;

    // build response
    var response: std.ArrayList(u8) = .{};
    defer response.deinit(alloc);

    try response.print(alloc,
        \\{{"uri":"{s}","repo":"{s}","rkey":"{s}","text":{s},"options":[
    , .{ poll_uri, repo, rkey, text_json });

    for (options, 0..) |opt, i| {
        if (i > 0) try response.appendSlice(alloc, ",");

        const count: i64 = blk: {
            const vrow = db.conn.row("SELECT COUNT(*) FROM votes WHERE subject = ? AND option = ?", .{ poll_uri, @as(i32, @intCast(i)) }) catch break :blk 0;
            if (vrow) |r| {
                defer r.deinit();
                break :blk r.int(0);
            }
            break :blk 0;
        };

        const opt_text = if (opt == .string) opt.string else "";
        try response.print(alloc,
            \\{{"text":"{s}","count":{d}}}
        , .{ opt_text, count });
    }

    try response.print(alloc,
        \\],"createdAt":"{s}"}}
    , .{created_at});

    try sendJson(request, response.items);
}

fn handleGetVotes(request: *http.Server.Request, uri_encoded: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // decode uri
    const uri_buf = try alloc.dupe(u8, uri_encoded);
    const uri = std.Uri.percentDecodeInPlace(uri_buf);

    db.mutex.lock();
    defer db.mutex.unlock();

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(alloc);

    try response.appendSlice(alloc, "[");

    var rows = db.conn.rows(
        "SELECT voter, option, uri, created_at FROM votes WHERE subject = ?",
        .{uri},
    ) catch {
        try sendJson(request, "[]");
        return;
    };
    defer rows.deinit();

    var first = true;
    while (rows.next()) |row| {
        if (!first) try response.appendSlice(alloc, ",");
        first = false;

        const voter = row.text(0);
        const option = row.int(1);
        const vote_uri = row.text(2);
        const created_at = row.text(3);

        try response.print(alloc,
            \\{{"voter":"{s}","option":{d},"uri":"{s}","createdAt":"{s}"}}
        , .{ voter, option, vote_uri, created_at });
    }

    if (rows.err) |err| {
        std.debug.print("votes query error: {}\n", .{err});
    }

    try response.appendSlice(alloc, "]");
    try sendJson(request, response.items);
}

fn sendJson(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
        },
    });
}

fn sendCorsHeaders(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = "*" },
            .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
        },
    });
}

fn sendNotFound(request: *http.Server.Request) !void {
    try request.respond("{\"error\":\"not found\"}", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = "*" },
        },
    });
}
