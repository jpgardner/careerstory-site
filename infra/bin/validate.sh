#!/usr/bin/env bash
# Deploy gate for CareerStory client HTML files.
# Implements the checks called out in the audit brief, Section 8.
# Usage: validate.sh <path-to-html> [<path-to-html> ...]
# Exits non-zero on any failure. CI uses this to block rsync.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: validate.sh <html-file> [<html-file> ...]" >&2
  exit 2
fi

require_node() {
  if ! command -v node >/dev/null 2>&1; then
    echo "FAIL: node is required for syntax validation" >&2
    exit 2
  fi
}
require_node

fail=0
warn=0

# Known third-party globals that should be typeof-guarded before use.
# Heuristic, not exhaustive. Add as we adopt new libs.
THIRD_PARTY_GLOBALS=(emailjs gapi Stripe Plausible plausible)

for file in "$@"; do
  echo "validating $file"

  if [ ! -f "$file" ]; then
    echo "  FAIL: file not found" >&2
    fail=$((fail + 1))
    continue
  fi

  # 8.4 Strip Cloudflare email obfuscation injection.
  # We do not auto-strip in CI. We fail and tell the operator to fix the source.
  if grep -qE '<script[^>]*data-cfasync' "$file"; then
    echo "  FAIL: <script data-cfasync> tag present (Cloudflare email obfuscation injection, brief Section 8.4)" >&2
    fail=$((fail + 1))
  fi

  # 8.1 Script tag balance.
  open_count=$(grep -oE '<script\b[^>]*>' "$file" | wc -l | tr -d ' ')
  close_count=$(grep -oE '</script>' "$file" | wc -l | tr -d ' ')
  if [ "$open_count" != "$close_count" ]; then
    echo "  FAIL: script tag imbalance ($open_count open, $close_count close, brief Section 8.1)" >&2
    fail=$((fail + 1))
  fi

  # 8.1 node --check on extracted JS.
  # Concatenate every inline script body. Skip blocks with src= attribute.
  js_extract=$(mktemp /tmp/cs-validate-XXXXXX.js)
  trap 'rm -f "$js_extract"' EXIT

  node -e '
    const fs = require("fs");
    const html = fs.readFileSync(process.argv[1], "utf8");
    const out = [];
    const re = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
    let m;
    while ((m = re.exec(html)) !== null) {
      const attrs = m[1] || "";
      if (/\bsrc\s*=/.test(attrs)) continue;
      if (/\btype\s*=\s*["\x27](?!text\/javascript|module|application\/javascript)/i.test(attrs)) continue;
      out.push(m[2]);
    }
    fs.writeFileSync(process.argv[2], out.join("\n;\n"));
  ' "$file" "$js_extract"

  if ! node --check "$js_extract" 2> /tmp/cs-validate-err; then
    echo "  FAIL: node --check failed on extracted JS (brief Section 8.1)" >&2
    sed 's/^/    /' /tmp/cs-validate-err >&2
    fail=$((fail + 1))
  fi
  rm -f "$js_extract" /tmp/cs-validate-err
  trap - EXIT

  # 8.2 typeof guards for known third-party globals.
  # Soft warning. Catches obvious cases like a bare `gapi.client.init()` with no guard.
  for g in "${THIRD_PARTY_GLOBALS[@]}"; do
    if grep -qE "\\b$g\\b" "$file"; then
      if ! grep -qE "typeof[[:space:]]+$g[[:space:]]*[!=]==?[[:space:]]*[\"']undefined[\"']" "$file"; then
        echo "  WARN: '$g' referenced without a typeof guard nearby (brief Section 8.2)"
        warn=$((warn + 1))
      fi
    fi
  done

  if [ "$fail" -eq 0 ]; then
    echo "  OK"
  fi
done

echo
echo "summary: $fail failure(s), $warn warning(s)"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
