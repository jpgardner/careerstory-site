# Phase 1 Runbook

This document is the handoff to whichever CLI agent is going to actually
stand up the CareerStory hosting service. Read top to bottom once before
running anything.

Goal: take a fresh Hetzner box from nothing to "first paying client lives
at their custom domain over HTTPS, Stripe billing on, monitor green."

Recurring price: **$10/month** (Stripe Price object should be `unit_amount=1000`).

---

## Decisions baked into this runbook

These were open in the plan. Defaults below. Override only with reason.

1. **Active client migration.** New clients only for Phase 1. Amanda
   (Netlify), Lydia, Emerson, Minerva stay on whatever they are on
   today. Cut them over in a planned Phase 2 window once the VPS is
   proven by at least one new paying client.

2. **Cloudflare zone ownership.** Operator's Cloudflare account holds
   every client zone during the subscription. `offboard.sh` triggers a
   transfer-out when a client leaves. Trust optic: address it in the
   onboarding email by saying we hold the zone for ops simplicity and
   will hand it back any time on request.

3. **Email default.** ImprovMX free forwarding (`hello@<domain>` to the
   client's real inbox). Workspace passthrough is a later upsell, not
   default. Already wired in `onboard.sh`.

---

## Prerequisites (accounts to create, ~30 minutes)

Do these first. You cannot proceed without them.

| Service | What to create | Where |
|---|---|---|
| Hetzner Cloud | Account, project, SSH key uploaded | https://console.hetzner.cloud |
| Cloudflare | Account, API token (scope: `Zone:Edit, DNS:Edit, Zone Settings:Edit, Account: Read`) | https://dash.cloudflare.com/profile/api-tokens |
| ImprovMX | Free account, API key | https://app.improvmx.com/api |
| Stripe | Account in live or test mode, secret key | https://dashboard.stripe.com/apikeys |
| Stripe Product + Price | One Product "CareerStory Hosting", recurring Price `$10/mo` (`unit_amount=1000, currency=usd, recurring.interval=month`) | https://dashboard.stripe.com/products |
| Stripe Webhook endpoint | URL = `https://<marketing-host>/api/stripe-webhook`, events = `invoice.payment_failed`, `invoice.payment_succeeded`, `customer.subscription.deleted`. Copy the signing secret. | https://dashboard.stripe.com/webhooks |
| UptimeRobot | Free account, main API key | https://uptimerobot.com/dashboard#mySettings |
| GitHub | The deploy SSH keypair (next step) and three repo secrets | This repo's Settings > Secrets |

The marketing host is the public domain for the operator's own site
plus the Stripe webhook path. For consistency with the existing copy
this is `careerstory.pro`. If you pick a different one, update
`infra/Caddyfile` in two places before deploy.

---

## Credentials checklist (.env on operator laptop)

Copy `infra/.env.example` to `infra/.env` and fill in. The onboard /
offboard scripts read this file via `set -a; . .env; set +a`.

```
CLOUDFLARE_API_TOKEN=...
CLOUDFLARE_ACCOUNT_ID=...
VPS_IP=...                     # set after step 1
VPS_HOST=...                   # the marketing host from above
IMPROVMX_API_KEY=...
STRIPE_SECRET_KEY=sk_...
STRIPE_PRICE_ID=price_...
UPTIMEROBOT_API_KEY=...
```

The VPS itself reads `/etc/careerstory/sidecar.env` (different file, set
during provisioning). Only Stripe values go there.

---

## Step 1. Provision the VPS (~15 minutes)

1. In Hetzner, create a CX22 in Ashburn (`us-east`) running Ubuntu
   24.04 LTS. Attach your SSH key. Note the public IPv4.

2. Set DNS for the marketing host so the Stripe webhook URL works
   later. In Cloudflare, the marketing host's A record should point at
   the same VPS IP, proxied. (Reuse the existing zone if you already
   own one.)

3. SSH in as `root`:
   ```bash
   ssh root@<VPS_IP>
   apt-get update && apt-get install -y git
   git clone https://github.com/jpgardner/careerstory-site.git
   cd careerstory-site
   ./infra/bin/provision-vps.sh
   ```
   The script is idempotent. Re-run if anything fails.

4. Populate the sidecar env file:
   ```bash
   cat > /etc/careerstory/sidecar.env <<EOF
   PORT=9000
   CLIENTS_JSON=/etc/careerstory/clients.json
   STRIPE_SECRET_KEY=sk_...
   STRIPE_WEBHOOK_SECRET=whsec_...
   GRACE_DAYS=14
   EOF
   chmod 600 /etc/careerstory/sidecar.env
   systemctl restart careerstory-sidecar
   curl -fsS http://127.0.0.1:9000/healthz
   ```

   Healthz should return `{"ok":true,"registry":"0 clients",...}`.

5. Generate a CI deploy key locally on your laptop, NOT on the VPS:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/careerstory_deploy -N "" -C "careerstory-ci"
   ```
   Paste the public half into the VPS:
   ```bash
   ssh root@<VPS_IP> "echo '<public key>' >> /home/careerstory/.ssh/authorized_keys"
   ```
   Test the deploy user can ssh:
   ```bash
   ssh -i ~/.ssh/careerstory_deploy careerstory@<VPS_IP> "id"
   ```

6. Add three secrets in this repo's Settings > Secrets and variables >
   Actions:
   - `VPS_SSH_PRIVATE_KEY` = contents of `~/.ssh/careerstory_deploy`
   - `VPS_HOST` = the VPS IP or marketing host
   - `VPS_KNOWN_HOSTS` = output of `ssh-keyscan <VPS_IP>` from your
     laptop

---

## Step 2. Wire the Stripe webhook (~5 minutes)

1. Confirm the marketing host's DNS is pointing at the VPS and
   propagated. `dig +short <marketing-host>` should return the VPS IP
   (or a Cloudflare proxy IP if the zone is proxied).

2. In Stripe Dashboard, create a webhook with URL
   `https://<marketing-host>/api/stripe-webhook` and the three events
   listed in the prerequisites table. Copy the signing secret into
   `/etc/careerstory/sidecar.env` as `STRIPE_WEBHOOK_SECRET`. Restart
   the sidecar.

3. Click "Send test webhook" in Stripe for a `customer.subscription.deleted`
   event. The sidecar log should show signature verification passing
   even if no clients.json entry matches.
   ```bash
   ssh root@<VPS_IP> "journalctl -u careerstory-sidecar -n 50"
   ```

---

## Step 3. First test client (~10 minutes)

The point of Phase 1 is to prove the path end to end before we trust
it for a real paying client. Use a domain you control as the test
target. Buying a $9 throwaway domain is fine.

1. On your laptop, drop a minimal HTML file:
   ```bash
   mkdir -p clients/test.<your-domain>
   cat > clients/test.<your-domain>/index.html <<'EOF'
   <!doctype html>
   <html><head><title>Test</title></head>
   <body><h1>It works.</h1></body></html>
   EOF
   ```

2. Run validate locally first:
   ```bash
   ./infra/bin/validate.sh clients/test.<your-domain>/index.html
   ```

3. Source the env and run onboard:
   ```bash
   set -a; . infra/.env; set +a
   ./infra/bin/onboard.sh test.<your-domain> "Test Client" you@example.com
   ```

   The script prints the Cloudflare nameservers if the zone was newly
   created. Point your registrar at them.

4. Commit and push to `main`:
   ```bash
   git add clients/ infra/clients.json
   git commit -m "Onboard test client"
   git push origin main
   ```

   GitHub Actions runs `validate.sh` then rsyncs to the VPS.

5. Once DNS propagates, hit the domain from a different network than
   the VPS:
   ```bash
   curl -I https://test.<your-domain>
   ```

   First request triggers Caddy on-demand TLS issuance via the sidecar
   `/check` gate. Expect `200 OK`. If you get `421` or a TLS error, see
   troubleshooting at the bottom.

---

## Step 4. Verification checklist

- [ ] `curl -I https://test.<your-domain>` returns 200 with valid TLS
- [ ] `curl https://<marketing-host>/api/stripe-webhook` returns 400
      "missing signature" (proves the webhook path is reachable)
- [ ] `journalctl -u careerstory-sidecar` shows recent log entries
      for `/check` hits
- [ ] UptimeRobot dashboard shows the test domain monitor as up
- [ ] Stripe Dashboard shows the test customer with an open invoice
- [ ] ImprovMX dashboard shows the domain with the alias
- [ ] `cat infra/clients.json` contains the test client entry with
      `status=active`

If all green, Phase 1 is done.

---

## Step 5. First real paying client

Same as Step 3 but with the real domain, real client name, real
email. One change: send the Stripe hosted invoice URL (the script
prints it) to the client. Once they pay, Stripe fires
`invoice.payment_succeeded` which the sidecar logs but does not need
to act on (`status` stays `active`).

---

## Troubleshooting

**TLS handshake fails on first request.** Caddy on-demand TLS calls
`http://127.0.0.1:9000/check?domain=<host>`. If the sidecar is down or
the host is missing from clients.json, Caddy refuses to issue. Fix:
verify the sidecar is up and the domain is in clients.json with
`status=active` or `grace`.

**Cloudflare proxy returns 522.** The proxy is reaching Caddy but
Caddy isn't binding. Check `systemctl status caddy` and the Caddyfile
syntax with `caddy validate --config /etc/caddy/Caddyfile`.

**rsync from CI fails with permission denied.** The `careerstory`
user is in the `caddy` group and `/srv/careerstory/sites` is
group-writable. If permissions drift, on the VPS:
```bash
chown -R caddy:caddy /srv/careerstory/sites
chmod -R g+rwX /srv/careerstory/sites
```

**Validator flags a Cloudflare obfuscation tag.** Strip it from the
source HTML in `clients/<domain>/index.html`. Brief Section 8.4. The
validator deliberately does not auto-fix.

---

## What is NOT in scope for Phase 1

- Migrating Amanda, Lydia, Emerson, Minerva. Defer to Phase 2.
- Quarterly content update tracking enforcement. Soft tracked in
  `clients.json.updates_used_this_quarter`, not enforced anywhere.
- Backups beyond Hetzner daily snapshots and git history.
- The 11-item add-on roadmap. Each add-on plugs in after Phase 1.
- Status page at `status.careerstory.<tld>`. Use UptimeRobot's free
  hosted page until justified.
