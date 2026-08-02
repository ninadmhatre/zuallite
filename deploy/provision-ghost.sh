#!/usr/bin/env bash
#
# Installs Ghost 6 + MySQL 8.4 as containers, fronted by the host's nginx with
# a Let's Encrypt certificate.
#
# Run AFTER provision.sh, and only once blog.<domain> resolves to this box --
# certbot validates over HTTP-01.
#
# Usage (as root):
#   BLOG_DOMAIN=blog.example.com ./provision-ghost.sh
#
# Idempotent: safe to re-run. Existing credentials in /opt/ghost/.env are
# preserved, because regenerating them would orphan the MySQL volume.

set -euo pipefail

BLOG_DOMAIN="${BLOG_DOMAIN:?set BLOG_DOMAIN, e.g. BLOG_DOMAIN=blog.example.com}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-ninad.mhatre@gmail.com}"
APP_DIR="/srv/zuallite"
GHOST_DIR="/opt/ghost"

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# shellcheck disable=SC1091
. /etc/os-release

log "Adding swap (MySQL's first-run init is the memory spike)"
if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Installing Docker CE (${ID} ${VERSION_CODENAME})"
export DEBIAN_FRONTEND=noninteractive
if ! command -v docker >/dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable
EOF
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

log "Writing ${GHOST_DIR}"
install -d -m 0750 "$GHOST_DIR"
install -m 0644 "$APP_DIR/deploy/ghost/compose.yaml" "$GHOST_DIR/compose.yaml"

# Alphanumeric only: these get interpolated into the compose healthcheck
# command, where shell metacharacters would be a problem.
randpw() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32; }

if [[ ! -f "$GHOST_DIR/.env" ]]; then
    log "Generating database credentials"
    umask 077
    cat > "$GHOST_DIR/.env" <<EOF
BLOG_DOMAIN=${BLOG_DOMAIN}
MYSQL_ROOT_PASSWORD=$(randpw)
GHOST_DB_PASSWORD=$(randpw)
EOF
    chmod 600 "$GHOST_DIR/.env"
else
    log "Keeping existing ${GHOST_DIR}/.env (rotating it would orphan the DB volume)"
fi

log "Starting Ghost and MySQL"
docker compose -f "$GHOST_DIR/compose.yaml" --env-file "$GHOST_DIR/.env" up -d

log "Waiting for Ghost to answer on 127.0.0.1:2368"
for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "http://127.0.0.1:2368/"; then
        echo "Ghost is up after ${i}s"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "Ghost did not come up. Logs:" >&2
        docker compose -f "$GHOST_DIR/compose.yaml" --env-file "$GHOST_DIR/.env" logs --tail 50 >&2
        exit 1
    fi
    sleep 1
done

log "Configuring nginx for ${BLOG_DOMAIN}"
sed "s/__BLOG_DOMAIN__/${BLOG_DOMAIN}/g" "$APP_DIR/deploy/nginx-ghost.conf" \
    > /etc/nginx/sites-available/ghost
ln -sfn /etc/nginx/sites-available/ghost /etc/nginx/sites-enabled/ghost
nginx -t
systemctl reload nginx

log "Requesting TLS certificate for ${BLOG_DOMAIN}"
certbot --nginx --non-interactive --agree-tos \
    -m "$LETSENCRYPT_EMAIL" \
    -d "$BLOG_DOMAIN" \
    --keep-until-expiring \
    --redirect

# Ghost 6 calls its own public https:// URL at boot to initialise ActivityPub.
# On the first run that happens before the certificate exists, so it logs
# ECONNREFUSED and gives up. Restarting now that TLS is live lets it succeed.
log "Restarting Ghost now that HTTPS is live"
docker compose -f "$GHOST_DIR/compose.yaml" --env-file "$GHOST_DIR/.env" restart ghost
for i in $(seq 1 60); do
    curl -fsS -o /dev/null "http://127.0.0.1:2368/" && break
    [[ $i -eq 60 ]] && { echo "Ghost did not come back after restart" >&2; exit 1; }
    sleep 1
done

cat <<EOF

==> Done. Create your admin account at:

      https://${BLOG_DOMAIN}/ghost/

    The FIRST person to open that URL claims the owner account, so do it now
    rather than later.

    Then make it a read-only blog:
      Settings -> Comments    -> "Nobody"
      Settings -> Membership  -> turn off subscription access / the portal
      Settings -> Access      -> "Public"

    Publish dates render by default in the stock Source theme.

    Operating:
      docker compose -f ${GHOST_DIR}/compose.yaml --env-file ${GHOST_DIR}/.env ps
      docker compose -f ${GHOST_DIR}/compose.yaml --env-file ${GHOST_DIR}/.env logs -f ghost

    Upgrading Ghost: bump the image tag in ${GHOST_DIR}/compose.yaml, then
    \`... up -d\`. Take a backup first (see RUNBOOK.md).

EOF
