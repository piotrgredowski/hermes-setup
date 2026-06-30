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

Copy the whole bundle to the host:

```bash
scp setup-hermes-ubuntu.sh uninstall-hermes-ubuntu.sh hermes-packages.json admin@HOST:/tmp/hermes-setup/
```

Run setup as an admin/root user:

```bash
ssh admin@HOST 'cd /tmp/hermes-setup && sudo -E TELEGRAM_BOT_TOKEN="123:abc" TELEGRAM_ALLOWED_USERS="123456789" OPENROUTER_API_KEY="sk-or-..." bash setup-hermes-ubuntu.sh'
```

Get `TELEGRAM_BOT_TOKEN` from BotFather. `TELEGRAM_ALLOWED_USERS` is the numeric
Telegram user ID, for example from `@userinfobot`.

## Important Variables

- `HERMES_USER=hermes` - account name
- `HERMES_START_SERVICE=1` - starts the service after installation
- `HERMES_INSTALL_OFFICE_PACKAGES=1` - also installs heavier document tools:
  `libreoffice`, `pandoc`, `poppler-utils`, `imagemagick`
- `HERMES_PACKAGE_JSON=/path/to/hermes-packages.json` - custom package manifest
  path

## Verification

```bash
ssh admin@HOST 'systemctl status hermes-gateway.service --no-pager'
ssh admin@HOST 'journalctl -u hermes-gateway.service -f'
ssh admin@HOST 'sudo -iu hermes'
```

Setup verifies that the `hermes` user can see `hermes`, `node`, `npm`, `npx`,
`uv`, and `uvx`.

## Uninstall

The default teardown removes the user, home directory, service, sudoers rule,
state directory, and only the apt packages that setup actually installed.

```bash
ssh admin@HOST 'cd /tmp/hermes-setup && sudo bash uninstall-hermes-ubuntu.sh'
```

To aggressively remove every installed package listed in `hermes-packages.json`:

```bash
ssh admin@HOST 'cd /tmp/hermes-setup && sudo -E HERMES_PURGE_ALL_LISTED_PACKAGES=1 bash uninstall-hermes-ubuntu.sh'
```
