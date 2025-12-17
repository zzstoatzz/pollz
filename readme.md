# pollz

polls on atproto

```
firehose → tap → backend (zig + sqlite) → frontend
                      ↑
              user's PDS (oauth)
```

## stack

- [tap](https://github.com/bluesky-social/atproto/tree/main/packages/tap) - firehose sync
- [zig](https://ziglang.org) + [httpz](https://github.com/ikskuh/http.zig) - backend
- [atcute](https://github.com/mary-ext/atcute) - atproto client
- [fly.io](https://fly.io) - backend hosting
- [cloudflare pages](https://pages.cloudflare.com) - frontend hosting
