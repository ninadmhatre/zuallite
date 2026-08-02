#!/usr/bin/env bash
#
# One-shot provisioning for a fresh Ubuntu 24.04 box (netcup VPS 500 G12).
# Sets up the Flask portfolio app only -- run provision-ghost.sh afterwards
# for the blog.
#
# Usage (as root on the new server):
#   DOMAIN=example.com ./provision.sh
#
# Idempotent: safe to re-run.

set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN, e.g. DOMAIN=example.com ./provision.sh}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-ninad.mhatre@gmail.com}"
REPO="${REPO:-https://github.com/ninadmhatre/zuallite.git}"
BRANCH="${BRANCH:-main}"
APP_USER="zuallite"
APP_DIR="/srv/zuallite"

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    ca-certificates curl git nginx ufw fail2ban \
    unattended-upgrades certbot python3-certbot-nginx

log "Enabling unattended security upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades

log "Configuring firewall"
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

log "Installing uv system-wide"
if ! command -v uv >/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
fi

log "Creating ${APP_USER} user"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$APP_DIR" --shell /bin/bash "$APP_USER"
fi
# nginx (www-data) must be able to traverse into static/.
chmod 755 "$APP_DIR"

log "Fetching application"
# useradd already populated the home dir from /etc/skel, so `git clone` would
# refuse it. init + fetch works into a non-empty directory.
if [[ ! -d "$APP_DIR/.git" ]]; then
    sudo -u "$APP_USER" git init -q -b "$BRANCH" "$APP_DIR"
    sudo -u "$APP_USER" git -C "$APP_DIR" remote add origin "$REPO"
fi
# Full history, not --depth=1: remote-deploy.sh rolls back to the previous
# commit when a deploy fails its health check.
sudo -u "$APP_USER" git -C "$APP_DIR" fetch --prune origin
sudo -u "$APP_USER" git -C "$APP_DIR" reset --hard "origin/${BRANCH}"

log "Installing Python dependencies"
sudo -u "$APP_USER" env HOME="$APP_DIR" uv sync --project "$APP_DIR" --extra prod --frozen

log "Installing systemd unit"
install -m 0644 "$APP_DIR/deploy/zuallite.service" /etc/systemd/system/zuallite.service

# SECRET_KEY is unused today (the app has no sessions) but is wired up so that
# adding one later does not require touching the unit file.
if [[ ! -f /etc/zuallite.env ]]; then
    umask 077
    printf 'SECRET_KEY=%s\n' "$(head -c 32 /dev/urandom | base64)" > /etc/zuallite.env
    chown root:"$APP_USER" /etc/zuallite.env
    chmod 640 /etc/zuallite.env
fi

systemctl daemon-reload
systemctl enable --now zuallite
systemctl restart zuallite

log "Allowing ${APP_USER} to restart its own service (for CI deploys)"
cat > /etc/sudoers.d/zuallite-deploy <<EOF
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart zuallite, /usr/bin/systemctl is-active zuallite, /usr/bin/systemctl status zuallite
EOF
chmod 440 /etc/sudoers.d/zuallite-deploy
visudo -cf /etc/sudoers.d/zuallite-deploy

if [[ -n "${DEPLOY_PUBKEY:-}" ]]; then
    log "Installing CI deploy key for ${APP_USER}"
    install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$APP_DIR/.ssh"
    touch "$APP_DIR/.ssh/authorized_keys"
    grep -qxF "$DEPLOY_PUBKEY" "$APP_DIR/.ssh/authorized_keys" \
        || printf '%s\n' "$DEPLOY_PUBKEY" >> "$APP_DIR/.ssh/authorized_keys"
    chown "$APP_USER:$APP_USER" "$APP_DIR/.ssh/authorized_keys"
    chmod 600 "$APP_DIR/.ssh/authorized_keys"
fi

log "Configuring nginx"
# This resets the vhost to its HTTP-only template, discarding certbot's edits.
# That is intentional and self-healing: the certbot step below re-installs the
# TLS listeners straight after.
sed "s/__DOMAIN__/${DOMAIN}/g" "$APP_DIR/deploy/nginx-zuallite.conf" \
    > /etc/nginx/sites-available/zuallite
ln -sfn /etc/nginx/sites-available/zuallite /etc/nginx/sites-enabled/zuallite
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

if [[ -n "${SKIP_CERTBOT:-}" ]]; then
    log "Skipping certbot (SKIP_CERTBOT set) -- re-run this script after DNS cutover"
else
    log "Requesting TLS certificate"
    echo "NOTE: this only succeeds once ${DOMAIN} and www.${DOMAIN} resolve to this box."
    # --keep-until-expiring makes re-runs reinstall the existing certificate
    # instead of failing with "not yet due for renewal".
    certbot --nginx --non-interactive --agree-tos \
        -m "$LETSENCRYPT_EMAIL" \
        -d "$DOMAIN" -d "www.${DOMAIN}" \
        --keep-until-expiring \
        --redirect
fi

log "Done. Checking health:"
curl -fsS -o /dev/null -w 'local gunicorn: HTTP %{http_code}\n' http://127.0.0.1:8000/
systemctl is-active zuallite
