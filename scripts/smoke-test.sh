#!/usr/bin/env bash
# Local end-to-end test of the Render deployment artifact:
#   build the image exactly as render.yaml would, boot it against a throwaway
#   pgvector Postgres with the exact env var contract, verify the boot chain
#   (alembic -> uvicorn -> $PORT routing) and the auth/health endpoints.
# Run BEFORE pushing an update (see README "Updating from upstream mem0"):
#   bash scripts/smoke-test.sh
set -euo pipefail

IMG=mem0-test
NET=mem0-test-net
PG=mem0-test-pg
API=mem0-test-api
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1. BUILD (dockerContext ./server, as in render.yaml) ==="
docker build -q -t "$IMG" -f "$REPO/server/Dockerfile" "$REPO/server" 2>&1 | tail -5
echo "build ok"

echo
echo "=== 2. THROWAWAY pgvector + prerequisite SQL (mirrors README/Neon steps) ==="
docker rm -f "$API" "$PG" >/dev/null 2>&1 || true
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=testpw pgvector/pgvector:pg17 >/dev/null
for _ in $(seq 1 30); do
  docker exec "$PG" pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$PG" psql -q -U postgres -c "CREATE DATABASE neondb"
docker exec "$PG" psql -q -U postgres -d neondb -c "CREATE EXTENSION IF NOT EXISTS vector"
docker exec "$PG" psql -q -U postgres -c "CREATE DATABASE mem0_app"
echo "neondb + vector ext + mem0_app ready"

echo
echo "=== 3. RUN API (Render contract: PORT=10000, auth on, real env names) ==="
JWT_SECRET="$(openssl rand -base64 48)"
docker run -d --name "$API" --network "$NET" \
  -e PORT=10000 \
  -e POSTGRES_HOST="$PG" -e POSTGRES_PORT=5432 -e POSTGRES_DB=neondb \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=testpw \
  -e POSTGRES_COLLECTION_NAME=memories -e APP_DB_NAME=mem0_app \
  -e JWT_SECRET="$JWT_SECRET" -e GOOGLE_API_KEY=AIza-test-key-not-real \
  -e AUTH_DISABLED=false -e MEM0_TELEMETRY=false \
  -e POSTGRES_SSLMODE=disable \
  -p 8899:10000 "$IMG" >/dev/null

echo
echo "=== 4. WAIT FOR BOOT (60s budget) ==="
ready=""
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8899/docs || true)"
  if [ "$code" = "200" ]; then ready=1; break; fi
  if [ "$(docker inspect -f '{{.State.Running}}' "$API" 2>/dev/null)" != "true" ]; then
    echo "!! API container died during boot:"
    docker logs "$API" 2>&1 | tail -40
    exit 1
  fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "!! TIMEOUT waiting for /docs:"
  docker logs "$API" 2>&1 | tail -40
  exit 1
fi
echo "boot ok"

echo
echo "=== 5. ENDPOINT CHECKS ==="
docker exec "$API" python -c 'from importlib.metadata import version; import main; cfg = main.DEFAULT_CONFIG; print("mem0ai:    ", version("mem0ai")); print("google-genai:", version("google-genai")); print("llm:     ", cfg["llm"]["provider"], "-", cfg["llm"]["config"]["model"]); print("embedder:", cfg["embedder"]["provider"], "-", cfg["embedder"]["config"]["model"], "dims", cfg["embedder"]["config"]["embedding_dims"]); print("pg dims: ", cfg["vector_store"]["config"]["embedding_model_dims"])'
d_code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8899/docs)"
s_body="$(curl -s -w '|%{http_code}' http://127.0.0.1:8899/auth/setup-status)"
m_code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8899/memories)"
echo "GET /docs               -> $d_code   (expect 200, Render health check path)"
echo "GET /auth/setup-status  -> $s_body   (expect 200 JSON)"
echo "GET /memories (no auth) -> $m_code   (expect 401/403, auth enforced)"
h_root="$(curl -s -o /dev/null -w '%{http_code}' -I http://127.0.0.1:8899/)"
h_docs="$(curl -s -o /dev/null -w '%{http_code}' -I http://127.0.0.1:8899/docs)"
echo "HEAD /                  -> $h_root   (expect 200, uptime probes e.g. UptimeRobot)"
echo "HEAD /docs              -> $h_docs   (expect 200, uptime probes)"

echo
echo "=== 6. DATABASE STATE ==="
echo "app DB tables (alembic target: mem0_app):"
docker exec "$PG" psql -U postgres -d mem0_app -c '\dt' | sed 's/^/    /'
echo "vector storage (neondb):"
docker exec "$PG" psql -U postgres -d neondb -c '\dt' | sed 's/^/    /'
docker exec "$PG" psql -U postgres -d neondb -c '\dx' | sed 's/^/    /'

echo
echo "=== 7. BOOT LOG (last 20 lines) ==="
docker logs "$API" 2>&1 | tail -20

echo
echo "=== 8. CLEANUP ==="
docker rm -f "$API" "$PG" >/dev/null
docker network rm "$NET" >/dev/null
echo "ALL CHECKS DONE"
