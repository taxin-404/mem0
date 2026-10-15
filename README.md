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
  vector vector(1536), -- text-embedding-3-small dimensions
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
   - `OPENAI_API_KEY`
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
