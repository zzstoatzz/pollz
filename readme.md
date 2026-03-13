# pollz

polls on [AT Protocol](https://atproto.com). create polls, vote, see results in real time.

**[pollz.waow.tech](https://pollz.waow.tech)**

## lexicons

- [`tech.waow.pollz.poll`](lexicons/tech/waow/pollz/poll.json) — a poll with question + options
- [`tech.waow.pollz.vote`](lexicons/tech/waow/pollz/vote.json) — a vote on a poll

## stack

```
jetstream → backend (zig + sqlite + oauth) → frontend (sveltekit)
                          ↑
                  user's PDS (oauth)
```

- **backend**: [zig](https://ziglang.org) 0.15, [zqlite](https://github.com/karlseguin/zqlite.zig), [zat](https://tangled.sh/zzstoatzz.io/zat) (AT Protocol primitives)
- **frontend**: [sveltekit](https://svelte.dev) + static adapter
- **infra**: [fly.io](https://fly.io) (backend), [cloudflare pages](https://pages.cloudflare.com) (frontend)

## develop

```sh
# backend
cd backend && zig build -Doptimize=Debug && ./zig-out/bin/pollz

# frontend
cd frontend && pnpm dev
```

## deploy

```sh
just deploy            # both
just deploy-backend    # fly.io
just deploy-frontend   # cloudflare pages
```
