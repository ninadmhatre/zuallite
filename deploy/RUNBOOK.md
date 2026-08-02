# Migration runbook: ninadmhatre.com → netcup

Stands the Flask portfolio up on a netcup VPS, adds a Ghost blog on
`blog.ninadmhatre.com`, and switches deploys from manual to GitHub Actions.

| Thing | Value |
| --- | --- |
| Host | netcup VPS 500 G12 — 2 vCPU, 4 GB DDR5, 128 GB NVMe |
| Price | €5.91/mo incl. 19% VAT (≈ $6.9) |
| IPv4 | `185.233.104.40` |
| IPv6 | from `2a03:4000:24:2fe::/64` — **confirm the actual address on the box** |
| OS | Debian 13 (trixie) |
| DNS | Namecheap BasicDNS (`dns1`/`dns2.registrar-servers.com`) |
| `ninadmhatre.com` + `www` | Flask app, gunicorn behind nginx |
| `blog.ninadmhatre.com` | Ghost 6 + MySQL 8.4 in containers, behind the same nginx |

---

## 0. State of play

**DNS is already live.** Namecheap BasicDNS is authoritative and all three A
records resolve to `185.233.104.40` at a 300s TTL. The old DigitalOcean zone is
gone and the droplet is destroyed, so there is **no rollback target** — but also
no cutover choreography to get wrong.

Two carried-over notes:

- Switching to BasicDNS auto-provisioned **Namecheap email forwarding** (five
  `eforward*.registrar-servers.com` MX records plus a matching SPF TXT). Either
  configure a forwarding address or delete all five MX records and replace the
  SPF with `v=spf1 -all`. Don't do half of each, and never add a second SPF
  record — two is a permerror.
- The IPv6 address from netcup's panel was link-local (`fe80::…`) and unusable.
  Get the real one with `ip -6 addr show scope global`. **If none is
  configured, publish no AAAA records at all** — an AAAA that doesn't answer is
  worse than none.

**Ghost runs in containers, not via ghost-cli.** On Debian 13 that's the clean
path: `ghost-cli` gates its nginx/systemd/SSL setup on Ubuntu and skips it on
Debian, and Debian's repos carry no `mysql-8.0`. Pinned `ghost:6-alpine` and
`mysql:8.4` images sidestep both. TLS still terminates on the host with
certbot, next to the Flask app's certificate.

This stack was booted and verified before writing this runbook —
`ghost:6-alpine` (6.55) against `mysql:8.4` (8.4.11): migrations ran, and the
homepage, `/rss/` and `/ghost/` all returned 200 behind a simulated nginx
proxy. Resident memory was ~197 MB for Ghost and ~478 MB for MySQL, so roughly
700 MB for the blog on top of ~60 MB for Flask. Comfortable on 4 GB.

Two behaviours worth knowing:

- Ghost 6 calls **its own public HTTPS URL** at boot to initialise ActivityPub
  (fediverse publishing). `provision-ghost.sh` therefore restarts the container
  once certbot has issued — before that, the first boot logs `ECONNREFUSED` and
  skips ActivityPub. Harmless, and handled.
- No `mysql_native_password` deprecation warning appeared with these versions,
  despite reports of it elsewhere. Nothing to ignore.

If you don't want the blog federating to Mastodon and friends, turn ActivityPub
off in **Settings → Social web** after setup.

---

## 1. Harden SSH, confirm the box

```bash
ssh root@185.233.104.40

cat /etc/os-release              # expect Debian 13 (trixie)
free -h                          # expect ~4 GB; note whether swap exists
ip -6 addr show scope global     # <-- your real IPv6, record it for step 3
```

Install your key, then stop using the emailed password:

```bash
# from your laptop
ssh-copy-id root@185.233.104.40
```

Back on the box, in `/etc/ssh/sshd_config`:

```
PermitRootLogin prohibit-password
PasswordAuthentication no
```

```bash
systemctl restart ssh
```

> Keep the current session open and verify a *second* SSH session works before
> closing it. This is the easiest way to lock yourself out of a fresh box.

## 2. Provision the Flask app

Generate the CI keypair on your laptop first (no passphrase — Actions can't
type one):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/zuallite_deploy -C "github-actions-zuallite" -N ""
```

Then on the server — DNS already resolves, so certbot runs in the same pass:

```bash
DOMAIN=ninadmhatre.com \
DEPLOY_PUBKEY="$(cat ~/.ssh/zuallite_deploy.pub)" \
  bash <(curl -fsSL https://raw.githubusercontent.com/ninadmhatre/zuallite/main/deploy/provision.sh)
```

This installs nginx, ufw, fail2ban, unattended-upgrades and uv; creates the
`zuallite` service user; clones the repo to `/srv/zuallite`; installs the
systemd unit; and requests a certificate for the apex and `www`.

Verify:

```bash
curl -sI https://ninadmhatre.com/ | head -1        # 200
curl -sI http://ninadmhatre.com/  | head -1        # 301 → https
systemctl is-active zuallite
systemctl list-timers certbot.timer
```

## 3. Add AAAA records (only if IPv6 exists)

If step 1 returned a global `2a03:4000:24:2fe::…` address, add it in Namecheap
→ Advanced DNS as `AAAA Record` for `@`, `www` and `blog`, TTL 5 min. Skip
entirely otherwise.

## 4. Install Ghost

`blog.ninadmhatre.com` already resolves, so this can run straight away:

```bash
BLOG_DOMAIN=blog.ninadmhatre.com bash /srv/zuallite/deploy/provision-ghost.sh
```

This adds a 2 GB swapfile, installs Docker CE from Docker's `trixie` repo,
writes `/opt/ghost/` with generated DB credentials, brings up Ghost and MySQL,
proxies them through nginx and requests a certificate.

Then **immediately** open `https://blog.ninadmhatre.com/ghost/` and create the
owner account — the first visitor to that URL claims it.

Make it read-only:

- **Settings → Comments** → `Nobody`
- **Settings → Membership** → turn off subscription access / the portal popup
- **Settings → Access** → `Public`

Publish dates render by default in the stock Source theme.

Point the portfolio at it by changing `EXTERNAL_BLOG` in `instance/default.py`
from dev.to to `https://blog.ninadmhatre.com`, then push to `main`.

To bring dev.to posts across: dev.to exports articles as JSON under *Settings →
Extensions → Export content*; Ghost imports under *Settings → Import content*.
Do this before you advertise the new URL.

## 5. Wire up GitHub Actions

Repo → **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `DEPLOY_HOST` | `185.233.104.40` |
| Secret | `DEPLOY_SSH_KEY` | contents of `~/.ssh/zuallite_deploy` (the **private** key) |
| Secret | `DEPLOY_KNOWN_HOSTS` | output of `ssh-keyscan -t ed25519 185.233.104.40` |
| Variable | `SITE_URL` | `https://ninadmhatre.com` |

Pinning `DEPLOY_KNOWN_HOSTS` instead of `StrictHostKeyChecking=no` is what
stops the runner handing your deploy key to whatever answers on that IP.

```bash
gh workflow run "Deploy to production"
gh run watch
```

Every push to `main` now deploys. `deploy/remote-deploy.sh` health-checks the
new revision and **reverts to the previous commit** if it fails to serve.

Note this pipeline deploys the Flask app only. Ghost is upgraded by bumping its
image tag (see below).

## 6. Verify

```bash
curl -sI https://ninadmhatre.com/            # 200
curl -sI https://www.ninadmhatre.com/        # 301 → apex
curl -sI http://ninadmhatre.com/             # 301 → https
curl -sI https://blog.ninadmhatre.com/       # 200
curl -s  https://ninadmhatre.com/nope        # 404 JSON
curl -sI https://ninadmhatre.com/static/css/styles.css   # 200 + Cache-Control
```

Certificates cover what you think they do:

```bash
for h in ninadmhatre.com blog.ninadmhatre.com; do
  echo | openssl s_client -connect $h:443 -servername $h 2>/dev/null \
    | openssl x509 -noout -subject -dates -ext subjectAltName
done
```

Then raise the DNS TTLs from 5 min to Automatic if you want.

---

## Operating notes

```bash
systemctl status zuallite          # Flask app
journalctl -u zuallite -f          # its logs (gunicorn logs to stdout)
```

Ghost — every command needs both flags, since the secrets live in `.env`:

```bash
cd /opt/ghost
docker compose --env-file .env ps
docker compose --env-file .env logs -f ghost
docker compose --env-file .env restart ghost
```

**Upgrading Ghost:** back up first (below), bump the `ghost:6-alpine` tag in
`/opt/ghost/compose.yaml`, then `docker compose --env-file .env up -d`.

**Backups.** Two things matter — the content volume and the database:

```bash
cd /opt/ghost
# database
docker compose --env-file .env exec -T db \
  mysqldump -u root --password="$(grep MYSQL_ROOT_PASSWORD .env | cut -d= -f2)" \
  --single-transaction ghost > ~/ghost-db-$(date +%F).sql
# content (themes, images)
docker run --rm -v ghost_ghost-content:/c -v "$HOME":/out alpine \
  tar czf /out/ghost-content-$(date +%F).tar.gz -C /c .
```

Keep `/opt/ghost/.env` safe — regenerating those credentials orphans the MySQL
volume, and `provision-ghost.sh` deliberately refuses to overwrite it.

**Docker and ufw:** Docker bypasses ufw for published ports, but the compose
file binds Ghost to `127.0.0.1:2368` and publishes nothing for MySQL, so
neither is reachable from outside. If you ever change those bindings, that
protection goes with them.

The Flask systemd unit runs gunicorn with `ProtectSystem=strict` on a read-only
filesystem — the app writes nothing. If you later add something that needs
disk, add an explicit `ReadWritePaths=` rather than relaxing the unit.
