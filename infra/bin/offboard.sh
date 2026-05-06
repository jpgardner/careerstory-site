#!/usr/bin/env bash
# Offboard a CareerStory hosting client.
#
# Usage:
#   offboard.sh <domain> [--keep-zone] [--no-archive]
#
# What this does (in order, all best-effort):
#   1. Builds clients/<domain>/<domain>.zip via git archive (the "we hand
#      you the HTML if you ever leave" promise from index.html:1100).
#   2. Cancels the Stripe subscription.
#   3. Deletes the ImprovMX domain (and all aliases).
#   4. Deletes the UptimeRobot monitor.
#   5. Deletes the Cloudflare zone unless --keep-zone is passed.
#      The client should transfer to their own registrar before you
#      delete, otherwise the zone goes to whoever holds the registrar
#      record. In most cases pass --keep-zone and resolve later.
#   6. Marks the client status=offboarded in clients.json.
#   7. Removes clients/<domain>/ on disk (next push to main rsyncs
#      the deletion to the VPS via --delete).
#
# Idempotent. Safe to re-run after partial failure.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_lib.sh"

require_cmd curl jq git

if [ "$#" -lt 1 ]; then
  echo "usage: offboard.sh <domain> [--keep-zone] [--no-archive]" >&2
  exit 2
fi

DOMAIN="$1"; shift
KEEP_ZONE=0
ARCHIVE=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep-zone) KEEP_ZONE=1; shift ;;
    --no-archive) ARCHIVE=0; shift ;;
    *) die "unknown flag: $1" ;;
  esac
done

require_env CLOUDFLARE_API_TOKEN \
            IMPROVMX_API_KEY \
            STRIPE_SECRET_KEY \
            UPTIMEROBOT_API_KEY

REPO_ROOT="$(cd "$HERE/../.." && pwd)"

ENTRY=$(clients_get "$DOMAIN")
if [ -z "$ENTRY" ] || [ "$ENTRY" = "null" ]; then
  warn "no clients.json entry for $DOMAIN, proceeding anyway"
fi

CUSTOMER_ID=$(echo "$ENTRY" | jq -r '.stripe_customer_id // empty')
SUB_ID=$(echo "$ENTRY" | jq -r '.stripe_subscription_id // empty')
UR_ID=$(echo "$ENTRY" | jq -r '.uptimerobot_id // empty')

# 1. Archive
if [ "$ARCHIVE" = 1 ] && [ -d "$REPO_ROOT/clients/$DOMAIN" ]; then
  ARCHIVE_PATH="$REPO_ROOT/clients/$DOMAIN/${DOMAIN}.zip"
  log "archiving clients/$DOMAIN/ to $ARCHIVE_PATH"
  ( cd "$REPO_ROOT" && git archive --format=zip -o "$ARCHIVE_PATH" HEAD -- "clients/$DOMAIN" )
  log "archive ready. email it to the client before removing the folder."
fi

# 2. Stripe
if [ -n "$SUB_ID" ]; then
  log "cancelling stripe subscription $SUB_ID"
  stripe_cancel_subscription "$SUB_ID" || warn "stripe cancel failed, check dashboard"
else
  warn "no stripe_subscription_id on file"
fi

# 3. ImprovMX
log "removing ImprovMX domain $DOMAIN"
improvmx_delete_domain "$DOMAIN"

# 4. UptimeRobot
if [ -n "$UR_ID" ]; then
  log "deleting uptimerobot monitor $UR_ID"
  uptimerobot_delete_monitor "$UR_ID"
fi

# 5. Cloudflare zone
if [ "$KEEP_ZONE" = 1 ]; then
  log "keeping cloudflare zone (transfer/cleanup later)"
else
  ZONE_ID=$(cf_zone_id "$DOMAIN")
  if [ -n "$ZONE_ID" ]; then
    log "deleting cloudflare zone $ZONE_ID"
    cf_delete_zone "$ZONE_ID"
  fi
fi

# 6. clients.json
log "marking $DOMAIN status=offboarded"
clients_set_status "$DOMAIN" offboarded

# 7. Disk
if [ -d "$REPO_ROOT/clients/$DOMAIN" ]; then
  log "removing clients/$DOMAIN/ from working tree"
  rm -rf "$REPO_ROOT/clients/$DOMAIN"
fi

cat <<EOF

offboarding complete for $DOMAIN

  stripe customer   ${CUSTOMER_ID:-(none on file)}
  stripe sub        ${SUB_ID:-(none on file)} cancelled
  improvmx          domain removed
  uptimerobot       ${UR_ID:-(none on file)} deleted
  cloudflare zone   $([ "$KEEP_ZONE" = 1 ] && echo "kept" || echo "deleted")
  clients.json      status=offboarded

next steps:
  1. commit clients.json + the deleted clients/$DOMAIN/ folder
  2. push to main, CI rsyncs the deletion to the VPS
  3. email the archive zip to the client (if generated)
EOF
