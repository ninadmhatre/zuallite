# Migration runbook: ninadmhatre.com → netcup

Stands the Flask portfolio up on a netcup VPS, adds a Ghost blog on
`blog.ninadmhatre.com`, and switches deploys from manual to GitHub Actions.

| Thing | Value |
| --- | --- |
| Host | netcup VPS 500 G12 — 2 vCPU, 4 GB DDR5, 128 GB NVMe |
| Price | €5.91/mo incl. 19% VAT (≈ $6.9) |
| IPv4 | `185.233.104.40` |
| IPv6 | from `2a03:4000:24:2fe::/64` — **confirm the actual address on the box** |
| OS | Ubuntu 24.04 LTS (**reinstall required** — netcup shipped Debian 13) |
| `ninadmhatre.com` + `www` | Flask app, gunicorn behind nginx |
| `blog.ninadmhatre.com` | Ghost 6, Node 22 + MySQL 8 |

---

## 0. State of play

Three things differ from a normal migration — read these before starting.

**The domain is already dark.** `ninadmhatre.com` is delegated to
`ns{1,2,3}.digitalocean.com`, and all three answer `REFUSED` — DigitalOcean no
longer holds the zone. Nothing resolves today.

Consequences:

- No TTL-lowering step, no propagation window, no cutover choreography, and
  **no rollback to DigitalOcean**. This is a greenfield DNS build.
- Whatever was in that zone is unrecoverable from here. **If the domain ever
  carried MX / SPF / DKIM / DMARC records, email is already broken** and you
  must recreate them from your mail provider's setup docs. Check this — it is
  the one thing that won't announce itself when the website comes back up.
- Because nothing resolves, HSTS is moot and certbot's HTTP-01 challenge will
  work as soon as DNS points at the new box.

**The box is Debian 13, not Ubuntu.** `provision.sh` and `provision-ghost.sh`
target Ubuntu 24.04. Ghost requires MySQL 8 (Debian ships MariaDB, and MySQL 8
is not in Debian's repos) and officially supports Ubuntu 22.04/24.04 only.
Reinstall before doing anything else — see step 1.

**The IPv6 address you have is link-local.** `fe80::…` cannot be routed or put
in DNS. The routable range is `2a03:4000:24:2fe::/64`; get the configured
address off the box in step 2.

---

## 1. Reinstall as Ubuntu 24.04

netcup **SCP** (Server Control Panel, not CCP) → your VPS → *Media* →
*Images* → **Ubuntu 24.04 LTS** → install.

The box is empty, so there is nothing to preserve. Takes a few minutes and the
root password is reset — netcup shows the new one in SCP.

> Doing this on Debian instead means sourcing MySQL 8 from Oracle's apt repo
> and running ghost-cli against an unsupported stack. Not worth it.

## 2. Harden SSH, confirm the box

```bash
ssh root@185.233.104.40

lsb_release -a                 # expect Ubuntu 24.04
free -h                        # expect ~4 GB; note whether swap exists
ip -6 addr show scope global   # <-- your real IPv6, record it for step 4
```

Install your key, then stop using the emailed password:

```bash
# from your laptop
ssh-copy-id root@185.233.104.40
```

Back on the box, edit `/etc/ssh/sshd_config`:

```
PermitRootLogin prohibit-password
PasswordAuthentication no
```

```bash
systemctl restart ssh
```

> Keep your current session open and verify a *second* SSH session works before
> closing it. This is the easiest way to lock yourself out of a fresh box.

## 3. Provision the Flask app

Generate the CI keypair on your laptop first (no passphrase — Actions can't
type one):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/zuallite_deploy -C "github-actions-zuallite" -N ""
```

Then on the server:

```bash
DOMAIN=ninadmhatre.com \
DEPLOY_PUBKEY="$(cat ~/.ssh/zuallite_deploy.pub)" \
SKIP_CERTBOT=1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/ninadmhatre/zuallite/main/deploy/provision.sh)
```

`SKIP_CERTBOT=1` because Let's Encrypt cannot validate a domain that doesn't
resolve yet. You re-run without it in step 5.

Verify before touching DNS, by faking resolution:

```bash
curl -sI --resolve ninadmhatre.com:80:185.233.104.40 http://ninadmhatre.com/
curl -s  --resolve ninadmhatre.com:80:185.233.104.40 http://ninadmhatre.com/ \
  | grep -o '<title>.*</title>'
```

Expect `HTTP/1.1 200` and `<title>Ninad Mhatre - Portfolio</title>`.

## 4. Build the DNS zone

The old zone is gone, so pick a host and create it fresh.
[Cloudflare's free tier](https://dash.cloudflare.com) is the sensible landing
spot: free, fast, good API, and it decouples DNS from whoever runs your compute
— which is exactly the coupling that just bit you.

Create the zone, add the records, **then** change the nameservers at your
registrar away from `ns{1,2,3}.digitalocean.com`.

| Type | Name | Value | TTL |
| --- | --- | --- | --- |
| A | `@` | `185.233.104.40` | 300 |
| AAAA | `@` | *(your global v6 from step 2)* | 300 |
| A | `www` | `185.233.104.40` | 300 |
| A | `blog` | `185.233.104.40` | 300 |
| AAAA | `blog` | *(your global v6)* | 300 |

Skip the AAAA records entirely if IPv6 isn't configured on the box — a
published AAAA that doesn't answer makes the site look broken to v6-capable
clients, which is worse than having no AAAA at all.

**Recreate any mail records** (MX, SPF `TXT`, DKIM `TXT`, DMARC `TXT`) from
your mail provider's docs. Nothing in the old zone survives.

If you use Cloudflare, keep the records **DNS-only (grey cloud)** until certbot
has issued — the orange-cloud proxy intercepts the HTTP-01 challenge.

Watch it land:

```bash
watch -n5 'dig +short ninadmhatre.com; dig +short blog.ninadmhatre.com'
```

Registrar nameserver changes can take a couple of hours to show up at the
registry, independent of your TTLs.

## 5. Issue certificates

Once `dig` returns `185.233.104.40`:

```bash
DOMAIN=ninadmhatre.com bash /srv/zuallite/deploy/provision.sh
```

certbot rewrites the nginx vhost with TLS and the HTTP→HTTPS redirect, and
installs a renewal timer.

```bash
curl -sI https://ninadmhatre.com/ | head -1
systemctl list-timers certbot.timer
```

## 6. Install Ghost

Only once `blog.ninadmhatre.com` resolves — ghost-cli requests its own
certificate during install.

```bash
BLOG_DOMAIN=blog.ninadmhatre.com bash /srv/zuallite/deploy/provision-ghost.sh
```

Then follow the printed instructions to run `ghost install` and create your
admin account at `https://blog.ninadmhatre.com/ghost/`.

For a read-only blog, in Ghost Admin:

- **Settings → Comments** → `Nobody`
- **Settings → Membership** → turn off subscription access / the portal popup
- **Settings → Access** → `Public`

Publish dates render by default in Ghost's stock Source theme.

Point the portfolio at it by changing `EXTERNAL_BLOG` in `instance/default.py`
from dev.to to `https://blog.ninadmhatre.com`.

To bring your dev.to posts across: dev.to exports articles as JSON under
*Settings → Extensions → Export content*; Ghost imports under *Settings →
Import content*. Do this before you advertise the new URL.

## 7. Wire up GitHub Actions

Repo → **Settings → Secrets and variables → Actions**:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `DEPLOY_HOST` | `185.233.104.40` |
| Secret | `DEPLOY_SSH_KEY` | contents of `~/.ssh/zuallite_deploy` (the **private** key) |
| Secret | `DEPLOY_KNOWN_HOSTS` | output of `ssh-keyscan -t ed25519 185.233.104.40` |
| Variable | `SITE_URL` | `https://ninadmhatre.com` |

Pinning `DEPLOY_KNOWN_HOSTS` instead of `StrictHostKeyChecking=no` is what
stops the runner handing your deploy key to whatever answers on that IP.

Test end to end:

```bash
gh workflow run "Deploy to production"
gh run watch
```

Every push to `main` now deploys. `deploy/remote-deploy.sh` health-checks the
new revision and **reverts to the previous commit** if it fails to serve.

## 8. Verify

```bash
curl -sI https://ninadmhatre.com/            # 200
curl -sI https://www.ninadmhatre.com/        # 301 → apex
curl -sI http://ninadmhatre.com/             # 301 → https
curl -sI https://blog.ninadmhatre.com/       # 200
curl -s  https://ninadmhatre.com/nope        # 404 JSON
curl -sI https://ninadmhatre.com/static/css/styles.css   # 200 + Cache-Control
```

Check the certificate covers both apex and `www`:

```bash
echo | openssl s_client -connect ninadmhatre.com:443 -servername ninadmhatre.com 2>/dev/null \
  | openssl x509 -noout -dates -ext subjectAltName
```

## 9. Close out DigitalOcean

There is no rollback path to DO (the zone is already gone), so this is just
billing hygiene:

1. Snapshot the droplet if you want anything off its disk.
2. Destroy the droplet.
3. Confirm the DO billing page shows $0 pending for next month.

Raise the DNS TTLs to 3600 once you're happy with the new setup.

---

## Operating notes

```bash
systemctl status zuallite          # Flask app
journalctl -u zuallite -f          # its logs (gunicorn logs to stdout)
sudo -u ghostadmin ghost status    # from /var/www/blog
```

The systemd unit runs gunicorn with `ProtectSystem=strict` on a read-only
filesystem — the app writes nothing. If you later add something that needs
disk, add an explicit `ReadWritePaths=` rather than relaxing the unit.

Ghost majors (`ghost update --major`) need a manual run roughly yearly. Node
and MySQL come from apt and unattended-upgrades covers security patches only.
