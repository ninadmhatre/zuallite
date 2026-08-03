#!/usr/bin/env bash
#
# One-time server provisioning: Flask portfolio + WriteFreely blog.
# Idempotent -- safe to re-run.
#
# Usage (as root on a fresh Debian 13 / Ubuntu 24.04 box):
#   DOMAIN=ninadmhatre.com ./setup.sh
#
# Optional:
#   BLOG_DOMAIN=blog.example.com   default: blog.<DOMAIN>
#   DEPLOY_PUBKEY="ssh-ed25519 …"  install the CI deploy key
#   SKIP_CERTBOT=1                 provision before DNS points here
#   REMOVE_GHOST=1                 tear down a previous Ghost/Docker install
#   WF_ADMIN_USER=ninad            blog admin username

set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN, e.g. DOMAIN=ninadmhatre.com ./setup.sh}"
BLOG_DOMAIN="${BLOG_DOMAIN:-blog.${DOMAIN}}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-ninad.mhatre@gmail.com}"
REPO="${REPO:-https://github.com/ninadmhatre/zuallite.git}"
BRANCH="${BRANCH:-main}"

APP_USER="zuallite"
APP_DIR="/srv/zuallite"

WF_USER="writefreely"
WF_DIR="/srv/writefreely"
WF_PORT="8080"
WF_VERSION="${WF_VERSION:-0.17.1}"
# sha256 of writefreely_${WF_VERSION}_linux_amd64.tar.gz. Update when bumping
# the version, or pass WF_SHA256=skip to bypass.
WF_SHA256="${WF_SHA256:-b3314ecce0f4b5d15b240b20f06cd8f200aea5f7a4274d64017de20d09cdad26}"
WF_ADMIN_USER="${WF_ADMIN_USER:-ninad}"

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# ---------------------------------------------------------------- packages ---
log "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    ca-certificates curl git nginx ufw fail2ban \
    unattended-upgrades certbot python3-certbot-nginx

log "Enabling unattended security upgrades"
# Written explicitly rather than via `dpkg-reconfigure -f noninteractive`,
# which is a no-op on Debian.
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades

log "Configuring firewall"
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# ------------------------------------------------------- optional teardown ---
if [[ -n "${REMOVE_GHOST:-}" ]]; then
    log "Removing previous Ghost install"
    if [[ -f /opt/ghost/compose.yaml ]] && command -v docker >/dev/null; then
        docker compose -f /opt/ghost/compose.yaml --env-file /opt/ghost/.env down -v || true
    fi
    rm -rf /opt/ghost
    rm -f /etc/nginx/sites-enabled/ghost /etc/nginx/sites-available/ghost
    echo "Docker itself left installed. Remove with: apt-get purge -y docker-ce docker-ce-cli containerd.io"
fi

# ----------------------------------------------------------- flask portfolio -
log "Installing uv system-wide"
command -v uv >/dev/null || \
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

log "Creating ${APP_USER}"
id -u "$APP_USER" >/dev/null 2>&1 || \
    useradd --system --create-home --home-dir "$APP_DIR" --shell /bin/bash "$APP_USER"
chmod 755 "$APP_DIR"   # nginx must traverse into static/

log "Fetching application"
# useradd populated the home dir from /etc/skel, so `git clone` would refuse
# it. init + fetch works into a non-empty directory. Full history, not
# --depth=1: deploy.sh rolls back to the previous commit on a failed deploy.
if [[ ! -d "$APP_DIR/.git" ]]; then
    sudo -u "$APP_USER" git init -q -b "$BRANCH" "$APP_DIR"
    sudo -u "$APP_USER" git -C "$APP_DIR" remote add origin "$REPO"
fi
sudo -u "$APP_USER" git -C "$APP_DIR" fetch --prune origin
sudo -u "$APP_USER" git -C "$APP_DIR" reset --hard "origin/${BRANCH}"

log "Installing Python dependencies"
sudo -u "$APP_USER" env HOME="$APP_DIR" uv sync --project "$APP_DIR" --extra prod --frozen

log "Installing zuallite.service"
install -m 0644 "$APP_DIR/deploy/zuallite.service" /etc/systemd/system/zuallite.service
if [[ ! -f /etc/zuallite.env ]]; then
    umask 077
    printf 'SECRET_KEY=%s\n' "$(head -c 32 /dev/urandom | base64)" > /etc/zuallite.env
    chown root:"$APP_USER" /etc/zuallite.env
    chmod 640 /etc/zuallite.env
fi
systemctl daemon-reload
systemctl enable --now zuallite
systemctl restart zuallite

if [[ -n "${DEPLOY_PUBKEY:-}" ]]; then
    log "Installing CI deploy key"
    install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$APP_DIR/.ssh"
    touch "$APP_DIR/.ssh/authorized_keys"
    grep -qxF "$DEPLOY_PUBKEY" "$APP_DIR/.ssh/authorized_keys" \
        || printf '%s\n' "$DEPLOY_PUBKEY" >> "$APP_DIR/.ssh/authorized_keys"
    chown "$APP_USER:$APP_USER" "$APP_DIR/.ssh/authorized_keys"
    chmod 600 "$APP_DIR/.ssh/authorized_keys"
fi

log "Granting ${APP_USER} restart rights (for CI deploys)"
cat > /etc/sudoers.d/zuallite-deploy <<EOF
${APP_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl restart zuallite, /usr/bin/systemctl is-active zuallite, /usr/bin/systemctl status zuallite
EOF
chmod 440 /etc/sudoers.d/zuallite-deploy
visudo -cf /etc/sudoers.d/zuallite-deploy

# ---------------------------------------------------------------- writefreely -
log "Creating ${WF_USER}"
id -u "$WF_USER" >/dev/null 2>&1 || \
    useradd --system --create-home --home-dir "$WF_DIR" --shell /usr/sbin/nologin "$WF_USER"

if [[ ! -x "$WF_DIR/writefreely" ]]; then
    log "Installing WriteFreely ${WF_VERSION}"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/wf.tar.gz" \
        "https://github.com/writefreely/writefreely/releases/download/v${WF_VERSION}/writefreely_${WF_VERSION}_linux_amd64.tar.gz"
    if [[ "$WF_SHA256" != "skip" ]]; then
        echo "${WF_SHA256}  ${tmp}/wf.tar.gz" | sha256sum -c - \
            || { echo "checksum mismatch -- refusing to install" >&2; exit 1; }
    fi
    tar xzf "$tmp/wf.tar.gz" -C "$tmp"
    cp -r "$tmp/writefreely/." "$WF_DIR/"
    rm -rf "$tmp"
    chown -R "$WF_USER:$WF_USER" "$WF_DIR"
    chmod 755 "$WF_DIR"
fi

if [[ ! -f "$WF_DIR/config.ini" ]]; then
    log "Writing WriteFreely config"
    cat > "$WF_DIR/config.ini" <<EOF
[server]
hidden_host          =
port                 = ${WF_PORT}
bind                 = localhost
tls_cert_path        =
tls_key_path         =
autocert             = false
templates_parent_dir =
static_parent_dir    =
pages_parent_dir     =
keys_parent_dir      =
hash_seed            =
gopher_port          = 0

[database]
type     = sqlite3
filename = writefreely.db
username =
password =
database =
host     = localhost
port     = 3306
tls      = false

[app]
site_name             = Ninad Mhatre
site_description      =
host                  = https://${BLOG_DOMAIN}
theme                 = write
editor                =
disable_js            = false
webfonts              = true
landing               =
simple_nav            = false
wf_modesty            = false
chorus                = false
forest                = false
disable_drafts        = false
single_user           = true
open_registration     = false
open_deletion         = false
min_username_len      = 3
max_blogs             = 1
federation            = false
public_stats          = false
monetization          = false
notes_only            = false
private               = false
local_timeline        = false
user_invites          =
default_visibility    = public
update_checks         = false
disable_password_auth = false
EOF
    chown "$WF_USER:$WF_USER" "$WF_DIR/config.ini"
    chmod 640 "$WF_DIR/config.ini"
fi

wf() { sudo -u "$WF_USER" "$WF_DIR/writefreely" -c "$WF_DIR/config.ini" "$@"; }

if [[ -z "$(ls -A "$WF_DIR/keys" 2>/dev/null)" ]]; then
    log "Generating WriteFreely keys"
    (cd "$WF_DIR" && wf keys generate)
fi

WF_CREDS_FILE="/root/writefreely-admin-credentials.txt"
if [[ ! -f "$WF_DIR/writefreely.db" ]]; then
    log "Initialising WriteFreely database"
    (cd "$WF_DIR" && wf db init)

    wf_pass="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
    (cd "$WF_DIR" && wf user create --admin "${WF_ADMIN_USER}:${wf_pass}")

    umask 077
    cat > "$WF_CREDS_FILE" <<EOF
WriteFreely admin
url:      https://${BLOG_DOMAIN}/login
username: ${WF_ADMIN_USER}
password: ${wf_pass}
EOF
    chmod 600 "$WF_CREDS_FILE"
fi

log "Installing writefreely.service"
install -m 0644 "$APP_DIR/deploy/writefreely.service" /etc/systemd/system/writefreely.service
systemctl daemon-reload
systemctl enable --now writefreely
systemctl restart writefreely

# ---------------------------------------------------------------------- nginx -
log "Configuring nginx"
# These reset the vhosts to their HTTP-only templates, discarding certbot's
# edits. Intentional and self-healing: the certbot step below re-adds TLS.
sed "s/__DOMAIN__/${DOMAIN}/g" "$APP_DIR/deploy/nginx-zuallite.conf" \
    > /etc/nginx/sites-available/zuallite
sed "s/__BLOG_DOMAIN__/${BLOG_DOMAIN}/g" "$APP_DIR/deploy/nginx-writefreely.conf" \
    > /etc/nginx/sites-available/writefreely
ln -sfn /etc/nginx/sites-available/zuallite   /etc/nginx/sites-enabled/zuallite
ln -sfn /etc/nginx/sites-available/writefreely /etc/nginx/sites-enabled/writefreely
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

if [[ -n "${SKIP_CERTBOT:-}" ]]; then
    log "Skipping certbot (SKIP_CERTBOT set) -- re-run after DNS points here"
else
    log "Requesting TLS certificates"
    # --keep-until-expiring makes re-runs reinstall rather than fail with
    # "not yet due for renewal". One call per vhost.
    certbot --nginx --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" \
        -d "$DOMAIN" -d "www.${DOMAIN}" --keep-until-expiring --redirect
    certbot --nginx --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" \
        -d "$BLOG_DOMAIN" --keep-until-expiring --redirect
fi

# --------------------------------------------------------------------- checks -
log "Health checks"
curl -fsS -o /dev/null -w 'flask       (127.0.0.1:8000): HTTP %{http_code}\n' http://127.0.0.1:8000/
curl -fsS -o /dev/null -w "writefreely (127.0.0.1:${WF_PORT}): HTTP %{http_code}\n" "http://127.0.0.1:${WF_PORT}/"
systemctl is-active zuallite writefreely

if [[ -f "$WF_CREDS_FILE" ]]; then
    cat <<EOF

==> Blog admin credentials are in ${WF_CREDS_FILE}

$(cat "$WF_CREDS_FILE")

    Save them somewhere safe, then delete that file.
    Username + password only -- no email, no 2FA, no mail server needed.

EOF
fi
