const std = @import("std");
const net = std.net;
const http = std.http;
const mem = std.mem;
const json = std.json;
const crypto = std.crypto;
const db = @import("db.zig");
const oauth = @import("oauth.zig");
const zat = @import("zat");

const SCOPE = "atproto repo:tech.waow.pollz.poll repo:tech.waow.pollz.vote";

fn getClientId() []const u8 {
    return std.posix.getenv("OAUTH_CLIENT_ID") orelse "https://api.pollz.waow.tech/oauth-client-metadata.json";
}

fn getRedirectUri() []const u8 {
    return std.posix.getenv("OAUTH_REDIRECT_URI") orelse "https://api.pollz.waow.tech/oauth/callback";
}

fn getFrontendOrigin() []const u8 {
    return std.posix.getenv("FRONTEND_ORIGIN") orelse "https://pollz.waow.tech";
}

fn getClientOrigin() []const u8 {
    // derive origin from client_id: e.g. "https://api.pollz.waow.tech/oauth/client-metadata" → "https://api.pollz.waow.tech"
    const client_id = getClientId();
    const scheme_end = mem.indexOf(u8, client_id, "://") orelse return client_id;
    const after_scheme = client_id[scheme_end + 3 ..];
    const path_start = mem.indexOf(u8, after_scheme, "/") orelse return client_id;
    return client_id[0 .. scheme_end + 3 + path_start];
}

fn getClientKeypair() !zat.Keypair {
    const key_hex = std.posix.getenv("OAUTH_CLIENT_SECRET_KEY") orelse return error.MissingClientKey;
    if (key_hex.len != 64) return error.InvalidClientKey;
    var key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, key_hex) catch return error.InvalidClientKey;
    return zat.Keypair.fromSecretKey(.p256, key_bytes);
}

pub fn handleConnection(conn_: net.Server.Connection) void {
    defer conn_.stream.close();

    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;

    var reader = conn_.stream.reader(&read_buffer);
    var writer = conn_.stream.writer(&write_buffer);

    var server = http.Server.init(reader.interface(), &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| {
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

    // OAuth client metadata (served at root path per AT Protocol convention)
    if (mem.eql(u8, target, "/oauth-client-metadata.json")) {
        try handleClientMetadata(request);
        return;
    }

    // OAuth endpoints
    if (mem.startsWith(u8, target, "/oauth/")) {
        if (mem.eql(u8, target, "/oauth/jwks")) {
            try handleJwks(request);
        } else if (mem.startsWith(u8, target, "/oauth/login")) {
            try handleLogin(request);
        } else if (mem.startsWith(u8, target, "/oauth/callback")) {
            try handleCallback(request);
        } else {
            try sendNotFound(request);
        }
        return;
    }

    // API endpoints
    if (mem.startsWith(u8, target, "/api/")) {
        if (mem.eql(u8, target, "/api/me")) {
            try handleMe(request);
        } else if (mem.startsWith(u8, target, "/api/polls")) {
            if (request.head.method == .POST) {
                if (mem.eql(u8, target, "/api/polls")) {
                    try handleCreatePoll(request);
                } else if (mem.endsWith(u8, target, "/vote")) {
                    try handleVote(request);
                } else {
                    try sendNotFound(request);
                }
            } else if (request.head.method == .DELETE) {
                if (mem.startsWith(u8, target, "/api/polls/")) {
                    const uri_encoded = target["/api/polls/".len..];
                    try handleDeletePoll(request, uri_encoded);
                } else {
                    try sendNotFound(request);
                }
            } else {
                // GET routes
                if (mem.eql(u8, target, "/api/polls")) {
                    try handleGetPolls(request);
                } else if (mem.indexOf(u8, target, "/votes")) |votes_idx| {
                    const uri_encoded = target["/api/polls/".len..votes_idx];
                    try handleGetVotes(request, uri_encoded);
                } else if (mem.startsWith(u8, target, "/api/polls/")) {
                    const uri_encoded = target["/api/polls/".len..];
                    try handleGetPoll(request, uri_encoded);
                }
            }
        } else if (mem.eql(u8, target, "/api/logout") and request.head.method == .POST) {
            try handleLogout(request);
        } else {
            try sendNotFound(request);
        }
        return;
    }

    if (mem.eql(u8, target, "/health")) {
        try sendJson(request, "{\"status\":\"ok\"}");
    } else {
        try sendNotFound(request);
    }
}

// --- OAuth endpoints ---

fn handleClientMetadata(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const client_id = getClientId();
    const redirect_uri = getRedirectUri();

    const keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };

    const jwk = oauth.jwkPublicKey(alloc, &keypair) catch {
        try sendError(request, .internal_server_error, "key error");
        return;
    };

    var body: std.ArrayList(u8) = .{};
    defer body.deinit(alloc);

    try body.print(alloc,
        \\{{
        \\  "client_id": "{s}",
        \\  "client_name": "pollz",
        \\  "client_uri": "{s}",
        \\  "application_type": "web",
        \\  "grant_types": ["authorization_code", "refresh_token"],
        \\  "response_types": ["code"],
        \\  "redirect_uris": ["{s}"],
        \\  "token_endpoint_auth_method": "private_key_jwt",
        \\  "token_endpoint_auth_signing_alg": "ES256",
        \\  "scope": "{s}",
        \\  "dpop_bound_access_tokens": true,
        \\  "jwks": {{"keys": [{s}]}}
        \\}}
    , .{ client_id, getClientOrigin(), redirect_uri, SCOPE, jwk });

    try sendJson(request, body.items);
}

fn handleJwks(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };

    const jwks = oauth.jwksJson(alloc, &keypair) catch {
        try sendError(request, .internal_server_error, "key error");
        return;
    };

    try sendJson(request, jwks);
}

fn handleLogin(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // parse ?handle= from query string
    const target = request.head.target;
    const handle_str = extractQueryParam(target, "handle") orelse {
        try sendError(request, .bad_request, "missing handle parameter");
        return;
    };

    // resolve handle → DID → PDS → auth server
    var handle_resolver = zat.HandleResolver.init(alloc);
    defer handle_resolver.deinit();

    const did = handle_resolver.resolve(zat.Handle.parse(handle_str) orelse {
        try sendError(request, .bad_request, "invalid handle");
        return;
    }) catch |err| {
        std.debug.print("handle resolution failed for '{s}': {}\n", .{ handle_str, err });
        try sendError(request, .bad_request, "could not resolve handle");
        return;
    };

    var did_resolver = zat.DidResolver.init(alloc);
    defer did_resolver.deinit();

    var did_doc = did_resolver.resolve(zat.Did.parse(did) orelse {
        try sendError(request, .bad_request, "invalid DID");
        return;
    }) catch {
        try sendError(request, .bad_request, "could not resolve DID");
        return;
    };
    defer did_doc.deinit();

    const pds_url = did_doc.pdsEndpoint() orelse {
        try sendError(request, .bad_request, "no PDS endpoint found");
        return;
    };

    // fetch PDS OAuth protected resource metadata
    const authserver_url = fetchAuthServerUrl(alloc, pds_url) catch {
        try sendError(request, .bad_request, "could not discover auth server");
        return;
    };

    // fetch auth server metadata
    var authserver_meta = fetchAuthServerMeta(alloc, authserver_url) catch {
        try sendError(request, .bad_request, "could not fetch auth server metadata");
        return;
    };
    defer authserver_meta.deinit();

    // use the issuer from metadata (not the discovered URL) for iss verification
    const authserver_iss = jsonGetString(authserver_meta.value, "issuer") orelse {
        try sendError(request, .bad_request, "auth server missing issuer");
        return;
    };

    const par_url = jsonGetString(authserver_meta.value, "pushed_authorization_request_endpoint") orelse {
        try sendError(request, .bad_request, "auth server missing PAR endpoint");
        return;
    };

    const authorization_endpoint = jsonGetString(authserver_meta.value, "authorization_endpoint") orelse {
        try sendError(request, .bad_request, "auth server missing authorization endpoint");
        return;
    };

    // generate PKCE + state + per-session DPoP key
    const pkce_verifier = try oauth.generatePkceVerifier(alloc);
    const pkce_challenge = try oauth.generatePkceChallenge(alloc, pkce_verifier);
    const state = try oauth.generateState(alloc);

    // generate a per-session DPoP keypair (separate from client secret key)
    var dpop_key_bytes: [32]u8 = undefined;
    crypto.random.bytes(&dpop_key_bytes);
    const dpop_keypair = zat.Keypair.fromSecretKey(.p256, dpop_key_bytes) catch {
        // extremely unlikely — retry with new random bytes
        try sendError(request, .internal_server_error, "key generation failed");
        return;
    };

    const client_keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };

    const client_id = getClientId();
    const redirect_uri = getRedirectUri();

    // send PAR request
    const par_result = sendParRequest(alloc, .{
        .par_url = par_url,
        .authserver_url = authserver_iss,
        .client_id = client_id,
        .redirect_uri = redirect_uri,
        .scope = SCOPE,
        .state = state,
        .pkce_challenge = pkce_challenge,
        .handle = handle_str,
        .client_keypair = &client_keypair,
        .dpop_keypair = &dpop_keypair,
    }) catch {
        try sendError(request, .bad_gateway, "PAR request failed");
        return;
    };

    const request_uri = par_result.request_uri;

    // store auth request in DB
    const hex_buf = std.fmt.bytesToHex(dpop_key_bytes, .lower);
    db.insertAuthRequest(
        state,
        authserver_iss,
        did,
        handle_str,
        pds_url,
        pkce_verifier,
        SCOPE,
        par_result.dpop_nonce,
        &hex_buf,
    ) catch {
        try sendError(request, .internal_server_error, "could not store auth request");
        return;
    };

    // redirect to auth server
    var redirect_url: std.ArrayList(u8) = .{};
    defer redirect_url.deinit(alloc);
    try redirect_url.print(
        alloc,
        "{s}?request_uri={s}&client_id={s}&state={s}",
        .{ authorization_endpoint, request_uri, client_id, state },
    );

    try sendRedirect(request, redirect_url.items);
}

fn handleCallback(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const target = request.head.target;
    std.debug.print("callback target: {s}\n", .{target});

    const code = extractQueryParam(target, "code") orelse {
        std.debug.print("callback missing code param\n", .{});
        try sendError(request, .bad_request, "missing code");
        return;
    };
    const state = extractQueryParam(target, "state") orelse {
        std.debug.print("callback missing state param\n", .{});
        try sendError(request, .bad_request, "missing state");
        return;
    };
    const iss_raw = extractQueryParam(target, "iss");
    const iss = if (iss_raw) |raw| blk: {
        const buf = try alloc.dupe(u8, raw);
        break :blk std.Uri.percentDecodeBackwards(buf, buf);
    } else null;

    // look up auth request
    const auth_req = db.getAuthRequest(state) orelse {
        try sendError(request, .bad_request, "unknown state — login may have expired");
        return;
    };

    // verify issuer matches
    if (iss) |issuer| {
        if (!mem.eql(u8, issuer, auth_req.authserver_iss)) {
            std.debug.print("issuer mismatch: callback iss='{s}', stored='{s}'\n", .{ issuer, auth_req.authserver_iss });
            try sendError(request, .bad_request, "issuer mismatch");
            return;
        }
    }

    // reconstruct DPoP keypair from stored hex key
    const dpop_keypair = keypairFromHex(auth_req.dpop_private_key) catch {
        try sendError(request, .internal_server_error, "invalid stored key");
        return;
    };

    const client_keypair = getClientKeypair() catch {
        try sendError(request, .internal_server_error, "server configuration error");
        return;
    };

    // re-fetch auth server metadata for token endpoint
    var authserver_meta = fetchAuthServerMeta(alloc, auth_req.authserver_iss) catch {
        try sendError(request, .bad_gateway, "could not fetch auth server metadata");
        return;
    };
    defer authserver_meta.deinit();

    const token_url = jsonGetString(authserver_meta.value, "token_endpoint") orelse {
        try sendError(request, .bad_gateway, "auth server missing token endpoint");
        return;
    };

    const client_id = getClientId();
    const redirect_uri = getRedirectUri();

    // exchange code for tokens
    const token_result = sendTokenRequest(alloc, .{
        .token_url = token_url,
        .authserver_url = auth_req.authserver_iss,
        .client_id = client_id,
        .redirect_uri = redirect_uri,
        .code = code,
        .pkce_verifier = auth_req.pkce_verifier,
        .client_keypair = &client_keypair,
        .dpop_keypair = &dpop_keypair,
        .dpop_nonce = auth_req.dpop_authserver_nonce,
    }) catch {
        try sendError(request, .bad_gateway, "token exchange failed");
        return;
    };

    // verify sub matches expected DID
    if (!mem.eql(u8, token_result.sub, auth_req.did)) {
        try sendError(request, .bad_request, "token subject does not match expected DID");
        return;
    }

    // store session
    db.upsertSession(
        auth_req.did,
        auth_req.handle,
        auth_req.pds_url,
        auth_req.authserver_iss,
        token_result.access_token,
        token_result.refresh_token,
        token_result.dpop_nonce,
        "", // PDS nonce not yet known
        auth_req.dpop_private_key,
    ) catch {
        try sendError(request, .internal_server_error, "could not store session");
        return;
    };

    // clean up auth request
    db.deleteAuthRequest(state);

    // redirect to frontend with session cookie
    var cookie_buf: [512]u8 = undefined;
    const cookie = std.fmt.bufPrint(
        &cookie_buf,
        "pollz_session={s}; HttpOnly; Secure; SameSite=Lax; Domain=pollz.waow.tech; Path=/; Max-Age=2592000",
        .{auth_req.did},
    ) catch {
        try sendError(request, .internal_server_error, "cookie error");
        return;
    };

    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = getFrontendOrigin() },
            .{ .name = "set-cookie", .value = cookie },
            .{ .name = "access-control-allow-origin", .value = getFrontendOrigin() },
            .{ .name = "access-control-allow-credentials", .value = "true" },
        },
    });
}

fn handleMe(request: *http.Server.Request) !void {
    const session_did = getSessionDid(request) orelse {
        try sendError(request, .unauthorized, "not logged in");
        return;
    };

    const session = db.getSession(session_did) orelse {
        try sendError(request, .unauthorized, "session not found");
        return;
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var body: std.ArrayList(u8) = .{};
    defer body.deinit(alloc);

    try body.print(alloc,
        \\{{"did":"{s}","handle":"{s}"}}
    , .{ session.did, session.handle });

    try sendJsonWithCredentials(request, body.items);
}

fn handleLogout(request: *http.Server.Request) !void {
    const session_did = getSessionDid(request);
    if (session_did) |did| {
        db.deleteSession(did);
    }

    try request.respond("{\"ok\":true}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "set-cookie", .value = "pollz_session=; HttpOnly; Secure; SameSite=Lax; Domain=pollz.waow.tech; Path=/; Max-Age=0" },
            .{ .name = "access-control-allow-origin", .value = getFrontendOrigin() },
            .{ .name = "access-control-allow-credentials", .value = "true" },
        },
    });
}

// --- BFF proxy endpoints ---

fn handleCreatePoll(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const session_did = getSessionDid(request) orelse {
        try sendError(request, .unauthorized, "not logged in");
        return;
    };

    const session = db.getSession(session_did) orelse {
        try sendError(request, .unauthorized, "session not found");
        return;
    };

    // read request body
    const body = readRequestBody(alloc, request) orelse {
        try sendError(request, .bad_request, "missing body");
        return;
    };

    // parse the poll creation request
    const parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch {
        try sendError(request, .bad_request, "invalid JSON");
        return;
    };
    defer parsed.deinit();

    const text = jsonGetString(parsed.value, "text") orelse {
        try sendError(request, .bad_request, "missing text");
        return;
    };

    const options_val = jsonGetPath(parsed.value, "options") orelse {
        try sendError(request, .bad_request, "missing options");
        return;
    };
    if (options_val != .array) {
        try sendError(request, .bad_request, "options must be an array");
        return;
    }

    // build record for PDS
    const now = try formatTimestamp(alloc);

    var record: std.ArrayList(u8) = .{};
    defer record.deinit(alloc);

    try record.print(alloc,
        \\{{"$type":"tech.waow.pollz.poll","text":"{s}","options":{f},"createdAt":"{s}"}}
    , .{ text, json.fmt(options_val, .{}), now });

    var xrpc_body: std.ArrayList(u8) = .{};
    defer xrpc_body.deinit(alloc);

    try xrpc_body.print(alloc,
        \\{{"repo":"{s}","collection":"tech.waow.pollz.poll","record":{s}}}
    , .{ session.did, record.items });

    // proxy to PDS
    const result = pdsAuthedRequest(alloc, session, "POST", "/xrpc/com.atproto.repo.createRecord", xrpc_body.items) catch {
        try sendError(request, .bad_gateway, "PDS request failed");
        return;
    };

    try sendJsonWithCredentials(request, result);
}

fn handleVote(request: *http.Server.Request) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const session_did = getSessionDid(request) orelse {
        try sendError(request, .unauthorized, "not logged in");
        return;
    };

    const session = db.getSession(session_did) orelse {
        try sendError(request, .unauthorized, "session not found");
        return;
    };

    // read request body
    const body = readRequestBody(alloc, request) orelse {
        try sendError(request, .bad_request, "missing body");
        return;
    };

    const parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch {
        try sendError(request, .bad_request, "invalid JSON");
        return;
    };
    defer parsed.deinit();

    const subject = jsonGetString(parsed.value, "subject") orelse {
        try sendError(request, .bad_request, "missing subject");
        return;
    };

    const option = jsonGetInt(parsed.value, "option") orelse {
        try sendError(request, .bad_request, "missing option");
        return;
    };

    const now = try formatTimestamp(alloc);

    var record: std.ArrayList(u8) = .{};
    defer record.deinit(alloc);

    try record.print(alloc,
        \\{{"$type":"tech.waow.pollz.vote","subject":"{s}","option":{d},"createdAt":"{s}"}}
    , .{ subject, option, now });

    var xrpc_body: std.ArrayList(u8) = .{};
    defer xrpc_body.deinit(alloc);

    try xrpc_body.print(alloc,
        \\{{"repo":"{s}","collection":"tech.waow.pollz.vote","record":{s}}}
    , .{ session.did, record.items });

    const result = pdsAuthedRequest(alloc, session, "POST", "/xrpc/com.atproto.repo.createRecord", xrpc_body.items) catch {
        try sendError(request, .bad_gateway, "PDS request failed");
        return;
    };

    try sendJsonWithCredentials(request, result);
}

fn handleDeletePoll(request: *http.Server.Request, uri_encoded: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const session_did = getSessionDid(request) orelse {
        try sendError(request, .unauthorized, "not logged in");
        return;
    };

    const session = db.getSession(session_did) orelse {
        try sendError(request, .unauthorized, "session not found");
        return;
    };

    const uri_buf = try alloc.dupe(u8, uri_encoded);
    const poll_uri = std.Uri.percentDecodeInPlace(uri_buf);

    // parse AT URI: at://did/collection/rkey
    if (!mem.startsWith(u8, poll_uri, "at://")) {
        try sendError(request, .bad_request, "invalid AT URI");
        return;
    }
    const after_scheme = poll_uri["at://".len..];
    const first_slash = mem.indexOf(u8, after_scheme, "/") orelse {
        try sendError(request, .bad_request, "invalid AT URI");
        return;
    };
    const repo = after_scheme[0..first_slash];
    const after_repo = after_scheme[first_slash + 1 ..];
    const second_slash = mem.indexOf(u8, after_repo, "/") orelse {
        try sendError(request, .bad_request, "invalid AT URI");
        return;
    };
    const collection = after_repo[0..second_slash];
    const rkey = after_repo[second_slash + 1 ..];

    // only the poll author can delete
    if (!mem.eql(u8, repo, session.did)) {
        try sendError(request, .forbidden, "you can only delete your own polls");
        return;
    }

    // deleteRecord is a POST to the PDS
    var xrpc_body: std.ArrayList(u8) = .{};
    defer xrpc_body.deinit(alloc);

    try xrpc_body.print(alloc,
        \\{{"repo":"{s}","collection":"{s}","rkey":"{s}"}}
    , .{ repo, collection, rkey });

    _ = pdsAuthedRequest(alloc, session, "POST", "/xrpc/com.atproto.repo.deleteRecord", xrpc_body.items) catch {
        try sendError(request, .bad_gateway, "PDS request failed");
        return;
    };

    // also delete from local DB
    db.deletePoll(poll_uri);

    try sendJsonWithCredentials(request, "{\"ok\":true}");
}

// --- profile resolution ---

const PROFILE_CACHE_SECS: i64 = 3600; // 1 hour

fn fetchAndCacheProfile(alloc: std.mem.Allocator, did: []const u8) void {
    const url = std.fmt.allocPrint(alloc, "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor={s}", .{did}) catch return;
    defer alloc.free(url);

    const body = httpGet(alloc, url) catch return;
    defer alloc.free(body);

    const parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch return;
    defer parsed.deinit();

    const handle = if (parsed.value.object.get("handle")) |v| switch (v) {
        .string => |s| s,
        else => did,
    } else did;

    const avatar = if (parsed.value.object.get("avatar")) |v| switch (v) {
        .string => |s| s,
        else => "",
    } else "";

    db.upsertProfile(did, handle, avatar);
}

fn getOrFetchProfile(alloc: std.mem.Allocator, did: []const u8) db.Profile {
    const now = @as(i64, @intCast(std.time.timestamp()));

    if (db.getProfile(did)) |profile| {
        if (now - profile.fetched_at < PROFILE_CACHE_SECS) {
            return profile;
        }
        // stale — serve it but refresh in background would be nice
        // for now just return stale data, fetch will happen on next miss
        return profile;
    }

    // cache miss — fetch synchronously
    fetchAndCacheProfile(alloc, did);

    // re-read from db
    return db.getProfile(did) orelse .{
        .did = did,
        .handle = did,
        .avatar_url = "",
        .fetched_at = now,
    };
}

// --- existing poll/vote read endpoints ---

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

    // collect poll data first so we can release db rows
    const PollRow = struct { uri: []const u8, repo: []const u8, rkey: []const u8, text_json: []const u8, options_json: []const u8, created_at: []const u8 };
    var poll_list: std.ArrayList(PollRow) = .{};
    defer poll_list.deinit(alloc);

    while (rows.next()) |row| {
        try poll_list.append(alloc, .{
            .uri = try alloc.dupe(u8, row.text(0)),
            .repo = try alloc.dupe(u8, row.text(1)),
            .rkey = try alloc.dupe(u8, row.text(2)),
            .text_json = try alloc.dupe(u8, row.text(3)),
            .options_json = try alloc.dupe(u8, row.text(4)),
            .created_at = try alloc.dupe(u8, row.text(5)),
        });
    }

    if (rows.err) |err| {
        std.debug.print("rows error: {}\n", .{err});
    }

    var first = true;
    for (poll_list.items) |p| {
        if (!first) try response.appendSlice(alloc, ",");
        first = false;

        // parse options array and get per-option counts
        const parsed = json.parseFromSlice(json.Value, alloc, p.options_json, .{}) catch {
            try response.print(alloc,
                \\{{"uri":"{s}","repo":"{s}","rkey":"{s}","text":{s},"options":[],"createdAt":"{s}"}}
            , .{ p.uri, p.repo, p.rkey, p.text_json, p.created_at });
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .array) {
            try response.print(alloc,
                \\{{"uri":"{s}","repo":"{s}","rkey":"{s}","text":{s},"options":[],"createdAt":"{s}"}}
            , .{ p.uri, p.repo, p.rkey, p.text_json, p.created_at });
            continue;
        }

        const options = parsed.value.array.items;

        // build options with counts
        var opts_json: std.ArrayList(u8) = .{};
        defer opts_json.deinit(alloc);
        try opts_json.appendSlice(alloc, "[");

        for (options, 0..) |opt, i| {
            if (i > 0) try opts_json.appendSlice(alloc, ",");

            const count: i64 = blk: {
                const vrow = db.conn.row("SELECT COUNT(*) FROM votes WHERE subject = ? AND option = ?", .{ p.uri, @as(i32, @intCast(i)) }) catch break :blk 0;
                if (vrow) |r| {
                    defer r.deinit();
                    break :blk r.int(0);
                }
                break :blk 0;
            };

            try opts_json.print(alloc,
                \\{{"text":{f},"count":{d}}}
            , .{ json.fmt(opt, .{}), count });
        }
        try opts_json.appendSlice(alloc, "]");

        // resolve author profile (release db mutex briefly for network fetch)
        db.mutex.unlock();
        const profile = getOrFetchProfile(alloc, p.repo);
        db.mutex.lock();

        // escape avatar_url for JSON
        var avatar_json: std.ArrayList(u8) = .{};
        defer avatar_json.deinit(alloc);
        if (profile.avatar_url.len > 0) {
            try avatar_json.appendSlice(alloc, "\"");
            try avatar_json.appendSlice(alloc, profile.avatar_url);
            try avatar_json.appendSlice(alloc, "\"");
        } else {
            try avatar_json.appendSlice(alloc, "null");
        }

        try response.print(alloc,
            \\{{"uri":"{s}","repo":"{s}","rkey":"{s}","text":{s},"options":{s},"createdAt":"{s}","author":{{"did":"{s}","handle":"{s}","avatar":{s}}}}}
        , .{ p.uri, p.repo, p.rkey, p.text_json, opts_json.items, p.created_at, profile.did, profile.handle, avatar_json.items });
    }

    try response.appendSlice(alloc, "]");
    try sendJson(request, response.items);
}

fn handleGetPoll(request: *http.Server.Request, uri_encoded: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

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

        try response.print(alloc,
            \\{{"text":{f},"count":{d}}}
        , .{ json.fmt(opt, .{}), count });
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

    const uri_buf = try alloc.dupe(u8, uri_encoded);
    const uri = std.Uri.percentDecodeInPlace(uri_buf);

    db.mutex.lock();
    defer db.mutex.unlock();

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(alloc);

    try response.appendSlice(alloc, "[");

    var rows = db.conn.rows(
        \\SELECT v.voter, v.option, v.uri, v.created_at, p.handle
        \\FROM votes v LEFT JOIN profiles p ON v.voter = p.did
        \\WHERE v.subject = ?
    ,
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
        const handle = row.text(4);
        const has_handle = handle.len > 0;

        if (has_handle) {
            try response.print(alloc,
                \\{{"voter":"{s}","option":{d},"uri":"{s}","createdAt":"{s}","handle":"{s}"}}
            , .{ voter, option, vote_uri, created_at, handle });
        } else {
            try response.print(alloc,
                \\{{"voter":"{s}","option":{d},"uri":"{s}","createdAt":"{s}"}}
            , .{ voter, option, vote_uri, created_at });
        }
    }

    if (rows.err) |err| {
        std.debug.print("votes query error: {}\n", .{err});
    }

    try response.appendSlice(alloc, "]");
    try sendJson(request, response.items);
}

// --- HTTP helpers ---

fn sendJson(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = getFrontendOrigin() },
            .{ .name = "access-control-allow-credentials", .value = "true" },
            .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
        },
    });
}

fn sendJsonWithCredentials(request: *http.Server.Request, body: []const u8) !void {
    try sendJson(request, body);
}

fn sendCorsHeaders(request: *http.Server.Request, body: []const u8) !void {
    try request.respond(body, .{
        .status = .no_content,
        .extra_headers = &.{
            .{ .name = "access-control-allow-origin", .value = getFrontendOrigin() },
            .{ .name = "access-control-allow-credentials", .value = "true" },
            .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
            .{ .name = "access-control-allow-headers", .value = "content-type" },
        },
    });
}

fn sendNotFound(request: *http.Server.Request) !void {
    try request.respond("{\"error\":\"not found\"}", .{
        .status = .not_found,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = getFrontendOrigin() },
            .{ .name = "access-control-allow-credentials", .value = "true" },
        },
    });
}

fn sendError(request: *http.Server.Request, status: http.Status, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{message}) catch "{\"error\":\"internal error\"}";
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "access-control-allow-origin", .value = getFrontendOrigin() },
            .{ .name = "access-control-allow-credentials", .value = "true" },
        },
    });
}

fn sendRedirect(request: *http.Server.Request, location: []const u8) !void {
    try request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = location },
        },
    });
}

// --- session/cookie helpers ---

fn getSessionDid(request: *http.Server.Request) ?[]const u8 {
    // parse cookie header for pollz_session=<did>
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            return parseCookieValue(h.value, "pollz_session");
        }
    }
    return null;
}

fn parseCookieValue(cookie_header: []const u8, name: []const u8) ?[]const u8 {
    var iter = mem.splitSequence(u8, cookie_header, "; ");
    while (iter.next()) |pair| {
        if (mem.startsWith(u8, pair, name)) {
            if (pair.len > name.len and pair[name.len] == '=') {
                return pair[name.len + 1 ..];
            }
        }
    }
    return null;
}

fn extractQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q_idx = mem.indexOf(u8, target, "?") orelse return null;
    const query = target[q_idx + 1 ..];
    var iter = mem.splitScalar(u8, query, '&');
    while (iter.next()) |pair| {
        const eq_idx = mem.indexOf(u8, pair, "=") orelse continue;
        if (mem.eql(u8, pair[0..eq_idx], name)) {
            return pair[eq_idx + 1 ..];
        }
    }
    return null;
}

fn readRequestBody(alloc: std.mem.Allocator, request: *http.Server.Request) ?[]u8 {
    const content_length = request.head.content_length orelse return null;
    if (content_length > 1024 * 64) return null;
    request.head.expect = null;
    var buf: [8192]u8 = undefined;
    const reader = request.readerExpectNone(&buf);
    return reader.readAlloc(alloc, @intCast(content_length)) catch null;
}

fn keypairFromHex(hex: []const u8) !zat.Keypair {
    if (hex.len != 64) return error.InvalidKeyHex;
    var key_bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key_bytes, hex) catch return error.InvalidKeyHex;
    return zat.Keypair.fromSecretKey(.p256, key_bytes);
}

// --- OAuth HTTP client helpers ---

/// simple HTTP GET that returns response body as owned slice
fn httpGet(alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(alloc);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch return error.FetchFailed;

    if (result.status != .ok) {
        aw.deinit();
        return error.FetchFailed;
    }

    return aw.toOwnedSlice() catch error.FetchFailed;
}

fn fetchAuthServerUrl(alloc: std.mem.Allocator, pds_url: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(alloc, "{s}/.well-known/oauth-protected-resource", .{pds_url});
    defer alloc.free(url);

    const body = try httpGet(alloc, url);
    defer alloc.free(body);

    const parsed = try json.parseFromSlice(json.Value, alloc, body, .{});
    defer parsed.deinit();

    const servers = parsed.value.object.get("authorization_servers") orelse return error.NoAuthServers;
    if (servers != .array or servers.array.items.len == 0) return error.NoAuthServers;

    const first = servers.array.items[0];
    if (first != .string) return error.NoAuthServers;

    return alloc.dupe(u8, first.string);
}

fn fetchAuthServerMeta(alloc: std.mem.Allocator, authserver_url: []const u8) !json.Parsed(json.Value) {
    const url = try std.fmt.allocPrint(alloc, "{s}/.well-known/oauth-authorization-server", .{authserver_url});
    defer alloc.free(url);

    const body = try httpGet(alloc, url);

    return json.parseFromSlice(json.Value, alloc, body, .{});
}

const ParResult = struct {
    request_uri: []const u8,
    dpop_nonce: []const u8,
};

const ParParams = struct {
    par_url: []const u8,
    authserver_url: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    state: []const u8,
    pkce_challenge: []const u8,
    handle: []const u8,
    client_keypair: *const zat.Keypair,
    dpop_keypair: *const zat.Keypair,
};

fn sendParRequest(alloc: std.mem.Allocator, params: ParParams) !ParResult {
    const client_assertion = try oauth.createClientAssertion(alloc, params.client_keypair, params.client_id, params.authserver_url);
    defer alloc.free(client_assertion);

    const dpop_proof = try oauth.createDpopProof(alloc, params.dpop_keypair, "POST", params.par_url, null, null);
    defer alloc.free(dpop_proof);

    const form_params = [_][2][]const u8{
        .{ "response_type", "code" },
        .{ "code_challenge", params.pkce_challenge },
        .{ "code_challenge_method", "S256" },
        .{ "redirect_uri", params.redirect_uri },
        .{ "scope", params.scope },
        .{ "state", params.state },
        .{ "login_hint", params.handle },
        .{ "client_id", params.client_id },
        .{ "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" },
        .{ "client_assertion", client_assertion },
    };

    const form_body = try oauth.formEncode(alloc, &form_params);
    defer alloc.free(form_body);

    // first attempt
    var result = try doPost(alloc, params.par_url, form_body, &.{
        .{ .name = "DPoP", .value = dpop_proof },
    });

    // handle DPoP nonce requirement (retry once)
    if (isDpopNonceError(result.status, result.body)) {
        const new_nonce = result.dpop_nonce orelse return error.MissingDpopNonce;

        alloc.free(result.body);

        const dpop_proof2 = try oauth.createDpopProof(alloc, params.dpop_keypair, "POST", params.par_url, new_nonce, null);
        defer alloc.free(dpop_proof2);

        result = try doPost(alloc, params.par_url, form_body, &.{
            .{ .name = "DPoP", .value = dpop_proof2 },
        });
    }

    defer alloc.free(result.body);

    if (result.status != .ok and result.status != .created) {
        std.debug.print("PAR error: {s}\n", .{result.body});
        return error.ParFailed;
    }

    const parsed = try json.parseFromSlice(json.Value, alloc, result.body, .{});
    defer parsed.deinit();

    const request_uri = jsonGetString(parsed.value, "request_uri") orelse return error.MissingRequestUri;

    return .{
        .request_uri = try alloc.dupe(u8, request_uri),
        .dpop_nonce = if (result.dpop_nonce) |n| try alloc.dupe(u8, n) else try alloc.dupe(u8, ""),
    };
}

const HttpResult = struct {
    status: http.Status,
    body: []u8,
    dpop_nonce: ?[]const u8,
};

fn doPost(alloc: std.mem.Allocator, url: []const u8, payload: []const u8, extra_headers: []const http.Header) !HttpResult {
    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var req = try client.request(.POST, try std.Uri.parse(url), .{
        .extra_headers = extra_headers,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = payload.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    try req.connection.?.flush();

    var redirect_buf: [1]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.FetchFailed;

    // extract DPoP-Nonce from response headers
    var dpop_nonce: ?[]const u8 = null;
    var header_iter = response.head.iterateHeaders();
    while (header_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "dpop-nonce")) {
            dpop_nonce = try alloc.dupe(u8, header.value);
            break;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&aw.writer) catch {
        aw.deinit();
        return error.FetchFailed;
    };

    const resp_body = aw.toOwnedSlice() catch {
        return error.FetchFailed;
    };

    return .{
        .status = response.head.status,
        .body = resp_body,
        .dpop_nonce = dpop_nonce,
    };
}

const TokenResult = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    sub: []const u8,
    dpop_nonce: []const u8,
};

const TokenParams = struct {
    token_url: []const u8,
    authserver_url: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code: []const u8,
    pkce_verifier: []const u8,
    client_keypair: *const zat.Keypair,
    dpop_keypair: *const zat.Keypair,
    dpop_nonce: []const u8,
};

fn sendTokenRequest(alloc: std.mem.Allocator, params: TokenParams) !TokenResult {
    const client_assertion = try oauth.createClientAssertion(alloc, params.client_keypair, params.client_id, params.authserver_url);
    defer alloc.free(client_assertion);

    const dpop_proof = try oauth.createDpopProof(alloc, params.dpop_keypair, "POST", params.token_url, if (params.dpop_nonce.len > 0) params.dpop_nonce else null, null);
    defer alloc.free(dpop_proof);

    const form_params = [_][2][]const u8{
        .{ "grant_type", "authorization_code" },
        .{ "code", params.code },
        .{ "redirect_uri", params.redirect_uri },
        .{ "code_verifier", params.pkce_verifier },
        .{ "client_id", params.client_id },
        .{ "client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" },
        .{ "client_assertion", client_assertion },
    };

    const form_body = try oauth.formEncode(alloc, &form_params);
    defer alloc.free(form_body);

    var result = try doPost(alloc, params.token_url, form_body, &.{
        .{ .name = "DPoP", .value = dpop_proof },
    });

    // handle DPoP nonce retry
    if (isDpopNonceError(result.status, result.body)) {
        const new_nonce = result.dpop_nonce orelse return error.MissingDpopNonce;
        alloc.free(result.body);

        const dpop_proof2 = try oauth.createDpopProof(alloc, params.dpop_keypair, "POST", params.token_url, new_nonce, null);
        defer alloc.free(dpop_proof2);

        result = try doPost(alloc, params.token_url, form_body, &.{
            .{ .name = "DPoP", .value = dpop_proof2 },
        });
    }

    defer alloc.free(result.body);

    if (result.status != .ok) {
        std.debug.print("token exchange error: {s}\n", .{result.body});
        return error.TokenExchangeFailed;
    }

    const parsed = try json.parseFromSlice(json.Value, alloc, result.body, .{});
    defer parsed.deinit();

    return .{
        .access_token = try alloc.dupe(u8, jsonGetString(parsed.value, "access_token") orelse return error.MissingAccessToken),
        .refresh_token = try alloc.dupe(u8, jsonGetString(parsed.value, "refresh_token") orelse return error.MissingRefreshToken),
        .sub = try alloc.dupe(u8, jsonGetString(parsed.value, "sub") orelse return error.MissingSub),
        .dpop_nonce = if (result.dpop_nonce) |n| try alloc.dupe(u8, n) else try alloc.dupe(u8, ""),
    };
}

fn pdsAuthedRequest(alloc: std.mem.Allocator, session: db.Session, method_str: []const u8, path: []const u8, body: ?[]const u8) ![]u8 {
    const dpop_keypair = keypairFromHex(session.dpop_private_key) catch return error.InvalidSessionKey;

    const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ session.pds_url, path });
    defer alloc.free(url);

    const ath = try oauth.accessTokenHash(alloc, session.access_token);
    defer alloc.free(ath);

    const dpop_proof = try oauth.createDpopProof(
        alloc,
        &dpop_keypair,
        method_str,
        url,
        if (session.dpop_pds_nonce.len > 0) session.dpop_pds_nonce else null,
        ath,
    );
    defer alloc.free(dpop_proof);

    var auth_header_buf: [4096]u8 = undefined;
    const auth_header = std.fmt.bufPrint(&auth_header_buf, "DPoP {s}", .{session.access_token}) catch return error.AuthHeaderTooLong;

    const http_method: http.Method = if (mem.eql(u8, method_str, "POST")) .POST else .GET;

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var req = try client.request(http_method, try std.Uri.parse(url), .{
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "DPoP", .value = dpop_proof },
        },
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    });
    defer req.deinit();

    if (body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(b);
        try body_writer.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buf: [1]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.FetchFailed;

    // extract DPoP-Nonce from response headers
    var header_iter = response.head.iterateHeaders();
    while (header_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "dpop-nonce")) {
            db.updateSessionNonce(session.did, .pds, header.value);

            // handle DPoP nonce retry
            if (isDpopNonceErrorStatus(response.head.status)) {
                var updated_session = session;
                updated_session.dpop_pds_nonce = header.value;
                return pdsAuthedRequest(alloc, updated_session, method_str, path, body);
            }
            break;
        }
    }

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const reader = response.reader(&.{});
    _ = reader.streamRemaining(&aw.writer) catch {
        aw.deinit();
        return error.FetchFailed;
    };

    return aw.toOwnedSlice() catch error.FetchFailed;
}

fn isDpopNonceError(status: http.Status, body: []const u8) bool {
    if (status != .bad_request and status != .unauthorized) return false;
    return mem.indexOf(u8, body, "use_dpop_nonce") != null;
}

fn isDpopNonceErrorStatus(status: http.Status) bool {
    return status == .bad_request or status == .unauthorized;
}

// --- JSON helpers ---

fn jsonGetString(value: json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn jsonGetInt(value: json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

fn jsonGetPath(value: json.Value, key: []const u8) ?json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

fn formatTimestamp(alloc: std.mem.Allocator) ![]u8 {
    const now = std.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now) };
    const day = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const md = year_day.calculateMonthDay();
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}
