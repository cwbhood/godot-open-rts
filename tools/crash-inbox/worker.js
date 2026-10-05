// Ironbound crash inbox: a free Cloudflare Worker that turns crash reports sent from the game
// into GitHub issues, so players without a GitHub account can send them too.
//
// The game POSTs {title, body, report_id, format} as JSON (see source/crash/CrashPrompt.gd).
// Secrets: GITHUB_TOKEN, a fine-grained token with "Issues: read and write" on the repo only.
// Vars: REPO (owner/name). Setup steps are in README.md next to this file.

const MAX_BODY = 60000;
const LABEL = "crash-report";

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("POST a crash report here", { status: 405 });
    }
    const raw = await request.text();
    if (raw.length > MAX_BODY + 2000) {
      return new Response("report too large", { status: 413 });
    }
    let report;
    try {
      report = JSON.parse(raw);
    } catch {
      return new Response("not JSON", { status: 400 });
    }
    const title = String(report.title || "").slice(0, 200);
    const body = String(report.body || "").slice(0, MAX_BODY);
    // only accept what the game produces, so the inbox can't be used to post anything else
    if (!title.startsWith("Crash report:") || !body.startsWith("### Ironbound crash report")) {
      return new Response("not a crash report", { status: 400 });
    }
    if (env.RATE_LIMITER) {
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      const { success } = await env.RATE_LIMITER.limit({ key: ip });
      if (!success) {
        return new Response("too many reports, try later", { status: 429 });
      }
    }
    const response = await fetch(`https://api.github.com/repos/${env.REPO}/issues`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.GITHUB_TOKEN}`,
        Accept: "application/vnd.github+json",
        "User-Agent": "ironbound-crash-inbox",
        "X-GitHub-Api-Version": "2022-11-28",
      },
      body: JSON.stringify({ title, body, labels: [LABEL] }),
    });
    if (!response.ok) {
      return new Response("could not file the issue", { status: 502 });
    }
    const issue = await response.json();
    return new Response(JSON.stringify({ issue: issue.number }), {
      status: 201,
      headers: { "Content-Type": "application/json" },
    });
  },
};
