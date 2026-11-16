---
title: "How to Start a Cloudflare Workers Project with Cloudflare One Access in 2026"
date: 2026-11-16
draft: false
tags:
    - cloudflare
    - workers
    - d1
    - cloudflare-one
    - access
    - vite
    - setup
    - security
    - tutorial
categories:
    - tech
    - tutorial
summary: "Step-by-step guide to starting a Cloudflare Workers project in 2026: Vite + @cloudflare/vite-plugin scaffold, Drizzle migrations on D1, idempotent literal-value seed imports, unit tests running inside workerd with @cloudflare/vitest-plugin, a Cloudflare One Access One-time PIN gate set up before the first deploy, and a minimal CI pipeline. Includes every gotcha found along the way: the wrangler OAuth token that silently returns an empty Access app list, wrangler v4's missing subdomain command, the D1 100-bound-parameter cap, JSON output shapes that are not what you'd guess, and the miniflare/undici/node:console crash that fails every test until you stop importing the plugin's root package from workerd."
description: "Start a Cloudflare Workers project the right way in 2026: scaffold with Vite, migrations with Drizzle on D1, tests running in workerd, and a Cloudflare One Access OTP gate in front — with every gotcha documented, from silent empty API responses to the vitest plugin crash."
---

I recently started building a private, single-user web app and the requirements were short: one deployable, zero ops, and **the app must never be reachable by anyone but me**. 

My favorite stack that fits are:

- **one Cloudflare Worker** serving both the static frontend and the API, 
- **one D1 database** (managed SQLite), 
- and **Cloudflare One Access** with a One-time PIN in front of everything. 



It all sits on the free tier for a single user.

This post is the setup guide I wish I'd had. It walks through the whole path: scaffold, database, migrations, seed data, tests, the Access gate, deploy, CI and i will document every gotcha I actually hit, because almost every one of them failed silently or with a misleading error.

> This is a *single-user private deployment* guide. Cloudflare One Access has team-scale features (groups, SAML, device posture) that I deliberately don't use. Everything here runs on free tiers: Workers Free, D1 Free, and Access for Teams (free up to 50 users). The one thing you must not cheap out on is the gate itself — the whole point is that the app is never public.

---

## What we are talking about

Four terms carry the rest of the article.

**[Cloudflare Workers](https://welcome.developers.workers.dev/)** is Cloudflare's serverless function runtime at the edge. In 2026 a Worker can also serve **static assets** (your built frontend) alongside its API routes, which means your whole app is one deployable: no separate hosting, no CORS, no second bill.

**[D1](https://developers.cloudflare.com/d1/)** is Cloudflare's managed SQLite. There is no database file to manage. Schema ships as versioned SQL **migrations** applied with wrangler, and you query it from the Worker through a binding. Its limits (which we'll meet in Step 3) actively shape how you write importers.

**[Cloudflare One Access](https://developers.cloudflare.com/cloudflare-one/access-controls/)** (the product formerly known as Cloudflare for Teams, living in the Zero Trust dashboard) is an identity-aware reverse proxy. You point it at a hostname, write an "allow" policy, and every request that isn't authenticated gets bounced to a login page *at the edge*, before your Worker runs. **No in-app auth code at all** and that's the appeal.

**One-time PIN (OTP)** is the simplest Access login method: type your email, get a 6-digit code, you're in. No [IdP](https://en.wikipedia.org/wiki/Identity_provider) setup and passwords, good for exactly one human.

## Prerequisites

- A Cloudflare account (free plan is fine).
- **Node 24+** and npm. I used Node 24.13.
- A **deliberately scoped API token** for CI: from the dashboard, My Profile → API Tokens → Create Token, with exactly:
  - `D1 Read`, `D1 Write`
  - `Workers Editor`
  - `Access: Apps and Policies Read` + `Write`

  Scope it to **one account**, and **skip IP address filtering**. GitHub Actions runners use dynamic IPs, so filtering would break CI for no security gain (the token only ever lives in your repo's secrets).
- Two secrets in GitHub (repo → Settings → Secrets and variables → Actions): `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. If you store them under an *environment* (e.g. `production`), only jobs that declare `environment: production` can read them. Remember that when you write the workflow.

## Step 1: Scaffold with Vite and the Cloudflare plugin

Create the project the way Cloudflare now recommends. Vite drives both the frontend build and the Worker build through `@cloudflare/vite-plugin`:

```bash
mkdir my-app && cd my-app
npm init -y
npm install hono                       # API framework (you can pick your own)
npm install -D vite @cloudflare/vite-plugin wrangler typescript
```

The two config files that matter:

```ts
// vite.config.ts
import { defineConfig } from "vite";
import { cloudflare } from "@cloudflare/vite-plugin";

export default defineConfig({
  plugins: [cloudflare({ viteEnvironment: { name: "worker" } })],
});
```

```toml
# wrangler.toml
name = "my-app"
main = "src/worker/index.ts"
compatibility_date = "2026-11-16"       # use today's date
compatibility_flags = ["nodejs_compat"]

[[d1_databases]]
binding = "DB"
database_name = "my-app"
database_id = "<copied in Step 2>"
migrations_dir = "drizzle/migrations"
```

**Gotchas in this step:**

1. **Do not add an `[assets]` section to `wrangler.toml`.** The Vite plugin builds your frontend into `dist/client` as "standard build output" and wrangler auto-detects it at deploy time. Configuring assets yourself fights the plugin.
2. **`wrangler types` generates `worker-configuration.d.ts`**. The `Env` type (`interface Env { DB: D1Database }`) plus the full Worker runtime types. **Commit this file** and add it to your ESLint ignores (it starts with `/* eslint-disable */` but still trips "unused eslint-disable directive" warnings). Then wire a check into CI:

   ```bash
   npx wrangler types --check   # fails if the committed file is stale
   ```

   Re-run `npx wrangler types` whenever `wrangler.toml` bindings change. In `tsconfig.json`, include the generated file and add `"types": ["vite/client"]`.
3. `vite dev` starts a local **workerd** (the same runtime production uses) with a local D1 database. Your API routes and static frontend both work at `localhost` immediately.

## Step 2: D1 database and Drizzle migrations

Create the database (this is a one-time remote operation, and it prints the id you need):

```bash
npx wrangler d1 create my-app
# ✅ Successfully created DB 'my-app' in region APAC
# "database_id": "4dd15cb4-a9b9-4858-b668-0a019a4a9ee3"
```

Copy that `database_id` into the `[[d1_databases]]` block in `wrangler.toml` (Step 1). The `binding` name (`DB`) is what your Worker and your generated `Env` type will call it.

For the schema, define tables with **[Drizzle ORM](https://orm.drizzle.team/)** and generate SQL migrations:

```ts
// drizzle.config.ts
import { defineConfig } from "drizzle-kit";
export default defineConfig({
  schema: "./drizzle/schema.ts",
  out: "./drizzle/migrations",
  dialect: "sqlite",
  strict: true,
});
```

```bash
npx drizzle-kit generate          # writes drizzle/migrations/0000_*.sql
npx wrangler d1 migrations apply my-app --local    # dev database
npx wrangler d1 migrations apply my-app --remote   # production database
```

**Gotchas in this step:**

1. **Drizzle and wrangler speak different SQL dialects (but it works out of the box).** Drizzle separates statements with a `--> statement-breakpoint` comment marker rather than just semicolons. wrangler's migration runner handles these files correctly, so point `migrations_dir` at Drizzle's output folder and don't hand-edit the files. (You *will* need the marker yourself in Step 4, so remember it exists.)
2. `wrangler d1 migrations apply` asks for confirmation before applying. In a non-interactive shell it announces `Using fallback value in non-interactive context: yes` and proceeds. Fine locally, worth knowing before you wire it into a script.
3. **Apply migrations to both databases**, and keep them in lockstep: `--local` for `vite dev` and tests, `--remote` for production. The applied set is tracked in the `d1_migrations` table per database, so they evolve independently until you check.

## Step 3: Importing seed data (the D1 limits that shape your importer)

My project required to be bootstrapped with bulk content (mine has 10000 rows). Writing the importer forces you into three D1 realities:

- **A statement may contain at most 100 bound parameters.** So a parameterized `INSERT` of even 15 rows with 8 columns overflows. The workaround (documented in D1's own docs, and the reason your importer looks unusual): **emit literal-value SQL**. String literals baked into the statement, no parameters at all.
- **A statement may be at most 100 KB.** So even literal inserts must be *chunked*. I used 100 rows per multi-row `INSERT`.
- **Re-imports must be idempotent.** Use `INSERT … ON CONFLICT (item_id) DO UPDATE SET …` so running the importer twice converges to the same state instead of duplicating rows.

The generator ends up looking like this (pure functions, no Node APIs, so tests can reuse it):

```ts
function chunk(rows: Row[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < rows.length; i += 100) {
    const values = rows
      .slice(i, i + 100)
      .map((r) => `('${esc(r.item_id)}', '${esc(r.content)}', …)`)
      .join(",\n");
    out.push(
      `INSERT INTO mytable (item_id, content, …) VALUES\n${values}` +
        ` ON CONFLICT(item_id) DO UPDATE SET content = excluded.content, …;`,
    );
  }
  return out;
}
```

Apply it with wrangler, then *verify* rather than trust:

```bash
npx wrangler d1 execute my-app --local --file scripts/seed.sql
npx wrangler d1 execute my-app --local --json \
  --command "SELECT (SELECT COUNT(*) FROM mytable) AS vocab, …"
```

**Gotchas in this step:**

1. **`wrangler d1 execute --json` output is `[{ "results": [ { …row… } ], "success": true, … }]`. `results` is an array of rows, not a row object.** I parsed it as `parsed[0].results` and got `undefined` for every column while staring at a log line that clearly showed the right JSON right below. It's `parsed[0].results[0]`.
2. **D1's `.first<T>()` in Worker code also returns a *row object*** (`{ value: "1" }`), not the scalar, even when your query has a single column. Destructure: `row?.value`.
3. **Verification SQL: every scalar subquery needs its own `FROM`.** `(SELECT COUNT(*) FROM vocabulary) - (SELECT COUNT(DISTINCT item_id))` fails with `no such column: item_id`. The second subquery is missing `FROM vocabulary`. The error names the column, not the missing clause, which sends you looking at the wrong thing.
4. Store a `seed_hash` (SHA-256 of the seed files) in a config table alongside `schema_version`, so a re-import after content updates is detectable instead of silent.

## Step 4: Tests inside workerd and the import that crashed everything

Cloudflare's current testing story is `@cloudflare/vitest-plugin`: it runs your Vitest suite **[inside workerd](https://github.com/cloudflare/workerd)**, the real Worker runtime, with real bindings (`env.DB` and friends come from your `wrangler.toml`). It does not use mocks of the runtime, so no drift between test and production. Setup:

```ts
// vitest.config.ts
import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.toml" } })],
  test: { setupFiles: ["./tests/setup.ts"] },
});
```

```ts
// tests/setup.ts — runs INSIDE workerd, like your tests
import { env } from "cloudflare:workers";
import { applyD1Migrations, type D1Migration } from "cloudflare:test";

const files = import.meta.glob("../drizzle/migrations/*.sql", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

const migrations: D1Migration[] = Object.entries(files)
  .sort(([a], [b]) => a.localeCompare(b))
  .map(([filePath, contents]) => ({
    name: (filePath.split("/").pop() ?? filePath).replace(/\.sql$/, ""),
    queries: contents
      .split("--> statement-breakpoint")   // remember that marker?
      .map((q) => q.trim())
      .filter(Boolean),
  }));

await applyD1Migrations(env.DB, migrations);
```

**This setup file is the single most important gotcha in this post.** The natural, documented-looking way to write it is:

```ts
import { readD1Migrations } from "@cloudflare/vitest-plugin";  // ← DON'T
const migrations = await readD1Migrations("./drizzle/migrations");
```

Do that and **every test fails. Even a file containing only `expect(1).toBe(2)`** with an error that points nowhere near your code:

```text
TypeError: Cannot destructure property 'Console' of 'require(...)' as it is undefined.
    at .../undici/lib/mock/pending-interceptors-formatter.js?mf_vitest_no_cjs_esm_shim:4:9
    at .../undici/index.js?mf_vitest_no_cjs_esm_shim:21:19
    at .../miniflare/dist/src/index.js:54383:22
```

What's actually happening, chain reaction style:

1. The plugin's **root package entry** (`@cloudflare/vitest-plugin`) is the *pool* module. It imports **miniflare** (a Node-side library).
2. Setup files run **inside workerd**, not in Node. Importing the pool module there drags miniflare and miniflare's dependency **undici** into the worker's module graph.
3. undici's mock support does `const { Console } = require('node:console')` at module load.
4. Inside this runner, `require('node:console')` resolves to the plugin's own ESM polyfill (registered in the runner's module manifest), and a CJS `require()` of an ESM module yields `undefined` here, hence "cannot destructure … as it is undefined".
5. The `?mf_vitest_no_cjs_esm_shim` suffix in the stack trace is the fingerprint of that module-fallback path.

Two facts make this confusing: `readD1Migrations()` genuinely *is* the API for this but its own type docs say to call it **"inside Node.js"** (it uses `fs.readFileSync`), and with this plugin setup files are *not* Node. And the failure happens at module-load time in a shared dependency, so nothing in the stack mentions your setup file at all.

**How to debug this class of problem** (this is how I proved miniflare was loading inside the worker): the plugin's module loader logs through `util.debuglog`, so run with:

```bash
NODE_DEBUG='vitest-plugin:module-fallback' npx vitest run
```

Every module resolution in the worker prints with its referrer. Seeing `miniflare/dist/src/index.js` and `undici/...` in that trace was the whole diagnosis in one shot.

**The fix** is the `import.meta.glob` version at the top of this section: read the migration SQL as strings through Vite (a transform that works fine in the test runtime), split on `--> statement-breakpoint`, and apply with `applyD1Migrations`. No Node APIs, no plugin-root import.

Three smaller setup gotchas while we're here:

- **`import { env } from "cloudflare:workers"`**. the `env` exported from `cloudflare:test` is deprecated (still works, warns in types). `applyD1Migrations` and the `D1Migration` type still come from `cloudflare:test`.
- **Types:** add `"types": ["@cloudflare/vitest-plugin/types"]` to `tsconfig.json`, or the `cloudflare:test` module won't resolve under `tsc --noEmit`.
- **`.first<T>()` returns a row object** (mentioned twice now because it cost me twice).

## Step 5: Cloudflare One Access: set up the gate *before* the first deploy

The rule for a private app: **the Access application exists before the Worker does.** That ordering feels backwards, but it's right. An Access application is just a *hostname policy*. It doesn't need anything to be deployed yet; it simply has no effect until traffic arrives at that hostname. And it means there is never a moment where a live Worker answers strangers.

### 5a. Find your `workers.dev` subdomain

The app's final URL will be `https://<worker-name>.<subdomain>.workers.dev`, and you need the full hostname to write the Access policy. Currenlty you can't get it from wrangler: **the `wrangler subdomain` command from v1/v2 is gone in wrangler 4**, and `wrangler whoami` doesn't print it. Query the account API instead (any token with account read. Even wrangler's own OAuth token works for this):

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/subdomain"
# → { "result": { "subdomain": "yourname" }, "success": true }
```

### 5b. Create the application in the One dashboard

In the new Cloudflare dashboard: **Protect & connect → Zero Trust → Access controls → Applications → Create new application → Self-hosted**:

![](./images/0001.png)

![](./images/0002.png)

| Field | Value |
|---|---|
| Name | `my-app` |
| Application domain | `my-app.yourname.workers.dev` (path empty = whole app) |
| Policy name | \**anything\** |
| Action | **Allow** |
| Include rule | **Emails** → your address |
| Session duration | 24 hours (or whatever you like) |

One-time PIN is the default login method for a fresh Access setup without extra configuration needed.

### 5c. Do not verify Access with wrangler's OAuth token

This one cost me a confusing half hour. After creating the app, I checked from the CLI with the token wrangler stores in `~/.config/.wrangler/config/default.toml`:

```bash
GET /accounts/<id>/access/apps
# → { "result": [], "success": true, "result_info": { "count": 0 } }   ← silent lie
POST /accounts/<id>/access/apps
# → { "errors": [{ "code": 1010, "error": "auth.forbidden" }] }
GET /accounts/<id>/access/organizations
# → { "errors": [{ "code": 10000, "message": "Authentication error" }] }
```

Three different behaviors, all useless: the **list endpoint returns `success: true` with an empty array** when the token lacks Access scope and it does *not* error, so you can easily conclude your app doesn't exist. Writes are correctly rejected, and sibling endpoints scream. wrangler's OAuth token simply wasn't granted Access scopes (it's meant for `wrangler deploy`, not Access administration).

Either use your **scoped API token** (the one from Prerequisites, which has `Access: Apps and Policies Read` + `Write`) for API verification, or better: verify *functionally*, which is what actually matters (Step 6). 

## Step 6: Deploy and prove the gate

```bash
npx vite build && npx wrangler deploy
```

The Vite plugin emits `dist/client` (your static frontend) plus the Worker bundle; wrangler uploads both in one operation. Output ends with your URL:

```text
Uploaded my-app (17.70 sec)
  https://my-app.yourname.workers.dev
```

Now the two curls that matter:

```bash
# BEFORE the first deploy (nothing exists yet):
curl -I https://my-app.yourname.workers.dev/
# → HTTP 404, body: error code: 1042     ← "no such worker"
#   Note: Access does NOT intercept yet — there's nothing to route to.

# AFTER deploy, still unauthenticated:
curl -I https://my-app.yourname.workers.dev/
# → HTTP/2 302
#   location: https://<your-team>.cloudflareaccess.com/cdn-cgi/access/login/…
#   www-authenticate: Cloudflare-Access resource_metadata="…/.well-known/…"
```

**That 302 is the acceptance test for the whole gate.** Unauthenticated traffic never sees your app. It's redirected to the Access login page at the edge. (`1042` pre-deploy is also why you can't pre-verify the gate: Access only starts intercepting once the hostname routes somewhere.)

Then walk through it in a browser: open the URL, land on the OTP page, enter your email, type the 6-digit code, see your app. Session persists for the policy duration you chose. That's the entire auth story. There is no auth code in your Worker, and there should never be.

**One deployment gotcha:** if you ever deploy *before* creating the Access app, the page is public until you add the policy. For a private app, treat Access creation as a hard prerequisite, not a cleanup step.

## Step 7: CI, kept minimal

For a project this size, CI is one job with the checks you'd run locally anyway:

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [master]
  pull_request:
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 24
          cache: npm
      - run: npm install
      - run: npm ci
      - run: npm run lint
      - run: npx wrangler types --check
      - run: npm run typecheck
      - run: npm test
      - run: npm run build
```

Notes: `wrangler types --check` needs **no credentials** (it only compares the generated file). That's why CI can run without any Cloudflare secrets at all. The API token and account id from Prerequisites only become necessary when a job *deploys*, and a deploy job should declare `environment: production` if that's where you stored the secrets. No deploy-by-default in CI is also a nice safety property for an app whose Access gate you just carefully ordered *before* the first deploy.

---

## Verification matrix

The end state, and how to test each row yourself:

| Check | Command | Expected |
|---|---|---|
| Local dev (workerd + D1) | `npx vite dev` | app on `localhost`, `/api/*` responds |
| Migrations (local) | `npx wrangler d1 migrations apply my-app --local` | `0000_*.sql`, `23 commands executed` |
| Migrations (remote) | same with `--remote` | same |
| Seed + row counts | `npm run seed` (file apply + `--json` count query) | `8334 vocabulary / 2091 kanji`, dups `0` |
| Idempotent re-import | run the seed twice | counts unchanged |
| Types fresh | `npx wrangler types --check` | `Types … are up to date` |
| Lint + types + tests | `npm run lint && npx tsc --noEmit && npx vitest run` | 0 errors, all tests pass **in workerd** |
| Build + deploy | `npx vite build && npx wrangler deploy` | URL printed, assets uploaded |
| **Gate blocks strangers** | `curl -I https://<app-url>/` (unauthenticated) | **302 → `*.cloudflareaccess.com/.../login/...`** + `www-authenticate: Cloudflare-Access` |
| Gate lets you in | browser + OTP email | app renders after 6-digit code |
| CI | push a branch | lint, `types --check`, typecheck, tests, build all green |

## Recap

1. Scaffold with **Vite + `@cloudflare/vite-plugin`**. No `[assets]` section, ever; wrangler detects `dist/client` for you.
2. Generate `worker-configuration.d.ts` with `wrangler types`, **commit it**, ignore it in ESLint, and gate CI with `wrangler types --check`.
3. Create D1 with `wrangler d1 create`, copy the `database_id`, and keep migrations applied to **both** `--local` and `--remote`.
4. Seed with **literal-value, chunked, `ON CONFLICT` SQL**. D1's 100-bound-parameter cap makes parameterized bulk inserts a dead end.
5. Parse `wrangler d1 execute --json` as `parsed[0].results[0]`, and expect **row objects** (not scalars) from `.first<T>()`.
6. Tests run **inside workerd**: never import `@cloudflare/vitest-plugin`'s root entry from setup/test code load migrations with `import.meta.glob` + `--> statement-breakpoint` instead. When a test crash points at some dependency's internals, `NODE_DEBUG='vitest-plugin:module-fallback'` shows you what's really being loaded.
7. Create the **Cloudflare One Access app before the first deploy**; the app doesn't need the Worker to exist, but the Worker must not exist without the app.
8. wrangler's OAuth token **cannot** verify Access (empty list ≠ empty truth) use a scoped API token or verify functionally.
9. Find your `workers.dev` subdomain via the account API wrangler 4 no longer has a `subdomain` command.
10. The gate's acceptance test is a **`302` to `cloudflareaccess.com`** from `curl` before deploy you'll see `1042` instead, which is expected.

Total cost of the finished stack: zero. Total time: an afternoon, most of which was staring at a module stack trace that didn't mention my code.

Thank's for reading, and happy coding!



