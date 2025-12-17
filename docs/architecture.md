# pollz architecture

## overview

pollz is a polling app built on atproto. users create polls and vote using their bluesky accounts.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   frontend  │────▶│   backend   │◀────│     tap     │
│  (vite/ts)  │     │    (zig)    │     │    (go)     │
│  cloudflare │     │   fly.io    │     │   fly.io    │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │                   │
       │                   ▼                   │
       │            ┌─────────────┐            │
       │            │   sqlite    │            │
       │            │  (fly vol)  │            │
       │            └─────────────┘            │
       │                                       │
       ▼                                       ▼
┌─────────────┐                         ┌─────────────┐
│  user PDS   │                         │  firehose   │
│  (bsky.social)                        │  (relay)    │
└─────────────┘                         └─────────────┘
```

## components

### frontend (src/)
- vanilla typescript with vite
- oauth via @atcute/oauth-browser-client
- writes polls/votes directly to user's PDS
- fetches poll data from backend API

### backend (backend/)
- zig http server
- sqlite for persistence
- consumes events from tap via websocket
- serves REST API for frontend

### tap (tap/)
- bluesky's official atproto sync utility
- handles firehose connection, backfill, cursor management
- filters for `tech.waow.poll` and `tech.waow.vote` collections
- delivers events to backend via websocket

## data flow

### creating a poll
1. user logs in via oauth
2. frontend calls `com.atproto.repo.createRecord` on user's PDS
3. PDS broadcasts to relay/firehose
4. tap receives event, forwards to backend
5. backend inserts poll into sqlite

### voting
1. frontend checks if user has existing vote on this poll
2. if exists: `com.atproto.repo.putRecord` (update)
3. if not: `com.atproto.repo.createRecord` (create)
4. tap receives event, forwards to backend
5. backend upserts vote (one vote per user per poll)

### reading polls
1. frontend fetches `/api/polls` from backend
2. backend queries sqlite, returns polls with vote counts
3. frontend renders poll list

## lexicons

### tech.waow.poll
```json
{
  "$type": "tech.waow.poll",
  "text": "what's the best language?",
  "options": ["rust", "zig", "go"],
  "createdAt": "2024-01-01T00:00:00.000Z"
}
```

### tech.waow.vote
```json
{
  "$type": "tech.waow.vote",
  "subject": "at://did:plc:.../tech.waow.poll/...",
  "option": 0,
  "createdAt": "2024-01-01T00:00:00.000Z"
}
```

## key lessons learned

### vote updates, not delete+create
when changing a vote, use `putRecord` to update the existing record rather than deleting and creating. this avoids race conditions where tap receives events out of order (create then delete) causing the vote to disappear.

### tap event ordering
tap delivers events in the order they're received from the firehose, but the firehose itself can deliver events out of order. the backend must handle this gracefully:
- `insertVote` uses upsert with timestamp comparison
- only updates if the incoming vote is newer than existing

### one vote per user per poll
enforced at multiple levels:
- frontend: checks for existing vote before creating
- backend: `UNIQUE(subject, voter)` constraint
- backend: upsert logic in `insertVote`

## deployment

### fly.io apps
- `pollz-backend` - zig backend with sqlite volume
- `pollz-tap` - tap instance with sqlite volume

### cloudflare pages
- frontend static files
- oauth client metadata at `/oauth-client-metadata.json`

### environment variables

backend:
- `TAP_HOST` - tap hostname (default: pollz-tap.internal)
- `TAP_PORT` - tap port (default: 2480)
- `DATA_PATH` - sqlite db path (default: /data/pollz.db)

tap:
- `TAP_DATABASE_URL` - sqlite path
- `TAP_COLLECTION_FILTERS` - collections to track
- `TAP_SIGNAL_COLLECTION` - collection for auto-discovery
