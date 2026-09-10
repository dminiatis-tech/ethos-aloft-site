# Host-side artifact gate

**Status: present but INERT.** Nothing invokes it. The Render service's Build
Command is empty, so this directory currently has no effect on any deploy.

Authorised by @Fizz 2026-09-09 (two-step arming, four conditions). Built and
controlled by Kit. It is deliberately committed *before* being armed so the logic
is versioned and reviewable first — Condition 3: **logic in a checked-in file,
only the invocation in the dashboard.**

## What it is for

`publishPath` is `.` and `buildCommand` has always been empty, so **nothing
host-side has ever stood between a bad `dist/` copy and the live site.** The
guards in the source repo's `package.json` are per-commit artifacts — they cannot
protect a worktree parked at an older commit, and there are 32 worktrees. A build
command cannot be missing from a checkout, because there is no checkout.

It catches the specific failure we measured: `npm run build` (without prerender)
never fails, exits 0, and leaves a complete-looking `dist/` whose `index.html`
has an **empty root div**. Copied into this mirror it would publish an
un-prerendered SPA with every per-route meta tag gone.

## ⛔ Rollback lever — read this before arming

**Clear the service's Build Command back to empty in the Render dashboard.** One
edit, restores today's behaviour exactly. The check writes nothing and moves
nothing; there is no other state to undo.

If it ever refuses a deploy you believe is good: clear the Build Command, publish,
*then* work out which assertion was wrong. **Do not weaken an assertion under time
pressure.**

## Arming — two steps, in this order

Both steps need the Render dashboard. Neither is reachable from our tooling: the
Render MCP server has no tool that updates an existing service's build command
(`create_*`, `update_environment_variables`, `trigger_deploy` only), there is no
API key in the agent environment, and there is no `render` CLI.

**Step 1 — report-only.** One deploy, then read the log.

1. Service → Environment → add `ARTIFACT_GATE_MODE` = `report`
2. Service → Settings → Build Command = `./.deploy-checks/verify-artifact.sh`
3. Trigger one deploy. Expect `PASS`, or failures printed with
   `REPORT-ONLY: … did NOT block this deploy`.

Order matters. **The script defaults to `enforce`**, so setting the Build Command
before the variable arms it enforcing and skips step 1. A default of `report`
would have been the wrong choice: a missing or misspelled variable would silently
disable the gate. Verified — `ARTIFACT_GATE_MODE=repot` still enforces.

**Step 2 — enforce.** Delete the `ARTIFACT_GATE_MODE` variable (or set it to
`enforce`). No script change.

## What it asserts

1. `index.html` exists at the publish root, is non-empty, has **no** empty root
   div, and **has** a non-empty `<title>` — presence as well as absence, because a
   truncated or replaced file can lose the empty div without being a document.
2. Every route in `routes.txt` has its own `index.html`, prerendered, titled.
3. **The other direction:** no prerendered route directory is missing from
   `routes.txt`. That is the drift alarm — without it the manifest can silently
   fall behind the source's `ROUTES`.
4. Fails closed on its own preconditions: manifest missing, unreadable, empty, or
   containing duplicates → `FATAL`, exit 1.

`routes.txt` is generated from `scripts/prerender.py:ROUTES` in the source repo.
⚠️ **Keeping it current is the ship step's job.** If it falls behind, assertion 3
is what tells you.

## Controls run before commit

| control | expected | result |
|---|---|---|
| good tree, enforce | PASS 0 | PASS 0 |
| un-prerendered apex shell | FAIL 1 | FAIL 1 |
| same tree, `report` | exit 0, REPORT-ONLY | exit 0, REPORT-ONLY |
| **misspelled mode, bad tree** | **still enforce, 1** | **enforce, 1** |
| missing route dir | FAIL 1 | FAIL 1 |
| stray dir not in manifest | FAIL 1 | FAIL 1 |
| manifest missing | FATAL 1 | FATAL 1 |
| empty manifest | FATAL 1 | FATAL 1 |
| no apex `index.html` | FAIL 1 | FAIL 1 |

The first version used `mapfile`, which is bash 4+ and absent on bash 3.2. It died
`FATAL` on a good tree — right direction, but a gate that depends on the build
image's bash version can start refusing everything after an unrelated image
change. Replaced with a portable read loop.

⚠️ `publishPath` is `.`, so files here enter the published set once a deploy runs.
They disclose nothing; noting it because things arrive in that set silently.
