#!/usr/bin/env bash
# Onboard a new CareerStory hosting client.
#
# Usage:
#   onboard.sh <domain> <client-name> <client-email> [--alias hello]
#
# Example:
#   onboard.sh amanda-logan.com "Amanda Logan" amanda@gmail.com
#
# Prereqs:
#   1. The client's site exists at clients/<domain>/index.html and passes validate.sh
#   2. DNS is being managed via Cloudflare (zone created or about to be)
#   3. Required env vars present (see require_env below)
#
# Idempotent: re-runnable if a step fails midway.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_lib.sh"

require_cmd curl jq

if [ "$#" -lt 3 ]; then
  echo "usage: onboard.sh <domain> <client-name> <client-email> [--alias hello]" >&2
  exit 2
fi

DOMAIN="$1"
CLIENT_NAME="$2"
CLIENT_EMAIL="$3"
shift 3

ALIAS_LOCAL="hello"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --alias) ALIAS_LOCAL="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done

require_env CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID VPS_IP \
            IMPROVMX_API_KEY \
            STRIPE_SECRET_KEY STRIPE_PRICE_ID \
            UPTIMEROBOT_API_KEY

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SITE_HTML="$REPO_ROOT/clients/$DOMAIN/index.html"

# 1. Validate
log "validating $SITE_HTML"
[ -f "$SITE_HTML" ] || die "no client HTML at $SITE_HTML, drop the file there first"
"$HERE/validate.sh" "$SITE_HTML"

# 2. Cloudflare zone (create or import existing)
log "ensuring cloudflare zone for $DOMAIN"
ZONE_ID=$(cf_zone_id "$DOMAIN")
if [ -z "$ZONE_ID" ]; then
  log "creating zone"
  resp=$(cf_create_zone "$DOMAIN")
  ZONE_ID=$(echo "$resp" | jq -r '.result.id // empty')
  [ -n "$ZONE_ID" ] || die "zone create failed: $resp"
  ns=$(echo "$resp" | jq -r '.result.name_servers | join(", ")')
  log "zone created. nameservers: $ns"
  log "ACTION REQUIRED: point the domain registrar at the cloudflare nameservers above"
else
  log "zone already present: $ZONE_ID"
fi

# 3. DNS A record + 4. email obfuscation off + Always HTTPS + Full Strict
log "setting A record to $VPS_IP (proxied)"
cf_upsert_a_record "$ZONE_ID" "$DOMAIN"
log "disabling cloudflare email obfuscation (brief Section 8.4)"
cf_disable_email_obfuscation "$ZONE_ID"
log "enabling Always Use HTTPS"
cf_set_always_use_https "$ZONE_ID"
log "setting SSL mode to Full (strict)"
cf_set_ssl_full_strict "$ZONE_ID"

# 5. ImprovMX forwarding
log "creating ImprovMX domain + alias $ALIAS_LOCAL@$DOMAIN -> $CLIENT_EMAIL"
improvmx_create_domain "$DOMAIN"
improvmx_create_alias "$DOMAIN" "$ALIAS_LOCAL" "$CLIENT_EMAIL"

# 6. Stripe customer + subscription
log "creating stripe customer"
CUSTOMER_RESP=$(stripe_create_customer "$CLIENT_NAME" "$CLIENT_EMAIL" "$DOMAIN")
CUSTOMER_ID=$(echo "$CUSTOMER_RESP" | jq -r '.id // empty')
[ -n "$CUSTOMER_ID" ] || die "stripe customer create failed: $CUSTOMER_RESP"

log "creating stripe subscription"
SUB_RESP=$(stripe_create_subscription "$CUSTOMER_ID" "$STRIPE_PRICE_ID")
SUB_ID=$(echo "$SUB_RESP" | jq -r '.id // empty')
INVOICE_URL=$(echo "$SUB_RESP" | jq -r '.latest_invoice.hosted_invoice_url // empty')
[ -n "$SUB_ID" ] || die "stripe sub create failed: $SUB_RESP"

# 7. UptimeRobot monitor
log "creating uptimerobot monitor"
UR_RESP=$(uptimerobot_create_monitor "$DOMAIN")
UR_ID=$(echo "$UR_RESP" | jq -r '.monitor.id // empty')

# 8. clients.json upsert
log "upserting clients.json"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -nc \
  --arg domain "$DOMAIN" \
  --arg client "$CLIENT_NAME" \
  --arg cust "$CUSTOMER_ID" \
  --arg sub "$SUB_ID" \
  --arg now "$NOW" \
  --arg email_alias "$ALIAS_LOCAL@$DOMAIN -> $CLIENT_EMAIL" \
  --arg ur "$UR_ID" \
  '{
    domain: $domain,
    client: $client,
    status: "active",
    stripe_customer_id: $cust,
    stripe_subscription_id: $sub,
    onboarded_at: $now,
    current_version_file: ($domain + "/index.html"),
    updates_used_this_quarter: 0,
    email_alias: $email_alias,
    uptimerobot_id: $ur
  }' | clients_upsert

cat <<EOF

onboarding complete for $DOMAIN

  client            $CLIENT_NAME
  email             $CLIENT_EMAIL
  forwarding alias  $ALIAS_LOCAL@$DOMAIN -> $CLIENT_EMAIL
  stripe customer   $CUSTOMER_ID
  stripe sub        $SUB_ID
  invoice link      ${INVOICE_URL:-(check stripe dashboard)}
  uptimerobot       ${UR_ID:-(none)}

next steps:
  1. send the invoice link to the client
  2. confirm the registrar nameservers are pointed at cloudflare
  3. commit clients.json + clients/$DOMAIN/ and push to main
     (CI rsyncs to the VPS, then first hit triggers Caddy on-demand TLS)
EOF
