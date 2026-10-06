# Website and release builds

The game's website is a plain static site in `site/` (HTML, one CSS file, one small
script, screenshots and the build-up video). No build tools, no cookies, no analytics.

## Edit the site

The pages are generated from `tools/site/build.py`, which holds the shared header,
footer and every page's text. Edit it, then regenerate and commit both:

```
python3 tools/site/build.py site
```

The About page reads `tools/site/creator.json` (name, bio, principles, links). Edit that
file to change the creator text; the photo is `site/assets/img/creator.webp`,
`creator-sm.webp` and `creator.jpg` (square, 640 px).

SEO: every page gets its own title, description, canonical URL, Open Graph and Twitter
card (share image `site/assets/img/share.jpg`, 1200x630) and JSON-LD (VideoGame and
SoftwareApplication on the home page, Person on About, breadcrumbs elsewhere).
`build.py` also writes `sitemap.xml`, `robots.txt` and the web manifest. If the site
moves to a custom domain, change `BASE` at the top of `build.py` and rebuild. Fonts are
self-hosted in `site/assets/fonts/` (SIL Open Font License), so pages make no requests
to Google.

Preview locally with `python3 -m http.server -d site 8000` and open http://localhost:8000.
Images live in `site/assets/img/` as WebP (a `-sm` copy for thumbnails), the video in
`site/assets/video/`.

The download buttons link to
`https://github.com/destinjones/godot-open-rts/releases/latest/download/<file>`, so they
always fetch the newest published release. `site/assets/site.js` also asks the public
GitHub API for the release name and file sizes; if there is no public release it points
the buttons at the Releases page instead.

## Make a release

`.github/workflows/release.yml` exports the game with Godot 4.7.2 for Windows, Linux and
macOS and attaches the zips plus `SHA256SUMS.txt` to a **draft** release.

1. Actions > Release builds > Run workflow. Pick the branch to build and a version
   (for example `0.1.0`). Pushing a tag `v0.1.0` does the same for the tagged commit.
2. When it finishes, open Releases, check the draft, edit the notes and press
   Publish release. Until then nobody else sees it.

Locally: install Godot 4.7.2 and its export templates, then
`GODOT=/path/to/godot tools/release/export.sh 0.1.0`. Output goes to `dist/`.

The builds are not code-signed. Windows SmartScreen and macOS Gatekeeper warn on first
start; `tools/release/README-FIRST.txt` (shipped in every zip) and the download page
explain how to get past that. Signing needs a paid certificate (Apple Developer
Program, or a Windows code-signing certificate) and can be added to the workflow later.

## Go live

1. Settings > Pages > Source: GitHub Actions. (Pages on a private repository needs a
   paid GitHub plan; on a public repository it is free.)
2. Actions > Website > Run workflow. The site appears at
   https://destinjones.github.io/godot-open-rts/ unless a custom domain is set.
3. After that, every change to `site/` merged into main publishes itself.

## Later: a browser build

Godot can export to the web, but only with the Compatibility renderer, and the game's
shaders and navmesh rebakes need checking there first. See the research notes on browser
play before adding a web export preset; the site would then get a Play in browser page.
