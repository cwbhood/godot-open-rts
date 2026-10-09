#!/usr/bin/env python3
"""Writes the Ironbound site pages into site/. Shared header and footer live here."""
import html
import json
import pathlib
import sys

OUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "site")
REPO = "https://github.com/destinjones/godot-open-rts"
# Where the site is published. Change this if a custom domain is added.
BASE = "https://destinjones.github.io/godot-open-rts/"
HERE = pathlib.Path(__file__).resolve().parent
CREATOR = json.loads((HERE / "creator.json").read_text())
LATEST = REPO + "/releases/latest/download/"

NAV = [
    ("index.html", "Home"),
    ("play.html", "How to play"),
    ("factions.html", "Factions"),
    ("changelog.html", "Changelog"),
    ("roadmap.html", "Roadmap"),
    ("open-source.html", "Open source"),
    ("support.html", "Crash reports"),
    ("community.html", "Community"),
    ("about.html", "About"),
]

MARK = (
    '<svg class="brand-mark" viewBox="0 0 32 32" aria-hidden="true">'
    '<path fill="var(--accent)" d="M7 2h18l5 5v18l-5 5H7l-5-5V7z"/>'
    '<path fill="var(--accent-ink)" d="M12 8h8v3h-2v10h2v3h-8v-3h2V11h-2z"/>'
    '<g fill="var(--accent-ink)"><circle cx="7.5" cy="7.5" r="1.4"/><circle cx="24.5" cy="7.5" r="1.4"/>'
    '<circle cx="7.5" cy="24.5" r="1.4"/><circle cx="24.5" cy="24.5" r="1.4"/></g></svg>'
)

ICON_DOWN = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="square" d="M12 3v12m-6-6 6 6 6-6M4 20h16"/></svg>'
ICON_WIN = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M3 5.5 10 4.5v7H3zM11 4.4 21 3v8.5H11zM3 12.5h7v7l-7-1zM11 12.5h10V21l-10-1.4z"/></svg>'
ICON_LINUX = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M12 2c-2.2 0-3.6 1.9-3.6 4.6 0 1.6.5 2.6-.6 4.3C6.5 12.8 5 14.9 5 17.2c0 .9.2 1.6.6 2.1-.6.5-1.4 1-1.2 1.7.3.9 2 .5 3.2 1 1.2.5 2.4 0 2.9-.8h3c.5.8 1.7 1.3 2.9.8 1.2-.5 2.9-.1 3.2-1 .2-.7-.6-1.2-1.2-1.7.4-.5.6-1.2.6-2.1 0-2.3-1.5-4.4-2.8-6.3-1.1-1.7-.6-2.7-.6-4.3C15.6 3.9 14.2 2 12 2zm-1.5 4.2c.5 0 .8.5.8 1.1s-.3 1-.8 1-.8-.4-.8-1 .3-1.1.8-1.1zm3 0c.5 0 .8.5.8 1.1s-.3 1-.8 1-.8-.4-.8-1 .3-1.1.8-1.1zM12 9.3c.9 0 2 .6 2 1s-1.1 1.1-2 1.1-2-.7-2-1.1 1.1-1 2-1z"/></svg>'
ICON_MAC = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M16.4 12.6c0-2.4 2-3.6 2.1-3.7-1.1-1.7-2.9-1.9-3.5-1.9-1.5-.2-2.9.9-3.7.9-.8 0-1.9-.9-3.2-.8-1.6 0-3.1 1-4 2.4-1.7 3-.4 7.4 1.2 9.8.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8 1.5 0 1.9.8 3.2.8 1.3 0 2.2-1.2 3-2.4.9-1.4 1.3-2.7 1.3-2.8 0 0-2.5-1-2.5-3.9zM14 5.5c.7-.8 1.1-1.9 1-3-1 0-2.1.7-2.8 1.5-.6.7-1.2 1.8-1 2.9 1 .1 2.1-.6 2.8-1.4z"/></svg>'


def esc(text):
    return html.escape(text, quote=True)


def page(filename, title, description, body, preview=False, schema=None, noindex=False):
    nav_items = []
    for href, label in NAV:
        current = ' aria-current="page"' if href == filename else ""
        nav_items.append(f'<li><a href="{href}"{current}>{label}</a></li>')
    current = ' aria-current="page"' if filename == "download.html" else ""
    nav_items.append(f'<li><a class="nav-cta" href="download.html"{current}>Download</a></li>')
    nav = "\n".join(nav_items)
    full_title = title if filename == "index.html" else f"{title} | Ironbound"
    url = BASE + ("" if filename == "index.html" else filename)
    share = BASE + "assets/img/share.jpg"
    robots = '<meta name="robots" content="noindex">' if noindex else '<meta name="robots" content="index, follow, max-image-preview:large">'
    # The 404 page is served at any missing path, so it pins its links to the site root.
    canonical = f'<base href="{BASE}">' if noindex else f'<link rel="canonical" href="{url}">'
    ld = ""
    if schema:
        ld = '<script type="application/ld+json">' + json.dumps(schema, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/") + "</script>"
    head = f"""<title>{esc(full_title)}</title>
<meta name="description" content="{esc(description)}">
{robots}
{canonical}
<meta name="author" content="{esc(CREATOR["name"])}">
<meta name="theme-color" content="#14110d">
<meta property="og:site_name" content="Ironbound">
<meta property="og:title" content="{esc(full_title)}">
<meta property="og:description" content="{esc(description)}">
<meta property="og:type" content="website">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{share}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="The Ironbound title over tanks and helicopters fighting beside an oasis">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{esc(full_title)}">
<meta name="twitter:description" content="{esc(description)}">
<meta name="twitter:image" content="{share}">
<link rel="icon" href="assets/favicon.svg" type="image/svg+xml">
<link rel="icon" href="assets/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="assets/apple-touch-icon.png">
<link rel="manifest" href="assets/site.webmanifest">
<link rel="preload" href="assets/fonts/big-shoulders-stencil-display-800.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="assets/fonts/barlow-400.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="assets/site.css">
{ld}"""
    content = f"""<a class="skip" href="#main">Skip to content</a>
<header class="site-header">
  <div class="wrap">
    <a class="brand" href="index.html">{MARK}Ironbound</a>
    <button class="nav-toggle" type="button" aria-expanded="false" aria-controls="site-nav">Menu</button>
    <nav class="site-nav" id="site-nav" aria-label="Main">
      <ul>
{nav}
      </ul>
    </nav>
  </div>
</header>
<div class="ribbon"><p>Early development. The game is playable and changing every day; expect rough edges.</p></div>
<main id="main">
{body}
</main>
<footer class="site-footer">
  <div class="wrap">
    <div class="stack">
      <a class="brand" href="index.html">{MARK}Ironbound</a>
      <p>A free, open source real-time strategy game made with Godot. Vibe coded by <a href="about.html">Destin Jones</a> with Claude, on top of Open RTS by Lampe Games. MIT licensed, so fork it and make it yours. No accounts, no ads, no cookies and no tracking on this site.</p>
    </div>
    <div>
      <h2>Play</h2>
      <ul>
        <li><a href="download.html">Download</a></li>
        <li><a href="play.html">How to play</a></li>
        <li><a href="factions.html">Factions</a></li>
      </ul>
    </div>
    <div>
      <h2>Project</h2>
      <ul>
        <li><a href="changelog.html">Changelog</a></li>
        <li><a href="roadmap.html">Roadmap</a></li>
        <li><a href="open-source.html">Licence, credits and mods</a></li>
        <li><a href="support.html">Crash reports</a></li>
        <li><a href="about.html">About the creator</a></li>
      </ul>
    </div>
    <div>
      <h2>Elsewhere</h2>
      <ul>
        <li><a href="{REPO}">Source code on GitHub</a></li>
        <li><a href="{REPO}/issues">Report a bug</a></li>
        <li><a href="https://github.com/lampe-games/godot-open-rts">Open RTS by Lampe Games</a> (the base)</li>
        <li><a href="https://godotengine.org">Godot Engine</a></li>
        <li><a href="https://destinjones.github.io/open-overwatch/">Open Overwatch</a>, also by Destin</li>
        <li><a href="https://destinjones.github.io/carfinder/">CarFinder</a>, also by Destin</li>
      </ul>
    </div>
  </div>
</footer>
<script src="assets/site.js" defer></script>"""
    if preview:
        return head + "\n" + content + "\n"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
{head}
</head>
<body>
{content}
</body>
</html>
"""


def shot(name, alt, caption=None, big=True):
    img = f'<img src="assets/img/{name}-sm.webp" alt="{esc(alt)}" width="720" height="405" loading="lazy" decoding="async">'
    cap = f"<figcaption>{caption}</figcaption>" if caption else ""
    inner = f'<figure><div class="shot">{img}</div>{cap}</figure>'
    if big:
        return f'<a href="assets/img/{name}.webp">{inner}</a>'
    return inner


def downloads(heading_level="h2"):
    def platform(key, asset, label, icon, note):
        return f"""<a class="platform" data-platform="{key}" data-asset="{asset}" href="{LATEST}{asset}">
          <strong>{icon}{label}</strong>
          <span data-size>{note}</span>
          <span data-yours hidden>Looks like your system</span>
        </a>"""

    return f"""<div class="crate" data-downloads>
      <div class="crate-head">
        <{heading_level}>Download Ironbound</{heading_level}>
        <span class="release-line" data-release-line>Latest release</span>
      </div>
      <div class="platforms">
        {platform("windows", "Ironbound-windows-x86_64.zip", "Windows", ICON_WIN, "64-bit, Windows 10 or later")}
        {platform("linux", "Ironbound-linux-x86_64.zip", "Linux", ICON_LINUX, "x86_64, needs Vulkan")}
        {platform("macos", "Ironbound-macos-universal.zip", "macOS", ICON_MAC, "Intel and Apple Silicon")}
      </div>
      <p class="notice info" data-no-release hidden><strong>The first public build is not out yet.</strong> The buttons open the releases page on GitHub, where it will appear.</p>
      <div class="notice">
        <strong>These builds are not code-signed, so your system will warn you the first time.</strong>
        <span>Windows: click <em>More info</em>, then <em>Run anyway</em>. macOS: right-click the app, choose <em>Open</em>, then <em>Open</em> again (on macOS 15, use <em>Open Anyway</em> in Privacy &amp; Security). Each release lists SHA-256 checksums so you can check the file. <a href="download.html#unsigned">Why unsigned?</a></span>
      </div>
      <p class="small muted">Free, no account, no installer: unzip and play. <a href="download.html#source">Run from source</a> &middot; <a href="{REPO}/releases" data-release-notes>All releases</a></p>
    </div>"""


LIGHTBOX = """<dialog class="lightbox" aria-label="Screenshot">
  <img src="data:," alt="">
  <div class="lightbox-bar"><span class="lightbox-caption small muted"></span><button type="button">Close</button></div>
</dialog>"""

# ---------------------------------------------------------------- home
HOME = f"""
<section class="hero" aria-labelledby="hero-title">
  <div class="hero-media"><img src="assets/img/clouds.webp" srcset="assets/img/clouds-sm.webp 720w, assets/img/clouds.webp 1600w" sizes="100vw" alt="" width="1600" height="900" fetchpriority="high"></div>
  <div class="wrap hero-body">
    <p class="eyebrow">Ironbound &middot; open source RTS &middot; Godot 4.7</p>
    <h1 id="hero-title">You never place a house. <span>The city builds itself.</span></h1>
    <p>Ironbound is a real-time strategy game where you are not the general. You are the one keeping a frontier city alive. Run the mines. Keep the trucks rolling. Lay the rail. Keep the power on. The army is what the city earns.</p>
    <p class="hero-flex">Free. No account. No installer. Unzip and play.</p>
    <div class="actions">
      <a class="btn" href="#download">{ICON_DOWN}<span>Download<small>Windows / Linux / macOS</small></span></a>
      <a class="btn btn-ghost" href="play.html">How to play</a>
    </div>
    <p class="hero-trust">Open source. MIT licensed. <a href="{REPO}/fork">Fork it</a> and build your own game.</p>
  </div>
</section>

<section aria-labelledby="fantasy-title">
  <div class="wrap">
    <div class="section-head">
      <p class="eyebrow">The fantasy</p>
      <h2 id="fantasy-title">Feed the city, and it feeds your war</h2>
      <p>There is no house to place and no district to plan. Every delivery that reaches your command center feeds citizens, and a fed, powered city grows on its own, builds workshops and earns science.</p>
      <p>Science is what moves you up: Industrial at 150, Electric at 450. Each tier opens heavier units, so the army you can field depends on how well you keep the city fed.</p>
    </div>
    <ul class="cargo" aria-label="The four commodities the city eats">
      <li><span class="tag tag-timber">Timber</span></li>
      <li><span class="tag tag-iron">Iron</span></li>
      <li><span class="tag tag-copper">Copper</span></li>
      <li><span class="tag tag-oil">Oil</span></li>
    </ul>
  </div>
</section>

<section aria-labelledby="loop-title">
  <div class="wrap">
    <div class="section-head">
      <p class="eyebrow">The loop</p>
      <h2 id="loop-title">Dig. Deliver. Grow. Deal. Hold the line.</h2>
    </div>
    <div class="loop">
      <div class="loop-step"><span class="mono">01</span><h3>Dig</h3><p>Constructors put lumber mills, mines and oil derricks next to deposits. Deposits run dry, so you keep expanding.</p></div>
      <div class="loop-step"><span class="mono">02</span><h3>Deliver</h3><p>Haulers drive goods home. Goods only count when they arrive. Raiders hunt the trucks.</p></div>
      <div class="loop-step"><span class="mono">03</span><h3>Grow</h3><p>Citizens eat what you deliver. The city builds itself from Frontier to Industrial to Electric.</p></div>
      <div class="loop-step"><span class="mono">04</span><h3>Deal</h3><p>Swap surplus with rival factions by caravan. Trade grows the city faster than digging alone.</p></div>
      <div class="loop-step"><span class="mono">05</span><h3>Hold the line</h3><p>New tiers unlock tanks, artillery, gunships and drones. Guard your routes. Break your rivals.</p></div>
    </div>
  </div>
</section>

<section aria-labelledby="buildup-title">
  <div class="wrap feature-video">
    <figure>
      <div class="shot">
        <video autoplay muted loop playsinline preload="metadata" poster="assets/img/build-up-poster.webp" width="1280" height="720" aria-describedby="buildup-text">
          <source src="assets/video/city-build-up.webm" type="video/webm">
          <source src="assets/video/city-build-up.mp4" type="video/mp4">
        </video>
      </div>
      <figcaption>The starter city going up. Cranes, workers and the command center rise while the clock waits.</figcaption>
    </figure>
    <div class="stack" id="buildup-text">
      <p class="eyebrow">Your first minute</p>
      <h2 id="buildup-title">Claim your ground before the timer runs out</h2>
      <p>Every match opens on the map. Pick your start zone, then watch builders raise your command center. From there the city keeps building on its own, for as long as you keep it supplied.</p>
      <p class="muted">Seven desert maps, from a duel on Twin Basins to four-player Four Oases, plus island maps where amphibious units cross the water.</p>
    </div>
  </div>
</section>

<section aria-labelledby="shots-title">
  <div class="wrap">
    <div class="section-head">
      <p class="eyebrow">Screenshots from the current test build</p>
      <h2 id="shots-title">Muzzle flashes, tracers and rocket trails</h2>
      <p>Click any shot to see it full size.</p>
    </div>
    <div class="gallery">
      {shot("battle", "Tanks, artillery and helicopters trading fire near an oasis", "Tanks, artillery and helicopters trading fire at an oasis")}
      {shot("base-roads-rail", "An AI base linked to its mines by roads and a railway", "A rival that paves roads and lays rail to its mines")}
      {shot("train", "A train running a loop between mines and the city", "Trains that lay their own track")}
      {shot("city-handover", "A command center surrounded by yellow constructors and turrets", "Your city the moment the build-up hands it over")}
      {shot("start-zones", "The start zone picker on the Four Oases map", "Four Oases: pick your start zone before the timer ends")}
      {shot("twin-isles", "Twin Isles: two sandy islands in a deep blue sea", "Twin Isles, where the fight crosses water")}
      {shot("sandstorm", "A sandstorm turning the desert orange", "Sandstorms turn the desert orange")}
      {shot("rain", "Rain falling over an oasis", "Rain rolling over an oasis")}
      {shot("map-editor", "The in-game map editor with lakes, forests and start points", "Paint your own map in the editor")}
    </div>
  </div>
</section>

<section aria-labelledby="features-title">
  <div class="wrap">
    <div class="section-head">
      <p class="eyebrow">What is in the build</p>
      <h2 id="features-title">Six systems. All shipped. All playable today.</h2>
      <p>Each crate below runs in the build you can download right now. The <a href="changelog.html">changelog</a> says when each part landed.</p>
    </div>
    <div class="manifest">
      <div class="manifest-group">
        <h3>Run an economy <span class="mono">CRATE 01</span></h3>
        <ul>
          <li>Dig timber, iron, copper and oil from deposits that run dry</li>
          <li>Put haulers on supply lines; a job board means a truck always finds work</li>
          <li>Wire a power grid with plants and pylons, and live through blackouts</li>
          <li>Pave dirt tracks into roads, and run trains that lay their own rail</li>
          <li>Buffer goods in storage yards and on conveyors; recycle surplus trucks for 75% back</li>
          <li>Set constructors to auto-expand and they grow the economy on their own</li>
        </ul>
      </div>
      <div class="manifest-group">
        <h3>Grow a city and trade <span class="mono">CRATE 02</span></h3>
        <ul>
          <li>Watch the city climb three tiers on nothing but deliveries</li>
          <li>Haggle with trade offers that tell you whether the price is fair; sign agreements or impose embargoes</li>
          <li>Ship goods by caravan, and guard them: caravans can be raided</li>
          <li>Declare war, sign non-aggression pacts or form alliances</li>
          <li>Count on civil defense and militia when the city is attacked</li>
        </ul>
      </div>
      <div class="manifest-group">
        <h3>Command an army <span class="mono">CRATE 03</span></h3>
        <ul>
          <li>Field tanks, heavy tanks, artillery, raiders, scout buggies, missile trucks, helicopters, gunships and drones</li>
          <li>Keep your drones flying: they must land at airports to refuel</li>
          <li>Drag a battle line, then fight, patrol, guard, retreat, set fire stances and queue it all with Shift</li>
          <li>Move big groups that steer around each other instead of jamming</li>
          <li>Hear every unit type answer in its own voice over the sound of the fight</li>
        </ul>
      </div>
      <div class="manifest-group">
        <h3>Face rival AIs <span class="mono">CRATE 04</span></h3>
        <ul>
          <li>Play against rival AIs that hold defence zones and raid your supply lines</li>
          <li>Pick your colour, your start zone and each AI's difficulty</li>
          <li>Choose Guided or Raw rules: tutorial, helper AI and auto-build on or off</li>
          <li>Race a 45-minute match clock to the best score, under a unit cap and city size caps</li>
        </ul>
      </div>
      <div class="manifest-group">
        <h3>Fight across a desert world <span class="mono">CRATE 05</span></h3>
        <ul>
          <li>Fight over oases, forests and canyons on maps with fair start zones</li>
          <li>Cross water to islands with amphibious units</li>
          <li>Play through rain, sandstorms and drifting cloud shadows</li>
          <li>Paint your own maps in the in-game editor</li>
          <li>Listen to an ambient soundscape made from scratch</li>
        </ul>
      </div>
      <div class="manifest-group">
        <h3>Learn it, then mod it <span class="mono">CRATE 06</span></h3>
        <ul>
          <li>Learn the game with a step-by-step tutorial, hints and an F1 manual</li>
          <li>Hand the economy to an opt-in helper AI that never attacks</li>
          <li>Send a crash or freeze report only when you choose to</li>
          <li>Mod units, maps and resources: they are plain JSON files</li>
          <li>Test whole matches from scripts with the play harness</li>
        </ul>
      </div>
    </div>
  </div>
</section>

<section aria-labelledby="fork-title">
  <div class="wrap">
    <div class="section-head">
      <p class="eyebrow">The story</p>
      <h2 id="fork-title">Vibe coded with Claude. Yours to fork.</h2>
      <p>Ironbound is a hobby project by one developer, <a href="about.html">Destin Jones</a>, built with Claude as the building partner, on top of <a href="https://github.com/lampe-games/godot-open-rts">Open RTS by Lampe Games</a> and the <a href="https://godotengine.org">Godot Engine</a>. Thanks to everyone whose open source work made it possible.</p>
      <p>Anyone is welcome to download it, fork it and build anything from it: your own RTS, a mod, a totally different game. The <a href="{REPO}/blob/main/LICENSE">MIT licence</a> lets you use, change and share it freely.</p>
    </div>
    <div class="actions">
      <a class="btn" href="{REPO}/fork">Fork on GitHub</a>
      <a class="btn btn-ghost" href="open-source.html">Licence, credits and mods</a>
    </div>
  </div>
</section>

<section aria-labelledby="honest-title">
  <div class="wrap">
    <div class="section-head">
      <p class="eyebrow">Straight talk</p>
      <h2 id="honest-title">Early development. You are joining a build.</h2>
      <p>Ironbound is playable and changing every day. Expect rough edges. In exchange, you get to watch it move: every change is in the <a href="changelog.html">changelog</a>, and anything that breaks can go straight to the <a href="{REPO}/issues">issue tracker</a>.</p>
      <p>The builds are not code-signed, so your system will warn you the first time you run one. Each release lists SHA-256 checksums so you can check the file. <a href="download.html#unsigned">Why unsigned?</a></p>
      <p>Next on the <a href="roadmap.html">roadmap</a>: two factions with two ways to win. The <strong>Foundry League</strong> builds heavy, tracked and fortified. The <strong>Sandline Syndicate</strong> trades and raids on wheels. <a href="factions.html">Meet the factions</a>.</p>
    </div>
  </div>
</section>

<section id="download" aria-labelledby="close-title">
  <div class="wrap stack-lg">
    <div class="section-head">
      <p class="eyebrow">Free for everyone</p>
      <h2 id="close-title">Free. No account. Unzip and play.</h2>
    </div>
    {downloads("h3")}
    <p class="closer">The city builds itself. <span>You just have to keep it alive.</span></p>
  </div>
</section>
{LIGHTBOX}
"""

# ---------------------------------------------------------------- download
DOWNLOAD = f"""
<div class="wrap page-head">
  <p class="eyebrow">Free for everyone</p>
  <h1>Download</h1>
  <p>Ironbound is free and open source. Pick your system, unzip, and run the game. There is no installer and nothing else to sign up for.</p>
</div>
<section aria-label="Download buttons">
  <div class="wrap">{downloads()}</div>
</section>
<section aria-labelledby="first-run">
  <div class="wrap docs" style="padding-block:0">
    <nav class="toc" aria-label="On this page"><ol>
      <li><a href="#first-run">First run</a></li>
      <li><a href="#unsigned">Unsigned builds</a></li>
      <li><a href="#checksums">Check your download</a></li>
      <li><a href="#requirements">System requirements</a></li>
      <li><a href="#source">Run from source</a></li>
      <li><a href="#browser">Play in the browser?</a></li>
    </ol></nav>
    <article>
      <section>
        <h2 id="first-run">First run</h2>
        <h3>Windows</h3>
        <ol><li>Unzip <code>Ironbound-windows-x86_64.zip</code> anywhere, for example your Desktop.</li><li>Open the folder and double-click <code>Ironbound.exe</code>.</li><li>If a blue box says <em>Windows protected your PC</em>, click <em>More info</em>, then <em>Run anyway</em>.</li></ol>
        <h3>Linux</h3>
        <ol><li>Unzip <code>Ironbound-linux-x86_64.zip</code>.</li><li>Run <code>./Ironbound.x86_64</code> from the folder. If it will not start, run <code>chmod +x Ironbound.x86_64</code> first.</li></ol>
        <h3>macOS</h3>
        <ol><li>Unzip <code>Ironbound-macos-universal.zip</code> and move the app inside (<code>Ironbound.app</code>) to Applications.</li><li>Right-click (or Control-click) the app, choose <em>Open</em>, then <em>Open</em> again.</li><li>On macOS 15 or later, try to open it once, then go to <em>System Settings</em> &rsaquo; <em>Privacy &amp; Security</em> and click <em>Open Anyway</em>.</li></ol>
        <p>In the game, press <kbd>F1</kbd> any time for the manual.</p>
      </section>
      <section>
        <h2 id="unsigned">Why your system warns you</h2>
        <p>Windows and macOS trust apps signed with a paid certificate from Microsoft or Apple. Ironbound is a free hobby project, so its builds are not signed, and both systems show a warning the first time you start it. The game is the same either way.</p>
        <p>Every build is made by GitHub Actions straight from the public source code, so anyone can see exactly what went into it. If you would rather not run an unsigned app, you can <a href="#source">run the game from source</a> with Godot.</p>
      </section>
      <section>
        <h2 id="checksums">Check your download</h2>
        <p>Each release has a <code>SHA256SUMS.txt</code> file. Compare its line for your zip with the hash of the file you downloaded:</p>
        <div class="table-wrap"><table>
          <thead><tr><th>System</th><th>Command</th></tr></thead>
          <tbody>
            <tr><td>Windows (PowerShell)</td><td><code>Get-FileHash Ironbound-windows-x86_64.zip -Algorithm SHA256</code></td></tr>
            <tr><td>Linux</td><td><code>sha256sum -c SHA256SUMS.txt --ignore-missing</code></td></tr>
            <tr><td>macOS</td><td><code>shasum -a 256 Ironbound-macos-universal.zip</code></td></tr>
          </tbody>
        </table></div>
      </section>
      <section>
        <h2 id="requirements">System requirements</h2>
        <div class="table-wrap"><table>
          <thead><tr><th></th><th>Minimum</th></tr></thead>
          <tbody>
            <tr><td>System</td><td>Windows 10 or 11 (64-bit), a 64-bit Linux desktop, or a recent macOS on Intel or Apple Silicon</td></tr>
            <tr><td>Graphics</td><td>A GPU with Vulkan, Direct3D 12 or Metal support (most cards from 2016 on)</td></tr>
            <tr><td>Memory</td><td>4 GB RAM; 8 GB for big four-player maps</td></tr>
            <tr><td>Disk</td><td>About 150 MB unzipped</td></tr>
            <tr><td>Screen</td><td>1280&times;720 or larger, mouse and keyboard</td></tr>
          </tbody>
        </table></div>
      </section>
      <section>
        <h2 id="source">Run from source</h2>
        <ol>
          <li>Install <a href="https://godotengine.org/download">Godot 4.7</a> (the standard build, not .NET).</li>
          <li>Download the source: <code>git clone {REPO}.git</code>, or use <em>Code</em> &rsaquo; <em>Download ZIP</em> on GitHub.</li>
          <li>Open Godot, choose <em>Import</em>, pick the <code>project.godot</code> file, and press <kbd>F5</kbd> to play.</li>
        </ol>
        <p>To make your own release zips, run <code>tools/release/export.sh</code> with Godot's export templates installed.</p>
      </section>
      <section>
        <h2 id="browser">Play in the browser?</h2>
        <p>Not yet. A browser version is possible with Godot's web export, but it needs the simpler web renderer and work on performance first. It is on the <a href="roadmap.html">roadmap</a> for later.</p>
      </section>
    </article>
  </div>
</section>
"""

# ---------------------------------------------------------------- how to play
PLAY_SECTIONS = [
    ("basics", "Basics and controls", """
<p>You run a frontier city. You do not place houses: the city builds itself when goods reach it. Your job is the economy around it (extractors, supply lines, power), trade, and the army that protects it.</p>
<div class="table-wrap"><table>
<thead><tr><th>Do this</th><th>With</th></tr></thead>
<tbody>
<tr><td>Select</td><td>Left-click; drag to select many; double-click selects every unit of that kind on screen</td></tr>
<tr><td>Order (move, attack, build, escort)</td><td>Right-click</td></tr>
<tr><td>Line up selected units</td><td>Hold right-click and drag</td></tr>
<tr><td>Queue orders</td><td>Hold <kbd>Shift</kbd></td></tr>
<tr><td>Move the camera</td><td><kbd>W</kbd> <kbd>A</kbd> <kbd>S</kbd> <kbd>D</kbd>; mouse wheel zooms; <kbd>Q</kbd> <kbd>E</kbd> rotate</td></tr>
<tr><td>Control groups</td><td><kbd>Ctrl</kbd>+number saves, the number recalls</td></tr>
<tr><td>Rotate a blueprint</td><td><kbd>R</kbd>; right-click cancels it</td></tr>
<tr><td>Manual</td><td><kbd>F1</kbd></td></tr>
<tr><td>Quicksave / quickload</td><td><kbd>F5</kbd> / <kbd>F9</kbd>; <kbd>Esc</kbd> opens Save game and Load game</td></tr>
</tbody></table></div>"""),
    ("tutorial", "Your first match", """
<p>Choose <em>Guided</em> in the Play menu and the tutorial walks you through these steps:</p>
<ol>
<li><strong>Select a constructor.</strong> The yellow bulldozers build everything. Left-click one; its build menu opens bottom right.</li>
<li><strong>Lay out an extractor.</strong> Move the mouse over a deposit (woods, iron or copper ore, an oil field). The right extractor appears next to it: click to place it. You pay right away.</li>
<li><strong>Let the constructor build it.</strong> The constructor drives to the site and must stay there until it is done. The label above the site says what it waits for.</li>
<li><strong>Get goods home.</strong> Haulers drive what extractors dig up back to your command center along a supply line. Goods count only once they arrive.</li>
<li><strong>Build power.</strong> Extractors and factories slow down without it. Build a power plant (it burns a little oil); pylons carry the grid to far extractors.</li>
<li><strong>Let constructors expand for you.</strong> Select a constructor and press Auto-expand (<kbd>G</kbd>).</li>
<li><strong>Grow the city to Industrial.</strong> A fed, powered city earns science; at 150 it reaches tier 2.</li>
<li><strong>Trade with a faction.</strong> In the City panel, pick a faction, choose what to give and get, and propose.</li>
<li><strong>Build an army.</strong> Build a vehicle factory and produce tanks. Park some near far extractors: raiders go for haulers first.</li>
<li><strong>Command your army.</strong> Drag a line with the right mouse button, or press <kbd>P</kbd> to patrol and <kbd>B</kbd> to patrol your base.</li>
</ol>"""),
    ("constructors", "Constructors and building", """
<p>Constructors build every structure. Hover a build button to see what it does, its cost and its tier. Placing a building pays for it at once and lays out a site. <strong>The site only grows while a constructor stands next to it.</strong> If you send the constructor elsewhere, the site waits; select a constructor and right-click the site to resume.</p>
<p>Extractors must touch a matching deposit. With a constructor selected, hovering a deposit picks the right extractor for you. To cancel a site, select it and press the X button; you get back the materials not yet on the road.</p>"""),
    ("auto-expand", "Auto-expand", """
<p>Select constructors and press <strong>Auto-expand</strong> (<kbd>G</kbd>). They then work on their own, in this order:</p>
<ol><li>run home when enemies come close,</li><li>finish any site nobody is working on,</li><li>build a power plant when the grid is short,</li><li>build pylons to wire far extractors,</li><li>build an extractor on the best free deposit near a command center,</li><li>pave the longest supply route (from Industrial on).</li></ol>
<p><strong>It spends your bank.</strong> <em>Keep in bank</em> sets how much of each commodity it must leave you. Any order you give an auto constructor pauses it until the order is done.</p>"""),
    ("resources", "Resources", """
<div class="table-wrap"><table>
<thead><tr><th>Commodity</th><th>From</th><th>Used for</th></tr></thead>
<tbody>
<tr><td><span class="tag tag-timber">Timber</span></td><td>Woods, lumber mill</td><td>Buildings and roads; your city eats a little</td></tr>
<tr><td><span class="tag tag-iron">Iron</span></td><td>Iron ore, mine</td><td>The main building and vehicle material</td></tr>
<tr><td><span class="tag tag-copper">Copper</span></td><td>Copper ore, mine</td><td>Power plants, pylons and advanced units</td></tr>
<tr><td><span class="tag tag-oil">Oil</span></td><td>Oil field, oil derrick</td><td>Fuel for power plants and haulers</td></tr>
</tbody></table></div>
<p>Deposits run dry over time; their look shows how much is left. Part of every delivery goes to the city warehouse to feed citizens, the rest to your bank.</p>"""),
    ("supply-lines", "Supply lines, roads and power", """
<p>Extractors fill a small local store. <strong>Haulers</strong> drive the goods to the closest command center along a supply line drawn on the ground. A full extractor stops. Sites inside the <strong>yard</strong> (about 9 m around a command center) get materials straight away; sites further out wait for a hauler.</p>
<p>Every route starts as a dirt track. Upgrade it to a paved road (&times;1.4 hauler speed, needs Industrial) or a railway (&times;2, needs Electric) with the extractor's Road button.</p>
<p>The top bar shows power supply and demand in MW. Without enough power, extraction drops, factories slow down and the city earns less science. Power plants burn oil; pylons extend the grid.</p>"""),
    ("city", "City and tiers", """
<p>The city panel (top right) shows population, needs, the warehouse and civil defense. Citizens eat timber, iron, copper and oil; a fed, powered city grows, builds workshops (faster production for you) and earns <strong>science</strong>.</p>
<div class="table-wrap"><table>
<thead><tr><th>Tier</th><th>Science</th><th>Largest city</th></tr></thead>
<tbody>
<tr><td>1 Frontier</td><td>Start</td><td>60 citizens</td></tr>
<tr><td>2 Industrial</td><td>150</td><td>100 citizens</td></tr>
<tr><td>3 Electric</td><td>450</td><td>130 citizens</td></tr>
</tbody></table></div>"""),
    ("trade", "Trade and diplomacy", """
<p>In the city panel, pick a faction, choose what you give and what you get, and propose. Each faction has its own prices; the panel shows both, the fair price, and a verdict judged at your prices (good, fair or bad). A deal is bad when it leaves you with under 10 of something.</p>
<p>Accepted goods travel by caravan, which can be raided. Trade agreements repeat a deal; an embargo stops trade. You can also declare war, sign non-aggression pacts and form alliances.</p>"""),
    ("orders", "Combat and unit orders", """
<div class="table-wrap"><table>
<thead><tr><th>Order</th><th>Key</th><th>What it does</th></tr></thead>
<tbody>
<tr><td>Fight</td><td><kbd>F</kbd></td><td>Go to a spot and fight whatever is met on the way</td></tr>
<tr><td>Patrol</td><td><kbd>P</kbd></td><td>Loop between points; Shift-click adds more</td></tr>
<tr><td>Patrol base</td><td><kbd>B</kbd></td><td>Loop around your city and past every extractor</td></tr>
<tr><td>Guard</td><td><kbd>V</kbd></td><td>Stay with a unit or building and defend it</td></tr>
<tr><td>Retreat</td><td><kbd>Z</kbd></td><td>Back to the nearest command center without stopping</td></tr>
<tr><td>Stop</td><td><kbd>X</kbd></td><td>Drop all orders</td></tr>
<tr><td>Fire stance</td><td><kbd>L</kbd></td><td>Fire at will, return fire or hold fire</td></tr>
<tr><td>Hold position</td><td><kbd>K</kbd></td><td>Shoot what is in range but never chase</td></tr>
</tbody></table></div>
<p>AI factions raid supply lines and far extractors first. Keep units near long routes. Fixed-wing drones must land at an <strong>airport</strong> to refuel and crash when they run dry.</p>
<p>Keys can be changed in <code>controls.cfg</code> in the game's user folder.</p>"""),
    ("helper", "The helper", """
<p>The helper is an assistant you switch on at the top left (or press <kbd>H</kbd>). It puts idle constructors on auto-expand, builds defenders up to the army size you set, scouts with a buggy and keeps constructors away from enemies. <strong>It never attacks.</strong> Your own orders always win, and switching it off hands everything back.</p>"""),
    ("limits", "Limits and match end", """
<p><strong>Unit cap.</strong> Every unit takes slots: constructors, haulers, scouts, raiders and drones 1; tanks and missile trucks 2; artillery and helicopters 3; heavy tanks and gunships 4; battle tanks 5. Your cap is 150, within a match-wide cap of 400.</p>
<p><strong>Match end.</strong> The clock counts down 45 minutes, or 5 minutes after the last deposit on the map runs dry. The best score wins: citizens + unit slots in use + 5 per finished building + science&nbsp;/&nbsp;10. Destroying every enemy wins at once.</p>"""),
]


def docs_page(sections):
    toc = "\n".join(f'<li><a href="#{sid}">{title}</a></li>' for sid, title, _ in sections)
    body = "\n".join(f'<section aria-labelledby="{sid}"><h2 id="{sid}">{title}</h2>{content}</section>' for sid, title, content in sections)
    return f'<div class="wrap docs"><nav class="toc" aria-label="On this page"><ol>{toc}</ol></nav><article>{body}</article></div>'


PLAY = f"""
<div class="wrap page-head">
  <p class="eyebrow">Manual</p>
  <h1>How to play</h1>
  <p>The same guide you get in the game with <kbd>F1</kbd>, plus the tutorial steps. Matches take up to 45 minutes against one to three AI rivals.</p>
</div>
<div class="wrap" style="padding-top:2rem">
  <div class="gallery">
    {shot("auto-expand", "The auto-expand panel listing constructors and what they are doing", "Auto-expand panel")}
    {shot("trade", "A trade offer with a good deal verdict", "Trade offers come with a verdict")}
    {shot("manual", "The in-game manual open on the Basics page", "The F1 manual in the game")}
  </div>
</div>
{docs_page(PLAY_SECTIONS)}
{LIGHTBOX}
"""

# ---------------------------------------------------------------- factions
FACTIONS = f"""
<div class="wrap page-head">
  <p class="eyebrow">Designed, being built next</p>
  <h1>Factions</h1>
  <p>Two factions share the same economy, tiers and 17 of 24 units, and differ in how they fight and earn. Today every player uses the shared roster; the faction split is the next big step on the <a href="roadmap.html">roadmap</a>.</p>
</div>
<section aria-label="The two factions">
  <div class="wrap factions">
    <article class="faction faction-foundry">
      <p class="eyebrow">Industry &middot; tracks &middot; fortifications</p>
      <h2>Foundry League</h2>
      <p>Olive-drab heavy industry. The League out-produces everyone, digs in behind bunkers and flak, and rolls forward with armour nobody else can field.</p>
      <dl>
        <dt>Colours</dt><dd>Olive and steel</dd>
        <dt>Moves on</dt><dd>Tracks</dd>
        <dt>Own units</dt><dd>Tank, Heavy Tank, Artillery, Battle Tank</dd>
        <dt>Own defences</dt><dd>Bunker, Flak Tower</dd>
        <dt>Own building</dt><dd>Foundry: factories in its power grid work 20% faster</dd>
        <dt>Plays like</dt><dd>Slow to start, hard to stop. Holds ground and wins long matches.</dd>
      </dl>
    </article>
    <article class="faction faction-sandline">
      <p class="eyebrow">Trade &middot; wheels &middot; raids</p>
      <h2>Sandline Syndicate</h2>
      <p>Rust-red caravan traders. The Syndicate makes its money on deals, guards its caravans with guns, and sends fast wheeled raiders after everyone else's trucks.</p>
      <dl>
        <dt>Colours</dt><dd>Rust red and sand</dd>
        <dt>Moves on</dt><dd>Wheels</dd>
        <dt>Own units</dt><dd>Raider, Scout Buggy, Rocket Technical, Gunship</dd>
        <dt>Own defences</dt><dd>Gun Nest, SAM Site</dd>
        <dt>Own building</dt><dd>Trading Post: a second caravan depot</dd>
        <dt>Plays like</dt><dd>Trade earns 1.5 times as much and caravans are armed. Fast, mobile, punishing on supply lines.</dd>
      </dl>
    </article>
  </div>
</section>
<section aria-labelledby="shared">
  <div class="wrap stack">
    <h2 id="shared">Shared by both</h2>
    <p>Every economy building, the constructor, hauler, caravan, drone, militia, missile truck and helicopter, and the same three city tiers. That keeps the economy easy to learn whichever side you pick.</p>
    <div class="gallery">
      {shot("unit-models", "Rows of new unit models on a desert map", "The new unit models in the game")}
    </div>
  </div>
</section>
{LIGHTBOX}
"""

# ---------------------------------------------------------------- changelog
CHANGES = [
    ("Unreleased", "Test build, 5 October 2026", [
        "Save and load: Save game and Load game in the pause menu, F5 quicksave, F9 quickload, an autosave every 5 minutes and Continue on the main menu",
        "Two factions: the Foundry League (tracked armour, bunkers, the Foundry) and the Sandline Syndicate (fast wheeled raiders, gunships, armed trade caravans)",
        "Faction voices: Syndicate crews, hired guns and pilots sound like the Syndicate; new boat and train crews",
        "Ironbound title, splash and icon; a tabbed Options screen and a full pause menu",
        "New HUD with a resource strip and folding panels; the Play menu fits 720p screens",
        "Original soundtrack that follows the fighting",
        "End screen with stats, a score chart and Play again",
        "Fixed: fog of war rendering black on some graphics cards",
        "Balance: the Foundry League no longer runs dry on iron. Bunker and Tank cost less iron, Tanks are a little faster and tougher, Heavy Tanks tougher, and Foundry factories work 10% faster (AI vs AI: 3 wins each, was 1 to 5)",
    ]),
    ("Test builds", "4 October 2026", [
        "Units steer around each other instead of getting stuck in crowds",
        "New unit models made in Blender, with a New / Classic switch in Options",
        "Play harness: one tool to play and test matches from scripts",
        "Match rules in the Play menu: Raw or Guided",
        "Delivery rework: a job board for trucks, storage yards, track-laying trains, recycling surplus trucks",
        "Water, amphibious units and the Twin Isles island map",
        "Unit orders: line drag, patrol, fight, guard, stances and Shift queue",
        "AI armies hold defence zones instead of bunching up at home",
        "Starter city build-up animation with cranes and workers",
        "Start zone picker before each match, fairer maps, two large maps",
        "A voice for every unit type, machine sounds for drones and buildings",
        "Pick your colour and each AI's difficulty",
        "Unit cap, city size caps per tier, and a match clock with a score",
        "Opt-in helper AI that runs the economy and never attacks",
        "Crash and freeze reports, sent only if you choose",
        "Fixed: mid-match freeze on crowded maps, frame rate collapse in long matches, iron mines that could not be placed, rain lag",
        "Visible weapon fire: muzzle flashes, tracers, impacts and rocket trails; war sounds",
        "Constructor auto-expand, site status labels, tutorial and the F1 manual",
        "Diplomacy: war, non-aggression pacts and alliances",
        "Airports for drones, auto-picked extractors, trade advice",
        "Every unit and building remodelled; team colours fixed",
    ]),
    ("Ironbound begins", "3 October 2026", [
        "Desert world: maps, weather, clouds, map editor and soundscape",
        "Economy: supply lines, power grid, an automatic city and moddable JSON data",
        "Milestone 1: a self-building city, trade with a rival, heavy tank tech",
        "Forked from Open RTS by Lampe Games and moved to Godot 4.7",
    ]),
    ("Open RTS 0.9.0", "Lampe Games, the base project", [
        "Custom maps, two new maps and a match setup page",
        "Loading page translations",
    ]),
    ("Open RTS 0.8.0 to 0.8.1", "Lampe Games", [
        "Main menu, match loading page, tooltips and FPS monitor",
        "Isometric camera, fog of war, terrain and air navigation, units and structures, minimap, human and AI players",
    ]),
]


def timeline(entries):
    items = []
    for name, when, lines in entries:
        lis = "".join(f"<li>{esc(x)}</li>" for x in lines)
        items.append(f'<li><h2>{esc(name)}</h2><span class="mono">{esc(when)}</span><ul>{lis}</ul></li>')
    return '<ol class="timeline">' + "".join(items) + "</ol>"


CHANGELOG = f"""
<div class="wrap page-head">
  <p class="eyebrow">What changed</p>
  <h1>Changelog</h1>
  <p>Newest first. Releases will get version numbers once the first public build is out; until then changes are grouped by when they reached the test build. The full history is on <a href="{REPO}/commits">GitHub</a>.</p>
</div>
<section aria-label="Changes"><div class="wrap">{timeline(CHANGES)}</div></section>
"""

# ---------------------------------------------------------------- roadmap
def road(status, cls, title, items):
    lis = "".join(f"<li>{x}</li>" for x in items)
    return f'<div class="card"><span class="tag {cls}">{status}</span><h3>{title}</h3><ul class="small">{lis}</ul></div>'


ROADMAP = f"""
<div class="wrap page-head">
  <p class="eyebrow">Where it is going</p>
  <h1>Roadmap</h1>
  <p>The plan, not a promise. Order can change after playtests.</p>
</div>
<section aria-label="Roadmap">
  <div class="wrap cards">
    {road("Now", "tag-built", "First public build", ["Every test build feature in one release", "Save and load, autosave", "Windows, Linux and macOS downloads", "This website"])}
    {road("Built", "tag-built", "Two factions", ["Each unit can belong to a faction", "Foundry League and Sandline Syndicate rosters", "AI that plays each faction by role", "City twists: Foundry production, Syndicate trade", "Faction voices"])}
    {road("Next", "tag-planned", "Polish", ["Nine new models: Battle Tank, Rocket Technical, Bunker, Flak Tower and more", "Slimmer, faster unit models", "Faction balance from AI ladders", "More maps, including island maps for four players"])}
    {road("Later", "tag-later", "Play in the browser", ["A web build with Godot's browser renderer", "Online matches hosted by one player, joined with a lobby code", "Free hosting, no game servers to pay for"])}
  </div>
</section>
"""

# ---------------------------------------------------------------- open source
OPEN = f"""
<div class="wrap page-head">
  <p class="eyebrow">Free to play, read, change and share</p>
  <h1>Open source</h1>
  <p>All the code and all the art in Ironbound are open. Fork it, mod it, learn from it, or help build it.</p>
  <p>Please take it and build anything you like. Ironbound is vibe coded with Claude, and it only exists because of Open RTS, Godot and many other open source projects, so passing it on feels right.</p>
  <div class="actions"><a class="btn" href="{REPO}/fork">Fork on GitHub</a><a class="btn btn-ghost" href="{REPO}/blob/main/LICENSE">Read the MIT licence</a></div>
</div>
{docs_page([
    ("licence", "Licence", f'''<p>Ironbound is released under the <strong>MIT licence</strong>, the same licence as <a href="https://github.com/lampe-games/godot-open-rts">Open RTS by Lampe Games</a>, the project it grew from. You may use, copy, change and sell it, as long as the licence and copyright notice stay with it. Read the <a href="{REPO}/blob/main/LICENSE">full licence</a>.</p>'''),
    ("credits", "Asset credits", '''<p>Assets made for Ironbound are original and generated by scripts in the repository, so they are MIT licensed too and anyone can rebuild them. No assets from non-commercial sources are used.</p>
<div class="table-wrap"><table><thead><tr><th>Assets</th><th>Made with</th></tr></thead><tbody>
<tr><td>Desert props, deposits, units, buildings</td><td>Modelled by script in Blender</td></tr>
<tr><td>Starter city build-up animation</td><td>Modelled and animated by script in Blender</td></tr>
<tr><td>Clouds texture</td><td>Generated noise</td></tr>
<tr><td>Ambience, war sounds, machine sounds, construction sounds</td><td>Synthesized from noise and sine waves</td></tr>
<tr><td>Unit and advisor voices</td><td>Kokoro-82M voice model (Apache 2.0, by hexgrad) run locally with kokoro-onnx (MIT)</td></tr>
<tr><td>Terrain, water, cloud and road shaders</td><td>Written for this project</td></tr>
<tr><td>3D Space Kit</td><td><a href="https://www.kenney.nl/assets/space-kit">Kenney.nl</a>, CC0</td></tr>
<tr><td>Godot and Lampe Games logos</td><td>See LOGO_LICENSES.md</td></tr>
<tr><td>Website fonts: Barlow, Big Shoulders Stencil, IBM Plex Mono</td><td>SIL Open Font License 1.1, licence files in site/assets/fonts</td></tr>
</tbody></table></div>
<p>The full list with rebuild commands is in <code>ASSET_CREDITS.md</code>.</p>'''),
    ("mods", "Mods", '''<p>Units, maps, resources, AI play styles, difficulties and voices are plain JSON files in <code>data/</code>. A mod adds or patches them from <code>mods/&lt;name&gt;/data/</code>, no code needed.</p>
<div class="cards">
<div class="card"><h3>Add a unit in 10 minutes</h3><p>Copy the scout buggy file, change its numbers and model, and the game builds the rest.</p></div>
<div class="card"><h3>Make a map</h3><p>Paint lakes, forests, deposits and start points in the in-game map editor, or hand-build a Godot scene.</p></div>
<div class="card"><h3>Add a resource</h3><p>A new commodity needs one entry in resources.json and one deposit scene.</p></div>
<div class="card"><h3>New voices</h3><p>Voice sets are JSON lists of short .ogg clips, one set per unit type.</p></div>
</div>
<p>Check your changes with the validator: <code>godot --headless --path . -s res://tools/validate_data.gd</code>. The guides are in <code>docs/modding/</code>.</p>'''),
    ("contributing", "Contributing", f'''<ol>
<li><strong>Bugs:</strong> open an <a href="{REPO}/issues">issue</a> with what happened and how to make it happen again. A crash report from the game is even better.</li>
<li><strong>Fixes:</strong> open a pull request. Run <code>gdformat --check source/</code> and <code>gdlint source/</code> first; the checks run on every pull request.</li>
<li><strong>Features:</strong> open an issue first so we can agree on the idea before you build it.</li>
<li><strong>Testing:</strong> <code>./play.sh</code> (or <code>play</code> on Windows) plays every test scenario and writes a report. See <code>docs/testing/play-harness.md</code>.</li>
</ol>
<p>Be kind in issues and reviews. Everyone here is volunteering their time.</p>'''),
    ("built-with", "Built with", '''<ul><li><a href="https://godotengine.org">Godot Engine</a> 4.7 (MIT)</li><li><a href="https://github.com/lampe-games/godot-open-rts">Open RTS</a> by Lampe Games (MIT)</li><li><a href="https://www.blender.org">Blender</a> for models, driven by Python scripts</li></ul>'''),
])}
"""

# ---------------------------------------------------------------- support / crash reports
SUPPORT_DOCS = docs_page([
    ("how", "How it works", '''<ol>
<li>The game writes a report when it crashes, freezes for 20 seconds or more, or logs 100 errors within 10 seconds.</li>
<li>The next time you start it, the main menu asks <em>Send last crash report?</em> and shows you the exact text.</li>
<li>Press <strong>Send</strong> to open a prefilled bug report on GitHub, then press <em>Submit</em> there. Press <strong>Don't send</strong> and the report stays on your computer.</li>
</ol>'''),
    ("contents", "What a report contains", '''<p>Game version and build, Godot version, the map, players and AI styles, match time, weather, unit count, frame rate and memory, your OS, CPU and GPU, the most frequent errors with their call stacks, the crash backtrace and the last log lines.</p>
<p><strong>It contains no names, accounts or addresses.</strong> Folder paths are shortened so your user name does not appear.</p>'''),
    ("where", "Where reports are kept", '''<div class="table-wrap"><table><thead><tr><th>System</th><th>Folder</th></tr></thead><tbody>
<tr><td>Windows</td><td><code>%APPDATA%\\Ironbound\\crash_reports</code></td></tr>
<tr><td>Linux</td><td><code>~/.local/share/Ironbound/crash_reports</code></td></tr>
<tr><td>macOS</td><td><code>~/Library/Application Support/Ironbound/crash_reports</code></td></tr>
</tbody></table></div>'''),
    ("manual", "Report a problem by hand", f'''<p>For bugs that are not crashes, <a href="{REPO}/issues/new">open an issue</a>: say what you did, what you expected and what happened, and attach a screenshot if you can. A GitHub account is needed.</p>'''),
])

SUPPORT = f"""
<div class="wrap page-head">
  <p class="eyebrow">When something breaks</p>
  <h1>Crash reports</h1>
  <p>If the game crashes or freezes, it saves a report on your computer. Nothing leaves your computer unless you say so.</p>
</div>
<div class="wrap" style="padding-top:2rem"><div class="gallery">{shot("crash-prompt", "The main menu asking whether to send the last crash report", "The prompt on the next start")}</div></div>
{SUPPORT_DOCS}
{LIGHTBOX}
"""

# ---------------------------------------------------------------- community
COMMUNITY = f"""
<div class="wrap page-head">
  <p class="eyebrow">Get involved</p>
  <h1>Community</h1>
  <p>Ironbound is built in the open. Everything happens on GitHub for now.</p>
</div>
<section aria-label="Links">
  <div class="wrap cards">
    <div class="card"><h3>Source code</h3><p>Read the code, or <a href="{REPO}/fork">fork it</a> and build anything you like: your own RTS, a mod, or something new.</p><a class="more" href="{REPO}">github.com/destinjones/godot-open-rts</a></div>
    <div class="card"><h3>Issues</h3><p>Report bugs, suggest features and follow what is being worked on.</p><a class="more" href="{REPO}/issues">Open issues</a></div>
    <div class="card"><h3>Pull requests</h3><p>See changes in progress and send your own.</p><a class="more" href="{REPO}/pulls">Pull requests</a></div>
    <div class="card"><h3>Releases</h3><p>Every build with its notes and checksums.</p><a class="more" href="{REPO}/releases">All releases</a></div>
    <div class="card"><h3>Open RTS</h3><p>The project Ironbound grew from, by Lampe Games.</p><a class="more" href="https://github.com/lampe-games/godot-open-rts">lampe-games/godot-open-rts</a></div>
    <div class="card"><h3>Godot Engine</h3><p>The free, open source engine the game runs on.</p><a class="more" href="https://godotengine.org">godotengine.org</a></div>
  </div>
</section>
"""

NOT_FOUND = f"""
<div class="wrap page-head">
  <p class="eyebrow">Error 404</p>
  <h1>Lost in the sandstorm</h1>
  <p>That page does not exist. Head back to the <a href="index.html">home page</a> or <a href="download.html">download the game</a>.</p>
</div>
<section><div class="wrap"><div class="shot"><img src="assets/img/sandstorm.webp" alt="A sandstorm over the desert" width="1600" height="900"></div></div></section>
"""

# ---------------------------------------------------------------- about the creator
def about_body():
    c = CREATOR
    bio = "".join(f"<p>{esc(x)}</p>" for x in c["bio"])
    principles = "".join(f'<div class="card"><h3>{esc(t)}</h3><p>{esc(d)}</p></div>' for t, d in c["principles"])
    links = " &middot; ".join(f'<a href="{esc(u)}" rel="me">{esc(n)}</a>' for n, u in c["links"])
    others = ""
    if c.get("other_projects"):
        items = "".join(f'<li><a href="{esc(u)}">{esc(n)}</a>: {esc(d)}</li>' for n, u, d in c["other_projects"])
        others = f'<h2>Also by me</h2><ul>{items}</ul>'
    return f"""
<div class="wrap page-head">
  <p class="eyebrow">About the creator</p>
  <h1>{esc(c["name"])}</h1>
  <p>{esc(c["headline"])}</p>
</div>
<section aria-label="Biography">
  <div class="wrap creator">
    <picture class="creator-photo">
      <source srcset="assets/img/creator-sm.webp 320w, assets/img/creator.webp 640w" sizes="(max-width: 52rem) 60vw, 20rem" type="image/webp">
      <img src="assets/img/creator.jpg" alt="{esc(c["photo_alt"])}" width="640" height="640">
    </picture>
    <div class="prose">
      <p class="eyebrow">{esc(c["role"])}</p>
      {bio}
      <p class="small muted">Find me on {links}.</p>
      {others}
    </div>
  </div>
</section>
<section aria-labelledby="how-built">
  <div class="wrap">
    <div class="section-head"><p class="eyebrow">The method</p><h2 id="how-built">How Ironbound is built</h2></div>
    <div class="cards">{principles}</div>
  </div>
</section>
"""


PERSON = {
    "@type": "Person",
    "@id": BASE + "about.html#person",
    "name": CREATOR["name"],
    "url": BASE + "about.html",
    "image": BASE + "assets/img/creator.jpg",
    "jobTitle": CREATOR["role"],
    "sameAs": CREATOR.get("same_as") or [u for _, u in CREATOR["links"]],
}
WEBSITE = {"@type": "WebSite", "@id": BASE + "#website", "url": BASE, "name": "Ironbound", "inLanguage": "en", "publisher": {"@id": BASE + "about.html#person"}}
GAME = {
    "@type": ["VideoGame", "SoftwareApplication"],
    "@id": BASE + "#game",
    "name": "Ironbound",
    "url": BASE,
    "description": "A free, open source real-time strategy game made with Godot, where your city builds itself and you run the economy, trade and the army.",
    "image": BASE + "assets/img/share.jpg",
    "screenshot": [BASE + "assets/img/" + n + ".webp" for n in ("battle", "city-handover", "start-zones", "twin-isles")],
    "genre": ["Real-time strategy", "City builder", "Strategy"],
    "gamePlatform": ["Windows", "Linux", "macOS"],
    "operatingSystem": "Windows 10, Linux, macOS",
    "applicationCategory": "GameApplication",
    "playMode": "SinglePlayer",
    "gameEngine": "Godot Engine 4.7",
    "license": "https://opensource.org/licenses/MIT",
    "isAccessibleForFree": True,
    "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    "downloadUrl": BASE + "download.html",
    "author": {"@id": BASE + "about.html#person"},
    "creator": {"@id": BASE + "about.html#person"},
    "isBasedOn": "https://github.com/lampe-games/godot-open-rts",
    "trailer": {
        "@type": "VideoObject",
        "name": "Ironbound starter city build-up",
        "description": "Cranes and workers raise the command center at the start of a match.",
        "thumbnailUrl": BASE + "assets/img/build-up-poster.webp",
        "contentUrl": BASE + "assets/video/city-build-up.mp4",
        "uploadDate": "2026-10-04",
    },
}
SOURCE = {"@type": "SoftwareSourceCode", "name": "Ironbound source code", "codeRepository": REPO, "programmingLanguage": "GDScript", "license": "https://opensource.org/licenses/MIT", "author": {"@id": BASE + "about.html#person"}}


def graph(*nodes):
    return {"@context": "https://schema.org", "@graph": list(nodes)}


def crumbs(filename, title):
    return {"@type": "BreadcrumbList", "itemListElement": [
        {"@type": "ListItem", "position": 1, "name": "Ironbound", "item": BASE},
        {"@type": "ListItem", "position": 2, "name": title, "item": BASE + filename},
    ]}


PAGES = [
    ("index.html", "Ironbound: free open source RTS where your city builds itself", "Ironbound is a free, open source real-time strategy game made with Godot. Your city builds itself; you run the mines, supply lines, trade and army. Download for Windows, Linux and macOS.", HOME),
    ("download.html", "Download", "Download Ironbound free for Windows, Linux or macOS. Open source, no account, no installer. Checksums and first-run help for unsigned builds.", DOWNLOAD),
    ("play.html", "How to play", "The Ironbound manual: controls, constructors, supply lines, power, city tiers, trade, diplomacy and unit orders for this Godot RTS.", PLAY),
    ("factions.html", "Factions", "Meet the Foundry League and the Sandline Syndicate, the two factions of Ironbound: heavy industry against caravan traders.", FACTIONS),
    ("changelog.html", "Changelog", "Every change to Ironbound, newest first, from the first fork of Open RTS to the current test build.", CHANGELOG),
    ("roadmap.html", "Roadmap", "What comes next for Ironbound: the first public build, two factions, polish, and play in the browser.", ROADMAP),
    ("open-source.html", "Open source, credits and mods", "Ironbound is MIT licensed. Asset credits, how to mod units, maps and resources, and how to contribute to this open source Godot RTS.", OPEN),
    ("support.html", "Crash reports", "How Ironbound's opt-in crash reports work, what they contain, and where they are stored on your computer.", SUPPORT),
    ("community.html", "Community", "Where to find the Ironbound project: source code, issues, pull requests and releases on GitHub.", COMMUNITY),
    ("about.html", "About the creator, Destin Jones", "Destin Jones created Ironbound, an open source RTS built in public by vibe coding with Claude as the building partner.", about_body()),
    ("404.html", "Page not found", "This page does not exist.", NOT_FOUND),
]

for filename, title, description, body in PAGES:
    if filename == "index.html":
        schema = graph(WEBSITE, GAME, PERSON, SOURCE)
    elif filename == "about.html":
        schema = graph(WEBSITE, dict(PERSON, description=" ".join(CREATOR["bio"][:1])), {"@type": "ProfilePage", "url": BASE + filename, "mainEntity": {"@id": BASE + "about.html#person"}}, crumbs(filename, "About the creator"))
    elif filename == "404.html":
        schema = None
    else:
        schema = graph(crumbs(filename, title))
    noindex = filename == "404.html"
    (OUT / filename).write_text(page(filename, title, description, body, schema=schema, noindex=noindex))
    if len(sys.argv) > 2 and filename == "index.html":
        pathlib.Path(sys.argv[2]).write_text(page(filename, title, description, body, preview=True, schema=schema))

urls = "".join(
    f"  <url><loc>{BASE + ('' if f == 'index.html' else f)}</loc><changefreq>weekly</changefreq><priority>{'1.0' if f == 'index.html' else '0.7'}</priority></url>\n"
    for f, *_ in PAGES if f != "404.html"
)
(OUT / "sitemap.xml").write_text(f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{urls}</urlset>\n')
(OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}sitemap.xml\n")
(OUT / "assets" / "site.webmanifest").write_text(json.dumps({
    "name": "Ironbound", "short_name": "Ironbound", "start_url": "../index.html", "display": "browser",
    "background_color": "#14110d", "theme_color": "#14110d",
    "icons": [{"src": "icon-192.png", "sizes": "192x192", "type": "image/png"}, {"src": "icon-512.png", "sizes": "512x512", "type": "image/png"}],
}, indent=2) + "\n")
print("wrote", len(PAGES), "pages, sitemap.xml, robots.txt")
