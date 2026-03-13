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

    // Profiles cache
    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS profiles (
        \\  did TEXT PRIMARY KEY,
        \\  handle TEXT,
        \\  avatar_url TEXT,
        \\  fetched_at INTEGER NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("failed to create profiles table: {}\n", .{err});
        return err;
    };

    // OAuth tables
    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS oauth_auth_request (
        \\  state TEXT PRIMARY KEY,
        \\  authserver_iss TEXT NOT NULL,
        \\  did TEXT NOT NULL,
        \\  handle TEXT NOT NULL,
        \\  pds_url TEXT NOT NULL,
        \\  pkce_verifier TEXT NOT NULL,
        \\  scope TEXT NOT NULL,
        \\  dpop_authserver_nonce TEXT NOT NULL DEFAULT '',
        \\  dpop_private_key BLOB NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("failed to create oauth_auth_request table: {}\n", .{err});
        return err;
    };

    conn.execNoArgs(
        \\CREATE TABLE IF NOT EXISTS oauth_session (
        \\  did TEXT PRIMARY KEY,
        \\  handle TEXT NOT NULL,
        \\  pds_url TEXT NOT NULL,
        \\  authserver_iss TEXT NOT NULL,
        \\  access_token TEXT NOT NULL,
        \\  refresh_token TEXT NOT NULL,
        \\  dpop_authserver_nonce TEXT NOT NULL DEFAULT '',
        \\  dpop_pds_nonce TEXT NOT NULL DEFAULT '',
        \\  dpop_private_key BLOB NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\)
    ) catch |err| {
        std.debug.print("failed to create oauth_session table: {}\n", .{err});
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

// --- OAuth ---

pub fn insertAuthRequest(
    state: []const u8,
    authserver_iss: []const u8,
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    pkce_verifier: []const u8,
    scope: []const u8,
    dpop_nonce: []const u8,
    dpop_private_key: []const u8,
) !void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec(
        \\INSERT INTO oauth_auth_request
        \\  (state, authserver_iss, did, handle, pds_url, pkce_verifier, scope, dpop_authserver_nonce, dpop_private_key, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        state,
        authserver_iss,
        did,
        handle,
        pds_url,
        pkce_verifier,
        scope,
        dpop_nonce,
        dpop_private_key,
        @as(i64, @intCast(std.time.timestamp())),
    }) catch |err| {
        std.debug.print("db insert auth request error: {}\n", .{err});
        return err;
    };
}

pub const AuthRequest = struct {
    state: []const u8,
    authserver_iss: []const u8,
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    pkce_verifier: []const u8,
    scope: []const u8,
    dpop_authserver_nonce: []const u8,
    dpop_private_key: []const u8,
};

pub fn getAuthRequest(state: []const u8) ?AuthRequest {
    mutex.lock();
    defer mutex.unlock();

    const row = conn.row(
        "SELECT state, authserver_iss, did, handle, pds_url, pkce_verifier, scope, dpop_authserver_nonce, dpop_private_key FROM oauth_auth_request WHERE state = ?",
        .{state},
    ) catch return null;
    if (row == null) return null;

    return .{
        .state = row.?.text(0),
        .authserver_iss = row.?.text(1),
        .did = row.?.text(2),
        .handle = row.?.text(3),
        .pds_url = row.?.text(4),
        .pkce_verifier = row.?.text(5),
        .scope = row.?.text(6),
        .dpop_authserver_nonce = row.?.text(7),
        .dpop_private_key = row.?.text(8),
    };
}

pub fn deleteAuthRequest(state: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec("DELETE FROM oauth_auth_request WHERE state = ?", .{state}) catch |err| {
        std.debug.print("db delete auth request error: {}\n", .{err});
    };
}

pub fn upsertSession(
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    authserver_iss: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    dpop_authserver_nonce: []const u8,
    dpop_pds_nonce: []const u8,
    dpop_private_key: []const u8,
) !void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec(
        \\INSERT INTO oauth_session
        \\  (did, handle, pds_url, authserver_iss, access_token, refresh_token,
        \\   dpop_authserver_nonce, dpop_pds_nonce, dpop_private_key, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(did) DO UPDATE SET
        \\  handle = excluded.handle,
        \\  access_token = excluded.access_token,
        \\  refresh_token = excluded.refresh_token,
        \\  dpop_authserver_nonce = excluded.dpop_authserver_nonce,
        \\  dpop_pds_nonce = excluded.dpop_pds_nonce,
        \\  created_at = excluded.created_at
    , .{
        did,
        handle,
        pds_url,
        authserver_iss,
        access_token,
        refresh_token,
        dpop_authserver_nonce,
        dpop_pds_nonce,
        dpop_private_key,
        @as(i64, @intCast(std.time.timestamp())),
    }) catch |err| {
        std.debug.print("db upsert session error: {}\n", .{err});
        return err;
    };
}

pub const Session = struct {
    did: []const u8,
    handle: []const u8,
    pds_url: []const u8,
    authserver_iss: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    dpop_authserver_nonce: []const u8,
    dpop_pds_nonce: []const u8,
    dpop_private_key: []const u8,
};

pub fn getSession(did: []const u8) ?Session {
    mutex.lock();
    defer mutex.unlock();

    const row = conn.row(
        \\SELECT did, handle, pds_url, authserver_iss, access_token, refresh_token,
        \\  dpop_authserver_nonce, dpop_pds_nonce, dpop_private_key
        \\FROM oauth_session WHERE did = ?
    , .{did}) catch return null;
    if (row == null) return null;

    return .{
        .did = row.?.text(0),
        .handle = row.?.text(1),
        .pds_url = row.?.text(2),
        .authserver_iss = row.?.text(3),
        .access_token = row.?.text(4),
        .refresh_token = row.?.text(5),
        .dpop_authserver_nonce = row.?.text(6),
        .dpop_pds_nonce = row.?.text(7),
        .dpop_private_key = row.?.text(8),
    };
}

pub fn deleteSession(did: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec("DELETE FROM oauth_session WHERE did = ?", .{did}) catch |err| {
        std.debug.print("db delete session error: {}\n", .{err});
    };
}

pub fn updateSessionNonce(did: []const u8, field: enum { authserver, pds }, nonce: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    switch (field) {
        .authserver => conn.exec("UPDATE oauth_session SET dpop_authserver_nonce = ? WHERE did = ?", .{ nonce, did }) catch {},
        .pds => conn.exec("UPDATE oauth_session SET dpop_pds_nonce = ? WHERE did = ?", .{ nonce, did }) catch {},
    }
}

pub fn updateSessionTokens(did: []const u8, access_token: []const u8, refresh_token: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec("UPDATE oauth_session SET access_token = ?, refresh_token = ? WHERE did = ?", .{ access_token, refresh_token, did }) catch {};
}

pub fn cleanupExpiredAuthRequests() void {
    mutex.lock();
    defer mutex.unlock();

    // delete auth requests older than 10 minutes
    const cutoff = @as(i64, @intCast(std.time.timestamp())) - 600;
    conn.exec("DELETE FROM oauth_auth_request WHERE created_at < ?", .{cutoff}) catch {};
}

// --- Profiles cache ---

pub const Profile = struct {
    did: []const u8,
    handle: []const u8,
    avatar_url: []const u8,
    fetched_at: i64,
};

pub fn getProfile(did: []const u8) ?Profile {
    mutex.lock();
    defer mutex.unlock();

    const row = conn.row(
        "SELECT did, handle, avatar_url, fetched_at FROM profiles WHERE did = ?",
        .{did},
    ) catch return null;
    if (row == null) return null;

    return .{
        .did = row.?.text(0),
        .handle = row.?.text(1),
        .avatar_url = row.?.text(2),
        .fetched_at = row.?.int(3),
    };
}

pub fn upsertProfile(did: []const u8, handle: []const u8, avatar_url: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    conn.exec(
        \\INSERT INTO profiles (did, handle, avatar_url, fetched_at)
        \\VALUES (?, ?, ?, ?)
        \\ON CONFLICT(did) DO UPDATE SET
        \\  handle = excluded.handle,
        \\  avatar_url = excluded.avatar_url,
        \\  fetched_at = excluded.fetched_at
    , .{
        did,
        handle,
        avatar_url,
        @as(i64, @intCast(std.time.timestamp())),
    }) catch |err| {
        std.debug.print("db upsert profile error: {}\n", .{err});
    };
}

/// get handle for a DID from cache (no locking - caller must hold mutex or accept races)
pub fn getHandleForDid(did: []const u8) ?[]const u8 {
    const row = conn.row(
        "SELECT handle FROM profiles WHERE did = ?",
        .{did},
    ) catch return null;
    if (row == null) return null;
    return row.?.text(0);
}
