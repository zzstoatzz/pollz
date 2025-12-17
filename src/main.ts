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

const POLL = "tech.waow.poll";
const VOTE = "tech.waow.vote";

const didDocumentResolver = new CompositeDidDocumentResolver({
  methods: {
    plc: new PlcDidDocumentResolver(),
    web: new AtprotoWebDidDocumentResolver(),
  },
});

const handleResolver = new CompositeHandleResolver({
  strategy: "dns-first",
  methods: {
    dns: new DohJsonHandleResolver({ dohUrl: "https://dns.google/resolve?" }),
    http: new WellKnownHandleResolver(),
  },
});

const BASE_URL = import.meta.env.VITE_BASE_URL || "https://pollz.waow.tech";

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

const app = document.getElementById("app")!;
const nav = document.getElementById("nav")!;
const status = document.getElementById("status")!;

let agent: OAuthUserAgent | null = null;
let currentDid: string | null = null;
let jetstream: WebSocket | null = null;

const setStatus = (msg: string) => (status.textContent = msg);

type Poll = {
  uri: string;
  repo: string;
  rkey: string;
  text: string;
  options: string[];
  createdAt: string;
  votes: Map<string, number>;
  voteCount?: number; // from backend, used when votes map is empty
};

const polls = new Map<string, Poll>();

// jetstream - replay last 24h on connect, then live updates
const connectJetstream = () => {
  if (jetstream?.readyState === WebSocket.OPEN) return;

  // cursor is microseconds since epoch - go back 24 hours
  const cursor = (Date.now() - 24 * 60 * 60 * 1000) * 1000;
  const url = `wss://jetstream1.us-east.bsky.network/subscribe?wantedCollections=${POLL}&wantedCollections=${VOTE}&cursor=${cursor}`;
  jetstream = new WebSocket(url);

  jetstream.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.kind !== "commit") return;

    const { commit } = msg;
    const uri = `at://${msg.did}/${commit.collection}/${commit.rkey}`;

    if (commit.collection === POLL) {
      if (commit.operation === "create" && commit.record) {
        polls.set(uri, {
          uri,
          repo: msg.did,
          rkey: commit.rkey,
          text: commit.record.text,
          options: commit.record.options,
          createdAt: commit.record.createdAt,
          votes: new Map(),
        });
        render();
      } else if (commit.operation === "delete") {
        polls.delete(uri);
        render();
      }
    }

    if (commit.collection === VOTE) {
      if (commit.operation === "create" && commit.record) {
        const poll = polls.get(commit.record.subject);
        if (poll && !poll.votes.has(uri)) {
          poll.votes.set(uri, commit.record.option);
          render();
        }
      } else if (commit.operation === "delete") {
        // find and remove vote from its poll
        for (const poll of polls.values()) {
          if (poll.votes.has(uri)) {
            poll.votes.delete(uri);
            render();
            break;
          }
        }
      }
    }
  };

  jetstream.onclose = () => setTimeout(connectJetstream, 3000);
};

// render
const render = () => {
  renderNav();

  const path = location.pathname;
  const match = path.match(/^\/poll\/([^/]+)\/([^/]+)$/);

  if (match) {
    renderPoll(match[1], match[2]);
  } else if (path === "/new") {
    renderCreate();
  } else {
    renderHome();
  }
};

const renderNav = () => {
  if (agent) {
    nav.innerHTML = `<a href="/">my polls</a> · <a href="/new">new</a> · <a href="#" id="logout">logout</a>`;
    document.getElementById("logout")!.onclick = async (e) => {
      e.preventDefault();
      if (currentDid) {
        await deleteStoredSession(currentDid as `did:${string}:${string}`);
        localStorage.removeItem("lastDid");
      }
      agent = null;
      currentDid = null;
      render();
    };
  } else {
    nav.innerHTML = `<input id="handle" placeholder="handle" style="width:120px"/> <button id="login">login</button>`;
    document.getElementById("login")!.onclick = async () => {
      const handle = (document.getElementById("handle") as HTMLInputElement).value.trim();
      if (!handle) return;
      setStatus("redirecting...");
      try {
        const url = await createAuthorizationUrl({
          scope: `atproto repo:${POLL} repo:${VOTE}`,
          target: { type: "account", identifier: handle },
        });
        location.assign(url);
      } catch (e) {
        setStatus(`error: ${e}`);
      }
    };
  }
};

const BACKEND_URL = import.meta.env.VITE_BACKEND_URL || "https://pollz-backend.fly.dev";

// fetch user's existing votes from their PDS
const loadUserVotes = async () => {
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

const renderHome = async () => {
  app.innerHTML = "<p>loading polls...</p>";

  try {
    // fetch all polls from backend
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

    // merge into local state
    for (const p of backendPolls) {
      const existing = polls.get(p.uri);
      if (existing) {
        // update vote count from backend
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

    // load user's votes now that polls are in memory
    await loadUserVotes();

    const allPolls = Array.from(polls.values())
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());

    const newLink = agent ? `<p><a href="/new">+ new poll</a></p>` : `<p>login to create polls</p>`;

    if (allPolls.length === 0) {
      app.innerHTML = newLink + "<p>no polls yet</p>";
    } else {
      app.innerHTML = newLink + allPolls.map(renderPollCard).join("");
      attachVoteHandlers();
    }
  } catch (e) {
    console.error("renderHome error:", e);
    app.innerHTML = "<p>failed to load polls</p>";
  }
};

const renderPollCard = (p: Poll) => {
  // always use backend voteCount for total
  const total = p.voteCount ?? 0;

  const opts = p.options
    .map((opt, i) => {
      return `
        <div class="option" data-vote="${i}" data-poll="${p.uri}">
          <span class="option-text">${esc(opt)}</span>
        </div>
      `;
    })
    .join("");

  return `
    <div class="poll">
      <a href="/poll/${p.repo}/${p.rkey}" class="poll-question">${esc(p.text)}</a>
      <div class="poll-meta">${ago(p.createdAt)} · <span class="vote-count" data-poll-uri="${p.uri}">${total} vote${total === 1 ? "" : "s"}</span></div>
      ${opts}
    </div>
  `;
};

const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const ago = (date: string) => {
  const seconds = Math.floor((Date.now() - new Date(date).getTime()) / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(date).toLocaleDateString();
};

const attachVoteHandlers = () => {
  app.querySelectorAll("[data-vote]").forEach((el) => {
    el.addEventListener("click", async (e) => {
      e.preventDefault();
      const t = e.currentTarget as HTMLElement;
      await vote(t.dataset.poll!, parseInt(t.dataset.vote!, 10));
    });
  });

  // attach hover handlers for vote counts
  app.querySelectorAll(".vote-count").forEach((el) => {
    el.addEventListener("mouseenter", showVotersTooltip);
    el.addEventListener("mouseleave", hideVotersTooltip);
  });
};

type Vote = { voter: string; option: number; uri: string; createdAt?: string; handle?: string };
const votersCache = new Map<string, Vote[]>();
const handleCache = new Map<string, string>();
let activeTooltip: HTMLElement | null = null;
let tooltipTimeout: ReturnType<typeof setTimeout> | null = null;

// resolve DID to handle
const resolveHandle = async (did: string): Promise<string> => {
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
  return did; // fallback to DID
};

const showVotersTooltip = async (e: Event) => {
  const el = e.target as HTMLElement;
  const pollUri = el.dataset.pollUri;
  if (!pollUri) return;

  // clear any pending hide
  if (tooltipTimeout) {
    clearTimeout(tooltipTimeout);
    tooltipTimeout = null;
  }

  // fetch voters if not cached
  if (!votersCache.has(pollUri)) {
    try {
      const res = await fetch(`${BACKEND_URL}/api/polls/${encodeURIComponent(pollUri)}/votes`);
      if (res.ok) {
        votersCache.set(pollUri, await res.json());
      }
    } catch (err) {
      console.error("failed to fetch voters:", err);
      return;
    }
  }

  const voters = votersCache.get(pollUri);
  if (!voters || voters.length === 0) return;

  // resolve handles for all voters
  await Promise.all(voters.map(async (v) => {
    if (!v.handle) {
      v.handle = await resolveHandle(v.voter);
    }
  }));

  // get poll options for display
  const poll = polls.get(pollUri);
  const options = poll?.options || [];

  // remove existing tooltip if any
  if (activeTooltip) activeTooltip.remove();

  // create tooltip
  const tooltip = document.createElement("div");
  tooltip.className = "voters-tooltip";
  tooltip.innerHTML = voters
    .map((v) => {
      const optText = options[v.option] || `option ${v.option}`;
      const profileUrl = `https://bsky.app/profile/${v.voter}`;
      const displayName = v.handle || v.voter;
      const timeStr = v.createdAt ? ago(v.createdAt) : "";
      return `<div class="voter"><a href="${profileUrl}" target="_blank" class="voter-link">@${esc(displayName)}</a> → ${esc(optText)}${timeStr ? ` <span class="vote-time">${timeStr}</span>` : ""}</div>`;
    })
    .join("");

  // keep tooltip visible when hovering over it
  tooltip.addEventListener("mouseenter", () => {
    if (tooltipTimeout) {
      clearTimeout(tooltipTimeout);
      tooltipTimeout = null;
    }
  });
  tooltip.addEventListener("mouseleave", hideVotersTooltip);

  // position tooltip
  const rect = el.getBoundingClientRect();
  tooltip.style.position = "fixed";
  tooltip.style.left = `${rect.left}px`;
  tooltip.style.top = `${rect.bottom + 4}px`;

  document.body.appendChild(tooltip);
  activeTooltip = tooltip;
};

const hideVotersTooltip = () => {
  // delay hiding so user can move to tooltip
  tooltipTimeout = setTimeout(() => {
    if (activeTooltip) {
      activeTooltip.remove();
      activeTooltip = null;
    }
  }, 150);
};

const attachShareHandler = () => {
  const btn = app.querySelector(".share-btn") as HTMLButtonElement;
  if (!btn) return;

  btn.addEventListener("click", async () => {
    const url = btn.dataset.url!;
    try {
      await navigator.clipboard.writeText(url);
      btn.textContent = "copied!";
      btn.classList.add("copied");
      setTimeout(() => {
        btn.textContent = "copy link";
        btn.classList.remove("copied");
      }, 2000);
    } catch {
      // fallback for older browsers
      const input = document.createElement("input");
      input.value = url;
      document.body.appendChild(input);
      input.select();
      document.execCommand("copy");
      document.body.removeChild(input);
      btn.textContent = "copied!";
      btn.classList.add("copied");
      setTimeout(() => {
        btn.textContent = "copy link";
        btn.classList.remove("copied");
      }, 2000);
    }
  });
};

const renderPoll = async (repo: string, rkey: string) => {
  const uri = `at://${repo}/${POLL}/${rkey}`;
  app.innerHTML = "<p>loading...</p>";

  try {
    // fetch poll with vote counts from backend
    const res = await fetch(`${BACKEND_URL}/api/polls/${encodeURIComponent(uri)}`);

    if (res.ok) {
      const data = await res.json() as {
        uri: string;
        repo: string;
        rkey: string;
        text: string;
        options: Array<{ text: string; count: number }>;
        createdAt: string;
      };

      // render poll with vote counts from backend
      const total = data.options.reduce((sum, o) => sum + o.count, 0);
      const opts = data.options
        .map((opt, i) => {
          const pct = total > 0 ? Math.round((opt.count / total) * 100) : 0;
          return `
          <div class="option" data-vote="${i}" data-poll="${uri}">
            <div class="option-bar" style="width: ${pct}%"></div>
            <span class="option-text">${esc(opt.text)}</span>
            <span class="option-count">${opt.count} (${pct}%)</span>
          </div>`;
        })
        .join("");

      const shareUrl = `${window.location.origin}/poll/${repo}/${rkey}`;
      app.innerHTML = `
        <p><a href="/">&larr; back</a></p>
        <div class="poll-detail">
          <div class="poll-header">
            <h2 class="poll-question">${esc(data.text)}</h2>
            <button class="share-btn" data-url="${shareUrl}">copy link</button>
          </div>
          ${opts}
          <div class="poll-meta">${ago(data.createdAt)} · <span class="vote-count" data-poll-uri="${uri}">${total} vote${total === 1 ? "" : "s"}</span></div>
        </div>`;
      attachVoteHandlers();
      attachShareHandler();
      return;
    }

    // fallback to direct PDS fetch if backend doesn't have it
    const didDoc = await didDocumentResolver.resolve(repo as `did:${string}:${string}`);
    const pds = didDoc?.service?.find((s: { id: string }) => s.id === "#atproto_pds") as { serviceEndpoint?: string } | undefined;
    const pdsUrl = pds?.serviceEndpoint || "https://bsky.social";

    const pdsClient = new Client({
      handler: simpleFetchHandler({ service: pdsUrl }),
    });

    const pdsRes = await pdsClient.get("com.atproto.repo.getRecord", {
      params: { repo, collection: POLL, rkey },
    });
    if (!pdsRes.ok) {
      app.innerHTML = "<p>not found</p>";
      return;
    }
    const rec = pdsRes.data.value as { text: string; options: string[]; createdAt: string };
    const poll = { uri: pdsRes.data.uri, repo, rkey, text: rec.text, options: rec.options, createdAt: rec.createdAt, votes: new Map() };
    polls.set(uri, poll);

    app.innerHTML = `<p><a href="/">&larr; back</a></p>${renderPollCard(poll)}`;
    attachVoteHandlers();
  } catch (e) {
    console.error("renderPoll error:", e);
    app.innerHTML = "<p>error loading poll</p>";
  }
};

const renderCreate = () => {
  if (!agent) {
    app.innerHTML = "<p>login to create</p>";
    return;
  }
  app.innerHTML = `
    <div class="create-form">
      <input type="text" id="question" placeholder="question" />
      <textarea id="options" rows="4" placeholder="options (one per line)"></textarea>
      <button id="create">create</button>
    </div>
  `;
  document.getElementById("create")!.onclick = create;
};

const create = async () => {
  if (!agent || !currentDid) return;

  const text = (document.getElementById("question") as HTMLInputElement).value.trim();
  const options = (document.getElementById("options") as HTMLTextAreaElement).value
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);

  if (!text || options.length < 2) {
    setStatus("need question + 2 options");
    return;
  }

  setStatus("creating...");
  const rpc = new Client({ handler: agent });
  const res = await rpc.post("com.atproto.repo.createRecord", {
    input: {
      repo: currentDid,
      collection: POLL,
      record: { $type: POLL, text, options, createdAt: new Date().toISOString() },
    },
  });

  if (!res.ok) {
    setStatus(`error: ${res.data.error}`);
    return;
  }

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

  setStatus("");
  history.pushState(null, "", "/");
  render();
};

const vote = async (pollUri: string, option: number) => {
  if (!agent || !currentDid) {
    setStatus("login to vote");
    return;
  }

  setStatus("voting...");
  const rpc = new Client({ handler: agent });

  // first, find and delete any existing votes on this poll
  try {
    const existing = await rpc.get("com.atproto.repo.listRecords", {
      params: { repo: currentDid, collection: VOTE, limit: 100 },
    });
    if (existing.ok) {
      for (const record of existing.data.records) {
        const val = record.value as { subject?: string };
        if (val.subject === pollUri) {
          const rkey = record.uri.split("/").pop()!;
          await rpc.post("com.atproto.repo.deleteRecord", {
            input: { repo: currentDid, collection: VOTE, rkey },
          });
        }
      }
    }
  } catch (e) {
    console.error("error checking existing votes:", e);
  }

  const res = await rpc.post("com.atproto.repo.createRecord", {
    input: {
      repo: currentDid,
      collection: VOTE,
      record: { $type: VOTE, subject: pollUri, option, createdAt: new Date().toISOString() },
    },
  });

  if (!res.ok) {
    console.error("vote error:", res.status, res.data);
    setStatus(`error: ${res.data.error || res.data.message || "unknown"}`);
    setTimeout(() => setStatus(""), 3000);
    return;
  }

  // update local state
  const poll = polls.get(pollUri);
  if (poll) {
    // remove any existing vote from this user
    for (const [uri, _] of poll.votes) {
      if (uri.startsWith(`at://${currentDid}/${VOTE}/`)) {
        poll.votes.delete(uri);
      }
    }
    poll.votes.set(res.data.uri, option);
  }

  setStatus("");
  render();
};

// oauth
const handleCallback = async () => {
  const params = new URLSearchParams(location.hash.slice(1));
  if (!params.has("state")) return false;

  history.replaceState(null, "", "/");
  setStatus("logging in...");

  try {
    const { session } = await finalizeAuthorization(params);
    agent = new OAuthUserAgent(session);
    currentDid = session.info.sub;
    localStorage.setItem("lastDid", currentDid);
    setStatus("");
    return true;
  } catch (e) {
    setStatus(`login failed: ${e}`);
    return false;
  }
};

const restoreSession = async () => {
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

// routing
window.addEventListener("popstate", render);
document.addEventListener("click", (e) => {
  const a = (e.target as HTMLElement).closest("a");
  if (a?.href.startsWith(location.origin) && !a.href.includes("#")) {
    e.preventDefault();
    history.pushState(null, "", a.href);
    render();
  }
});

// init
(async () => {
  await handleCallback();
  await restoreSession();
  connectJetstream();
  render();
})();
