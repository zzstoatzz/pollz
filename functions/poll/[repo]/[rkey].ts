// Cloudflare Pages Function for dynamic OG tags
const BACKEND_URL = "https://pollz-backend.fly.dev";

interface Poll {
  uri: string;
  repo: string;
  rkey: string;
  text: string;
  options: Array<{ text: string; count: number }>;
  createdAt: string;
}

export const onRequest: PagesFunction = async (context) => {
  const { repo, rkey } = context.params as { repo: string; rkey: string };
  const userAgent = context.request.headers.get("user-agent") || "";

  // check if this is a bot/crawler requesting the page
  const isCrawler = /bot|crawler|spider|facebook|twitter|slack|discord|telegram|whatsapp|linkedin|preview/i.test(userAgent);

  if (!isCrawler) {
    // not a crawler, serve the SPA normally
    return context.next();
  }

  // fetch poll data from backend
  const pollUri = `at://${repo}/tech.waow.poll/${rkey}`;
  try {
    const res = await fetch(`${BACKEND_URL}/api/polls/${encodeURIComponent(pollUri)}`);
    if (!res.ok) {
      return context.next();
    }

    const poll: Poll = await res.json();
    const total = poll.options.reduce((sum, o) => sum + o.count, 0);
    const optionsText = poll.options.map(o => `${o.text}: ${o.count}`).join(" | ");
    const description = `${total} vote${total === 1 ? "" : "s"} · ${optionsText}`;
    const url = `https://pollz.waow.tech/poll/${repo}/${rkey}`;

    // return HTML with proper OG tags for crawlers
    const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${escapeHtml(poll.text)} - pollz</title>
  <meta name="description" content="${escapeHtml(description)}">

  <!-- Open Graph -->
  <meta property="og:type" content="website">
  <meta property="og:title" content="${escapeHtml(poll.text)}">
  <meta property="og:description" content="${escapeHtml(description)}">
  <meta property="og:url" content="${url}">
  <meta property="og:site_name" content="pollz">

  <!-- Twitter -->
  <meta name="twitter:card" content="summary">
  <meta name="twitter:title" content="${escapeHtml(poll.text)}">
  <meta name="twitter:description" content="${escapeHtml(description)}">

  <meta http-equiv="refresh" content="0;url=${url}">
</head>
<body>
  <p>redirecting to <a href="${url}">${escapeHtml(poll.text)}</a>...</p>
</body>
</html>`;

    return new Response(html, {
      headers: { "content-type": "text/html;charset=UTF-8" },
    });
  } catch (e) {
    console.error("failed to fetch poll for OG tags:", e);
    return context.next();
  }
};

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
