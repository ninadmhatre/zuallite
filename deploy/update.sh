#!/usr/bin/env bash
#
# Routine maintenance: OS packages, WriteFreely, and the Flask app's deps.
# Safe to run any time; each part is skipped if already current.
#
# Usage (as root):
#   ./update.sh                    everything
#   ./update.sh system             OS packages only
#   ./update.sh blog               WriteFreely only
#   ./update.sh app                Flask deps + restart only
#
# Bump WriteFreely with:
#   WF_VERSION=0.18.0 WF_SHA256=<sha> ./update.sh blog
# Find the sha with:
#   curl -sL <tarball-url> | sha256sum

set -euo pipefail

WHAT="${1:-all}"

APP_USER="zuallite"
APP_DIR="/srv/zuallite"
BRANCH="${BRANCH:-main}"

WF_USER="writefreely"
WF_DIR="/srv/writefreely"
WF_PORT="8080"
WF_VERSION="${WF_VERSION:-0.17.1}"
WF_SHA256="${WF_SHA256:-b3314ecce0f4b5d15b240b20f06cd8f200aea5f7a4274d64017de20d09cdad26}"

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

update_system() {
    log "Updating OS packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get autoremove -y -qq

    if [[ -f /var/run/reboot-required ]]; then
        echo "!! A reboot is required to finish applying updates."
    fi
}

update_blog() {
    local current=""
    [[ -x "$WF_DIR/writefreely" ]] && \
        current="$("$WF_DIR/writefreely" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

    if [[ "$current" == "$WF_VERSION" ]]; then
        log "WriteFreely already at ${WF_VERSION}"
        return 0
    fi

    log "Updating WriteFreely ${current:-none} -> ${WF_VERSION}"

    local tmp; tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/wf.tar.gz" \
        "https://github.com/writefreely/writefreely/releases/download/v${WF_VERSION}/writefreely_${WF_VERSION}_linux_amd64.tar.gz"
    if [[ "$WF_SHA256" != "skip" ]]; then
        echo "${WF_SHA256}  ${tmp}/wf.tar.gz" | sha256sum -c - \
            || { echo "checksum mismatch -- refusing to install" >&2; rm -rf "$tmp"; exit 1; }
    fi
    tar xzf "$tmp/wf.tar.gz" -C "$tmp"

    # Back up the SQLite database before any migration touches it.
    local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    if [[ -f "$WF_DIR/writefreely.db" ]]; then
        cp -a "$WF_DIR/writefreely.db" "$WF_DIR/writefreely.db.bak-${stamp}"
        echo "backed up db to writefreely.db.bak-${stamp}"
    fi

    systemctl stop writefreely

    # Replace binary and the asset dirs it ships; leave config, keys and db.
    install -m 0755 -o "$WF_USER" -g "$WF_USER" "$tmp/writefreely/writefreely" "$WF_DIR/writefreely"
    local d
    for d in templates static pages; do
        rm -rf "${WF_DIR:?}/${d}"
        cp -r "$tmp/writefreely/${d}" "$WF_DIR/${d}"
    done
    chown -R "$WF_USER:$WF_USER" "$WF_DIR"
    rm -rf "$tmp"

    log "Migrating WriteFreely database"
    (cd "$WF_DIR" && sudo -u "$WF_USER" "$WF_DIR/writefreely" -c "$WF_DIR/config.ini" db migrate)

    systemctl start writefreely
}

update_app() {
    log "Updating Flask app dependencies"
    sudo -u "$APP_USER" git -C "$APP_DIR" fetch --prune origin
    sudo -u "$APP_USER" git -C "$APP_DIR" reset --hard "origin/${BRANCH}"
    sudo -u "$APP_USER" env HOME="$APP_DIR" \
        uv sync --project "$APP_DIR" --extra prod --frozen
    systemctl restart zuallite
}

case "$WHAT" in
    all)    update_system; update_blog; update_app ;;
    system) update_system ;;
    blog)   update_blog ;;
    app)    update_app ;;
    *)      echo "usage: $0 [all|system|blog|app]" >&2; exit 2 ;;
esac

log "Health checks"
ok=0
if systemctl is-enabled --quiet zuallite 2>/dev/null; then
    curl -fsS -o /dev/null -w 'flask       : HTTP %{http_code}\n' http://127.0.0.1:8000/ || ok=1
fi
if systemctl is-enabled --quiet writefreely 2>/dev/null; then
    curl -fsS -o /dev/null -w "writefreely : HTTP %{http_code}\n" "http://127.0.0.1:${WF_PORT}/" || ok=1
fi
systemctl is-active zuallite writefreely || ok=1
exit $ok
