---
title: "Setting Up the Search Backend for career-ops with Pi"
date: 2026-10-09
draft: false
tags:
    - ai
    - career-ops
    - pi
    - web-search
    - agentic-coding
    - job-search
    - wigolo
    - duckduckgo
    - jina
    - tavily
    - serper
    - setup
categories:
    - tech
    - tutorial
summary: "Step-by-step guide to fixing and setting up the search backend tools for career-ops when running inside Pi. Starts from the missing piece most guides skip: the unipi extension (@pi-unipi/web-api) that actually provides Pi's web tools, and how to install it with pi install. Then covers how its provider-based web_search ranks backends, diagnosing which providers are down or unconfigured, setting up wigolo as a free local search daemon, working around an ISP-level DNS hijack that silently breaks DuckDuckGo, wiring free Jina and Tavily API keys (including two upstream quirks that make them fail silently), and enabling the career-ops Tavily and Serper plugins through .env and plugins.mjs. Ends with a verification matrix. All on free tiers."
description: "Guide to setting up career-ops' search backends in Pi: wigolo local search, DuckDuckGo behind an ISP DNS hijack, free Jina and Tavily keys, and the career-ops Tavily/Serper plugins. Includes the quirks that make each one fail silently and how to verify everything actually works."
---

I set up [career-ops](https://github.com/santifer/career-ops) recently to run my job search pipeline, and everything core worked out of the box: the tracker, the evaluation reports, the CV generation. But the moment I asked Pi to actually _search the web_ (research a company, verify a job posting is real, dig into a salary range), everything fell over. Every single search backend was either down or not set up. DuckDuckGo failed with a bare `fetch failed`. The local provider complained about a daemon nobody had ever started. Jina returned `401 Unauthorized`. Tavily didn't even show up in the list of available providers.

Turns out each of those four failures had a completely different root cause, and three of them were free to fix with no infrastructure at all. This post walks through how I diagnosed and fixed all of them, plus the two career-ops search plugins, so you end up with a working search stack where every component is either fully keyless or on a free tier.

> There are paid tiers involved here (Tavily, Serper, Jina all sell plans), but everything in this post runs on their free offerings or on local software. I'll flag the paid path only where it exists.

---

## But first, what are we even talking about?

Since this post assumes you already use career-ops, I'll keep this short. Two tools matter for the rest of the article.

**career-ops** is an AI-powered job search pipeline that runs inside your coding CLI. It scans company career boards for openings, evaluates job descriptions against your profile, generates tailored CVs, and tracks everything in a markdown tracker. It's CLI-agnostic: the same pipeline runs in Claude Code, Codex, OpenCode, and Pi. Its scanning core (the part that hits Greenhouse, Lever, Ashby, and Workday APIs) is deliberately zero-token and doesn't need any search backend at all. The search backends this post is about power the _research_ side: verifying a posting is legit, company deep-dives, and general web lookups the agent does on your behalf.

**Pi** is the coding agent CLI I run career-ops in. Like the others, it can read your project, run commands, and call tools. Out of the box it's deliberately minimal though: its core tool set is files, shell, and editing. It has no built-in web search, which is exactly what the next term solves.

**unipi** is a third-party extension package for Pi (by Neuron Mr White, published on npm as `@pi-unipi/web-api`) that adds the web tooling: `web_search`, `multi_web_content_read`, and `web_llm_summarize`. Everything in this post lives inside it. It's provider-based: instead of one hardcoded search engine, it keeps a ranked list of interchangeable backends, and every call can name which backend to use or fall through the list automatically. It also owns the `~/.unipi/config/web-api/` config directory and the `/unipi:web-settings` command. If you open Pi and there's no `web_search` tool at all, this is the piece you're missing, and the first prerequisite below handles it.

A few more terms, because this setup is dense with them:

**Search backend / provider** is one specific source of web search (or page fetching). Pi's web API ships several, mixing local software and hosted APIs.

**Source rank** is the number you pass to `web_search` to pick a backend explicitly. Without it, Pi walks the list cheapest-first and falls through on failure, which is why a single broken backend usually just makes searches slower instead of dead. Explicit ranks: **1** wigolo, **2** DuckDuckGo, **3** Jina Search, **4** SerpAPI, **5** Tavily, **6** Perplexity.

**wigolo** is a local-first web intelligence tool. It runs a daemon on your machine that searches multiple engines, caches pages, and can even rerank results with a small local ML model. No API key, no account, no rate limits (beyond your own bandwidth). It's Pi's rank-1 provider.

**Jina AI Search** is a hosted search API with a free tier. You send a query, it returns structured results. Access needs an API key these days.

**Tavily** is a search API built specifically for AI agents (results come back as clean content chunks instead of snippets). Also free-tier with a key.

**Serper** is a Google Search API (results via Google's programmable search backbone), free tier, also keyed. In career-ops it ships as a plugin rather than a built-in Pi provider.

**API key** is a unique string that authenticates your requests with a hosted service. Each of the keyed providers gives you one when you sign up.

**ISP-level DNS hijack** is the sneaky one, and it deserves its own callout because it looks exactly like "the internet is broken" from the tool's side. Your router asks your ISP's resolver "what IP is duckduckgo.com?", and instead of the real answer, the ISP returns the IP of a block page. Some ISPs do this to censor sites. The tool then connects to the wrong server, TLS fails, and you get `fetch failed` with zero hints about the actual cause.

---

## How the backend is structured (and where config lives)

Before fixing things, it helps to know where unipi keeps its search configuration, because it's two small files in one directory:

```
~/.unipi/config/web-api/
├── auth.json     # API keys, keyed by provider id
└── config.json   # provider enablement + overrides
```

`auth.json` is a flat map of `provider-id → key`. `config.json` holds provider settings like `enabled`. Both are read on every search call, so edits apply immediately, no Pi restart needed (the exception being environment variables, which are read once at process start).

The defaults, as shipped:

| Rank | Provider          | Needs API key | Enabled by default |
| ---- | ----------------- | ------------- | ------------------ |
| 1    | wigolo (local)    | No            | Yes (but needs `wigolo init`) |
| 2    | DuckDuckGo        | No            | Yes                |
| 3    | Jina Search       | No\*          | Yes                |
| 4    | SerpAPI           | Yes           | **No**             |
| 5    | Tavily            | Yes           | **No**             |
| 6    | Perplexity        | Yes           | **No**             |

\* more on this one later, because "no key needed" is quietly no longer true.

There's also an interactive settings UI for all of this: run `/unipi:web-settings` inside Pi. Editing the JSON files by hand works too, and for scripting I prefer it.

---

## Prerequisites

Before starting, make sure you have:

- **Pi** installed and running (this post uses v1.x)
- **The unipi extension**, since Pi core ships no web tools. Pi has its own package manager for exactly this, so inside Pi run:

  ```bash
  pi install npm:@pi-unipi/web-api
  ```

  `pi list` should show it afterwards, and Pi will now expose the three web tools plus the `/unipi:web-settings` command. Note this is third-party code that executes inside your agent session, so the usual Pi package trust rules apply: review the source before installing. On first run it creates its config directory, which the rest of this post edits by hand.

- **The `browser_search` tool**, referenced in a couple of steps below, is a _separate_ Pi package (`pi-browser-search`), installed the same way: `pi install npm:pi-browser-search`. It's optional for the search backend itself, but the DNS fix in Step 2 repairs it too.
- **A career-ops checkout** (only needed for the plugin section at the end)
- **API keys: none required upfront.** The two free ones are created mid-post, and everything else is keyless.

---

## Step 0: Find out what's actually broken

Don't configure anything yet. Test each rank first, by asking Pi directly (if the `web_search` tool doesn't exist at all, go back to the prerequisites):

> _"Search the web for 'nodejs release schedule' using source 2"_

or in one shot per backend. When I did this on a fresh install, the diagnosis came out surprisingly clean:

| Backend          | Error                              | Root cause                                    |
| ---------------- | ---------------------------------- | --------------------------------------------- |
| wigolo (1)       | daemon could not be reached / ENOENT | Never installed or initialized                |
| DuckDuckGo (2)   | `fetch failed`                     | ISP DNS hijack (spoiler)                      |
| Jina (3)         | `401 Unauthorized`                 | Keyless search discontinued; needs a free key |
| Tavily (5)       | `No provider at rank 5`            | Shipped `enabled: false`                      |

Four failures, four different causes. Fixing them in order of increasing weirdness.

---

## Step 1: wigolo — the free local backend

wigolo is the only fully local option in the list: no account, no key, no monthly quota. It just needs a one-time setup. The Pi docs phrase the failure helpfully: install a REST-capable wigolo (newer than `0.1.43-beta.2`) and run its init.

```bash
npm install -g wigolo@latest
wigolo init
```

`wigolo init` checks your system, then downloads its components: a semantic embeddings model (BGE-small-en-v1.5), a cross-encoder reranker (ms-marco-MiniLM-L-6-v2), and browser engines for JS-heavy pages. The models are small (tens to hundreds of MB) and cached under `~/.wigolo`.

Two things worth knowing from my run:

- The browser engine downloads (Chromium, Firefox, WebKit) go through Playwright's CDN. On a slow or restricted network they can time out. **This is fine.** Init reports the failure, falls back to a multi-engine HTTP backend for search, and marks `requiredFailed: false`. You can retry browsers later with `wigolo warmup --browser` — you only truly need them for scraping JavaScript-rendered pages, not for search.
- The old SearXNG sidecar is no longer part of the default setup; current wigolo uses its multi-engine core backend directly.

Once init finishes, you can start the daemon explicitly if you want to inspect it:

```bash
wigolo serve      # daemon on 127.0.0.1:3333, loopback only
wigolo health     # should print {"status":"healthy",...}
```

In practice you don't need to manage this yourself: Pi's web API client starts the daemon lazily on first use and reuses it (it's expensive to boot, so it's a cached singleton). I started it manually once just to confirm health, and let Pi handle it after that.

Quick verification, rank 1:

> _"Search the web for 'best ATS friendly resume template' using source 1"_

Real results, zero tokens, zero API keys. 

---

## Step 2: DuckDuckGo — when "fetch failed" is actually your ISP

This one is my favorite because nothing in the error message points at the real cause. DuckDuckGo is enabled by default and needs no key, so on a normal network it just works. Mine didn't:

```
Search failed: DuckDuckGo: fetch failed
```

Bare `fetch failed` usually means a network-level problem, so I checked connectivity directly with `curl`. Other sites were fine, but duckduckgo.com specifically failed TLS verification with a hostname mismatch. Then the resolver check made it obvious:

```bash
$ getent hosts duckduckgo.com
114.7.173.245   internetpositif.ioh.co.id duckduckgo.com
```

My ISP's resolver was answering with a block page instead of the real site. I confirmed the block was DNS-only (not IP-level) two ways: resolving through a public DoH endpoint returned the real IP (`20.43.161.105`), and connecting to that IP directly with the right hostname via `curl --resolve` returned a clean `200`. So the fix was simply: stop using the ISP's resolver.

> **For Indonesian readers:** this specific block page (`internetpositif.ioh.co.id`) is the ISP-level filtering used by some Indonesian providers. If any site fails for you with a TLS or "fetch failed" error while others load fine, run `getent hosts <domain>` (or `nslookup`) first. A weird hostname in the answer is your smoking gun. Note that the same fix also restores `browser_search` in Pi, which routes through the same network stack.

On Linux with NetworkManager, pointing the connection at public resolvers is two commands (run `nmcli -t -f NAME,DEVICE con show --active` to get your connection name):

```bash
sudo nmcli con mod "<your-connection>" ipv4.dns "1.1.1.1 9.9.9.9" ipv4.ignore-auto-dns yes
sudo nmcli con up "<your-connection>"
```

That's durable across reboots. After it applied, DuckDuckGo and `browser_search` both came back immediately. No key, no restart.

One caveat: this fixes DNS resolution, and it was enough for me because the block was DNS-only. If an ISP blocks by IP or SNI instead, you'd need encrypted DNS (DoH/DoT) or a VPN. Check with the `curl --resolve` trick above before assuming.

---

## Step 3: Jina — a free key, plus the quirk that hides it

Jina Search is enabled by default and was, for a long time, usable keyless. Not anymore: every call came back `401 Unauthorized`. The fix is signing up at [jina.ai](https://jina.ai) and grabbing a free API key (it starts with `jina_`, and the free tier comes with daily credits that are plenty for research-sized usage).

You can verify the key immediately with curl, outside of Pi entirely:

```bash
curl "https://s.jina.ai/?q=node.js%20release%20schedule" \
  -H "Authorization: Bearer jina_XXXX"
```

`200` with real results? Key is good. Now the quirk.

**Where you put the key depends on an implementation detail that will waste an hour if you don't know it.** Pi's search tool only attaches keys from `auth.json` to providers that are marked `requiresApiKey: true` (SerpAPI, Tavily, Perplexity). Jina is marked as optional-key, so its `auth.json` entry is silently ignored, and the provider falls back to an environment variable instead: `JINA_API_KEY`.

So the working setup is the env var, exported where your shell can see it:

```bash
# ~/.bashrc (and ~/.profile for login shells)
export JINA_API_KEY="jina_XXXX"
```

If you want it to survive even terminal-less launches (desktop entries, systemd user services), mirror it too:

```bash
mkdir -p ~/.config/environment.d
echo "JINA_API_KEY=jina_XXXX" > ~/.config/environment.d/99-web-search.conf
```

Two follow-ups that bit me:

- **Environment variables are read at process start.** If Pi is already running when you export the key, the current session keeps failing with `401` until you restart Pi. Worse, if you restart Pi from a terminal that was opened *before* the export existed, it still won't see it. New terminal, then relaunch.
- **Jina snippets may render as `undefined`.** The provider code maps a `snippet` field, but Jina's JSON actually returns `description`. Search results still come back (titles and URLs are fine), just without snippet text. If it bothers you, it's a one-line patch in the provider file `@pi-unipi/web-api/src/providers/jina-search.ts`:

```ts
snippet: item.snippet || item.description || "",
```

> **A note on patching node_modules:** this patch lives in Pi's installed packages, so the next package update will revert it. That's acceptable for a one-liner you can re-apply (or upstream may have fixed it by the time you read this), but be aware it's a local modification, not a durable fix.

After the restart, rank 3 works.

---

## Step 4: Tavily — the key isn't enough, it ships disabled

Tavily's free tier (1,000 credits/month at time of writing) covers research comfortably. Sign up at [tavily.com](https://www.tavily.com), get your key (`tvly-...`), verify it with curl:

```bash
curl https://api.tavily.com/search \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer tvly-XXXX" \
  -d '{"query":"node.js release schedule","max_results":2}'
```

Then, unlike Jina, this key **does** go into `auth.json` — that part works as expected:

```json
{
  "jina-search": "jina_XXXX",
  "tavily": "tvly-XXXX"
}
```

Keep that file private while you're at it (`chmod 600`); it's a flat file of live credentials.

But the search will still fail with `No provider at rank 5 for search. Available ranks: 1, 2, 3`. The provider ships **`enabled: false`** by default. Flip it in `config.json`:

```json
{
  "providers": {
    "tavily": { "enabled": true }
  }
}
```

Config is read per call, so no restart needed. Rank 5 immediately returns full results.

---

## Step 5: The career-ops side — Tavily and Serper plugins

Pi's `web_search` and career-ops' own plugin system are separate layers. The plugins give the *pipeline* (scans, liveness checks, company research) direct access to Tavily and Serper, independent of whatever Pi's agent tools are doing. Both are approved community plugins.

Keys for career-ops plugins live in a `.env` file in the career-ops repo root (gitignored, same pattern as any dotenv setup):

```bash
TAVILY_API_KEY=tvly-XXXX
SERPER_API_KEY=XXXX
```

Then install and enable:

```bash
node plugins.mjs add career-ops-plugin-tavily
node plugins.mjs enable tavily --confirm
node plugins.mjs add career-ops-plugin-serper
node plugins.mjs enable serper --confirm
```

**Serper** is a `provider`-type plugin, so `plugins.mjs run serper` will correctly tell you it only runs through the scanner (a `provider: serper` entry in `portals.yml`). Nothing to test standalone; the key verification you did with curl is enough.

**Tavily** exposes a `search` hook, and here I hit the third silent failure of this setup:

```
⚠️  tavily: skipping — search hook failed — Cannot read properties of undefined (reading 'TAVILY_API_KEY')
```

The engine calls search hooks as `hook(payload, ctx)`, but the plugin was written against an older `search(ctx)` signature — so the query string lands in the plugin's `ctx` slot, `ctx.env` is undefined, and the key lookup crashes. If you see this exact error, it's the signature mismatch, not a missing key. The plugin lives in `plugins.local/` (gitignored, local-only), so a small compat shim is safe:

```js
async search(payload, ctx) {
  let query = payload;
  if (payload && typeof payload === 'object' && (ctx === undefined || ctx === null)) {
    ctx = payload; query = undefined;
  }
  // ...use ctx.env, use query if present, else build from ctx.settings
}
```

career-ops hashes plugin files and refuses to load a plugin whose files changed without a re-trust, so after editing you'll get a "files changed since you trusted it" warning. Review your own diff, then:

```bash
node plugins.mjs trust tavily
node plugins.mjs run tavily search "senior applied ai engineer remote" --dry-run
```

`--dry-run` matters here: without it, results get appended to your `data/pipeline.md` inbox. With it, you should see real jobs listed and "pipeline not written". (One debugging note that cost me a false alarm: the `injected env (0) from .env` line in the output is not an error. `scan.mjs` loads dotenv quietly at import time, so the banner only counts *newly* injected variables, which is zero when they're already loaded.)

---

## Verification matrix

The end state, and how to test each row yourself:

| Backend                     | Type             | Cost  | Test                                            |
| --------------------------- | ---------------- | ----- | ----------------------------------------------- |
| wigolo (source 1)           | local daemon     | free  | "search ... using source 1"                     |
| DuckDuckGo (source 2)       | keyless API      | free  | "search ... using source 2"                     |
| Jina (source 3)             | keyed API        | free tier | "search ... using source 3"                  |
| Tavily (source 5)           | keyed API        | free tier | "search ... using source 5"                  |
| `browser_search`            | built-in browser | free  | any JS-rendered page lookup                     |
| career-ops `tavily` plugin  | pipeline search  | free tier | `node plugins.mjs run tavily search "q" --dry-run` |
| career-ops `serper` plugin  | pipeline provider | free tier | `provider: serper` in portals.yml + a scan      |

Two habits worth keeping: rotate any key that's ever been pasted somewhere it shouldn't be (chat transcripts count), and remember that aggregator listings that surface through any of these backends are unconfirmed until checked against the employer's own careers page — that discipline is baked into career-ops for good reason.

Also worth repeating: none of this is required for career-ops' core scanning. The ATS scanning paths are zero-token and unaffected. This stack is what makes the *research* muscle work: verifying postings, digging into companies, and generally letting the agent look things up without you babysitting each lookup.

---

## Recap

1. Install the unipi extension first — Pi core has no web tools, and every backend in this post hangs off it
2. Test each source rank before configuring anything — four errors usually mean four different causes
3. wigolo: `npm i -g wigolo@latest && wigolo init`, let Pi manage the daemon, browser engines are optional
4. DuckDuckGo: if it fails while everything else works, check your resolver — an ISP DNS hijack masquerades as `fetch failed`; fix it at the NetworkManager level
5. Jina: grab a free key, put it in `JINA_API_KEY` (not `auth.json` — optional-key providers ignore it), restart Pi from a fresh terminal
6. Tavily: free key goes in `auth.json`, but you must also enable the provider in `config.json`
7. career-ops plugins: keys in `.env`, `plugins.mjs add` + `enable --confirm`, shim the Tavily search signature if you hit the `ctx.env` crash, `trust` after any local edit
8. Verify everything with explicit source ranks and `--dry-run` before letting results into your pipeline

Thank's for reading, and happy coding!
