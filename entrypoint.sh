#!/bin/bash
# Kener entrypoint for Railway.
#
# Claims the owner account over loopback so the public listener never opens with
# the admin seat free, kicks off a one-shot repair of the stored siteURL setting,
# then hands over to the image's own entrypoint.
set -eo pipefail

LIB=/usr/local/lib/kener-railway

log() { echo "[kener-railway] $*"; }

# --- Platform defaults ------------------------------------------------------
: "${PORT:=3000}"
export PORT

# ORIGIN is what SvelteKit compares every form POST's Origin header against, and
# what decides whether the session cookie gets its Secure flag. A deployment that
# has a public domain can always answer this itself, so default it rather than
# letting a missing value reject every login.
if [ -z "${ORIGIN:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  ORIGIN="https://${RAILWAY_PUBLIC_DOMAIN}"
  export ORIGIN
  log "ORIGIN was unset, defaulted to ${ORIGIN}"
fi

if [ -z "${ORIGIN:-}" ]; then
  log "WARNING: ORIGIN is unset — every form submission will be rejected as cross-site."
fi

if [ -z "${REDIS_URL:-}" ]; then
  log "WARNING: REDIS_URL is unset — Kener needs Redis for its monitor scheduler."
fi

if [ -z "${DATABASE_URL:-}" ]; then
  log "WARNING: DATABASE_URL is unset — falling back to SQLite under /app/database,"
  log "WARNING: which is container-local storage and is lost on every deploy."
fi

# --- ICMP diagnostic ---------------------------------------------------------
# Kener's Ping monitor type shells out to iputils, which needs either CAP_NET_RAW
# or an ICMP datagram socket. Railway grants neither, and the app can only report
# the result as "host is unreachable" — indistinguishable from a real outage. Say
# so once, here, where it is provably measured inside the real container.
if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
  log "ICMP is available; Ping monitors will work."
else
  log "NOTE: ICMP is not permitted in this container (CAP_NET_RAW dropped and"
  log "NOTE: net.ipv4.ping_group_range is $(cat /proc/sys/net/ipv4/ping_group_range 2>/dev/null | tr '\t' ' ')),"
  log "NOTE: so Kener's Ping monitors will always report DOWN. Use a TCP Port,"
  log "NOTE: DNS or HTTP/API monitor for the same targets instead."
fi

# --- Owner account ----------------------------------------------------------
# Kener has no signup page. /account/signin exposes a `signup` form action that
# succeeds while the users table is empty, so a public deployment gives the admin
# seat to the first visitor. Seed it here, against a listener bound to loopback.
if [ -n "${KENER_ADMIN_EMAIL:-}" ] && [ -n "${KENER_ADMIN_PASSWORD:-}" ]; then
  USER_COUNT="$(node "$LIB/users-count.mjs" || echo unknown)"

  if [ "$USER_COUNT" != "0" ] && [ "$USER_COUNT" != "unknown" ]; then
    log "${USER_COUNT} account(s) already exist, skipping the loopback bootstrap"
  else
    BOOTSTRAP_PORT="${KENER_BOOTSTRAP_PORT:-3999}"
    BOOTSTRAP_URL="http://127.0.0.1:${BOOTSTRAP_PORT}"
    BOOT_LOG="$(mktemp)"
    log "seeding the owner account over loopback on ${BOOTSTRAP_URL}"

    # ORIGIN follows the loopback address so this instance's CSRF check accepts
    # the seeding request, and PORT keeps the public port free until it is gone.
    env PORT="$BOOTSTRAP_PORT" ORIGIN="$BOOTSTRAP_URL" node build/main.js >"$BOOT_LOG" 2>&1 &
    BOOTSTRAP_PID=$!

    # Railway only shows what reaches stdout, and the bootstrap instance is where
    # a failed migration would be explained, so mirror its log out as it lands.
    tail -n +1 -f "$BOOT_LOG" | sed -u 's/^/[kener-bootstrap] /' &
    TAIL_PID=$!

    if KENER_BOOTSTRAP_URL="$BOOTSTRAP_URL" \
       KENER_BOOTSTRAP_LOG="$BOOT_LOG" \
       KENER_BOOTSTRAP_READY_MARKER="Kener is running on port ${BOOTSTRAP_PORT}!" \
       node "$LIB/seed-admin.mjs"; then
      log "owner account is in place"
    else
      log "WARNING: owner seeding did not complete — the public instance still starts,"
      log "WARNING: so claim the account yourself at ${ORIGIN:-the public URL}/account/signin NOW."
    fi

    kill "$BOOTSTRAP_PID" 2>/dev/null || true
    for _ in $(seq 1 30); do
      kill -0 "$BOOTSTRAP_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$BOOTSTRAP_PID" 2>/dev/null || true
    wait "$BOOTSTRAP_PID" 2>/dev/null || true
    kill "$TAIL_PID" 2>/dev/null || true
    rm -f "$BOOT_LOG"
    log "loopback bootstrap instance stopped"
  fi
else
  log "WARNING: KENER_ADMIN_EMAIL/KENER_ADMIN_PASSWORD are unset, so no owner account"
  log "WARNING: could be seeded. Kener grants the owner seat to the first person who"
  log "WARNING: submits the form at /account/signin — claim it as soon as this is up."
fi

# --- Stored settings --------------------------------------------------------
# Behind the exec, so a cold boot is not delayed by it: the app writes the row
# this repairs only after it has started listening.
( node "$LIB/repair-site-url.mjs" || true ) &

# --- Serve ------------------------------------------------------------------
log "starting kener on port ${PORT} (origin: ${ORIGIN:-unset})"
exec /app/docker-entrypoint.sh "$@"
