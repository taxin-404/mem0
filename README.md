# mem0 on Render

Self-hosted [mem0](https://github.com/mem0ai/mem0) REST API server on Render's free
tier, using an external Neon Postgres (pgvector) — no Render database, no monthly cost.

- Repo layout: this repo is only the upstream `mem0/server/` directory (Docker build
  context) plus `render.yaml`. The image installs the `mem0ai` SDK from PyPI.
- Modify this repo's `server/Dockerfile` carefully — it is upstream code with two
  local changes: migrations run on boot (`alembic upgrade head`) and uvicorn binds
  to Render's `$PORT` instead of a hardcoded 8000.

## One-time Neon prerequisites (run BEFORE first deploy)

In the Neon Dashboard → SQL editor (database selected: `neondb`):

```sql
-- 1. pgvector + mem0's storage table (mem0 would lazily create these on the
--    first memory operation; pre-running proves Neon privileges upfront)
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS memories (
  id UUID PRIMARY KEY,
  vector vector(768), -- gemini-embedding-001 dimensions (768)
  payload JSONB
);

-- 2. separate database for auth / API keys / audit log (alembic target)
CREATE DATABASE mem0_app;
```

If the editor lets you switch database to `postgres`, also run
`CREATE EXTENSION IF NOT EXISTS vector;` there — mem0's pgvector bootstrap may
initialize through the maintenance database first.

## Deploy

1. Push this repo to GitHub (default branch `main`).
2. Open `https://dashboard.render.com/blueprint/new?repo=<this repo URL>`.
3. When prompted, fill the secrets:
   - `POSTGRES_HOST` — Neon **Direct** endpoint host (NOT the `-pooler` one), no `https://`
   - `POSTGRES_USER` — `neondb_owner`
   - `POSTGRES_PASSWORD` — your Neon password
   - `GOOGLE_API_KEY` — free Gemini key from
     [AI Studio](https://aistudio.google.com/apikey) (no credit card needed).
     Setting this key auto-selects the Gemini provider for both LLM and
     embeddings: `gemini-3.5-flash-lite` + `models/gemini-embedding-001`,
     both free-tier eligible.
   - `JWT_SECRET` — auto-generated, no action needed
4. Apply, watch the first deploy, check logs.

## Post-deploy checks

- `GET /docs` → 200 (health check path)
- `GET /auth/setup-status` → first-admin setup state
- If the boot log shows a `database ... does not exist` or
  `extension "vector" is not supported` error → re-run the Neon SQL above.
- If bootstrap fails connecting to the maintenance database, the fallback is
  mem0's direct connection string option (pgvector config `db_url`), which skips
  the bootstrap flow.

## Environment notes

- `HISTORY_DB_PATH` defaults to `/app/history/history.db` — a local SQLite file.
  Render's filesystem is ephemeral: the memory edit history resets on redeploy.
  Memories themselves live in Neon and are unaffected.
- Free web services spin down after 15 min without inbound traffic: keep
  UptimeRobot (5-min interval) pointed at any route (e.g. `/docs`).
- Health check uses `/docs` deliberately: it must NOT touch the database, so Neon
  can suspend between real memory operations and stay inside its 100 CU-hour
  free-tier budget.

## Updating from upstream mem0

Updates are **automatic**. A scheduled GitHub Action
(`.github/workflows/auto-update.yml` — every Monday, plus on-demand from the
Actions tab) will:

1. bump the pinned `mem0ai` SDK when PyPI has a newer release,
2. take upstream's version of any `server/` file this fork never patched,
3. run the full Docker smoke test — updates are only pushed if it passes.
   Pushes to `main` trigger a Render deploy, and a failed deploy leaves the
   previous version serving,
4. open a GitHub issue when upstream changed one of the six hand-patched
   files below — those are never auto-merged; the issue walks through the
   manual merge, and `scripts/update-manifest.sh` records the merge so the
   alert stops recurring.

If an auto-update ever breaks something: the old Render deploy keeps serving
until a good one succeeds — `git revert` the auto commit (or ask) and push.

The rest of this section is what the Action automates, kept as the manual
reference.

### 1. The `mem0ai` engine (Python SDK, installed from PyPI)

The memory logic (fact extraction, embeddings, pgvector/Gemini providers) lives
in the SDK; the REST wrapper is thin. `server/requirements.txt` pins the engine
(currently `mem0ai==2.2.1` — the version verified by the smoke test), so updates
are deliberate instead of surprise-breaking your next redeploy:

```bash
# 1. bump the pin in server/requirements.txt:  mem0ai==X.Y.Z
bash scripts/smoke-test.sh          # full local Docker test (requires Docker)
git commit -am "Bump mem0ai to X.Y.Z"
git push                            # Render auto-deploys from main
```

### 2. The REST wrapper (`server/` directory)

`server/` is a copy of upstream `mem0/server/` with a handful of local patches
(see `git log -- server/`). To sync new wrapper code without losing them:

```bash
git fetch --depth 1 upstream main:refs/remotes/upstream/main   # remote already configured
git diff --stat HEAD upstream/main -- server/                  # what differs

# a) files WITHOUT local patches can be taken wholesale:
git checkout upstream/main -- server/<path>

# b) files WITH local patches — merge by hand:
#    server/main.py            GOOGLE_API_KEY -> gemini auto-select, sslmode
#                              passthrough, 768-dim defaults
#    server/db.py              URL-escaped credentials + sslmode query param
#    server/Dockerfile         /app/history dir, alembic-on-boot CMD, $PORT
#    server/requirements.txt   google-genai (not google-generativeai), mem0ai pin
#    server/alembic/env.py     % escaping for the app-DB URL
#    server/.env.example       local-dev sslmode note
```

- Upstream alembic migrations (`server/alembic/versions/`) arrive with the sync
  and run automatically on boot (`alembic upgrade head`) — schema updates are free.
- After any sync or pin bump: `bash scripts/smoke-test.sh`, then push.
- Pushes to `main` redeploy the service (Render blueprint default). If it doesn't,
  service dashboard → Manual Deploy → Clear build cache & deploy.

## MCP bridge (AI-agent memory)

`mcp/server.py` wraps this server's REST API as MCP tools (`add_memory`,
`search_memory`, `list_memories`, `delete_memory`) so coding agents (OpenCode,
Claude Code, Cursor…) get durable memory across sessions — backed by this
deployment's Gemini + Neon stack. Setup once per machine:

```bash
cd mcp && python3 -m venv .venv && .venv/bin/pip install "mcp<2" httpx
opencode mcp add mem0 --global -- "$PWD/.venv/bin/python" "$PWD/server.py"
```

Auth: create a key on the server (`POST /api-keys`, label e.g.
`opencode-mem0-mcp`), store the returned `m0sk_...` value in
`~/.config/opencode/mem0-api-key` (chmod 600), and give the server entry this
environment block in `~/.config/opencode/opencode.json`:

```jsonc
"environment": {
  "MEM0_API_KEY_FILE": "/home/<you>/.config/opencode/mem0-api-key",
  "MEM0_API_URL": "https://<your-render-service>.onrender.com",
  "MEM0_USER_ID": "<memory scope, e.g. your name>"
}
```

The key never lives in the repo or in the MCP config itself.

Want this on another machine or in a different agent (Claude Code, Cursor, …)?
Copy the one-shot prompt from `mcp/AGENT-SETUP.md` into that agent — it
performs the whole setup from scratch.
