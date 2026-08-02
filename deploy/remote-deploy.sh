#!/usr/bin/env bash
#
# Runs ON THE SERVER, piped in over SSH by .github/workflows/deploy.yml.
# Rolls itself back if the new revision fails its health check.

set -euo pipefail

APP_DIR=/srv/zuallite
BRANCH=main

cd "$APP_DIR"
export HOME="$APP_DIR"
export PATH="/usr/local/bin:$PATH"

health_ok() {
    for _ in $(seq 1 15); do
        if curl -fsS -o /dev/null http://127.0.0.1:8000/; then
            return 0
        fi
        sleep 1
    done
    return 1
}

previous=$(git rev-parse HEAD)

git fetch --prune origin
git reset --hard "origin/${BRANCH}"
target=$(git rev-parse HEAD)

if [[ "$previous" == "$target" ]]; then
    echo "Already at ${target}; restarting anyway to pick up config changes."
fi

uv sync --extra prod --frozen
sudo /usr/bin/systemctl restart zuallite

if health_ok; then
    echo "Deployed ${target}"
    exit 0
fi

echo "Health check failed for ${target}; rolling back to ${previous}" >&2
git reset --hard "$previous"
uv sync --extra prod --frozen
sudo /usr/bin/systemctl restart zuallite

if health_ok; then
    echo "Rolled back to ${previous}" >&2
else
    echo "ROLLBACK ALSO UNHEALTHY -- manual intervention required" >&2
fi
exit 1
