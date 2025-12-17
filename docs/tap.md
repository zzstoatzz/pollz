# tap integration

tap is bluesky's official atproto sync utility. pollz uses it to receive real-time events from the firehose.

## what tap provides

- firehose connection with automatic reconnection
- signature verification of repo structure and identity
- automatic backfill when adding new repos
- filtered output by collection
- ordering guarantees - backfill completes before live events
- cursor management - persists automatically, resumes on restart

## pollz tap configuration

```toml
# tap/fly.toml
[env]
  TAP_COLLECTION_FILTERS = "tech.waow.poll,tech.waow.vote"
  TAP_SIGNAL_COLLECTION = "tech.waow.poll"
  TAP_DATABASE_URL = "sqlite:///data/tap.db"
  TAP_DISABLE_ACKS = "true"
```

`TAP_SIGNAL_COLLECTION` makes tap automatically discover and track all repos that have ever created a poll.

## event format

tap delivers events via websocket at `/channel`:

```json
{
  "id": 12345,
  "type": "record",
  "record": {
    "live": true,
    "did": "did:plc:abc123",
    "collection": "tech.waow.poll",
    "rkey": "3kb3fge5lm32x",
    "action": "create",
    "record": {
      "text": "what's your favorite color?",
      "options": ["red", "blue", "green"],
      "$type": "tech.waow.poll",
      "createdAt": "2024-10-07T12:00:00.000Z"
    }
  }
}
```

### action types
- `create` - new record created
- `update` - existing record updated (same rkey)
- `delete` - record deleted

## backend tap consumer

the backend connects to tap via websocket and processes events:

```zig
// tap.zig
if (mem.eql(u8, action.string, "create") or mem.eql(u8, action.string, "update")) {
    // process poll or vote
} else if (mem.eql(u8, action.string, "delete")) {
    // delete poll or vote
}
```

## handling out-of-order events

tap delivers events in firehose order, but the firehose itself can deliver events out of order. example:

1. user deletes old vote, creates new vote
2. firehose delivers: create (new), delete (old)
3. if backend processes delete after create, the new vote disappears

### solution: use putRecord instead of delete+create

when changing a vote, the frontend uses `putRecord` to update the existing record:

```typescript
// api.ts
if (existingRkey) {
  // update existing vote - single "update" event
  await rpc.post("com.atproto.repo.putRecord", { ... });
} else {
  // create new vote
  await rpc.post("com.atproto.repo.createRecord", { ... });
}
```

this results in a single "update" event instead of separate "delete" and "create" events, eliminating the race condition.

### backend upsert logic

as additional protection, `insertVote` uses upsert with timestamp comparison:

```sql
INSERT INTO votes (uri, subject, option, voter, created_at)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(subject, voter) DO UPDATE SET
  uri = excluded.uri,
  option = excluded.option,
  created_at = excluded.created_at
WHERE excluded.created_at > votes.created_at OR votes.created_at IS NULL
```

this ensures that if out-of-order events do occur, older events don't overwrite newer ones.

## deployment

tap runs as a separate fly.io app (`pollz-tap`) and communicates with the backend over fly's internal network:

```
pollz-tap.internal:2480  →  pollz-backend
```

## further reading

- [tap README](https://github.com/bluesky-social/indigo/blob/main/cmd/tap/README.md)
- [indigo repo](https://github.com/bluesky-social/indigo)
- [bailey's tap guide](https://marvins-guide.leaflet.pub/3m7ttuppfzc23)
