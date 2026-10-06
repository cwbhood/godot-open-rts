# Crash inbox (optional)

Without this, the game's "Send report" button opens a prefilled GitHub issue in the
player's browser, which needs a GitHub account. This Cloudflare Worker lets the game post
the report itself and files the issue for the player. Cloudflare's free plan allows
100,000 requests a day, far more than crash reports need.

Setup, about 10 minutes:

1. Create a free Cloudflare account and install Wrangler: `npm install -g wrangler`, then
   `wrangler login`.
2. On GitHub, create a fine-grained personal access token limited to
   `destinjones/godot-open-rts` with **Issues: Read and write** and nothing else.
3. In this folder: `wrangler secret put GITHUB_TOKEN` (paste the token), then
   `wrangler deploy`. It prints the address, like
   `https://ironbound-crash-inbox.<you>.workers.dev`.
4. In `project.godot` set `ironbound/crash_reports/endpoint` to that address (or in the
   editor: Project Settings, Ironbound, Crash Reports, Endpoint).
5. Create the `crash-report` label on the repository so issues are easy to filter.

The worker only accepts text that starts like a game crash report, caps the size, and limits
each address to 5 reports a minute.
