# Hermes Ubuntu Setup

Idempotent scripts for installing Hermes Agent on Ubuntu Server under a
dedicated `hermes` user, without root or sudo access for that user.

Setup:

- creates the `hermes` user and group
- removes the user from privileged groups such as `sudo`, `docker`, and `lxd`
- installs apt packages from `hermes-packages.json`
- installs Hermes Agent under `/home/hermes/.hermes`
- configures Telegram through `/home/hermes/.hermes/.env`
- installs a managed startup-context block in `/home/hermes/.hermes/SOUL.md`
  so Hermes knows how to update and restart itself without sudo
- installs the gateway as the `hermes-gateway.service` systemd service, while
  the process itself runs as `User=hermes`
- optionally installs a Tailscale-reachable dashboard as
  `hermes-dashboard.service`, also running as `User=hermes`

## Files

- `setup-hermes-ubuntu.sh` - installation and configuration
- `uninstall-hermes-ubuntu.sh` - teardown for resources created by setup
- `hermes-packages.json` - apt package manifest and required user-space tools

## Setup

Set the variables once in your local shell:

```bash
export HERMES_HOST='admin@HOST'
export HERMES_REMOTE_DIR='/tmp/hermes-setup'

export TELEGRAM_BOT_TOKEN='123:abc'
export TELEGRAM_ALLOWED_USERS='123456789'
export OPENCODE_GO_API_KEY='...'

# Optional but recommended: choose a model supported by your provider.
# export HERMES_MODEL_PROVIDER='opencode-go'
# export HERMES_MODEL_DEFAULT='REPLACE_WITH_SUPPORTED_MODEL'
# export HERMES_MODEL_API_MODE='chat_completions'

export HERMES_INSTALL_TAILSCALE='1'
# Optional but recommended for unattended setup:
# export TAILSCALE_AUTHKEY='tskey-auth-...'
# Optional display name in Tailscale:
# export TAILSCALE_HOSTNAME='baden'

export HERMES_DASHBOARD_ENABLE='1'
export HERMES_DASHBOARD_HOST='tailscale'
export HERMES_DASHBOARD_PORT='9119'
export HERMES_DASHBOARD_TLS_ENABLE='0'
# One-time cleanup after trying the old MagicDNS/Tailscale Serve HTTPS path:
# export HERMES_TAILSCALE_SERVE_RESET='1'
export HERMES_DASHBOARD_USERNAME='admin'
# Optional: omit to auto-generate a strong first-run password.
# export HERMES_DASHBOARD_PASSWORD='choose-a-long-unique-password'
```

Get `TELEGRAM_BOT_TOKEN` from BotFather. `TELEGRAM_ALLOWED_USERS` is the numeric
Telegram user ID, for example from `@userinfobot`. Setup validates the bot
token with Telegram before starting the gateway. If Telegram rejects it, ask
BotFather for a fresh token with `/token`, update `TELEGRAM_BOT_TOKEN`, and
rerun setup.

For dashboard access, setup can install Tailscale. With
`HERMES_INSTALL_TAILSCALE=1`, setup installs `tailscaled` using the official
Tailscale Linux installer and enables the system service. If `TAILSCALE_AUTHKEY`
is set, setup also runs `tailscale up` unattended. If you omit
`TAILSCALE_AUTHKEY`, setup installs Tailscale but you must log the host in
manually.

Set `HERMES_DASHBOARD_HOST=tailscale` to bind the dashboard to the host's raw
Tailscale IPv4 address. This avoids MagicDNS, Tailscale Serve, nginx, and TLS
proxying. The dashboard is reachable only from machines that can reach that
tailnet IP, for example `http://100.x.y.z:9119`.

You can provide `HERMES_DASHBOARD_PASSWORD`, or omit it and let setup generate
one. The setup script stores a scrypt password hash in
`/home/hermes/.hermes/config.yaml`; it does not store
`HERMES_DASHBOARD_PASSWORD` in plaintext. If setup generates the password, a
root-only first-run copy is written to
`/var/lib/hermes-setup/dashboard-credentials.txt`.

`HERMES_DASHBOARD_TLS_ENABLE=1` is still available, but it requires a `*.ts.net`
MagicDNS hostname and Tailscale HTTPS certificates. For the simpler raw-IP
setup, keep `HERMES_DASHBOARD_TLS_ENABLE=0`.

Copy the whole bundle to the host:

```bash
ssh "$HERMES_HOST" "mkdir -p '$HERMES_REMOTE_DIR'"
scp setup-hermes-ubuntu.sh uninstall-hermes-ubuntu.sh hermes-packages.json "$HERMES_HOST:$HERMES_REMOTE_DIR/"
```

Run setup as an admin/root user:

```bash
ssh -t "$HERMES_HOST" "cd '$HERMES_REMOTE_DIR' && sudo env \
  TELEGRAM_BOT_TOKEN='$TELEGRAM_BOT_TOKEN' \
  TELEGRAM_ALLOWED_USERS='$TELEGRAM_ALLOWED_USERS' \
  OPENCODE_GO_API_KEY='$OPENCODE_GO_API_KEY' \
  HERMES_MODEL_PROVIDER='${HERMES_MODEL_PROVIDER:-}' \
  HERMES_MODEL_DEFAULT='${HERMES_MODEL_DEFAULT:-}' \
  HERMES_MODEL_API_MODE='${HERMES_MODEL_API_MODE:-}' \
  HERMES_MODEL_BASE_URL='${HERMES_MODEL_BASE_URL:-}' \
  HERMES_INSTALL_TAILSCALE='$HERMES_INSTALL_TAILSCALE' \
  TAILSCALE_AUTHKEY='${TAILSCALE_AUTHKEY:-}' \
  TAILSCALE_HOSTNAME='${TAILSCALE_HOSTNAME:-}' \
  HERMES_DASHBOARD_ENABLE='$HERMES_DASHBOARD_ENABLE' \
  HERMES_DASHBOARD_HOST='$HERMES_DASHBOARD_HOST' \
  HERMES_DASHBOARD_PORT='$HERMES_DASHBOARD_PORT' \
  HERMES_DASHBOARD_TLS_ENABLE='$HERMES_DASHBOARD_TLS_ENABLE' \
  HERMES_TAILSCALE_SERVE_RESET='${HERMES_TAILSCALE_SERVE_RESET:-0}' \
  HERMES_DASHBOARD_USERNAME='$HERMES_DASHBOARD_USERNAME' \
  HERMES_DASHBOARD_PASSWORD='${HERMES_DASHBOARD_PASSWORD:-}' \
  HERMES_START_SERVICE=1 \
  bash setup-hermes-ubuntu.sh"
```

Re-running setup is safe and is the supported way to repair or upgrade this
host. During a re-run, setup temporarily stops the Hermes gateway/dashboard,
recreates the Hermes Python virtual environment, and then starts the managed
services again.

## Important Variables

- `HERMES_USER=hermes` - account name
- `HERMES_START_SERVICE=1` - starts the service after installation
- `HERMES_INSTALL_OFFICE_PACKAGES=1` - also installs heavier document tools:
  `libreoffice`, `pandoc`, `poppler-utils`, `imagemagick`
- `HERMES_INSTALL_TAILSCALE=auto` - installs Tailscale automatically when the
  dashboard host is `tailscale`, `tailscale0`, or a `*.ts.net` hostname; set
  `1` to always install or `0` to skip
- `TAILSCALE_AUTHKEY` - optional auth key for unattended `tailscale up`
- `TAILSCALE_HOSTNAME=baden` - optional hostname passed to `tailscale up`
- `TAILSCALE_ADVERTISE_TAGS` / `TAILSCALE_ACCEPT_DNS` /
  `TAILSCALE_EXTRA_ARGS` - optional extra `tailscale up` settings
- `HERMES_MODEL_PROVIDER` / `HERMES_MODEL_DEFAULT` /
  `HERMES_MODEL_API_MODE` / `HERMES_MODEL_BASE_URL` - optional default model
  configuration written to `/home/hermes/.hermes/config.yaml`. The model name
  must be supported by the selected provider; for example, `opencode-go`
  rejects unsupported model names with `HTTP 401: Model ... is not supported`.
- `HERMES_STARTUP_CONTEXT_ENABLE=1` - writes a managed block to
  `/home/hermes/.hermes/SOUL.md` that tells Hermes to use
  `hermes-self-update` for self-updates and `hermes-gateway-restart` for
  self-restarts. Existing custom `SOUL.md` content is preserved.
- `HERMES_STARTUP_CONTEXT_FILE=/home/hermes/.hermes/SOUL.md` - override the
  startup context file path
- `HERMES_DASHBOARD_ENABLE=1` - installs and starts the dashboard service
- `HERMES_DASHBOARD_HOST=tailscale` - binds the dashboard to the host's raw
  Tailscale IPv4 address. You can also set a literal IP or hostname.
- `HERMES_DASHBOARD_PORT=9119` - dashboard port
- `HERMES_DASHBOARD_TLS_ENABLE=0` - raw Tailscale IP over HTTP. Set to `1` only
  for the optional MagicDNS/Tailscale Serve HTTPS path.
- `HERMES_DASHBOARD_TLS_PORT=9119` - public HTTPS port exposed by Tailscale
  Serve when TLS is enabled
- `HERMES_DASHBOARD_PROXY_PORT=9120` - localhost-only nginx proxy port used to
  rewrite the `Host` header before requests reach Hermes when TLS is enabled
- `HERMES_TAILSCALE_SERVE_RESET=1` - one-time cleanup switch for removing old
  Tailscale Serve configuration after switching back from MagicDNS/HTTPS to raw
  Tailscale IP. This runs `tailscale serve reset`, so use it only when this host
  is not serving anything else through Tailscale Serve.
- `HERMES_DASHBOARD_USERNAME=admin` - dashboard login username. If omitted on
  first setup, setup uses `admin`.
- `HERMES_DASHBOARD_PASSWORD` - first-run dashboard password. If omitted and no
  dashboard password already exists, setup generates a strong password and
  stores a root-only copy in `/var/lib/hermes-setup/dashboard-credentials.txt`.
  Later runs can omit the password unless you want to rotate it.
- `HERMES_PACKAGE_JSON=/path/to/hermes-packages.json` - custom package manifest
  path

## Verification

```bash
ssh "$HERMES_HOST" 'systemctl status hermes-gateway.service --no-pager'
ssh "$HERMES_HOST" 'systemctl status tailscaled --no-pager'
ssh "$HERMES_HOST" 'systemctl status hermes-dashboard.service --no-pager'
ssh "$HERMES_HOST" 'journalctl -u hermes-gateway.service -n 200 -o cat --no-pager'
ssh "$HERMES_HOST" 'journalctl -u hermes-gateway.service -f'
ssh -t "$HERMES_HOST" 'sudo cat /var/lib/hermes-setup/dashboard-credentials.txt'
ssh -t "$HERMES_HOST" 'sudo -iu hermes'
```

If you did not pass `TAILSCALE_AUTHKEY`, finish Tailscale login manually and
then start the dashboard:

```bash
ssh -t "$HERMES_HOST" 'sudo tailscale up'
ssh "$HERMES_HOST" 'sudo systemctl restart hermes-dashboard.service'
```

Setup verifies that the `hermes` user can see `hermes`, `node`, `npm`, `npx`,
`uv`, `uvx`, `hermes-dashboard-run`, `hermes-self-update`, and
`hermes-gateway-restart`.

To open the dashboard from a machine on the same tailnet:

```bash
export HERMES_TAILSCALE_IP="$(ssh "$HERMES_HOST" 'tailscale ip -4 | head -n 1')"
open "http://$HERMES_TAILSCALE_IP:$HERMES_DASHBOARD_PORT"
```

On Linux, replace `open` with `xdg-open`, or paste the URL into your browser.

If you previously enabled the MagicDNS/Tailscale Serve HTTPS path and the raw
IP says `Client sent an HTTP request to an HTTPS server`, old Tailscale Serve
configuration is still active on that port. Inspect it:

```bash
ssh "$HERMES_HOST" 'sudo tailscale serve status'
```

If that status only contains the old Hermes dashboard entry, clear it manually:

```bash
ssh -t "$HERMES_HOST" 'sudo tailscale serve reset'
```

`tailscale serve reset` removes all Tailscale Serve configuration on that node,
so do not run it if the host serves anything else through Tailscale Serve.
You can also do the same cleanup during setup by exporting
`HERMES_TAILSCALE_SERVE_RESET=1` for one run.

## Day-to-Day Operations

The `hermes` user can update its own Hermes runtime and request a gateway
restart without sudo:

```bash
ssh -t "$HERMES_HOST" 'sudo -iu hermes'
hermes-self-update
hermes-gateway-restart
```

`hermes-self-update` runs `hermes update` and then asks the running gateway
process to restart. `hermes-gateway-restart` sends a restart signal to the
gateway process owned by `hermes`; systemd brings the service back up because
the service itself is configured with restart supervision. The `hermes` user is
not granted `sudo` or permission to manage systemd directly.

Setup also writes this operational knowledge into the Hermes startup context
file, `/home/hermes/.hermes/SOUL.md`, using a managed block. That lets Hermes
know which commands to call when you ask it to update or restart itself.

## Uninstall

The default teardown removes the user, home directory, service, sudoers rule,
state directory, and only the apt packages that setup actually installed.
Tailscale is removed only if this setup installed it; set
`HERMES_REMOVE_TAILSCALE=0` to keep it.

```bash
ssh -t "$HERMES_HOST" "cd '$HERMES_REMOTE_DIR' && sudo bash uninstall-hermes-ubuntu.sh"
```

To aggressively remove every installed package listed in `hermes-packages.json`:

```bash
ssh -t "$HERMES_HOST" "cd '$HERMES_REMOTE_DIR' && sudo env HERMES_PURGE_ALL_LISTED_PACKAGES=1 bash uninstall-hermes-ubuntu.sh"
```
