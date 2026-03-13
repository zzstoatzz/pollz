const std = @import("std");
const mem = std.mem;
const json = std.json;
const crypto = std.crypto;
const Allocator = mem.Allocator;
const zat = @import("zat");

const base64url = std.base64.url_safe_no_pad;

// --- JWT creation ---

/// create a signed JWT from header and payload JSON strings.
/// caller owns returned slice.
pub fn createJwt(allocator: Allocator, header_json: []const u8, payload_json: []const u8, keypair: *const zat.Keypair) ![]u8 {
    const header_b64 = try base64urlEncode(allocator, header_json);
    defer allocator.free(header_b64);

    const payload_b64 = try base64urlEncode(allocator, payload_json);
    defer allocator.free(payload_b64);

    // signing input: header.payload
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signing_input);

    const sig = try keypair.sign(signing_input);
    const sig_b64 = try base64urlEncodeBytes(allocator, &sig.bytes);
    defer allocator.free(sig_b64);

    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, sig_b64 });
}

// --- DPoP proof ---

/// create a DPoP proof JWT per RFC 9449.
/// htm: HTTP method (e.g. "POST"), htu: target URI, nonce: server-provided DPoP-Nonce,
/// ath: optional access token hash (base64url-encoded SHA-256 of the access token).
pub fn createDpopProof(
    allocator: Allocator,
    keypair: *const zat.Keypair,
    htm: []const u8,
    htu: []const u8,
    nonce: ?[]const u8,
    ath: ?[]const u8,
) ![]u8 {
    const jwk = try jwkPublicKey(allocator, keypair);
    defer allocator.free(jwk);

    const jti = try generateJti(allocator);
    defer allocator.free(jti);

    const now = std.time.timestamp();

    // header: {"typ":"dpop+jwt","alg":"ES256","jwk":{...}}
    const header = try std.fmt.allocPrint(allocator,
        \\{{"typ":"dpop+jwt","alg":"ES256","jwk":{s}}}
    , .{jwk});
    defer allocator.free(header);

    // payload
    var payload_buf: std.ArrayList(u8) = .{};
    defer payload_buf.deinit(allocator);

    try payload_buf.appendSlice(allocator, "{");
    try payload_buf.print(allocator,
        \\"jti":"{s}","htm":"{s}","htu":"{s}","iat":{d}
    , .{ jti, htm, htu, now });

    if (nonce) |n| {
        try payload_buf.print(allocator, ",\"nonce\":\"{s}\"", .{n});
    }
    if (ath) |a| {
        try payload_buf.print(allocator, ",\"ath\":\"{s}\"", .{a});
    }

    try payload_buf.appendSlice(allocator, "}");

    return createJwt(allocator, header, payload_buf.items, keypair);
}

// --- client assertion ---

/// compute the JWK thumbprint (kid) for a keypair.
/// caller owns returned slice.
pub fn jwkThumbprint(allocator: Allocator, keypair: *const zat.Keypair) ![]u8 {
    const Scheme = crypto.sign.ecdsa.EcdsaP256Sha256;
    const sk = Scheme.SecretKey.fromBytes(keypair.secret_key) catch return error.InvalidSecretKey;
    const kp = Scheme.KeyPair.fromSecretKey(sk) catch return error.InvalidSecretKey;
    const uncompressed = kp.public_key.toUncompressedSec1();

    const x_b64 = try base64urlEncodeBytes(allocator, uncompressed[1..33]);
    defer allocator.free(x_b64);
    const y_b64 = try base64urlEncodeBytes(allocator, uncompressed[33..65]);
    defer allocator.free(y_b64);

    const input = try std.fmt.allocPrint(allocator,
        \\{{"crv":"P-256","kty":"EC","x":"{s}","y":"{s}"}}
    , .{ x_b64, y_b64 });
    defer allocator.free(input);

    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    return base64urlEncodeBytes(allocator, &hash);
}

/// create a `private_key_jwt` client assertion for token endpoint auth.
/// client_id: the OAuth client ID, aud: the token endpoint URL.
pub fn createClientAssertion(
    allocator: Allocator,
    keypair: *const zat.Keypair,
    client_id: []const u8,
    aud: []const u8,
) ![]u8 {
    const jti = try generateJti(allocator);
    defer allocator.free(jti);

    const kid = try jwkThumbprint(allocator, keypair);
    defer allocator.free(kid);

    const now = std.time.timestamp();

    const header = try std.fmt.allocPrint(allocator,
        \\{{"typ":"JWT","alg":"ES256","kid":"{s}"}}
    , .{kid});
    defer allocator.free(header);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"iss":"{s}","sub":"{s}","aud":"{s}","jti":"{s}","iat":{d},"exp":{d}}}
    , .{ client_id, client_id, aud, jti, now, now + 120 });
    defer allocator.free(payload);

    return createJwt(allocator, header, payload, keypair);
}

// --- PKCE S256 ---

/// generate a PKCE code challenge from a code verifier using S256.
/// caller owns returned slice.
pub fn generatePkceChallenge(allocator: Allocator, verifier: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(verifier, &hash, .{});
    return base64urlEncodeBytes(allocator, &hash);
}

/// generate a random PKCE code verifier (43 chars, base64url-encoded 32 random bytes).
/// caller owns returned slice.
pub fn generatePkceVerifier(allocator: Allocator) ![]u8 {
    var random_bytes: [32]u8 = undefined;
    crypto.random.bytes(&random_bytes);
    return base64urlEncodeBytes(allocator, &random_bytes);
}

/// generate a random state parameter.
/// caller owns returned slice.
pub fn generateState(allocator: Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    crypto.random.bytes(&random_bytes);
    return base64urlEncodeBytes(allocator, &random_bytes);
}

// --- JWK ---

/// generate a JWK JSON string for the public key of a P-256 keypair.
/// includes kid (JWK thumbprint per RFC 7638), use, and alg fields.
/// caller owns returned slice.
pub fn jwkPublicKey(allocator: Allocator, keypair: *const zat.Keypair) ![]u8 {
    const Scheme = crypto.sign.ecdsa.EcdsaP256Sha256;
    const sk = Scheme.SecretKey.fromBytes(keypair.secret_key) catch return error.InvalidSecretKey;
    const kp = Scheme.KeyPair.fromSecretKey(sk) catch return error.InvalidSecretKey;
    const uncompressed = kp.public_key.toUncompressedSec1();

    // uncompressed format: 0x04 || x[32] || y[32]
    const x = uncompressed[1..33];
    const y = uncompressed[33..65];

    const x_b64 = try base64urlEncodeBytes(allocator, x);
    defer allocator.free(x_b64);

    const y_b64 = try base64urlEncodeBytes(allocator, y);
    defer allocator.free(y_b64);

    // JWK thumbprint (RFC 7638): SHA-256 of canonical JSON with members in lexicographic order
    const thumbprint_input = try std.fmt.allocPrint(allocator,
        \\{{"crv":"P-256","kty":"EC","x":"{s}","y":"{s}"}}
    , .{ x_b64, y_b64 });
    defer allocator.free(thumbprint_input);

    var thumbprint_hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(thumbprint_input, &thumbprint_hash, .{});
    const kid = try base64urlEncodeBytes(allocator, &thumbprint_hash);
    defer allocator.free(kid);

    return std.fmt.allocPrint(allocator,
        \\{{"kty":"EC","crv":"P-256","x":"{s}","y":"{s}","kid":"{s}","use":"sig","alg":"ES256"}}
    , .{ x_b64, y_b64, kid });
}

/// generate a JWKS JSON containing the public key.
/// caller owns returned slice.
pub fn jwksJson(allocator: Allocator, keypair: *const zat.Keypair) ![]u8 {
    const jwk = try jwkPublicKey(allocator, keypair);
    defer allocator.free(jwk);

    return std.fmt.allocPrint(allocator,
        \\{{"keys":[{s}]}}
    , .{jwk});
}

// --- access token hash ---

/// compute the `ath` claim for DPoP: base64url(SHA-256(access_token)).
/// caller owns returned slice.
pub fn accessTokenHash(allocator: Allocator, access_token: []const u8) ![]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(access_token, &hash, .{});
    return base64urlEncodeBytes(allocator, &hash);
}

// --- form URL encoding ---

/// encode key-value pairs as application/x-www-form-urlencoded.
/// caller owns returned slice.
pub fn formEncode(allocator: Allocator, params: []const [2][]const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    for (params, 0..) |kv, i| {
        if (i > 0) try buf.appendSlice(allocator, "&");
        try percentEncode(allocator, &buf, kv[0]);
        try buf.appendSlice(allocator, "=");
        try percentEncode(allocator, &buf, kv[1]);
    }

    return buf.toOwnedSlice(allocator);
}

// --- helpers ---

fn base64urlEncode(allocator: Allocator, data: []const u8) ![]u8 {
    const len = base64url.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, len);
    _ = base64url.Encoder.encode(buf, data);
    return buf;
}

fn base64urlEncodeBytes(allocator: Allocator, data: []const u8) ![]u8 {
    return base64urlEncode(allocator, data);
}

fn generateJti(allocator: Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    crypto.random.bytes(&random_bytes);
    return base64urlEncodeBytes(allocator, &random_bytes);
}

fn percentEncode(allocator: Allocator, buf: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (isUnreserved(c)) {
            try buf.append(allocator, c);
        } else {
            try buf.print(allocator, "%{X:0>2}", .{c});
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
        else => false,
    };
}

// --- tests ---

test "PKCE S256 challenge" {
    const allocator = std.testing.allocator;

    // RFC 7636 example: verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const challenge = try generatePkceChallenge(allocator, verifier);
    defer allocator.free(challenge);

    // expected: E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge);
}

test "PKCE verifier generation" {
    const allocator = std.testing.allocator;
    const verifier = try generatePkceVerifier(allocator);
    defer allocator.free(verifier);

    // 32 bytes → 43 base64url chars
    try std.testing.expectEqual(@as(usize, 43), verifier.len);
}

test "form URL encoding" {
    const allocator = std.testing.allocator;

    const params = [_][2][]const u8{
        .{ "grant_type", "authorization_code" },
        .{ "code", "abc123" },
        .{ "redirect_uri", "https://example.com/callback" },
    };

    const encoded = try formEncode(allocator, &params);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings(
        "grant_type=authorization_code&code=abc123&redirect_uri=https%3A%2F%2Fexample.com%2Fcallback",
        encoded,
    );
}

test "JWK public key generation" {
    const allocator = std.testing.allocator;

    const keypair = try zat.Keypair.fromSecretKey(.p256, .{
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
    });

    const jwk = try jwkPublicKey(allocator, &keypair);
    defer allocator.free(jwk);

    // verify it's valid JSON with the right fields
    const parsed = try json.parseFromSlice(json.Value, allocator, jwk, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("EC", obj.get("kty").?.string);
    try std.testing.expectEqualStrings("P-256", obj.get("crv").?.string);
    try std.testing.expect(obj.get("x") != null);
    try std.testing.expect(obj.get("y") != null);
    try std.testing.expectEqualStrings("sig", obj.get("use").?.string);
    try std.testing.expectEqualStrings("ES256", obj.get("alg").?.string);
    try std.testing.expect(obj.get("kid") != null);
}

test "JWT creation and structure" {
    const allocator = std.testing.allocator;

    const keypair = try zat.Keypair.fromSecretKey(.p256, .{
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
    });

    const header =
        \\{"alg":"ES256","typ":"JWT"}
    ;
    const payload =
        \\{"sub":"test","iat":1700000000}
    ;

    const token = try createJwt(allocator, header, payload, &keypair);
    defer allocator.free(token);

    // JWT should have 3 dot-separated parts
    var parts: usize = 0;
    var iter = mem.splitScalar(u8, token, '.');
    while (iter.next()) |_| parts += 1;
    try std.testing.expectEqual(@as(usize, 3), parts);
}

test "DPoP proof creation" {
    const allocator = std.testing.allocator;

    const keypair = try zat.Keypair.fromSecretKey(.p256, .{
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
    });

    const proof = try createDpopProof(allocator, &keypair, "POST", "https://auth.example.com/token", "server-nonce", null);
    defer allocator.free(proof);

    // should be a valid 3-part JWT
    var parts: usize = 0;
    var iter = mem.splitScalar(u8, proof, '.');
    while (iter.next()) |_| parts += 1;
    try std.testing.expectEqual(@as(usize, 3), parts);

    // decode header to verify it contains typ: dpop+jwt and jwk
    var iter2 = mem.splitScalar(u8, proof, '.');
    const header_b64 = iter2.next().?;
    var header_buf: [4096]u8 = undefined;
    const header_len = try base64url.Decoder.calcSizeForSlice(header_b64);
    try base64url.Decoder.decode(header_buf[0..header_len], header_b64);
    const header_parsed = try json.parseFromSlice(json.Value, allocator, header_buf[0..header_len], .{});
    defer header_parsed.deinit();

    try std.testing.expectEqualStrings("dpop+jwt", header_parsed.value.object.get("typ").?.string);
    try std.testing.expectEqualStrings("ES256", header_parsed.value.object.get("alg").?.string);
    try std.testing.expect(header_parsed.value.object.get("jwk") != null);
}

test "client assertion creation" {
    const allocator = std.testing.allocator;

    const keypair = try zat.Keypair.fromSecretKey(.p256, .{
        0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30,
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40,
    });

    const assertion = try createClientAssertion(allocator, &keypair, "https://pollz.waow.tech/oauth/client-metadata", "https://bsky.social/oauth/token");
    defer allocator.free(assertion);

    // decode payload to verify claims
    var iter = mem.splitScalar(u8, assertion, '.');
    _ = iter.next(); // skip header
    const payload_b64 = iter.next().?;
    var payload_buf: [4096]u8 = undefined;
    const payload_len = try base64url.Decoder.calcSizeForSlice(payload_b64);
    try base64url.Decoder.decode(payload_buf[0..payload_len], payload_b64);
    const payload_parsed = try json.parseFromSlice(json.Value, allocator, payload_buf[0..payload_len], .{});
    defer payload_parsed.deinit();

    const obj = payload_parsed.value.object;
    try std.testing.expectEqualStrings("https://pollz.waow.tech/oauth/client-metadata", obj.get("iss").?.string);
    try std.testing.expectEqualStrings("https://pollz.waow.tech/oauth/client-metadata", obj.get("sub").?.string);
    try std.testing.expectEqualStrings("https://bsky.social/oauth/token", obj.get("aud").?.string);
}

test "access token hash" {
    const allocator = std.testing.allocator;
    const ath = try accessTokenHash(allocator, "test-access-token");
    defer allocator.free(ath);
    try std.testing.expect(ath.len > 0);
}
