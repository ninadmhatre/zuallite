#!/usr/bin/env bash
#
# Installs Ghost prerequisites (Node 22, MySQL 8, ghost-cli) on the same box as
# the Flask app, then hands over to the interactive `ghost install`.
#
# Run AFTER provision.sh, and only once blog.<domain> resolves to this box --
# ghost-cli requests its own Let's Encrypt certificate during install.
#
# Usage (as root):
#   BLOG_DOMAIN=blog.example.com ./provision-ghost.sh

set -euo pipefail

BLOG_DOMAIN="${BLOG_DOMAIN:?set BLOG_DOMAIN, e.g. BLOG_DOMAIN=blog.example.com}"
GHOST_USER="${GHOST_USER:-ghostadmin}"
GHOST_DIR="/var/www/blog"

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

log "Adding swap (Ghost + MySQL are memory-hungry at startup)"
if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

log "Installing Node.js 22"
export DEBIAN_FRONTEND=noninteractive
if ! command -v node >/dev/null || [[ "$(node -v)" != v22.* ]]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y -qq nodejs
fi

log "Installing MySQL 8"
apt-get install -y -qq mysql-server
systemctl enable --now mysql

log "Installing ghost-cli"
npm install -g ghost-cli@latest

log "Creating ${GHOST_USER} (ghost-cli refuses to run as root)"
if ! id -u "$GHOST_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$GHOST_USER"
    usermod -aG sudo "$GHOST_USER"
fi

install -d -o "$GHOST_USER" -g "$GHOST_USER" -m 775 "$GHOST_DIR"

cat <<EOF

==> Prerequisites installed. Now run the interactive installer:

      su - ${GHOST_USER}
      cd ${GHOST_DIR}
      ghost install

    Answer the prompts as follows:

      Blog URL ............... https://${BLOG_DOMAIN}
      MySQL hostname ......... localhost
      MySQL username ......... root          (auth_socket; ghost-cli handles it)
      MySQL password ......... <blank>
      Ghost database name .... ghost_prod
      Set up a ghost MySQL user? .. yes
      Set up NGINX? .......... yes
      Set up SSL? ............ yes
      Set up systemd? ........ yes
      Start Ghost? ........... yes

    Then open https://${BLOG_DOMAIN}/ghost/ to create the admin account.

    Afterwards, in Ghost Admin turn the site read-only for visitors:
      Settings -> Membership  -> turn OFF subscription access / portal
      Settings -> Comments    -> set to "Nobody"  (comments off)
      Settings -> Access      -> "Public" (anyone can read)

    Publish dates are shown by every default theme (Source) out of the box.

EOF
