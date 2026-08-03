# Deployment

Flask portfolio + WriteFreely blog on one netcup VPS.

| | |
| --- | --- |
| Host | netcup VPS 500 G12 — 2 vCPU, 4 GB, 128 GB NVMe, Debian 13 |
| IPv4 | `185.233.104.40` |
| DNS | Namecheap BasicDNS |
| `ninadmhatre.com` + `www` | Flask, gunicorn → `127.0.0.1:8000`, nginx |
| `blog.ninadmhatre.com` | WriteFreely → `127.0.0.1:8080`, nginx |

## Three scripts

| Script | When | Run as |
| --- | --- | --- |
| `setup.sh` | Once per server. Idempotent. | root |
| `deploy.sh` | Every push to `main` (CI), or by hand. Flask only. | `zuallite` |
| `update.sh` | Maintenance: OS, WriteFreely, deps. | root |

```bash
# first-time provisioning
DOMAIN=ninadmhatre.com DEPLOY_PUBKEY="$(cat zuallite_deploy.pub)" ./setup.sh

# deploy app code (CI does this automatically)
sudo -u zuallite bash /srv/zuallite/deploy/deploy.sh

# maintenance
./update.sh              # everything
./update.sh system       # OS packages
./update.sh blog         # WriteFreely
./update.sh app          # Flask deps + restart
```

`setup.sh` options: `BLOG_DOMAIN`, `DEPLOY_PUBKEY`, `SKIP_CERTBOT=1` (provision
before DNS resolves), `REMOVE_GHOST=1` (tear down a previous Ghost install),
`WF_ADMIN_USER`.

## Why WriteFreely, not Ghost

Ghost requires MySQL 8, ~700 MB RAM, and — the dealbreaker — emails a 6-digit
code on staff sign-in from a new device, with no way to log in if you have no
mail server.

WriteFreely: 13 MB Go binary, SQLite, ~30 MB RAM, **username + password only**.
No email anywhere, no 2FA, no mail server. `single_user = true` means the
instance *is* one blog; `open_registration = false` means `/signup` renders
"Registration closed". There is no comment system to disable.

Trade-offs: plain design, no image hosting (link images from elsewhere),
markdown editor rather than a rich one.

## Blog admin

`setup.sh` generates a random password and writes it to
`/root/writefreely-admin-credentials.txt` (mode 600). Save it somewhere safe
and delete the file.

Log in at `https://blog.ninadmhatre.com/login`. Reset the password with:

```bash
cd /srv/writefreely
sudo -u writefreely ./writefreely -c config.ini user reset-pass ninad
```

## Switching an existing Ghost box over

One-time, on a server that already ran the old `provision-ghost.sh`:

```bash
cd /srv/zuallite && sudo -u zuallite git pull
sudo DOMAIN=ninadmhatre.com REMOVE_GHOST=1 bash deploy/setup.sh
```

That stops and deletes the Ghost containers and volumes, removes its nginx
vhost, then installs WriteFreely on the same subdomain. The existing
certificate is reused. Docker itself is left installed — remove it with
`apt-get purge -y docker-ce docker-ce-cli containerd.io` if you want the disk
back.

## CI

Push to `main` → `.github/workflows/deploy.yml` SSHes in as `zuallite` and runs
`deploy.sh`, which health-checks the new revision and **reverts to the previous
commit** if it fails to serve.

Repo secrets: `DEPLOY_HOST`, `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`.
Repo variable: `SITE_URL`.

Set them from the CLI, not the browser — pasted values pick up trailing
whitespace, which ssh rejects with `hostname contains invalid characters`:

```bash
gh secret set DEPLOY_HOST --body "185.233.104.40"
gh secret set DEPLOY_SSH_KEY < ~/.ssh/zuallite_deploy
gh secret set DEPLOY_KNOWN_HOSTS --body "$(ssh-keyscan -t ed25519 185.233.104.40)"
gh variable set SITE_URL --body "https://ninadmhatre.com"
```

CI deploys the Flask app only. The blog is updated with `update.sh blog`.

## Operating

```bash
systemctl status zuallite writefreely
journalctl -u zuallite -f
journalctl -u writefreely -f
```

Backups — the blog is one SQLite file plus its keys:

```bash
tar czf ~/blog-$(date +%F).tar.gz -C /srv/writefreely writefreely.db keys config.ini
```

`update.sh blog` snapshots `writefreely.db` before migrating, as
`writefreely.db.bak-<timestamp>`. Prune those occasionally.

Bumping WriteFreely means updating the pinned checksum too:

```bash
curl -sL https://github.com/writefreely/writefreely/releases/download/v0.18.0/writefreely_0.18.0_linux_amd64.tar.gz | sha256sum
WF_VERSION=0.18.0 WF_SHA256=<that> ./update.sh blog
```

Both systemd units run with `ProtectSystem=strict`. The Flask app writes
nothing; WriteFreely gets an explicit `ReadWritePaths=/srv/writefreely` for its
SQLite database. If either later needs disk elsewhere, add a path rather than
relaxing the unit.

## Verify

```bash
curl -sI https://ninadmhatre.com/            # 200
curl -sI https://www.ninadmhatre.com/        # 301 → apex
curl -sI http://ninadmhatre.com/             # 301 → https
curl -sI https://blog.ninadmhatre.com/       # 200
curl -s  https://blog.ninadmhatre.com/signup | grep -i closed   # registration closed
```

## Loose ends

- **Namecheap MX** — switching to BasicDNS auto-added five
  `eforward*.registrar-servers.com` records plus an SPF TXT. Mail is accepted
  but forwards nowhere. Either configure a forwarding address, or delete the
  MX records and set the TXT to `v=spf1 -all`. Never add a second SPF record.
- **IPv6** — no AAAA records published. The address netcup showed was
  link-local (`fe80::`); get the real one with `ip -6 addr show scope global`.
  Publish no AAAA at all rather than one that doesn't answer.
- **`EXTERNAL_BLOG`** in `instance/default.py` still points at dev.to.
