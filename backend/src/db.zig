const std = @import("std");
const json = std.json;
const mem = std.mem;
const Thread = std.Thread;
const Allocator = mem.Allocator;
const zqlite = @import("zqlite");

pub var conn: zqlite.Conn = undefined;
pub var mutex: Thread.Mutex = .{};

pub fn init(path: [*:0]const u8) !void {
    std.debug.print("opening database at: {s}\n", .{path});
    conn = zqlite.open(path, zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite) catch |err| {
        std.debug.print("failed to open database: {}\n", .{err});
        return err;
    };
    try initSchema();
}

pub fn close() void {
    conn.close();
}

fn initSchema() !void {
    mutex.lock();
    defer mutex.unlock();

    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS polls (
        \\  uri TEXT PRIMARY KEY,
        \\  repo TEXT NOT NULL,
        \\  rkey TEXT NOT NULL,
        \\  text TEXT NOT NULL,
        \\  options TEXT NOT NULL,
        \\  created_at TEXT NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("failed to create polls table: {}\n", .{err});
        return err;
    };

    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS votes (
        \\  uri TEXT PRIMARY KEY,
        \\  subject TEXT NOT NULL,
        \\  option INTEGER NOT NULL,
        \\  voter TEXT NOT NULL,
        \\  created_at TEXT,
        \\  UNIQUE(subject, voter)
        \\)
    ) catch |err| {
        std.debug.print("failed to create votes table: {}\n", .{err});
        return err;
    };

    // add created_at column if it doesn't exist (migration for existing DBs)
    conn.execNoArgs("ALTER TABLE votes ADD COLUMN created_at TEXT") catch {};

    conn.execNoArgs(
        \\CREATE INDEX IF NOT EXISTS idx_votes_subject ON votes(subject)
    ) catch |err| {
        std.debug.print("failed to create index: {}\n", .{err});
        return err;
    };

    conn.execNoArgs(
        \\CREATE INDEX IF NOT EXISTS idx_votes_voter ON votes(subject, voter)
    ) catch |err| {
        std.debug.print("failed to create voter index: {}\n", .{err});
        return err;
    };

    std.debug.print("database schema initialized\n", .{});
}

pub fn insertPoll(uri: []const u8, did: []const u8, rkey: []const u8, text_json: []const u8, options_json: []const u8, created_at: []const u8) !void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec(
        "INSERT OR IGNORE INTO polls (uri, repo, rkey, text, options, created_at) VALUES (?, ?, ?, ?, ?, ?)",
        .{ uri, did, rkey, text_json, options_json, created_at },
    ) catch |err| {
        std.debug.print("db insert poll error: {}\n", .{err});
        return err;
    };
}

pub fn insertVote(uri: []const u8, subject: []const u8, option: i32, voter: []const u8, created_at: ?[]const u8) !void {
    mutex.lock();
    defer mutex.unlock();

    // upsert: update if exists and new vote is newer, otherwise insert
    // this handles out-of-order events from tap
    conn.exec(
        \\INSERT INTO votes (uri, subject, option, voter, created_at)
        \\VALUES (?, ?, ?, ?, ?)
        \\ON CONFLICT(subject, voter) DO UPDATE SET
        \\  uri = excluded.uri,
        \\  option = excluded.option,
        \\  created_at = excluded.created_at
        \\WHERE excluded.created_at > votes.created_at OR votes.created_at IS NULL
    , .{ uri, subject, option, voter, created_at }) catch |err| {
        std.debug.print("db insert vote error: {}\n", .{err});
        return err;
    };
}

pub fn deletePoll(uri: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec("DELETE FROM polls WHERE uri = ?", .{uri}) catch |err| {
        std.debug.print("db delete poll error: {}\n", .{err});
    };
    // also delete associated votes
    conn.exec("DELETE FROM votes WHERE subject = ?", .{uri}) catch |err| {
        std.debug.print("db delete votes error: {}\n", .{err});
    };
}

pub fn deleteVote(uri: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    // only delete if the URI matches - if a newer vote replaced this one,
    // the URI won't match and we should not delete
    conn.exec("DELETE FROM votes WHERE uri = ?", .{uri}) catch |err| {
        std.debug.print("db delete vote error: {}\n", .{err});
    };
}
