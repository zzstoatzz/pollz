import { Client, simpleFetchHandler } from "@atcute/client";
import {
  CompositeDidDocumentResolver,
  CompositeHandleResolver,
  DohJsonHandleResolver,
  PlcDidDocumentResolver,
  AtprotoWebDidDocumentResolver,
  WellKnownHandleResolver,
} from "@atcute/identity-resolver";
import {
  configureOAuth,
  createAuthorizationUrl,
  defaultIdentityResolver,
  finalizeAuthorization,
  getSession,
  OAuthUserAgent,
  deleteStoredSession,
} from "@atcute/oauth-browser-client";

export const POLL = "tech.waow.poll";
export const VOTE = "tech.waow.vote";

export const didDocumentResolver = new CompositeDidDocumentResolver({
  methods: {
    plc: new PlcDidDocumentResolver(),
    web: new AtprotoWebDidDocumentResolver(),
  },
});

export const handleResolver = new CompositeHandleResolver({
  strategy: "dns-first",
  methods: {
    dns: new DohJsonHandleResolver({ dohUrl: "https://dns.google/resolve?" }),
    http: new WellKnownHandleResolver(),
  },
});

const BASE_URL = import.meta.env.VITE_BASE_URL || "https://pollz.waow.tech";
export const BACKEND_URL = import.meta.env.VITE_BACKEND_URL || "https://pollz-backend.fly.dev";

configureOAuth({
  metadata: {
    client_id: `${BASE_URL}/oauth-client-metadata.json`,
    redirect_uri: `${BASE_URL}/`,
  },
  identityResolver: defaultIdentityResolver({
    handleResolver,
    didDocumentResolver,
  }),
});

// state
export let agent: OAuthUserAgent | null = null;
export let currentDid: string | null = null;

export const setAgent = (a: OAuthUserAgent | null) => { agent = a; };
export const setCurrentDid = (did: string | null) => { currentDid = did; };

export type Poll = {
  uri: string;
  repo: string;
  rkey: string;
  text: string;
  options: string[];
  createdAt: string;
  votes: Map<string, number>;
  voteCount?: number;
};

export const polls = new Map<string, Poll>();

// oauth
export const login = async (handle: string): Promise<void> => {
  const url = await createAuthorizationUrl({
    scope: `atproto repo:${POLL} repo:${VOTE}`,
    target: { type: "account", identifier: handle },
  });
  location.assign(url);
};

export const logout = async (): Promise<void> => {
  if (currentDid) {
    await deleteStoredSession(currentDid as `did:${string}:${string}`);
    localStorage.removeItem("lastDid");
  }
  agent = null;
  currentDid = null;
};

export const handleCallback = async (): Promise<boolean> => {
  const params = new URLSearchParams(location.hash.slice(1));
  if (!params.has("state")) return false;

  history.replaceState(null, "", "/");
  const { session } = await finalizeAuthorization(params);
  agent = new OAuthUserAgent(session);
  currentDid = session.info.sub;
  localStorage.setItem("lastDid", currentDid);
  return true;
};

export const restoreSession = async (): Promise<void> => {
  const lastDid = localStorage.getItem("lastDid");
  if (!lastDid) return;

  try {
    const session = await getSession(lastDid as `did:${string}:${string}`);
    agent = new OAuthUserAgent(session);
    currentDid = session.info.sub;
  } catch {
    localStorage.removeItem("lastDid");
  }
};

// backend api
export const fetchPolls = async (): Promise<void> => {
  const res = await fetch(`${BACKEND_URL}/api/polls`);
  if (!res.ok) throw new Error("failed to fetch polls");

  const backendPolls = await res.json() as Array<{
    uri: string;
    repo: string;
    rkey: string;
    text: string;
    options: string[];
    createdAt: string;
    voteCount: number;
  }>;

  for (const p of backendPolls) {
    const existing = polls.get(p.uri);
    if (existing) {
      existing.voteCount = p.voteCount;
    } else {
      polls.set(p.uri, {
        uri: p.uri,
        repo: p.repo,
        rkey: p.rkey,
        text: p.text,
        options: p.options,
        createdAt: p.createdAt,
        votes: new Map(),
        voteCount: p.voteCount,
      });
    }
  }
};

export const fetchPoll = async (uri: string) => {
  const res = await fetch(`${BACKEND_URL}/api/polls/${encodeURIComponent(uri)}`);
  if (!res.ok) return null;
  return res.json() as Promise<{
    uri: string;
    repo: string;
    rkey: string;
    text: string;
    options: Array<{ text: string; count: number }>;
    createdAt: string;
  }>;
};

export const fetchVoters = async (pollUri: string) => {
  const res = await fetch(`${BACKEND_URL}/api/polls/${encodeURIComponent(pollUri)}/votes`);
  if (!res.ok) return [];
  return res.json() as Promise<Array<{ voter: string; option: number; uri: string; createdAt?: string }>>;
};

// user votes
export const loadUserVotes = async (): Promise<void> => {
  if (!agent || !currentDid) return;

  try {
    const rpc = new Client({ handler: agent });
    const res = await rpc.get("com.atproto.repo.listRecords", {
      params: { repo: currentDid, collection: VOTE, limit: 100 },
    });

    if (res.ok) {
      for (const record of res.data.records) {
        const val = record.value as { subject?: string; option?: number };
        if (val.subject && typeof val.option === "number") {
          const poll = polls.get(val.subject);
          if (poll) {
            poll.votes.set(record.uri, val.option);
          }
        }
      }
    }
  } catch (e) {
    console.error("failed to load user votes:", e);
  }
};

// create poll
export const createPoll = async (text: string, options: string[]): Promise<string | null> => {
  if (!agent || !currentDid) return null;

  const rpc = new Client({ handler: agent });
  const res = await rpc.post("com.atproto.repo.createRecord", {
    input: {
      repo: currentDid,
      collection: POLL,
      record: { $type: POLL, text, options, createdAt: new Date().toISOString() },
    },
  });

  if (!res.ok) throw new Error(res.data.error || "failed to create poll");

  const rkey = res.data.uri.split("/").pop()!;
  polls.set(res.data.uri, {
    uri: res.data.uri,
    repo: currentDid,
    rkey,
    text,
    options,
    createdAt: new Date().toISOString(),
    votes: new Map(),
  });

  return res.data.uri;
};

// vote - creates or updates vote record on user's PDS
export const vote = async (pollUri: string, option: number): Promise<void> => {
  if (!agent || !currentDid) throw new Error("not logged in");

  const rpc = new Client({ handler: agent });

  // check if we already have a vote on this poll
  const existing = await rpc.get("com.atproto.repo.listRecords", {
    params: { repo: currentDid, collection: VOTE, limit: 100 },
  });

  let existingRkey: string | null = null;
  if (existing.ok) {
    for (const record of existing.data.records) {
      const val = record.value as { subject?: string };
      if (val.subject === pollUri) {
        existingRkey = record.uri.split("/").pop()!;
        break;
      }
    }
  }

  if (existingRkey) {
    // update existing vote
    const res = await rpc.post("com.atproto.repo.putRecord", {
      input: {
        repo: currentDid,
        collection: VOTE,
        rkey: existingRkey,
        record: { $type: VOTE, subject: pollUri, option, createdAt: new Date().toISOString() },
      },
    });
    if (!res.ok) throw new Error(res.data.error || res.data.message || "vote update failed");
  } else {
    // create new vote
    const res = await rpc.post("com.atproto.repo.createRecord", {
      input: {
        repo: currentDid,
        collection: VOTE,
        record: { $type: VOTE, subject: pollUri, option, createdAt: new Date().toISOString() },
      },
    });
    if (!res.ok) throw new Error(res.data.error || res.data.message || "vote failed");
  }
};

// resolve handle from DID
const handleCache = new Map<string, string>();

export const resolveHandle = async (did: string): Promise<string> => {
  if (handleCache.has(did)) return handleCache.get(did)!;
  try {
    const res = await fetch(`https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=${did}`);
    if (res.ok) {
      const data = await res.json();
      if (data.handle) {
        handleCache.set(did, data.handle);
        return data.handle;
      }
    }
  } catch {}
  return did;
};

// fetch poll directly from PDS (fallback)
export const fetchPollFromPDS = async (repo: string, rkey: string) => {
  const didDoc = await didDocumentResolver.resolve(repo as `did:${string}:${string}`);
  const pds = didDoc?.service?.find((s: { id: string }) => s.id === "#atproto_pds") as { serviceEndpoint?: string } | undefined;
  const pdsUrl = pds?.serviceEndpoint || "https://bsky.social";

  const pdsClient = new Client({
    handler: simpleFetchHandler({ service: pdsUrl }),
  });

  const res = await pdsClient.get("com.atproto.repo.getRecord", {
    params: { repo, collection: POLL, rkey },
  });

  if (!res.ok) return null;

  const rec = res.data.value as { text: string; options: string[]; createdAt: string };
  return {
    uri: res.data.uri,
    repo,
    rkey,
    text: rec.text,
    options: rec.options,
    createdAt: rec.createdAt,
  };
};
