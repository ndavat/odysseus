#!/bin/sh
# render-start.sh — Render.com container command (free / demo tier).
#
# Render sets this as the container CMD (overrides the Dockerfile's hardcoded
# `uvicorn … --port 7000`). docker/entrypoint.sh runs first and has already:
#   - dropped privs to user `$PUID:$PGID` via gosu
#   - repaired ownership of bind mounts (including /app/data)
#   - run `python setup.py` (idempotent: seeds data dirs + admin if missing)
# So at the top of this script we are already the non-root `odysseus` user.
#
# Free-plan realities (render.com/docs/free, as of 2026):
#   - NO persistent disk. /app/data is ephemeral: every redeploy, restart,
#     or 15-min idle spin-down wipes SQLite (app.db), auth.json, settings,
#     sessions, memory, presets, uploads, generated images, scheduled tasks.
#     This means we re-seed settings.json on every boot (file may be gone).
#   - 512 MB RAM cap. The ChromaDB sidecar was dropped from earlier revisions
#     (this script no longer starts one) — vector search falls back to
#     keyword RAG while we live on free.
#   - 15-min idle spin-down + ~1 min cold-start on return.
#
# Responsibilities here:
#   0. Seed /app/data/settings.json with search_provider=duckduckgo if
#      missing. Only writes when the file is absent — never clobbers user
#      edits (when they survive a spin-down).
#   1. Spawn uvicorn as a child of THIS shell and wait on it. We deliberately
#      do NOT `exec uvicorn`: exec would replace this shell and drop the
#      TERM trap below, leaving only Render's hard-kill. Keeping the shell
#      alive means SIGTERM hits the shell → trap forwards it to uvicorn →
#      uvicorn gets its own SIGTERM and does a graceful shutdown.

set -eu

log() { printf '[render-start] %s\n' "$*" >&2; }

# Resolve the non-root user from PUID; matches what entrypoint.sh created.
USER_NAME="$(getent passwd "${PUID:-1000}" | cut -d: -f1)"
[ -z "$USER_NAME" ] && USER_NAME=odysseus

mkdir -p /app/data/logs

# 0. Seed /app/data/settings.json with DuckDuckGo as the search provider -----
# App's src/settings.py default is "searxng"; there's no env override. On the
# free tier this file may be wiped on every spin-down — that's fine; we
# re-seed idempotently on each boot so first-time UX is sensible.
SETTINGS_FILE=/app/data/settings.json
if [ ! -f "$SETTINGS_FILE" ]; then
  log "seeding $SETTINGS_FILE with search_provider=duckduckgo"
  cat > "$SETTINGS_FILE" <<'JSON'
{
  "search_provider": "duckduckgo",
  "search_count": 10,
  "search_safesearch": "1"
}
JSON
else
  log "settings.json already exists; leaving untouched (UI → Search can switch provider anytime)"
fi

# 1. uvicorn — keep this shell alive so the trap survives --------------------
UVI_PORT="${PORT:-7000}"
log "starting uvicorn on 0.0.0.0:${UVI_PORT} (ODYSSEUS_DATA_DIR=/app/data — EPHEMERAL on free plan)"
gosu "$USER_NAME" uvicorn app:app --host 0.0.0.0 --port "$UVI_PORT" \
  > /app/data/logs/uvicorn.log 2>&1 &
UVI_PID=$!

# Forward SIGTERM/SIGINT to uvicorn. Without this trap, a `exec uvicorn`
# pattern would drop it and Render's hard-kill would terminate uvicorn
# mid-request. With this trap, Render's SIGTERM hits the shell, the trap
# forwards it, and uvicorn does its graceful shutdown.
trap 'kill -TERM "${UVI_PID:-}" 2>/dev/null || true' TERM INT

# Wait for uvicorn (the foreground process).
wait "$UVI_PID"
UVI_EXIT=$?

log "uvicorn exited with $UVI_EXIT; container shutting down"
exit "$UVI_EXIT"
