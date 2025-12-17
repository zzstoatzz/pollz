# zig 0.15 notes

reference for zig 0.15 patterns used in the backend.

## breaking changes from 0.14

### json.stringify → json.fmt
```zig
// old: json.stringify(value, .{}, writer);
// new: use json.fmt formatter
try buffer.print(allocator, "{f}", .{json.fmt(value, .{})});
```

### std.ArrayList is unmanaged by default
```zig
// old 0.14 style:
var list = std.ArrayList(u8).init(allocator);
try list.appendSlice("hello");
list.deinit();

// new 0.15 style:
var list: std.ArrayList(u8) = .{};
try list.appendSlice(allocator, "hello");
list.deinit(allocator);
```

### std.time.sleep removed
```zig
// use posix.nanosleep instead
std.posix.nanosleep(seconds, nanoseconds);
```

### std.Uri.percentDecode → percentDecodeInPlace
```zig
// copy to mutable buffer first, then decode in place
const uri_buf = try alloc.dupe(u8, uri_encoded);
const uri = std.Uri.percentDecodeInPlace(uri_buf);
```

## http server patterns

### net.Stream → http.Server
```zig
var read_buffer: [8192]u8 = undefined;
var write_buffer: [8192]u8 = undefined;

var reader = conn.stream.reader(&read_buffer);
var writer = conn.stream.writer(&write_buffer);

var server = http.Server.init(reader.interface(), &writer.interface);
```

### responding to requests
```zig
try request.respond(body, .{
    .status = .ok,
    .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
    },
});
```

## websocket client (karlseguin/websocket.zig)

```zig
const websocket = @import("websocket");

var client = try websocket.Client.init(allocator, .{
    .host = "example.com",
    .port = 443,
    .tls = true,
});
defer client.deinit();

// Host header must be provided manually
client.handshake("/path", .{ .headers = "Host: example.com\r\n" }) catch |err| {
    // handle error
};

// handler must have serverMessage(self, data) function
var handler = MyHandler{};
try client.readLoop(&handler);
```

## sqlite patterns (zqlite)

### prepared statements with bind
```zig
var stmt = conn.prepare("SELECT * FROM votes WHERE uri = ?") catch return;
defer stmt.deinit();

const row = stmt.bind(.{uri}).step() catch return;
if (row) |r| {
    const subject = r[0].?.text;
    // ...
}
```

### upsert with ON CONFLICT
```zig
conn.exec(
    \\INSERT INTO votes (uri, subject, option, voter, created_at)
    \\VALUES (?, ?, ?, ?, ?)
    \\ON CONFLICT(subject, voter) DO UPDATE SET
    \\  uri = excluded.uri,
    \\  option = excluded.option,
    \\  created_at = excluded.created_at
    \\WHERE excluded.created_at > votes.created_at OR votes.created_at IS NULL
, .{ uri, subject, option, voter, created_at }) catch |err| {
    // handle error
};
```

## build.zig.zon

```zig
.{
    .name = .pollz,
    .version = "0.0.0",
    .fingerprint = 0x...,  // required in 0.15
    .dependencies = .{
        .zqlite = .{ ... },
        .websocket = .{ ... },
    },
}
```
