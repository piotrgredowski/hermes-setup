#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent Hermes Agent bootstrap for Ubuntu Server.
#
# Intended model:
# - Run this script as root, or with sudo, on the Ubuntu host.
# - The script creates/repairs a dedicated unprivileged user.
# - Hermes is installed as that user under /home/hermes.
# - The gateway runs persistently as a systemd system service with User=hermes.
# - Tailscale can be installed/configured as a root-owned system service.
# - The hermes user is explicitly kept out of sudo/root-equivalent groups.
#
# Minimal example:
#   scp setup-hermes-ubuntu.sh uninstall-hermes-ubuntu.sh hermes-packages.json admin@HOST:/tmp/hermes-setup/
#   ssh admin@HOST 'cd /tmp/hermes-setup && sudo -E bash setup-hermes-ubuntu.sh'
#
# Minimal example with secrets:
#   TELEGRAM_BOT_TOKEN='123:abc' \
#   TELEGRAM_ALLOWED_USERS='123456789' \
#   OPENROUTER_API_KEY='sk-or-...' \
#   sudo -E bash setup-hermes-ubuntu.sh
#
# If the package manifest is elsewhere, pass HERMES_PACKAGE_JSON=/path/to/hermes-packages.json.

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_GROUP="${HERMES_GROUP:-$HERMES_USER}"
HERMES_HOME_DIR="${HERMES_HOME_DIR:-/home/$HERMES_USER}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-$HERMES_HOME_DIR/.hermes}"
HERMES_WORK_DIR="${HERMES_WORK_DIR:-$HERMES_HOME_DIR/work}"
HERMES_INSTALL_URL="${HERMES_INSTALL_URL:-https://hermes-agent.nousresearch.com/install.sh}"
HERMES_BRANCH="${HERMES_BRANCH:-main}"
HERMES_COMMIT="${HERMES_COMMIT:-}"
HERMES_SKIP_BROWSER="${HERMES_SKIP_BROWSER:-0}"
HERMES_START_SERVICE="${HERMES_START_SERVICE:-1}"
HERMES_INSTALL_SYSTEM_PACKAGES="${HERMES_INSTALL_SYSTEM_PACKAGES:-1}"
HERMES_INSTALL_PLAYWRIGHT_SYSTEM_DEPS="${HERMES_INSTALL_PLAYWRIGHT_SYSTEM_DEPS:-1}"
HERMES_INSTALL_OFFICE_PACKAGES="${HERMES_INSTALL_OFFICE_PACKAGES:-0}"
HERMES_INSTALL_TAILSCALE="${HERMES_INSTALL_TAILSCALE:-auto}"
HERMES_SERVICE_NAME="${HERMES_SERVICE_NAME:-hermes-gateway.service}"
HERMES_DASHBOARD_ENABLE="${HERMES_DASHBOARD_ENABLE:-0}"
HERMES_DASHBOARD_SERVICE_NAME="${HERMES_DASHBOARD_SERVICE_NAME:-hermes-dashboard.service}"
HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-tailscale}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_DASHBOARD_START="${HERMES_DASHBOARD_START:-$HERMES_START_SERVICE}"
HERMES_DASHBOARD_TLS_ENABLE="${HERMES_DASHBOARD_TLS_ENABLE:-0}"
HERMES_DASHBOARD_TLS_PORT="${HERMES_DASHBOARD_TLS_PORT:-$HERMES_DASHBOARD_PORT}"
HERMES_DASHBOARD_PROXY_PORT="${HERMES_DASHBOARD_PROXY_PORT:-9120}"
HERMES_TAILSCALE_SERVE_RESET="${HERMES_TAILSCALE_SERVE_RESET:-0}"
HERMES_MODEL_PROVIDER="${HERMES_MODEL_PROVIDER:-}"
HERMES_MODEL_DEFAULT="${HERMES_MODEL_DEFAULT:-}"
HERMES_MODEL_API_MODE="${HERMES_MODEL_API_MODE:-}"
HERMES_MODEL_BASE_URL="${HERMES_MODEL_BASE_URL:-}"
HERMES_HOME_MODE="${HERMES_HOME_MODE:-750}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || pwd)"
DEFAULT_PACKAGE_JSON="$SCRIPT_DIR/hermes-packages.json"
if [[ ! -f "$DEFAULT_PACKAGE_JSON" && -f "$PWD/hermes-packages.json" ]]; then
  DEFAULT_PACKAGE_JSON="$PWD/hermes-packages.json"
fi
HERMES_PACKAGE_JSON="${HERMES_PACKAGE_JSON:-$DEFAULT_PACKAGE_JSON}"
HERMES_STATE_DIR="${HERMES_STATE_DIR:-/var/lib/hermes-setup}"
HERMES_APT_INSTALLED_BY_US_FILE="${HERMES_APT_INSTALLED_BY_US_FILE:-$HERMES_STATE_DIR/apt-installed-by-hermes.txt}"
HERMES_DASHBOARD_CREDENTIALS_FILE="${HERMES_DASHBOARD_CREDENTIALS_FILE:-$HERMES_STATE_DIR/dashboard-credentials.txt}"
HERMES_TAILSCALE_INSTALLED_BY_US_FILE="${HERMES_TAILSCALE_INSTALLED_BY_US_FILE:-$HERMES_STATE_DIR/tailscale-installed-by-hermes}"

TAILSCALE_INSTALL_URL="${TAILSCALE_INSTALL_URL:-https://tailscale.com/install.sh}"
TAILSCALE_TRACK="${TAILSCALE_TRACK:-stable}"
TAILSCALE_VERSION="${TAILSCALE_VERSION:-}"
TAILSCALE_FORCE_UP="${TAILSCALE_FORCE_UP:-0}"
HERMES_DASHBOARD_STARTED=0

PRIVILEGED_GROUPS=(
  adm
  admin
  docker
  kvm
  libvirt
  lxd
  root
  sudo
  wheel
)

OPTIONAL_ENV_KEYS=(
  OPENROUTER_API_KEY
  NOVITA_API_KEY
  GOOGLE_API_KEY
  GEMINI_API_KEY
  HF_TOKEN
  KIMI_API_KEY
  GLM_API_KEY
  OLLAMA_API_KEY
  OPENCODE_ZEN_API_KEY
  OPENCODE_GO_API_KEY
  OPENAI_API_KEY
  ANTHROPIC_API_KEY
  TELEGRAM_ALLOWED_CHATS
  TELEGRAM_GROUP_ALLOWED_USERS
  TELEGRAM_GROUP_ALLOWED_CHATS
  TELEGRAM_HOME_CHANNEL
  TELEGRAM_HOME_CHANNEL_NAME
  TELEGRAM_CRON_THREAD_ID
  TELEGRAM_OBSERVE_UNMENTIONED_GROUP_MESSAGES
  TELEGRAM_PROXY
  TELEGRAM_REACTIONS
)

LLM_PROVIDER_KEYS=(
  OPENROUTER_API_KEY
  NOVITA_API_KEY
  GOOGLE_API_KEY
  GEMINI_API_KEY
  HF_TOKEN
  KIMI_API_KEY
  GLM_API_KEY
  OLLAMA_API_KEY
  OPENCODE_ZEN_API_KEY
  OPENCODE_GO_API_KEY
  OPENAI_API_KEY
  ANTHROPIC_API_KEY
)

log() {
  printf '[hermes-setup] %s\n' "$*"
}

warn() {
  printf '[hermes-setup] WARN: %s\n' "$*" >&2
}

die() {
  printf '[hermes-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "run as root, e.g. sudo -E bash setup-hermes-ubuntu.sh"
  fi
}

require_ubuntu_systemd() {
  if [[ ! -r /etc/os-release ]]; then
    die "cannot detect OS: /etc/os-release is missing"
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" && "${ID_LIKE:-}" != *"ubuntu"* && "${ID_LIKE:-}" != *"debian"* ]]; then
    warn "this script is tuned for Ubuntu/Debian-like hosts; detected ID=${ID:-unknown}"
  fi

  command -v systemctl >/dev/null 2>&1 || die "systemctl is required"
  [[ -d /run/systemd/system ]] || die "systemd does not appear to be PID 1"
}

require_package_json() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read $HERMES_PACKAGE_JSON"
  [[ -r "$HERMES_PACKAGE_JSON" ]] || die "package manifest not found: $HERMES_PACKAGE_JSON"
  python3 -m json.tool "$HERMES_PACKAGE_JSON" >/dev/null || die "invalid JSON: $HERMES_PACKAGE_JSON"
}

json_list() {
  python3 - "$HERMES_PACKAGE_JSON" "$@" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
paths = sys.argv[2:]
with open(manifest_path, "r", encoding="utf-8") as f:
    data = json.load(f)

seen = set()
for path in paths:
    node = data
    for part in path.split("."):
        node = node[part]
    if not isinstance(node, list):
        raise SystemExit(f"{path} is not a list")
    for item in node:
        if not isinstance(item, str):
            raise SystemExit(f"{path} contains a non-string item")
        if item not in seen:
            seen.add(item)
            print(item)
PY
}

json_alternatives() {
  python3 - "$HERMES_PACKAGE_JSON" "$1" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
path = sys.argv[2]
with open(manifest_path, "r", encoding="utf-8") as f:
    data = json.load(f)

node = data
for part in path.split("."):
    node = node[part]
if not isinstance(node, list):
    raise SystemExit(f"{path} is not a list")

for entry in node:
    packages = entry.get("packages") if isinstance(entry, dict) else None
    if not packages or not all(isinstance(pkg, str) for pkg in packages):
        raise SystemExit(f"{path} contains an invalid alternatives entry")
    print("\t".join(packages))
PY
}

apt_package_exists() {
  apt-cache show "$1" >/dev/null 2>&1
}

apt_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fxq "install ok installed"
}

record_packages_installed_by_us() {
  local -a packages=("$@")
  ((${#packages[@]} > 0)) || return 0

  install -d -m 755 -o root -g root "$HERMES_STATE_DIR"
  touch "$HERMES_APT_INSTALLED_BY_US_FILE"
  chmod 0644 "$HERMES_APT_INSTALLED_BY_US_FILE"
  {
    cat "$HERMES_APT_INSTALLED_BY_US_FILE"
    printf '%s\n' "${packages[@]}"
  } | awk 'NF' | sort -u > "$HERMES_APT_INSTALLED_BY_US_FILE.tmp"
  install -m 0644 -o root -g root "$HERMES_APT_INSTALLED_BY_US_FILE.tmp" "$HERMES_APT_INSTALLED_BY_US_FILE"
  rm -f "$HERMES_APT_INSTALLED_BY_US_FILE.tmp"
}

first_available_package() {
  local candidate
  for candidate in "$@"; do
    if apt_package_exists "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

apt_install_available() {
  local -a available=()
  local -a missing=()
  local -a not_previously_installed=()
  local pkg

  for pkg in "$@"; do
    if apt_package_exists "$pkg"; then
      available+=("$pkg")
      if ! apt_package_installed "$pkg"; then
        not_previously_installed+=("$pkg")
      fi
    else
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]} > 0)); then
    warn "skipping unavailable apt packages: ${missing[*]}"
  fi

  if ((${#available[@]} > 0)); then
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
      apt-get install -y --no-install-recommends "${available[@]}"
  fi

  local -a installed_by_this_run=()
  for pkg in "${not_previously_installed[@]}"; do
    if apt_package_installed "$pkg"; then
      installed_by_this_run+=("$pkg")
    fi
  done
  record_packages_installed_by_us "${installed_by_this_run[@]}"
}

install_system_packages() {
  if [[ "$HERMES_INSTALL_SYSTEM_PACKAGES" != "1" ]]; then
    log "Skipping apt package install because HERMES_INSTALL_SYSTEM_PACKAGES=$HERMES_INSTALL_SYSTEM_PACKAGES"
    return
  fi

  log "Installing system packages needed by Hermes and browser tools"
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get update

  local -a base_packages=()
  mapfile -t base_packages < <(json_list apt.base apt.agent_tools)
  apt_install_available "${base_packages[@]}"

  if [[ "$HERMES_INSTALL_OFFICE_PACKAGES" == "1" ]]; then
    local -a office_packages=()
    mapfile -t office_packages < <(json_list apt.office_optional)
    apt_install_available "${office_packages[@]}"
  fi

  if [[ "$HERMES_INSTALL_PLAYWRIGHT_SYSTEM_DEPS" == "1" ]]; then
    local -a browser_packages=()
    mapfile -t browser_packages < <(json_list apt.browser)
    local -a alternatives=()
    local selected=""
    while IFS=$'\t' read -r -a alternatives; do
      selected="$(first_available_package "${alternatives[@]}" || true)"
      if [[ -n "$selected" ]]; then
        browser_packages+=("$selected")
      else
        warn "skipping unavailable package alternatives: ${alternatives[*]}"
      fi
    done < <(json_alternatives apt.browser_alternatives)
    apt_install_available "${browser_packages[@]}"
  fi
}

dashboard_host_is_tailscale() {
  local host_lc="${HERMES_DASHBOARD_HOST,,}"
  case "$host_lc" in
    tailscale|tailscale0|*.ts.net)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

tailscale_requested() {
  case "${HERMES_INSTALL_TAILSCALE,,}" in
    1|true|yes|on)
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    auto)
      [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] && dashboard_host_is_tailscale
      return
      ;;
    *)
      die "HERMES_INSTALL_TAILSCALE must be 1, 0, or auto"
      ;;
  esac
}

tailscale_ipv4() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale ip -4 2>/dev/null | awk 'NF { print; exit }'
}

tailscale_has_ip() {
  [[ -n "$(tailscale_ipv4)" ]]
}

dashboard_tls_enabled() {
  [[ "$HERMES_DASHBOARD_TLS_ENABLE" == "1" ]]
}

dashboard_url() {
  [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] || return 1

  local scheme="http"
  local host="$HERMES_DASHBOARD_HOST"
  local port="$HERMES_DASHBOARD_PORT"

  if dashboard_tls_enabled; then
    scheme="https"
    port="$HERMES_DASHBOARD_TLS_PORT"
  fi

  case "${host,,}" in
    tailscale|tailscale0)
      host="$(tailscale_ipv4 || true)"
      [[ -n "$host" ]] || return 1
      ;;
  esac

  printf '%s://%s:%s/login?next=%%2F\n' "$scheme" "$host" "$port"
}

install_tailscale() {
  tailscale_requested || return 0

  local had_tailscale=0
  local installer=""
  local -a installed_by_setup=()

  if apt_package_installed tailscale || command -v tailscale >/dev/null 2>&1; then
    had_tailscale=1
  fi

  if ! command -v tailscale >/dev/null 2>&1 || ! command -v tailscaled >/dev/null 2>&1; then
    log "Installing Tailscale via official installer"
    installer="$(mktemp)"
    curl -fsSL "$TAILSCALE_INSTALL_URL" -o "$installer"
    TRACK="$TAILSCALE_TRACK" TAILSCALE_VERSION="$TAILSCALE_VERSION" sh "$installer"
    rm -f "$installer"
  else
    log "Tailscale is already installed"
  fi

  command -v tailscale >/dev/null 2>&1 || die "tailscale command is not available after installation"
  command -v tailscaled >/dev/null 2>&1 || die "tailscaled command is not available after installation"

  if [[ "$had_tailscale" != "1" ]]; then
    local pkg
    for pkg in tailscale tailscale-archive-keyring; do
      if apt_package_installed "$pkg"; then
        installed_by_setup+=("$pkg")
      fi
    done
    record_packages_installed_by_us "${installed_by_setup[@]}"
    install -d -m 755 -o root -g root "$HERMES_STATE_DIR"
    touch "$HERMES_TAILSCALE_INSTALLED_BY_US_FILE"
    chmod 0644 "$HERMES_TAILSCALE_INSTALLED_BY_US_FILE"
  fi

  log "Enabling tailscaled"
  systemctl enable --now tailscaled

  configure_tailscale_login
}

install_dashboard_tls_proxy_packages() {
  [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] || return 0
  dashboard_tls_enabled || return 0

  log "Installing dashboard TLS reverse proxy packages"
  local -a proxy_packages=()
  mapfile -t proxy_packages < <(json_list apt.dashboard_tls_proxy_optional)
  apt_install_available "${proxy_packages[@]}"
}

configure_tailscale_login() {
  tailscale_requested || return 0

  if tailscale_has_ip && [[ "$TAILSCALE_FORCE_UP" != "1" ]]; then
    log "Tailscale is already up"
    return 0
  fi

  if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
    warn "Tailscale is installed but not logged in. Provide TAILSCALE_AUTHKEY for unattended setup, or run: sudo tailscale up"
    return 0
  fi

  local -a up_args=(up --authkey "$TAILSCALE_AUTHKEY")
  local -a extra_args=()

  if [[ -n "${TAILSCALE_HOSTNAME:-}" ]]; then
    up_args+=(--hostname "$TAILSCALE_HOSTNAME")
  fi
  if [[ -n "${TAILSCALE_ADVERTISE_TAGS:-}" ]]; then
    up_args+=(--advertise-tags "$TAILSCALE_ADVERTISE_TAGS")
  fi
  if [[ -n "${TAILSCALE_ACCEPT_DNS:-}" ]]; then
    up_args+=(--accept-dns="$TAILSCALE_ACCEPT_DNS")
  fi
  if [[ -n "${TAILSCALE_EXTRA_ARGS:-}" ]]; then
    # Simple extra flags only; quoted shell fragments are intentionally not eval'd.
    read -r -a extra_args <<<"$TAILSCALE_EXTRA_ARGS"
    up_args+=("${extra_args[@]}")
  fi

  log "Bringing Tailscale up"
  tailscale "${up_args[@]}"
}

ensure_group_and_user() {
  [[ "$HERMES_USER" != "root" ]] || die "HERMES_USER must not be root"

  if ! getent group "$HERMES_GROUP" >/dev/null; then
    log "Creating group $HERMES_GROUP"
    groupadd "$HERMES_GROUP"
  fi

  if id "$HERMES_USER" >/dev/null 2>&1; then
    local uid
    uid="$(id -u "$HERMES_USER")"
    [[ "$uid" != "0" ]] || die "existing user $HERMES_USER has uid 0; refusing"

    local existing_home
    existing_home="$(getent passwd "$HERMES_USER" | cut -d: -f6)"
    if [[ "$existing_home" != "$HERMES_HOME_DIR" ]]; then
      die "existing user $HERMES_USER has home $existing_home, expected $HERMES_HOME_DIR; set HERMES_HOME_DIR=$existing_home or choose another HERMES_USER"
    fi
  else
    log "Creating unprivileged user $HERMES_USER"
    useradd \
      --create-home \
      --home-dir "$HERMES_HOME_DIR" \
      --shell /bin/bash \
      --gid "$HERMES_GROUP" \
      "$HERMES_USER"
  fi

  usermod --shell /bin/bash "$HERMES_USER"
  install -d -m "$HERMES_HOME_MODE" -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_HOME_DIR"
  install -d -m 700 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_DATA_DIR"
  install -d -m 755 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_HOME_DIR/.local"
  install -d -m 755 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_HOME_DIR/.local/bin"
  install -d -m 755 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_HOME_DIR/.local/share"
  install -d -m 700 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_HOME_DIR/.cache"
  install -d -m 755 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_WORK_DIR"
}

remove_privileged_groups() {
  local primary_group
  primary_group="$(id -gn "$HERMES_USER")"

  local group
  for group in "${PRIVILEGED_GROUPS[@]}"; do
    getent group "$group" >/dev/null || continue
    if id -nG "$HERMES_USER" | tr ' ' '\n' | grep -Fxq "$group"; then
      if [[ "$primary_group" == "$group" ]]; then
        die "$HERMES_USER has privileged primary group $group; refusing"
      fi
      log "Removing $HERMES_USER from privileged group $group"
      gpasswd -d "$HERMES_USER" "$group" >/dev/null || true
    fi
  done

  for group in "${PRIVILEGED_GROUPS[@]}"; do
    getent group "$group" >/dev/null || continue
    if id -nG "$HERMES_USER" | tr ' ' '\n' | grep -Fxq "$group"; then
      die "$HERMES_USER is still a member of privileged group $group"
    fi
  done
}

install_sudo_deny_rule() {
  if ! command -v visudo >/dev/null 2>&1 || [[ ! -d /etc/sudoers.d ]]; then
    warn "visudo or /etc/sudoers.d not present; group removal remains the sudo boundary"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  {
    printf '# Managed by setup-hermes-ubuntu.sh\n'
    printf '# Defense-in-depth: %s must not be granted sudo by broad group rules.\n' "$HERMES_USER"
    printf '%s ALL=(ALL:ALL) !ALL\n' "$HERMES_USER"
  } >"$tmp"
  chmod 0440 "$tmp"

  if visudo -cf "$tmp" >/dev/null; then
    install -m 0440 -o root -g root "$tmp" "/etc/sudoers.d/99-${HERMES_USER}-no-sudo"
  else
    rm -f "$tmp"
    die "generated sudoers deny rule did not pass visudo validation"
  fi
  rm -f "$tmp"
}

configure_user_shell() {
  local profile="$HERMES_HOME_DIR/.profile"
  local bashrc="$HERMES_HOME_DIR/.bashrc"
  local block

  block="$(cat <<'EOF'
# >>> hermes local tools >>>
export PATH="$HOME/.hermes/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.hermes/node/bin:$PATH"
export npm_config_prefix="$HOME/.local"
# <<< hermes local tools <<<
EOF
)"

  touch "$profile" "$bashrc"
  chown "$HERMES_USER:$HERMES_GROUP" "$profile" "$bashrc"

  update_managed_shell_block "$profile" "$block"
  update_managed_shell_block "$bashrc" "$block"

  printf 'prefix=%s/.local\n' "$HERMES_HOME_DIR" >"$HERMES_HOME_DIR/.npmrc"
  chown "$HERMES_USER:$HERMES_GROUP" "$HERMES_HOME_DIR/.npmrc"
  chmod 0644 "$HERMES_HOME_DIR/.npmrc"
}

update_managed_shell_block() {
  local file="$1"
  local block="$2"
  local tmp
  tmp="$(mktemp)"
  awk '
    /^# >>> hermes local tools >>>$/ { skip = 1; next }
    /^# <<< hermes local tools <<<$/{ skip = 0; next }
    !skip { print }
  ' "$file" >"$tmp"
  printf '\n%s\n' "$block" >>"$tmp"
  install -m 0644 -o "$HERMES_USER" -g "$HERMES_GROUP" "$tmp" "$file"
  rm -f "$tmp"
}

configure_authorized_keys() {
  if [[ -z "${HERMES_AUTHORIZED_KEYS:-}" && -z "${HERMES_AUTHORIZED_KEYS_FILE:-}" ]]; then
    return
  fi

  local ssh_dir="$HERMES_HOME_DIR/.ssh"
  local authorized_keys="$ssh_dir/authorized_keys"
  install -d -m 700 -o "$HERMES_USER" -g "$HERMES_GROUP" "$ssh_dir"
  touch "$authorized_keys"
  chmod 600 "$authorized_keys"
  chown "$HERMES_USER:$HERMES_GROUP" "$authorized_keys"

  if [[ -n "${HERMES_AUTHORIZED_KEYS_FILE:-}" ]]; then
    [[ -r "$HERMES_AUTHORIZED_KEYS_FILE" ]] || die "cannot read HERMES_AUTHORIZED_KEYS_FILE=$HERMES_AUTHORIZED_KEYS_FILE"
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      grep -Fxq "$key" "$authorized_keys" || printf '%s\n' "$key" >>"$authorized_keys"
    done <"$HERMES_AUTHORIZED_KEYS_FILE"
  fi

  if [[ -n "${HERMES_AUTHORIZED_KEYS:-}" ]]; then
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      grep -Fxq "$key" "$authorized_keys" || printf '%s\n' "$key" >>"$authorized_keys"
    done <<<"$HERMES_AUTHORIZED_KEYS"
  fi

  chown "$HERMES_USER:$HERMES_GROUP" "$authorized_keys"
  chmod 600 "$authorized_keys"
}

run_as_hermes() {
  local command="$1"
  runuser -u "$HERMES_USER" -- \
    env \
      HOME="$HERMES_HOME_DIR" \
      USER="$HERMES_USER" \
      LOGNAME="$HERMES_USER" \
      SHELL=/bin/bash \
      HERMES_HOME="$HERMES_DATA_DIR" \
      PATH="$HERMES_DATA_DIR/bin:$HERMES_HOME_DIR/.local/bin:$HERMES_HOME_DIR/.cargo/bin:$HERMES_HOME_DIR/go/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin" \
      bash -lc "$command"
}

stop_existing_hermes_services_for_update() {
  local service
  local -a services=("$HERMES_DASHBOARD_SERVICE_NAME" "$HERMES_SERVICE_NAME")

  for service in "${services[@]}"; do
    [[ -n "$service" ]] || continue
    if systemctl cat "$service" >/dev/null 2>&1 || [[ -e "/etc/systemd/system/$service" ]]; then
      log "Stopping $service before Hermes update"
      systemctl stop "$service" >/dev/null 2>&1 || true
    fi
  done
}

clean_broken_hermes_venv() {
  local venv_dir="$HERMES_DATA_DIR/hermes-agent/venv"
  [[ -d "$venv_dir" ]] || return 0

  log "Removing existing Hermes virtual environment before update"
  run_as_hermes "rm -rf $(printf '%q' "$venv_dir")"
  if [[ -e "$venv_dir" ]]; then
    rm -rf --one-file-system "$venv_dir" || true
  fi
  [[ ! -e "$venv_dir" ]] || die "could not remove existing Hermes virtual environment at $venv_dir"
}

install_hermes_agent() {
  local -a args=(--skip-setup --non-interactive --branch "$HERMES_BRANCH")
  if [[ "$HERMES_SKIP_BROWSER" == "1" ]]; then
    args+=(--skip-browser)
  fi
  if [[ -n "$HERMES_COMMIT" ]]; then
    args+=(--commit "$HERMES_COMMIT")
  fi

  local quoted_args=""
  printf -v quoted_args '%q ' "${args[@]}"

  log "Installing/updating Hermes Agent as $HERMES_USER"
  run_as_hermes "curl -fsSL $(printf '%q' "$HERMES_INSTALL_URL") | bash -s -- $quoted_args"

  run_as_hermes "command -v hermes >/dev/null && hermes --help >/dev/null"
}

ensure_user_tool_shims() {
  local tool
  for tool in uv uvx; do
    if [[ -x "$HERMES_DATA_DIR/bin/$tool" ]]; then
      ln -sfn "$HERMES_DATA_DIR/bin/$tool" "$HERMES_HOME_DIR/.local/bin/$tool"
      chown -h "$HERMES_USER:$HERMES_GROUP" "$HERMES_HOME_DIR/.local/bin/$tool" 2>/dev/null || true
    fi
  done
}

install_user_operation_helpers() {
  local helper_dir="$HERMES_HOME_DIR/.local/bin"
  install -d -m 755 -o "$HERMES_USER" -g "$HERMES_GROUP" "$helper_dir"

  cat > "$helper_dir/hermes-gateway-restart" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export PATH="$HERMES_HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HERMES_HOME/node/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

own_uid="$(id -u)"

pid_is_ours() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  [[ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" == "$own_uid" ]]
}

find_gateway_pids() {
  local pid=""
  local pid_file="$HERMES_HOME/gateway.pid"

  if [[ -r "$pid_file" ]]; then
    pid="$(tr -dc '0-9' < "$pid_file" || true)"
    if pid_is_ours "$pid"; then
      printf '%s\n' "$pid"
    fi
  fi

  pgrep -u "$own_uid" -f 'hermes_cli\.main.*gateway run' 2>/dev/null || true
}

mapfile -t pids < <(find_gateway_pids | awk 'NF' | sort -un)

if ((${#pids[@]} == 0)); then
  echo "No running Hermes gateway process found for user $(id -un)." >&2
  exit 1
fi

for pid in "${pids[@]}"; do
  kill -USR1 "$pid"
done

echo "Requested graceful Hermes gateway restart for PID(s): ${pids[*]}"
EOF

  cat > "$helper_dir/hermes-self-update" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export PATH="$HERMES_HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HERMES_HOME/node/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

hermes update "$@"

if command -v hermes-gateway-restart >/dev/null 2>&1; then
  if ! hermes-gateway-restart; then
    echo "Hermes updated, but no running gateway process was restarted." >&2
  fi
else
  echo "Hermes updated. Restart helper not found; restart the gateway manually." >&2
fi
EOF

  cat > "$helper_dir/hermes-dashboard-run" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

export HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
export PATH="$HERMES_HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HERMES_HOME/node/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

resolve_tailscale_host() {
  local ip_addr=""

  if command -v tailscale >/dev/null 2>&1; then
    ip_addr="$(tailscale ip -4 2>/dev/null | awk 'NF { print; exit }' || true)"
  fi

  if [[ -z "$ip_addr" ]] && command -v ip >/dev/null 2>&1; then
    ip_addr="$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }' || true)"
  fi

  if [[ -z "$ip_addr" ]]; then
    echo "Could not determine a Tailscale IPv4 address. Is tailscaled running and logged in?" >&2
    return 1
  fi

  printf '%s\n' "$ip_addr"
}

host="${HERMES_DASHBOARD_HOST:-127.0.0.1}"
port="${HERMES_DASHBOARD_PORT:-9119}"

if [[ "${HERMES_DASHBOARD_TLS_ENABLE:-0}" == "1" ]]; then
  host="127.0.0.1"
fi

case "${host,,}" in
  tailscale|tailscale0)
    host="$(resolve_tailscale_host)"
    ;;
  0.0.0.0|::)
    if [[ "${HERMES_DASHBOARD_ALLOW_ALL_INTERFACES:-0}" != "1" ]]; then
      echo "Refusing to bind Hermes dashboard to $host without HERMES_DASHBOARD_ALLOW_ALL_INTERFACES=1." >&2
      echo "Use HERMES_DASHBOARD_HOST=tailscale for tailnet-only access." >&2
      exit 1
    fi
    ;;
esac

exec hermes dashboard --no-open --host "$host" --port "$port"
EOF

  chown "$HERMES_USER:$HERMES_GROUP" \
    "$helper_dir/hermes-gateway-restart" \
    "$helper_dir/hermes-self-update" \
    "$helper_dir/hermes-dashboard-run"
  chmod 0755 \
    "$helper_dir/hermes-gateway-restart" \
    "$helper_dir/hermes-self-update" \
    "$helper_dir/hermes-dashboard-run"
}

dotenv_quote() {
  local value="$1"
  if [[ "$value" =~ ^[A-Za-z0-9_./:@,+%=-]+$ ]]; then
    printf '%s' "$value"
    return
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  value="${value//\`/\\\`}"
  printf '"%s"' "$value"
}

dotenv_get_raw() {
  local key="$1"
  local file="$HERMES_DATA_DIR/.env"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
}

dotenv_has_value() {
  local key="$1"
  local value
  value="$(dotenv_get_raw "$key")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  [[ -n "$value" && "$value" != "your-token-here" ]]
}

dotenv_value() {
  local key="$1"
  local value
  value="$(dotenv_get_raw "$key")"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s' "$value"
}

dotenv_set() {
  local key="$1"
  local value="$2"
  local file="$HERMES_DATA_DIR/.env"
  local tmp

  install -d -m 700 -o "$HERMES_USER" -g "$HERMES_GROUP" "$HERMES_DATA_DIR"
  touch "$file"
  chmod 600 "$file"
  chown "$HERMES_USER:$HERMES_GROUP" "$file"

  tmp="$(mktemp)"
  grep -Ev "^${key}=" "$file" >"$tmp" || true
  printf '%s=%s\n' "$key" "$(dotenv_quote "$value")" >>"$tmp"
  install -m 600 -o "$HERMES_USER" -g "$HERMES_GROUP" "$tmp" "$file"
  rm -f "$tmp"
}

validate_telegram_token() {
  local token=""
  token="$(dotenv_value TELEGRAM_BOT_TOKEN)"

  [[ -n "$token" ]] || die "TELEGRAM_BOT_TOKEN is required on first run"

  if [[ ! "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]]; then
    die "TELEGRAM_BOT_TOKEN does not look like a BotFather token; get a fresh token with /token in BotFather"
  fi

  log "Validating Telegram bot token"
  if ! TELEGRAM_SETUP_VALIDATE_TOKEN="$token" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ["TELEGRAM_SETUP_VALIDATE_TOKEN"]
url = f"https://api.telegram.org/bot{token}/getMe"

try:
    with urllib.request.urlopen(url, timeout=15) as response:
        payload = json.loads(response.read().decode("utf-8"))
except (OSError, urllib.error.URLError, json.JSONDecodeError):
    raise SystemExit(1)

raise SystemExit(0 if payload.get("ok") is True else 1)
PY
  then
    die "TELEGRAM_BOT_TOKEN was rejected by Telegram; get a fresh token with /token in BotFather and rerun setup"
  fi
}

configure_env_file() {
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    dotenv_set TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
  fi
  if [[ -n "${TELEGRAM_ALLOWED_USERS:-}" ]]; then
    dotenv_set TELEGRAM_ALLOWED_USERS "${TELEGRAM_ALLOWED_USERS// /}"
  fi

  if ! dotenv_has_value TELEGRAM_BOT_TOKEN; then
    die "TELEGRAM_BOT_TOKEN is required on first run"
  fi
  if ! dotenv_has_value TELEGRAM_ALLOWED_USERS; then
    die "TELEGRAM_ALLOWED_USERS is required on first run; without it Hermes denies all Telegram users"
  fi

  validate_telegram_token

  local key
  for key in "${OPTIONAL_ENV_KEYS[@]}"; do
    if [[ -n "${!key:-}" ]]; then
      dotenv_set "$key" "${!key}"
    fi
  done

  local has_llm_provider=0
  for key in "${LLM_PROVIDER_KEYS[@]}"; do
    if dotenv_has_value "$key"; then
      has_llm_provider=1
      break
    fi
  done
  if [[ "$has_llm_provider" != "1" ]]; then
    warn "No LLM provider key is configured. Gateway can start, but agent replies may fail until Hermes is configured with a model provider."
  fi
}

configure_model_settings() {
  if [[ -z "$HERMES_MODEL_PROVIDER" && -z "$HERMES_MODEL_DEFAULT" && -z "$HERMES_MODEL_API_MODE" && -z "$HERMES_MODEL_BASE_URL" ]]; then
    return 0
  fi

  local python_bin="$HERMES_DATA_DIR/hermes-agent/venv/bin/python"
  [[ -x "$python_bin" ]] || die "Hermes venv Python not found at $python_bin"

  log "Configuring Hermes default model"
  runuser -u "$HERMES_USER" -- \
    env \
      HOME="$HERMES_HOME_DIR" \
      USER="$HERMES_USER" \
      LOGNAME="$HERMES_USER" \
      HERMES_SETUP_MODEL_PROVIDER="$HERMES_MODEL_PROVIDER" \
      HERMES_SETUP_MODEL_DEFAULT="$HERMES_MODEL_DEFAULT" \
      HERMES_SETUP_MODEL_API_MODE="$HERMES_MODEL_API_MODE" \
      HERMES_SETUP_MODEL_BASE_URL="$HERMES_MODEL_BASE_URL" \
      "$python_bin" - "$HERMES_DATA_DIR/config.yaml" <<'PY'
import os
import sys
from pathlib import Path

import yaml

config_path = Path(sys.argv[1])
config_path.parent.mkdir(parents=True, exist_ok=True)

if config_path.exists():
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
else:
    loaded = {}

if not isinstance(loaded, dict):
    raise SystemExit(f"{config_path} must contain a YAML mapping")

model = loaded.setdefault("model", {})
if not isinstance(model, dict):
    raise SystemExit("model in config.yaml must be a mapping")

mapping = {
    "provider": os.environ.get("HERMES_SETUP_MODEL_PROVIDER", ""),
    "default": os.environ.get("HERMES_SETUP_MODEL_DEFAULT", ""),
    "api_mode": os.environ.get("HERMES_SETUP_MODEL_API_MODE", ""),
    "base_url": os.environ.get("HERMES_SETUP_MODEL_BASE_URL", ""),
}

for key, value in mapping.items():
    if value:
        model[key] = value

config_path.write_text(
    yaml.safe_dump(loaded, sort_keys=False, default_flow_style=False),
    encoding="utf-8",
)
config_path.chmod(0o600)
PY
}

install_playwright_system_deps_via_upstream() {
  if [[ "$HERMES_INSTALL_PLAYWRIGHT_SYSTEM_DEPS" != "1" ]]; then
    return
  fi

  local install_dir="$HERMES_DATA_DIR/hermes-agent"
  local npx_bin="$HERMES_HOME_DIR/.local/bin/npx"
  [[ -x "$npx_bin" && -d "$install_dir" ]] || return

  log "Letting Playwright verify/install remaining Chromium system dependencies"
  HOME=/root \
  PATH="$HERMES_DATA_DIR/bin:$HERMES_HOME_DIR/.local/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -lc "cd $(printf '%q' "$install_dir") && npx playwright install-deps chromium" || \
    warn "playwright install-deps failed; browser tools may need manual system packages"
}

remove_hermes_user_gateway_service() {
  local uid
  uid="$(id -u "$HERMES_USER" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 0

  local user_unit_dir="$HERMES_HOME_DIR/.config/systemd/user"
  local user_unit="$user_unit_dir/$HERMES_SERVICE_NAME"

  if [[ -e "$user_unit" ]]; then
    log "Removing stale user-scoped gateway service for $HERMES_USER"
    runuser -u "$HERMES_USER" -- \
      env \
        HOME="$HERMES_HOME_DIR" \
        USER="$HERMES_USER" \
        LOGNAME="$HERMES_USER" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user disable --now "$HERMES_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$user_unit"
    rmdir "$user_unit_dir" >/dev/null 2>&1 || true
  fi
}

install_gateway_service() {
  local python_bin="$HERMES_DATA_DIR/hermes-agent/venv/bin/python"
  [[ -x "$python_bin" ]] || die "Hermes venv Python not found at $python_bin"

  local -a install_args=(
    --system
    --run-as-user "$HERMES_USER"
    --force
    --start-on-login
    --no-start-now
  )

  log "Installing systemd service $HERMES_SERVICE_NAME running as $HERMES_USER"
  env \
    HOME="$HERMES_HOME_DIR" \
    USER="$HERMES_USER" \
    LOGNAME="$HERMES_USER" \
    SHELL=/bin/bash \
    HERMES_HOME="$HERMES_DATA_DIR" \
    PATH="$HERMES_DATA_DIR/bin:$HERMES_HOME_DIR/.local/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin" \
    "$python_bin" -m hermes_cli.main gateway install "${install_args[@]}"

  systemctl daemon-reload
  systemctl enable "$HERMES_SERVICE_NAME"

  local unit_path="/etc/systemd/system/$HERMES_SERVICE_NAME"
  [[ -f "$unit_path" ]] || die "expected systemd unit not found: $unit_path"
  grep -Fxq "User=$HERMES_USER" "$unit_path" || die "$unit_path does not run as User=$HERMES_USER"

  install_gateway_service_dropin

  if [[ "$HERMES_START_SERVICE" == "1" ]]; then
    systemctl restart "$HERMES_SERVICE_NAME"
  else
    systemctl stop "$HERMES_SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

install_gateway_service_dropin() {
  local dropin_dir="/etc/systemd/system/$HERMES_SERVICE_NAME.d"
  local dropin_file="$dropin_dir/10-hermes-setup.conf"

  install -d -m 755 -o root -g root "$dropin_dir"
  cat >"$dropin_file" <<EOF
[Service]
Environment="HOME=$HERMES_HOME_DIR"
Environment="USER=$HERMES_USER"
Environment="LOGNAME=$HERMES_USER"
Environment="SHELL=/bin/bash"
Environment="HERMES_HOME=$HERMES_DATA_DIR"
Environment="PYTHONUNBUFFERED=1"
Environment="PATH=$HERMES_DATA_DIR/bin:$HERMES_HOME_DIR/.local/bin:$HERMES_HOME_DIR/.cargo/bin:$HERMES_HOME_DIR/go/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin"
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
EOF
  chmod 0644 "$dropin_file"
  systemctl daemon-reload
}

validate_dashboard_settings() {
  [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] || return 0

  if [[ ! "$HERMES_DASHBOARD_PORT" =~ ^[0-9]+$ ]] || ((HERMES_DASHBOARD_PORT < 1 || HERMES_DASHBOARD_PORT > 65535)); then
    die "HERMES_DASHBOARD_PORT must be a TCP port number from 1 to 65535"
  fi
  if [[ ! "$HERMES_DASHBOARD_TLS_PORT" =~ ^[0-9]+$ ]] || ((HERMES_DASHBOARD_TLS_PORT < 1 || HERMES_DASHBOARD_TLS_PORT > 65535)); then
    die "HERMES_DASHBOARD_TLS_PORT must be a TCP port number from 1 to 65535"
  fi
  if [[ ! "$HERMES_DASHBOARD_PROXY_PORT" =~ ^[0-9]+$ ]] || ((HERMES_DASHBOARD_PROXY_PORT < 1 || HERMES_DASHBOARD_PROXY_PORT > 65535)); then
    die "HERMES_DASHBOARD_PROXY_PORT must be a TCP port number from 1 to 65535"
  fi

  if [[ "$HERMES_DASHBOARD_HOST" == *"://"* || "$HERMES_DASHBOARD_HOST" == *"/"* || "$HERMES_DASHBOARD_HOST" == *"?"* ]]; then
    die "HERMES_DASHBOARD_HOST must be only a host or IP, not a full URL; use tailscale or 100.x.y.z instead of http://100.x.y.z:9119"
  fi

  if dashboard_tls_enabled && [[ "${HERMES_DASHBOARD_HOST,,}" != *.ts.net ]]; then
    die "HERMES_DASHBOARD_TLS_ENABLE=1 requires HERMES_DASHBOARD_HOST to be a *.ts.net MagicDNS name"
  fi

  case "$HERMES_DASHBOARD_HOST" in
    0.0.0.0|::)
      if [[ "${HERMES_DASHBOARD_ALLOW_ALL_INTERFACES:-0}" != "1" ]]; then
        die "refusing HERMES_DASHBOARD_HOST=$HERMES_DASHBOARD_HOST; use tailscale or set HERMES_DASHBOARD_ALLOW_ALL_INTERFACES=1"
      fi
      ;;
  esac
}

dashboard_basic_auth_value() {
  local key="$1"
  local config_file="$HERMES_DATA_DIR/config.yaml"
  local python_bin="$HERMES_DATA_DIR/hermes-agent/venv/bin/python"
  [[ -r "$config_file" ]] || return 0
  [[ -x "$python_bin" ]] || python_bin="python3"

  "$python_bin" - "$config_file" "$key" <<'PY'
import sys

import yaml

config_path = sys.argv[1]
key = sys.argv[2]

with open(config_path, "r", encoding="utf-8") as f:
    loaded = yaml.safe_load(f) or {}

if not isinstance(loaded, dict):
    raise SystemExit(0)

section = (
    loaded.get("dashboard", {})
    if isinstance(loaded.get("dashboard", {}), dict)
    else {}
).get("basic_auth", {})

if not isinstance(section, dict):
    raise SystemExit(0)

value = section.get(key, "")
if value:
    print(value)
PY
}

dashboard_has_existing_password() {
  [[ -n "$(dashboard_basic_auth_value password_hash)" || -n "$(dashboard_basic_auth_value password)" ]]
}

generate_dashboard_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(24))
PY
  fi
}

write_generated_dashboard_credentials() {
  local username="$1"
  local password="$2"
  local tmp
  local url_hint=""
  url_hint="$(dashboard_url || true)"

  install -d -m 700 -o root -g root "$HERMES_STATE_DIR"
  tmp="$(mktemp)"
  {
    printf '# Managed by setup-hermes-ubuntu.sh\n'
    printf '# Root-only copy of the generated first-run dashboard password.\n'
    if [[ -n "$url_hint" ]]; then
      printf 'url_hint=%s\n' "$url_hint"
    fi
    printf 'username=%s\n' "$username"
    printf 'password=%s\n' "$password"
  } >"$tmp"
  install -m 0600 -o root -g root "$tmp" "$HERMES_DASHBOARD_CREDENTIALS_FILE"
  rm -f "$tmp"
}

configure_dashboard_auth() {
  [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] || return 0

  local python_bin="$HERMES_DATA_DIR/hermes-agent/venv/bin/python"
  local install_dir="$HERMES_DATA_DIR/hermes-agent"
  [[ -x "$python_bin" ]] || die "Hermes venv Python not found at $python_bin"
  [[ -d "$install_dir" ]] || die "Hermes install dir not found at $install_dir"

  local username="${HERMES_DASHBOARD_USERNAME:-${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}}"
  local password="${HERMES_DASHBOARD_PASSWORD:-${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}}"
  local password_hash="${HERMES_DASHBOARD_PASSWORD_HASH:-${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-}}"
  local secret="${HERMES_DASHBOARD_SESSION_SECRET:-${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}}"
  local ttl="${HERMES_DASHBOARD_SESSION_TTL_SECONDS:-${HERMES_DASHBOARD_BASIC_AUTH_TTL_SECONDS:-}}"
  local existing_username=""
  local generated_password=0

  existing_username="$(dashboard_basic_auth_value username || true)"
  if [[ -z "$username" ]]; then
    username="${existing_username:-admin}"
  fi

  if [[ -z "$password" && -z "$password_hash" ]] && ! dashboard_has_existing_password; then
    password="$(generate_dashboard_password)"
    generated_password=1
  fi

  log "Configuring dashboard basic auth"
  runuser -u "$HERMES_USER" -- \
    env \
      HOME="$HERMES_HOME_DIR" \
      USER="$HERMES_USER" \
      LOGNAME="$HERMES_USER" \
      HERMES_HOME="$HERMES_DATA_DIR" \
      PYTHONPATH="$install_dir" \
      HERMES_SETUP_DASHBOARD_USERNAME="$username" \
      HERMES_SETUP_DASHBOARD_PASSWORD="$password" \
      HERMES_SETUP_DASHBOARD_PASSWORD_HASH="$password_hash" \
      HERMES_SETUP_DASHBOARD_SECRET="$secret" \
      HERMES_SETUP_DASHBOARD_TTL_SECONDS="$ttl" \
      "$python_bin" - "$HERMES_DATA_DIR/config.yaml" <<'PY'
import os
import secrets
import sys
from pathlib import Path

import yaml
from plugins.dashboard_auth.basic import hash_password

config_path = Path(sys.argv[1])
config_path.parent.mkdir(parents=True, exist_ok=True)

if config_path.exists():
    loaded = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
else:
    loaded = {}

if not isinstance(loaded, dict):
    raise SystemExit(f"{config_path} must contain a YAML mapping")

dashboard = loaded.setdefault("dashboard", {})
if not isinstance(dashboard, dict):
    raise SystemExit("dashboard in config.yaml must be a mapping")

basic_auth = dashboard.setdefault("basic_auth", {})
if not isinstance(basic_auth, dict):
    raise SystemExit("dashboard.basic_auth in config.yaml must be a mapping")

username = os.environ.get("HERMES_SETUP_DASHBOARD_USERNAME", "")
password = os.environ.get("HERMES_SETUP_DASHBOARD_PASSWORD", "")
password_hash = os.environ.get("HERMES_SETUP_DASHBOARD_PASSWORD_HASH", "")
secret = os.environ.get("HERMES_SETUP_DASHBOARD_SECRET", "")
ttl = os.environ.get("HERMES_SETUP_DASHBOARD_TTL_SECONDS", "")

if username:
    basic_auth["username"] = username
elif not basic_auth.get("username"):
    raise SystemExit(
        "HERMES_DASHBOARD_USERNAME is required on first dashboard setup"
    )

if password_hash:
    basic_auth["password_hash"] = password_hash
    basic_auth["password"] = ""
elif password:
    basic_auth["password_hash"] = hash_password(password)
    basic_auth["password"] = ""
elif not basic_auth.get("password_hash") and not basic_auth.get("password"):
    raise SystemExit(
        "HERMES_DASHBOARD_PASSWORD or HERMES_DASHBOARD_PASSWORD_HASH is required on first dashboard setup"
    )

if secret:
    basic_auth["secret"] = secret
elif not basic_auth.get("secret"):
    basic_auth["secret"] = secrets.token_urlsafe(48)

if ttl:
    try:
        basic_auth["session_ttl_seconds"] = int(ttl)
    except ValueError as exc:
        raise SystemExit("HERMES_DASHBOARD_SESSION_TTL_SECONDS must be an integer") from exc
elif not basic_auth.get("session_ttl_seconds"):
    basic_auth["session_ttl_seconds"] = 12 * 60 * 60

config_path.write_text(
    yaml.safe_dump(loaded, sort_keys=False, default_flow_style=False),
    encoding="utf-8",
)
config_path.chmod(0o600)
PY

  if [[ "$generated_password" == "1" ]]; then
    write_generated_dashboard_credentials "$username" "$password"
    warn "Generated dashboard password. Read it with: sudo cat $HERMES_DASHBOARD_CREDENTIALS_FILE"
  fi
}

remove_dashboard_service_if_disabled() {
  [[ "$HERMES_DASHBOARD_ENABLE" != "1" ]] || return 0

  if [[ -f "/etc/systemd/system/$HERMES_DASHBOARD_SERVICE_NAME" ]]; then
    log "Removing disabled dashboard service $HERMES_DASHBOARD_SERVICE_NAME"
    systemctl disable --now "$HERMES_DASHBOARD_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$HERMES_DASHBOARD_SERVICE_NAME"
    systemctl daemon-reload
    systemctl reset-failed "$HERMES_DASHBOARD_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  remove_dashboard_tls_proxy_config
}

remove_dashboard_tls_proxy_config() {
  if [[ -f /etc/nginx/conf.d/hermes-dashboard.conf ]]; then
    log "Removing dashboard TLS reverse proxy config"
    rm -f /etc/nginx/conf.d/hermes-dashboard.conf
    if command -v nginx >/dev/null 2>&1; then
      nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
  fi
}

install_dashboard_service() {
  if [[ "$HERMES_DASHBOARD_ENABLE" != "1" ]]; then
    remove_dashboard_service_if_disabled
    return 0
  fi

  validate_dashboard_settings
  configure_dashboard_auth

  local runner="$HERMES_HOME_DIR/.local/bin/hermes-dashboard-run"
  local start_dashboard="$HERMES_DASHBOARD_START"
  [[ -x "$runner" ]] || die "dashboard runner not found at $runner"

  if [[ "$start_dashboard" == "1" ]] && dashboard_host_is_tailscale && ! tailscale_has_ip; then
    warn "Dashboard service will be installed but not started because Tailscale has no IPv4 address yet. Run sudo tailscale up, then sudo systemctl restart $HERMES_DASHBOARD_SERVICE_NAME."
    start_dashboard=0
  fi

  log "Installing systemd service $HERMES_DASHBOARD_SERVICE_NAME running as $HERMES_USER"
  cat >"/etc/systemd/system/$HERMES_DASHBOARD_SERVICE_NAME" <<EOF
[Unit]
Description=Hermes Dashboard
After=network-online.target tailscaled.service $HERMES_SERVICE_NAME
Wants=network-online.target

[Service]
Type=simple
User=$HERMES_USER
Group=$HERMES_GROUP
WorkingDirectory=$HERMES_WORK_DIR
Environment="HOME=$HERMES_HOME_DIR"
Environment="USER=$HERMES_USER"
Environment="LOGNAME=$HERMES_USER"
Environment="SHELL=/bin/bash"
Environment="HERMES_HOME=$HERMES_DATA_DIR"
Environment="HERMES_DASHBOARD_HOST=$HERMES_DASHBOARD_HOST"
Environment="HERMES_DASHBOARD_PORT=$HERMES_DASHBOARD_PORT"
Environment="HERMES_DASHBOARD_TLS_ENABLE=$HERMES_DASHBOARD_TLS_ENABLE"
Environment="PATH=$HERMES_DATA_DIR/bin:$HERMES_HOME_DIR/.local/bin:$HERMES_HOME_DIR/.cargo/bin:$HERMES_HOME_DIR/go/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=$runner
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "/etc/systemd/system/$HERMES_DASHBOARD_SERVICE_NAME"
  systemctl daemon-reload
  systemctl enable "$HERMES_DASHBOARD_SERVICE_NAME"

  if [[ "$start_dashboard" == "1" ]]; then
    systemctl restart "$HERMES_DASHBOARD_SERVICE_NAME"
    HERMES_DASHBOARD_STARTED=1
  else
    systemctl stop "$HERMES_DASHBOARD_SERVICE_NAME" >/dev/null 2>&1 || true
    HERMES_DASHBOARD_STARTED=0
  fi

  grep -Fxq "User=$HERMES_USER" "/etc/systemd/system/$HERMES_DASHBOARD_SERVICE_NAME" || \
    die "/etc/systemd/system/$HERMES_DASHBOARD_SERVICE_NAME does not run as User=$HERMES_USER"

  configure_dashboard_tls_proxy
  configure_tailscale_serve
}

configure_dashboard_tls_proxy() {
  if [[ "$HERMES_DASHBOARD_ENABLE" != "1" ]] || ! dashboard_tls_enabled; then
    remove_dashboard_tls_proxy_config
    return 0
  fi

  command -v nginx >/dev/null 2>&1 || die "nginx is required for dashboard TLS proxy"

  log "Configuring local dashboard TLS reverse proxy"
  cat >"/etc/nginx/conf.d/hermes-dashboard.conf" <<EOF
# Managed by setup-hermes-ubuntu.sh
server {
    listen 127.0.0.1:$HERMES_DASHBOARD_PROXY_PORT;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:$HERMES_DASHBOARD_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1:$HERMES_DASHBOARD_PORT;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  nginx -t
  systemctl enable nginx
  if systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    systemctl start nginx
  fi
}

configure_tailscale_serve() {
  [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] || return 0
  dashboard_tls_enabled || return 0

  if ! tailscale_has_ip; then
    warn "Tailscale Serve HTTPS was not configured because Tailscale has no IPv4 address yet. Run sudo tailscale up, then rerun setup."
    return 0
  fi

  if [[ "$HERMES_DASHBOARD_STARTED" != "1" ]]; then
    warn "Tailscale Serve HTTPS was not configured because the dashboard backend is not running."
    return 0
  fi

  log "Configuring Tailscale Serve HTTPS for dashboard"
  if ! tailscale serve --yes --bg --https="$HERMES_DASHBOARD_TLS_PORT" "http://127.0.0.1:$HERMES_DASHBOARD_PROXY_PORT"; then
    die "failed to configure Tailscale Serve HTTPS. Ensure MagicDNS and HTTPS Certificates are enabled in the Tailscale admin console."
  fi
}

reset_tailscale_serve_if_requested() {
  [[ "$HERMES_TAILSCALE_SERVE_RESET" == "1" ]] || return 0
  [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]] || return 0
  if dashboard_tls_enabled; then
    warn "HERMES_TAILSCALE_SERVE_RESET=1 was ignored because dashboard TLS is enabled."
    return 0
  fi
  command -v tailscale >/dev/null 2>&1 || return 0

  log "Resetting Tailscale Serve configuration because HERMES_TAILSCALE_SERVE_RESET=1"
  tailscale serve reset
}

verify_user_toolchain() {
  local -a commands=()
  mapfile -t commands < <(json_list checks.user_commands)

  local command_name=""
  local quoted=""
  for command_name in "${commands[@]}"; do
    printf -v quoted '%q' "$command_name"
    run_as_hermes "command -v $quoted >/dev/null" || die "$command_name is not available for $HERMES_USER"
  done

  run_as_hermes "uv --version && uvx --version && node --version && npm --version && npx --version"
}

verify_installation() {
  log "Verifying user privilege boundary"
  if id -nG "$HERMES_USER" | tr ' ' '\n' | grep -Exq 'sudo|admin|wheel|docker|lxd|libvirt|root'; then
    die "$HERMES_USER still has a root-equivalent group"
  fi

  log "Verifying user toolchain"
  verify_user_toolchain

  log "Hermes command:"
  run_as_hermes "command -v hermes && hermes --help | head -n 1"

  if [[ "$HERMES_START_SERVICE" == "1" ]]; then
    log "Checking gateway service"
    systemctl is-enabled "$HERMES_SERVICE_NAME" >/dev/null
    if ! systemctl is-active --quiet "$HERMES_SERVICE_NAME"; then
      systemctl status "$HERMES_SERVICE_NAME" --no-pager || true
      journalctl -u "$HERMES_SERVICE_NAME" -n 80 --no-pager || true
      die "$HERMES_SERVICE_NAME is not active"
    fi
  fi

  if [[ "$HERMES_DASHBOARD_ENABLE" == "1" && "$HERMES_DASHBOARD_STARTED" == "1" ]]; then
    log "Checking dashboard service"
    systemctl is-enabled "$HERMES_DASHBOARD_SERVICE_NAME" >/dev/null
    if ! systemctl is-active --quiet "$HERMES_DASHBOARD_SERVICE_NAME"; then
      systemctl status "$HERMES_DASHBOARD_SERVICE_NAME" --no-pager || true
      journalctl -u "$HERMES_DASHBOARD_SERVICE_NAME" -n 80 --no-pager || true
      die "$HERMES_DASHBOARD_SERVICE_NAME is not active"
    fi
  fi
}

main() {
  require_root
  require_ubuntu_systemd
  require_package_json
  install_system_packages
  install_tailscale
  install_dashboard_tls_proxy_packages
  ensure_group_and_user
  remove_privileged_groups
  install_sudo_deny_rule
  configure_user_shell
  configure_authorized_keys
  stop_existing_hermes_services_for_update
  clean_broken_hermes_venv
  install_hermes_agent
  ensure_user_tool_shims
  install_user_operation_helpers
  install_playwright_system_deps_via_upstream
  configure_env_file
  configure_model_settings
  remove_hermes_user_gateway_service
  install_gateway_service
  reset_tailscale_serve_if_requested
  install_dashboard_service
  verify_installation

  log "Done."
  log "Service: systemctl status $HERMES_SERVICE_NAME --no-pager"
  log "Logs:    journalctl -u $HERMES_SERVICE_NAME -f"
  if [[ "$HERMES_DASHBOARD_ENABLE" == "1" ]]; then
    local dashboard_url_value=""
    dashboard_url_value="$(dashboard_url || true)"
    log "Dashboard: systemctl status $HERMES_DASHBOARD_SERVICE_NAME --no-pager"
    if [[ -n "$dashboard_url_value" ]]; then
      log "Dashboard URL: $dashboard_url_value"
    else
      log "Dashboard URL: unavailable until Tailscale has an IPv4 address; run: tailscale ip -4"
    fi
  fi
  log "Shell:   sudo -iu $HERMES_USER"
}

main "$@"
