# zig 0.15 notes

## breaking changes from 0.14

### `json.stringify` → `json.fmt`
```zig
// old: json.stringify(value, .{}, writer);
// new: use json.fmt formatter
try buffer.print(allocator, "{f}", .{json.fmt(value, .{})});
```

### `std.builtin.Mode` → `std.builtin.OptimizeMode`
the optimization mode enum was renamed

### `std.time.sleep` removed
use `std.posix.nanosleep(seconds, nanoseconds)` instead

### `std.ArrayList` is now unmanaged by default
the old `ArrayList` with embedded allocator is now `array_list.AlignedManaged`.
the new `std.ArrayList(T)` returns an unmanaged struct that:
- doesn't store the allocator internally
- requires passing allocator to methods like `appendSlice(alloc, slice)`
- initializes with `.{}` or `.empty` instead of `.init(allocator)`
- `deinit(alloc)` takes allocator as argument

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

### build.zig changes
- `root_source_file` → `root_module` with `b.createModule(...)`
- `strip` field removed from `ExecutableOptions`
- fingerprint field required in `build.zig.zon`

### `std.http.Server` API
requires `*std.Io.Reader` and `*std.Io.Writer`, not raw `net.Stream`

## net.Stream → http.Server

```zig
var read_buffer: [8192]u8 = undefined;
var write_buffer: [8192]u8 = undefined;

var reader = conn.stream.reader(&read_buffer);
var writer = conn.stream.writer(&write_buffer);

// reader has .interface() method that returns *Io.Reader
// writer has .interface field that is Io.Writer
var server = http.Server.init(reader.interface(), &writer.interface);
```

### http.Server.Request.respond
the `respond` method is on `Request`, not `Server`:
```zig
try request.respond(body, .{
    .status = .ok,
    .extra_headers = &.{
        .{ .name = "content-type", .value = "application/json" },
    },
});
```

### `std.Uri.percentDecode` → `std.Uri.percentDecodeInPlace`
there's no allocating `percentDecode` anymore. use in-place decoding:
```zig
// copy to mutable buffer first, then decode in place
const uri_buf = try alloc.dupe(u8, uri_encoded);
const uri = std.Uri.percentDecodeInPlace(uri_buf);
```

### `std.http.Client` for outgoing requests
```zig
var client = std.http.Client{ .allocator = allocator };
defer client.deinit();

const uri = std.Uri.parse("https://example.com/api") catch return;

// use .headers to control accept-encoding (default is gzip/deflate)
var req = client.request(.GET, uri, .{
    .headers = .{ .accept_encoding = .{ .override = "identity" } },
}) catch return;
defer req.deinit();

req.sendBodiless() catch return;

var redirect_buf: [8192]u8 = undefined;
var response = req.receiveHead(&redirect_buf) catch return;

if (response.head.status != .ok) return;

// read response body - use allocRemaining with Limit
var reader = response.reader(&.{});
const body = reader.allocRemaining(allocator, std.Io.Limit.limited(65536)) catch return;
defer allocator.free(body);
```

## external libraries

### websocket.zig (karlseguin/websocket.zig)
use for websocket client/server. add to `build.zig.zon`:
```zig
.dependencies = .{
    .websocket = .{
        .url = "https://github.com/karlseguin/websocket.zig/archive/refs/heads/master.tar.gz",
        .hash = "websocket-0.1.0-ZPISdRNzAwAGszh62EpRtoQxu8wb1MSMVI6Ow0o2dmyJ",
    },
},
```

client usage:
```zig
const websocket = @import("websocket");

var client = try websocket.Client.init(allocator, .{
    .host = "example.com",
    .port = 443,
    .tls = true,
});
defer client.deinit();

// Host header is NOT automatically added - must provide it
client.handshake("/path", .{ .headers = "Host: example.com\r\n" }) catch |err| {
    // handle error
};

// handler must have serverMessage(self, data) function
var handler = MyHandler{};
try client.readLoop(&handler);
```
