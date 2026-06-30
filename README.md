# Hermes Ubuntu Setup

Idempotent scripts for installing Hermes Agent on Ubuntu Server under a
dedicated `hermes` user, without root or sudo access for that user.

Setup:

- creates the `hermes` user and group
- removes the user from privileged groups such as `sudo`, `docker`, and `lxd`
- installs apt packages from `hermes-packages.json`
- installs Hermes Agent under `/home/hermes/.hermes`
- configures Telegram through `/home/hermes/.hermes/.env`
- installs the gateway as the `hermes-gateway.service` systemd service, while
  the process itself runs as `User=hermes`

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
export OPENROUTER_API_KEY='sk-or-...'
```

Get `TELEGRAM_BOT_TOKEN` from BotFather. `TELEGRAM_ALLOWED_USERS` is the numeric
Telegram user ID, for example from `@userinfobot`.

Copy the whole bundle to the host:

```bash
ssh "$HERMES_HOST" "mkdir -p '$HERMES_REMOTE_DIR'"
scp setup-hermes-ubuntu.sh uninstall-hermes-ubuntu.sh hermes-packages.json "$HERMES_HOST:$HERMES_REMOTE_DIR/"
```

Run setup as an admin/root user:

```bash
ssh "$HERMES_HOST" "cd '$HERMES_REMOTE_DIR' && sudo env \
  TELEGRAM_BOT_TOKEN='$TELEGRAM_BOT_TOKEN' \
  TELEGRAM_ALLOWED_USERS='$TELEGRAM_ALLOWED_USERS' \
  OPENROUTER_API_KEY='$OPENROUTER_API_KEY' \
  bash setup-hermes-ubuntu.sh"
```

## Important Variables

- `HERMES_USER=hermes` - account name
- `HERMES_START_SERVICE=1` - starts the service after installation
- `HERMES_INSTALL_OFFICE_PACKAGES=1` - also installs heavier document tools:
  `libreoffice`, `pandoc`, `poppler-utils`, `imagemagick`
- `HERMES_PACKAGE_JSON=/path/to/hermes-packages.json` - custom package manifest
  path

## Verification

```bash
ssh "$HERMES_HOST" 'systemctl status hermes-gateway.service --no-pager'
ssh "$HERMES_HOST" 'journalctl -u hermes-gateway.service -f'
ssh "$HERMES_HOST" 'sudo -iu hermes'
```

Setup verifies that the `hermes` user can see `hermes`, `node`, `npm`, `npx`,
`uv`, and `uvx`.

## Uninstall

The default teardown removes the user, home directory, service, sudoers rule,
state directory, and only the apt packages that setup actually installed.

```bash
ssh "$HERMES_HOST" "cd '$HERMES_REMOTE_DIR' && sudo bash uninstall-hermes-ubuntu.sh"
```

To aggressively remove every installed package listed in `hermes-packages.json`:

```bash
ssh "$HERMES_HOST" "cd '$HERMES_REMOTE_DIR' && sudo env HERMES_PURGE_ALL_LISTED_PACKAGES=1 bash uninstall-hermes-ubuntu.sh"
```
