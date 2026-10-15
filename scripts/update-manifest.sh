#!/usr/bin/env bash
# Record the current upstream state of the 6 hand-patched files in
# server/.upstream-manifest. Run this AFTER hand-merging an upstream change
# into one of those files (the auto-update workflow compares against this
# manifest to decide whether upstream has new changes for them).
set -euo pipefail
cd "$(dirname "$0")/.."

git remote add upstream https://github.com/mem0ai/mem0.git 2>/dev/null || true
git fetch --depth 1 upstream main:refs/remotes/upstream/main

: > server/.upstream-manifest
for f in server/main.py server/db.py server/Dockerfile \
         server/requirements.txt server/alembic/env.py server/.env.example; do
  printf '%s  %s\n' "$(git rev-parse "upstream/main:$f")" "$f" >> server/.upstream-manifest
done
echo "server/.upstream-manifest updated:"
cat server/.upstream-manifest
