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

    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS cursor (
        \\  id INTEGER PRIMARY KEY CHECK (id = 1),
        \\  time_us INTEGER NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("failed to create cursor table: {}\n", .{err});
        return err;
    };

    std.debug.print("database schema initialized\n", .{});
}

pub fn getCursor() ?i64 {
    mutex.lock();
    defer mutex.unlock();

    const row = conn.row("SELECT time_us FROM cursor WHERE id = 1", .{}) catch return null;
    if (row == null) return null;
    defer row.?.deinit();
    return row.?.int(0);
}

pub fn saveCursor(time_us: i64) void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec("INSERT OR REPLACE INTO cursor (id, time_us) VALUES (1, ?)", .{time_us}) catch |err| {
        std.debug.print("failed to save cursor: {}\n", .{err});
    };
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

    // delete any existing vote by this user on this poll, then insert new one
    // this enforces one vote per user per poll
    conn.exec("DELETE FROM votes WHERE subject = ? AND voter = ?", .{ subject, voter }) catch {};

    conn.exec(
        "INSERT INTO votes (uri, subject, option, voter, created_at) VALUES (?, ?, ?, ?, ?)",
        .{ uri, subject, option, voter, created_at },
    ) catch |err| {
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

    conn.exec("DELETE FROM votes WHERE uri = ?", .{uri}) catch |err| {
        std.debug.print("db delete vote error: {}\n", .{err});
    };
}
