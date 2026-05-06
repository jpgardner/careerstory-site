#!/usr/bin/env bash
# Idempotent bootstrap for a fresh Ubuntu 24.04 VPS.
# Run as root on the box. Safe to re-run.
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/careerstory-site/main/infra/bin/provision-vps.sh | sudo bash
#
# Or after a git clone on the box:
#   sudo ./infra/bin/provision-vps.sh
#
# Required env vars on first run (set in /etc/careerstory/sidecar.env afterward):
#   STRIPE_SECRET_KEY        live or test key
#   STRIPE_WEBHOOK_SECRET    from the Stripe webhook config
#
# What this does:
#   1. apt update + base packages
#   2. installs Caddy 2 from the official apt repo
#   3. installs Node 20 from NodeSource
#   4. creates /srv/careerstory/sites and /etc/careerstory
#   5. creates the deploy user 'careerstory' for rsync from GitHub Actions
#   6. installs the sidecar to /opt/careerstory-sidecar with a systemd unit
#   7. drops the Caddyfile at /etc/caddy/Caddyfile and reloads
#   8. opens ufw 22, 80, 443

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root" >&2
  exit 1
fi

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
DEPLOY_USER="${DEPLOY_USER:-careerstory}"
SITES_DIR="/srv/careerstory/sites"
ETC_DIR="/etc/careerstory"
SIDECAR_DIR="/opt/careerstory-sidecar"

echo "==> repo: $REPO_DIR"
echo "==> deploy user: $DEPLOY_USER"

echo "==> apt update + base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl gnupg ca-certificates rsync ufw debian-keyring debian-archive-keyring apt-transport-https

if ! command -v caddy >/dev/null 2>&1; then
  echo "==> installing Caddy"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -y
  apt-get install -y caddy
fi

if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -c2- | cut -d. -f1)" -lt 20 ]; then
  echo "==> installing Node 20"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

echo "==> creating directories"
mkdir -p "$SITES_DIR" "$ETC_DIR" "$SIDECAR_DIR" /var/log/caddy
chown -R caddy:caddy "$SITES_DIR" /var/log/caddy

if [ ! -f "$ETC_DIR/clients.json" ]; then
  echo '{ "version": 1, "clients": [] }' > "$ETC_DIR/clients.json"
fi
chmod 644 "$ETC_DIR/clients.json"

if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "==> creating deploy user $DEPLOY_USER"
  useradd -m -s /bin/bash "$DEPLOY_USER"
  mkdir -p "/home/$DEPLOY_USER/.ssh"
  touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chmod 700 "/home/$DEPLOY_USER/.ssh"
  chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
  chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
fi

# Let the deploy user write to the sites dir without owning Caddy.
usermod -aG caddy "$DEPLOY_USER" || true
chmod g+w "$SITES_DIR"

echo "==> installing sidecar to $SIDECAR_DIR"
cp "$REPO_DIR/infra/sidecar/server.js" "$SIDECAR_DIR/server.js"
cp "$REPO_DIR/infra/sidecar/package.json" "$SIDECAR_DIR/package.json"
(cd "$SIDECAR_DIR" && npm install --omit=dev --no-audit --no-fund)

if [ ! -f "$ETC_DIR/sidecar.env" ]; then
  cat > "$ETC_DIR/sidecar.env" <<'EOF'
# Populate before starting careerstory-sidecar.
PORT=9000
CLIENTS_JSON=/etc/careerstory/clients.json
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=
GRACE_DAYS=14
EOF
  chmod 600 "$ETC_DIR/sidecar.env"
fi

cat > /etc/systemd/system/careerstory-sidecar.service <<EOF
[Unit]
Description=CareerStory edge sidecar
After=network.target

[Service]
Type=simple
EnvironmentFile=$ETC_DIR/sidecar.env
WorkingDirectory=$SIDECAR_DIR
ExecStart=/usr/bin/node $SIDECAR_DIR/server.js
Restart=on-failure
RestartSec=2
User=caddy
Group=caddy
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$ETC_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable careerstory-sidecar
systemctl restart careerstory-sidecar

echo "==> installing Caddyfile"
cp "$REPO_DIR/infra/Caddyfile" /etc/caddy/Caddyfile
systemctl enable caddy
systemctl reload caddy || systemctl restart caddy

echo "==> firewall"
ufw allow 22/tcp || true
ufw allow 80/tcp || true
ufw allow 443/tcp || true
ufw --force enable || true

echo
echo "provisioning complete."
echo
echo "next steps:"
echo "  1. edit $ETC_DIR/sidecar.env with Stripe keys"
echo "  2. systemctl restart careerstory-sidecar"
echo "  3. paste your CI deploy public key into /home/$DEPLOY_USER/.ssh/authorized_keys"
echo "  4. test: curl http://127.0.0.1:9000/healthz"
