#!/bin/sh
# render-start.sh — Render.com container command.
#
# Render sets this as the container CMD (overrides the Dockerfile's hardcoded
# `uvicorn … --port 7000`). docker/entrypoint.sh runs first and has already:
#   - dropped privs to user `$PUID:$PGID` via gosu
#   - repaired ownership of bind mounts (including /app/data)
#   - run `python setup.py` (idempotent: seeds data dirs + admin if missing)
# So at the top of this script we are already the non-root `odysseus` user.
#
# Responsibilities here:
#   0. Idempotently install the full chromadb package (requirements.txt ships
#      chromadb-client, the lightweight HTTP-only client; the `chromadb` CLI
#      used by our sidecar comes from the full distribution).
#   1. Start a ChromaDB sidecar on loopback:8100 with data on the persistent
#      disk (/app/data/chroma). Avoids paying for a second Render service.
#   2. Wait for the ChromaDB /api/v1/heartbeat endpoint so the app's startup
#      probe doesn't race the sidecar.
#   3. Seed /app/data/settings.json on first boot with search_provider =
#      "duckduckgo" since we don't run SearXNG in this single-service setup.
#      Only writes when the file is missing — never clobbers user edits.
#   4. Spawn uvicorn as a child of THIS shell and wait on it. We deliberately
#      do NOT `exec uvicorn`: exec replaces this shell and would drop the
#      TERM trap below, leaving ChromaDB without a graceful shutdown signal.
#      Keeping the shell alive means SIGTERM hits the shell, the trap
#      forwards it to both children, and uvicorn still gets its own SIGTERM
#      to do graceful shutdown.

set -eu

log() { printf '[render-start] %s\n' "$*" >&2; }

# Resolve the non-root user from PUID; matches what entrypoint.sh created.
USER_NAME="$(getent passwd "${PUID:-1000}" | cut -d: -f1)"
[ -z "$USER_NAME" ] && USER_NAME=odysseus

mkdir -p /app/data/chroma /app/data/logs

# 0. Ensure the full chromadb package is installed ----------------------------
# requirements.txt ships chromadb-client (HTTP-only) which lets the app TALK
# to ChromaDB, but it doesn't include the `chromadb` console script used by
# our sidecar here. The full `chromadb` distribution (~5 MB) provides it.
# Idempotent: when already present, pip is a quick no-op.
if ! command -v chromadb >/dev/null 2>&1; then
  log "chromadb CLI missing — pip-installing full chromadb (one-time, ~5s)"
  pip install --quiet --no-cache-dir chromadb || {
    log "FATAL: 'pip install chromadb' failed; sidecar cannot start"
    exit 1
  }
fi

# 1. ChromaDB sidecar ---------------------------------------------------------
log "starting chromadb sidecar on 127.0.0.1:8100 (data: /app/data/chroma)"
gosu "$USER_NAME" chromadb run \
  --host 127.0.0.1 \
  --port 8100 \
  --path /app/data/chroma \
  > /app/data/logs/chromadb.log 2>&1 &
CHROMA_PID=$!

# Initial signal handler — must be registered NOW so that a SIGTERM arriving
# during the (up to 30s) chromadb heartbeat wait below doesn't orphan chroma.
# `$UVI_PID` may be unset at this point; the conditional in the trap body
# prevents `kill -TERM ""` from erroring. The later UVI_PID assignment does
# not require re-registering — traps read scope variables at fire time, so
# once `$UVI_PID` is set (Section 4) the same trap handles it too.
trap '[ -n "${UVI_PID:-}" ] && kill -TERM "$UVI_PID" 2>/dev/null || true; kill -TERM "${CHROMA_PID:-}" 2>/dev/null || true' TERM INT

# 2. Wait for ChromaDB heartbeat ---------------------------------------------
log "waiting for chromadb /api/v1/heartbeat…"
CHROMA_OK=0
for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:8100/api/v1/heartbeat >/dev/null 2>&1; then
    log "chromadb healthy after ${i}s"
    CHROMA_OK=1
    break
  fi
  if ! kill -0 "$CHROMA_PID" 2>/dev/null; then
    log "chromadb exited before becoming ready — last 40 log lines:"
    tail -40 /app/data/logs/chromadb.log >&2 || true
    exit 1
  fi
  sleep 1
done
if [ "$CHROMA_OK" -ne 1 ]; then
  log "chromadb never became healthy in 30s. Continuing anyway (app degrades to keyword fallback)."
fi

# 3. Seed /app/data/settings.json with DuckDuckGo as the search provider -----
# App's src/settings.py default is "searxng"; there's no env override. So on
# first boot we drop a minimal settings.json. After that, the file persists
# across deploys (lives on the persistent disk) and the user can change
# search_provider in Settings → Search.
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

# 4. uvicorn — keep this shell alive so the trap survives --------------------
UVI_PORT="${PORT:-7000}"
log "starting uvicorn on 0.0.0.0:${UVI_PORT} (ODYSSEUS_DATA_DIR=/app/data)"
gosu "$USER_NAME" uvicorn app:app --host 0.0.0.0 --port "$UVI_PORT" \
  > /app/data/logs/uvicorn.log 2>&1 &
UVI_PID=$!

# Forward SIGTERM/SIGINT to BOTH children. Without this trap, exec-ing into
# uvicorn would drop it and ChromaDB would leak until Render's hard-kill.
# These vars must be set BEFORE the trap is registered for $CHROMA_PID/$UVI_PID
# to be visible to the trap — both are set above.
# (Trap was already registered earlier — right after $CHROMA_PID=$! — so the
# unhandled SIGTERM window ends at +30s instead of extending the full lifetime
# of the heartbeat wait. Re-registering here is unnecessary: trap bodies read
# scope variables at fire-time, so the same handler covers both children now
# that $UVI_PID has been set.)

# Wait for uvicorn (the foreground process). It will receive SIGTERM via the
# trap directly so it can do its graceful shutdown.
wait "$UVI_PID"
UVI_EXIT=$?

# uvicorn exited (normally or via signal). Reap chromadb too before exit.
kill -TERM "$CHROMA_PID" 2>/dev/null || true
wait "$CHROMA_PID" 2>/dev/null || true

log "uvicorn exited with $UVI_EXIT; chromadb reaped; container shutting down"
exit "$UVI_EXIT"
