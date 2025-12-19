import {
  POLL,
  agent,
  currentDid,
  setAgent,
  setCurrentDid,
  polls,
  login,
  logout,
  handleCallback,
  restoreSession,
  fetchPolls,
  fetchPoll,
  fetchVoters,
  createPoll,
  vote,
  resolveHandle,
  fetchPollFromPDS,
  type Poll,
} from "./lib/api";
import { esc, ago } from "./lib/utils";

const app = document.getElementById("app")!;
const nav = document.getElementById("nav")!;
const status = document.getElementById("status")!;

const setStatus = (msg: string) => (status.textContent = msg);

const showToast = (msg: string) => {
  const existing = document.querySelector(".toast");
  if (existing) existing.remove();

  const toast = document.createElement("div");
  toast.className = "toast";
  toast.textContent = msg;
  document.body.appendChild(toast);

  setTimeout(() => toast.remove(), 3000);
};

// track if a vote is in progress to prevent double-clicks
let votingInProgress = false;

// render
const render = () => {
  renderNav();

  const path = location.pathname;
  const match = path.match(/^\/poll\/([^/]+)\/([^/]+)$/);

  if (match) {
    renderPollPage(match[1], match[2]);
  } else if (path === "/new") {
    renderCreate();
  } else if (path === "/mine") {
    renderHome(true);
  } else {
    renderHome(false);
  }
};

const renderNav = () => {
  if (agent) {
    nav.innerHTML = `<a href="/">all</a> · <a href="/mine">mine</a> · <a href="/new">new</a> · <a href="#" id="logout">logout</a>`;
    document.getElementById("logout")!.onclick = async (e) => {
      e.preventDefault();
      await logout();
      setAgent(null);
      setCurrentDid(null);
      render();
    };
  } else {
    nav.innerHTML = `<input id="handle" placeholder="handle" style="width:120px"/> <button id="login">login</button>`;
    document.getElementById("login")!.onclick = async () => {
      const handle = (document.getElementById("handle") as HTMLInputElement).value.trim();
      if (!handle) return;
      setStatus("redirecting...");
      try {
        await login(handle);
      } catch (e) {
        setStatus(`error: ${e}`);
      }
    };
  }
};

const renderHome = async (mineOnly: boolean = false) => {
  app.innerHTML = "<p>loading polls...</p>";

  try {
    await fetchPolls();

    let filteredPolls = Array.from(polls.values());
    if (mineOnly && currentDid) {
      filteredPolls = filteredPolls.filter((p) => p.repo === currentDid);
    }
    filteredPolls.sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());

    const newLink = agent ? `<p><a href="/new">+ new poll</a></p>` : `<p>login to create polls</p>`;
    const heading = mineOnly ? `<p><strong>my polls</strong></p>` : "";

    if (filteredPolls.length === 0) {
      const msg = mineOnly ? "you haven't created any polls yet" : "no polls yet";
      app.innerHTML = newLink + heading + `<p>${msg}</p>`;
    } else {
      app.innerHTML = newLink + heading + filteredPolls.map(renderPollCard).join("");
      attachVoteHandlers();
    }
  } catch (e) {
    console.error("renderHome error:", e);
    app.innerHTML = "<p>failed to load polls</p>";
  }
};

const renderPollCard = (p: Poll) => {
  const total = p.voteCount ?? 0;
  const disabled = votingInProgress ? " disabled" : "";

  const opts = p.options
    .map((opt, i) => `
      <div class="option${disabled}" data-vote="${i}" data-poll="${p.uri}">
        <span class="option-text">${esc(opt)}</span>
      </div>
    `)
    .join("");

  return `
    <div class="poll">
      <a href="/poll/${p.repo}/${p.rkey}" class="poll-question">${esc(p.text)}</a>
      <div class="poll-meta">${ago(p.createdAt)} · <span class="vote-count" data-poll-uri="${p.uri}">${total} vote${total === 1 ? "" : "s"}</span></div>
      ${opts}
    </div>
  `;
};

// voters tooltip
type VoteInfo = { voter: string; option: number; uri: string; createdAt?: string; handle?: string };
const votersCache = new Map<string, VoteInfo[]>();
const pollOptionsCache = new Map<string, string[]>(); // for tooltip option names
let activeTooltip: HTMLElement | null = null;
let tooltipTimeout: ReturnType<typeof setTimeout> | null = null;

const showVotersTooltip = async (e: Event) => {
  const el = e.target as HTMLElement;
  const pollUri = el.dataset.pollUri;
  if (!pollUri) return;

  if (tooltipTimeout) {
    clearTimeout(tooltipTimeout);
    tooltipTimeout = null;
  }

  if (!votersCache.has(pollUri)) {
    try {
      const voters = await fetchVoters(pollUri);
      votersCache.set(pollUri, voters);
    } catch (err) {
      console.error("failed to fetch voters:", err);
      return;
    }
  }

  const voters = votersCache.get(pollUri);
  if (!voters || voters.length === 0) return;

  await Promise.all(voters.map(async (v) => {
    if (!v.handle) {
      v.handle = await resolveHandle(v.voter);
    }
  }));

  const poll = polls.get(pollUri);
  const options = poll?.options || pollOptionsCache.get(pollUri) || [];

  if (activeTooltip) activeTooltip.remove();

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

  tooltip.addEventListener("mouseenter", () => {
    if (tooltipTimeout) {
      clearTimeout(tooltipTimeout);
      tooltipTimeout = null;
    }
  });
  tooltip.addEventListener("mouseleave", hideVotersTooltip);

  const rect = el.getBoundingClientRect();
  tooltip.style.position = "fixed";
  tooltip.style.left = `${rect.left}px`;
  tooltip.style.top = `${rect.bottom + 4}px`;

  document.body.appendChild(tooltip);
  activeTooltip = tooltip;
};

const hideVotersTooltip = () => {
  tooltipTimeout = setTimeout(() => {
    if (activeTooltip) {
      activeTooltip.remove();
      activeTooltip = null;
    }
  }, 150);
};

const attachVoteHandlers = () => {
  app.querySelectorAll("[data-vote]").forEach((el) => {
    el.addEventListener("click", async (e) => {
      e.preventDefault();
      const t = e.currentTarget as HTMLElement;
      await handleVote(t.dataset.poll!, parseInt(t.dataset.vote!, 10));
    });
  });

  app.querySelectorAll(".vote-count").forEach((el) => {
    el.addEventListener("mouseenter", showVotersTooltip);
    el.addEventListener("mouseleave", hideVotersTooltip);
  });
};

const handleVote = async (pollUri: string, option: number) => {
  if (!agent || !currentDid) {
    showToast("login to vote");
    return;
  }

  if (votingInProgress) {
    return;
  }

  votingInProgress = true;
  setStatus("voting...");

  // disable all vote options visually
  app.querySelectorAll("[data-vote]").forEach((el) => {
    el.classList.add("disabled");
  });

  try {
    await vote(pollUri, option);
    setStatus("confirming...");

    // poll backend until vote is confirmed (tap needs time to process)
    const maxWait = 10000;
    const pollInterval = 500;
    const start = Date.now();

    while (Date.now() - start < maxWait) {
      const voters = await fetchVoters(pollUri);
      const myVote = voters.find(v => v.voter === currentDid);
      if (myVote && myVote.option === option) {
        break;
      }
      await new Promise(r => setTimeout(r, pollInterval));
    }

    // clear voters cache so tooltip shows fresh data
    votersCache.delete(pollUri);

    setStatus("");
    render();
  } catch (e) {
    console.error("vote error:", e);
    setStatus(`error: ${e}`);
    setTimeout(() => {
      setStatus("");
      render();
    }, 2000);
  } finally {
    votingInProgress = false;
  }
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

const renderPollPage = async (repo: string, rkey: string) => {
  const uri = `at://${repo}/${POLL}/${rkey}`;
  app.innerHTML = "<p>loading...</p>";

  try {
    const data = await fetchPoll(uri);

    if (data) {
      // cache options for tooltip
      pollOptionsCache.set(uri, data.options.map(o => o.text));
      const total = data.options.reduce((sum, o) => sum + o.count, 0);
      const disabled = votingInProgress ? " disabled" : "";

      const opts = data.options
        .map((opt, i) => {
          const pct = total > 0 ? Math.round((opt.count / total) * 100) : 0;
          return `
            <div class="option${disabled}" data-vote="${i}" data-poll="${uri}">
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
    const pdsData = await fetchPollFromPDS(repo, rkey);
    if (!pdsData) {
      app.innerHTML = "<p>not found</p>";
      return;
    }

    const poll: Poll = { ...pdsData };
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
  document.getElementById("create")!.onclick = handleCreate;
};

const handleCreate = async () => {
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
  try {
    await createPoll(text, options);
    setStatus("");
    history.pushState(null, "", "/");
    render();
  } catch (e) {
    setStatus(`error: ${e}`);
  }
};

// oauth callback handler
const handleOAuthCallback = async () => {
  const params = new URLSearchParams(location.hash.slice(1));
  if (!params.has("state")) return false;

  setStatus("logging in...");

  try {
    const success = await handleCallback();
    setStatus("");
    return success;
  } catch (e) {
    setStatus(`login failed: ${e}`);
    return false;
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
  await handleOAuthCallback();
  await restoreSession();
  render();
})();
