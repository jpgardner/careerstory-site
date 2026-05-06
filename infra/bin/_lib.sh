#!/usr/bin/env bash
# Shared helpers for onboard.sh and offboard.sh.
# All API calls use curl + jq. Source this from sibling scripts:
#   . "$(dirname "$0")/_lib.sh"

set -euo pipefail

require_cmd() {
  for c in "$@"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "missing required command: $c" >&2
      exit 2
    fi
  done
}

require_env() {
  for v in "$@"; do
    if [ -z "${!v:-}" ]; then
      echo "missing required env var: $v" >&2
      exit 2
    fi
  done
}

log()  { echo "==> $*"; }
warn() { echo "warn: $*" >&2; }
die()  { echo "fail: $*" >&2; exit 1; }

# ---- Cloudflare ------------------------------------------------------------

cf_api() {
  # Usage: cf_api METHOD PATH [BODY]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "https://api.cloudflare.com/client/v4$path"
}

cf_zone_id() {
  # Echo zone id for $1, empty if not present in operator account.
  cf_api GET "/zones?name=$1" | jq -r '.result[0].id // empty'
}

cf_create_zone() {
  local domain="$1"
  cf_api POST "/zones" "$(jq -nc --arg n "$domain" --arg a "$CLOUDFLARE_ACCOUNT_ID" \
    '{name:$n, account:{id:$a}, jump_start:false, type:"full"}')"
}

cf_upsert_a_record() {
  # Replaces any existing A record for $domain with one pointing at $VPS_IP, proxied.
  local zone_id="$1" domain="$2"
  local existing
  existing=$(cf_api GET "/zones/$zone_id/dns_records?type=A&name=$domain" \
    | jq -r '.result[].id')
  for id in $existing; do
    cf_api DELETE "/zones/$zone_id/dns_records/$id" >/dev/null
  done
  cf_api POST "/zones/$zone_id/dns_records" "$(jq -nc \
    --arg n "$domain" --arg c "$VPS_IP" \
    '{type:"A", name:$n, content:$c, ttl:1, proxied:true}')" >/dev/null
}

cf_disable_email_obfuscation() {
  # Brief Section 8.4: this injection corrupts client JS. Off on every zone.
  local zone_id="$1"
  cf_api PATCH "/zones/$zone_id/settings/email_obfuscation" \
    '{"value":"off"}' >/dev/null
}

cf_set_always_use_https() {
  local zone_id="$1"
  cf_api PATCH "/zones/$zone_id/settings/always_use_https" \
    '{"value":"on"}' >/dev/null
}

cf_set_ssl_full_strict() {
  local zone_id="$1"
  cf_api PATCH "/zones/$zone_id/settings/ssl" \
    '{"value":"strict"}' >/dev/null
}

cf_delete_zone() {
  local zone_id="$1"
  cf_api DELETE "/zones/$zone_id" >/dev/null
}

# ---- ImprovMX --------------------------------------------------------------

improvmx_api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" \
    -u "api:$IMPROVMX_API_KEY" \
    -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "https://api.improvmx.com/v3$path"
}

improvmx_create_domain() {
  local domain="$1"
  improvmx_api POST "/domains/" "$(jq -nc --arg d "$domain" '{domain:$d}')" >/dev/null || true
}

improvmx_create_alias() {
  local domain="$1" alias_local="$2" forward_to="$3"
  improvmx_api POST "/domains/$domain/aliases/" \
    "$(jq -nc --arg a "$alias_local" --arg f "$forward_to" '{alias:$a, forward:$f}')" >/dev/null
}

improvmx_delete_domain() {
  local domain="$1"
  improvmx_api DELETE "/domains/$domain" >/dev/null || true
}

# ---- Stripe ---------------------------------------------------------------

stripe_api() {
  local method="$1" path="$2"
  shift 2
  local args=(-sS -X "$method" -u "$STRIPE_SECRET_KEY:")
  for kv in "$@"; do
    args+=(-d "$kv")
  done
  curl "${args[@]}" "https://api.stripe.com/v1$path"
}

stripe_create_customer() {
  local name="$1" email="$2" domain="$3"
  stripe_api POST "/customers" \
    "name=$name" "email=$email" \
    "metadata[domain]=$domain" \
    "metadata[product]=careerstory_hosting"
}

stripe_create_subscription() {
  local customer_id="$1" price_id="$2"
  stripe_api POST "/subscriptions" \
    "customer=$customer_id" \
    "items[0][price]=$price_id" \
    "collection_method=send_invoice" \
    "days_until_due=7"
}

stripe_cancel_subscription() {
  local sub_id="$1"
  stripe_api DELETE "/subscriptions/$sub_id" >/dev/null
}

# ---- UptimeRobot ---------------------------------------------------------

uptimerobot_api() {
  local action="$1"
  shift
  local args=(-sS -X POST \
    -d "api_key=$UPTIMEROBOT_API_KEY" -d "format=json")
  for kv in "$@"; do
    args+=(-d "$kv")
  done
  curl "${args[@]}" "https://api.uptimerobot.com/v2/$action"
}

uptimerobot_create_monitor() {
  local domain="$1"
  uptimerobot_api newMonitor \
    "friendly_name=$domain" \
    "url=https://$domain" \
    "type=1" \
    "interval=300"
}

uptimerobot_delete_monitor() {
  # Best effort. Caller should have monitor_id stashed in clients.json.
  local monitor_id="$1"
  uptimerobot_api deleteMonitor "id=$monitor_id" >/dev/null || true
}

# ---- clients.json (local repo copy) --------------------------------------

CLIENTS_JSON_LOCAL="${CLIENTS_JSON_LOCAL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/clients.json}"

clients_get() {
  jq --arg d "$1" '.clients[] | select(.domain==$d)' "$CLIENTS_JSON_LOCAL"
}

clients_upsert() {
  # stdin: a single client object. Replaces by domain or appends.
  local payload domain tmp
  payload=$(cat)
  domain=$(echo "$payload" | jq -r '.domain')
  tmp=$(mktemp)
  jq --argjson new "$payload" --arg d "$domain" '
    .clients = ((.clients // []) | map(select(.domain != $d)) + [$new])
  ' "$CLIENTS_JSON_LOCAL" > "$tmp"
  mv "$tmp" "$CLIENTS_JSON_LOCAL"
}

clients_set_status() {
  local domain="$1" status="$2" tmp
  tmp=$(mktemp)
  jq --arg d "$domain" --arg s "$status" '
    .clients |= map(if .domain==$d then .status = $s else . end)
  ' "$CLIENTS_JSON_LOCAL" > "$tmp"
  mv "$tmp" "$CLIENTS_JSON_LOCAL"
}
