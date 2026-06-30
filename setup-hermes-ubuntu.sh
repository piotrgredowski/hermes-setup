#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent Hermes Agent bootstrap for Ubuntu Server.
#
# Intended model:
# - Run this script as root, or with sudo, on the Ubuntu host.
# - The script creates/repairs a dedicated unprivileged user.
# - Hermes is installed as that user under /home/hermes.
# - The gateway runs persistently as a systemd system service with User=hermes.
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
HERMES_SERVICE_NAME="${HERMES_SERVICE_NAME:-hermes-gateway.service}"
HERMES_HOME_MODE="${HERMES_HOME_MODE:-750}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || pwd)"
DEFAULT_PACKAGE_JSON="$SCRIPT_DIR/hermes-packages.json"
if [[ ! -f "$DEFAULT_PACKAGE_JSON" && -f "$PWD/hermes-packages.json" ]]; then
  DEFAULT_PACKAGE_JSON="$PWD/hermes-packages.json"
fi
HERMES_PACKAGE_JSON="${HERMES_PACKAGE_JSON:-$DEFAULT_PACKAGE_JSON}"
HERMES_STATE_DIR="${HERMES_STATE_DIR:-/var/lib/hermes-setup}"
HERMES_APT_INSTALLED_BY_US_FILE="${HERMES_APT_INSTALLED_BY_US_FILE:-$HERMES_STATE_DIR/apt-installed-by-hermes.txt}"

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
  local marker="# >>> hermes local tools >>>"
  local block

  block="$(cat <<'EOF'
# >>> hermes local tools >>>
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.hermes/node/bin:$PATH"
export npm_config_prefix="$HOME/.local"
# <<< hermes local tools <<<
EOF
)"

  touch "$profile" "$bashrc"
  chown "$HERMES_USER:$HERMES_GROUP" "$profile" "$bashrc"

  if ! grep -Fq "$marker" "$profile"; then
    printf '\n%s\n' "$block" >>"$profile"
  fi
  if ! grep -Fq "$marker" "$bashrc"; then
    printf '\n%s\n' "$block" >>"$bashrc"
  fi

  printf 'prefix=%s/.local\n' "$HERMES_HOME_DIR" >"$HERMES_HOME_DIR/.npmrc"
  chown "$HERMES_USER:$HERMES_GROUP" "$HERMES_HOME_DIR/.npmrc"
  chmod 0644 "$HERMES_HOME_DIR/.npmrc"
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
      PATH="$HERMES_HOME_DIR/.local/bin:$HERMES_HOME_DIR/.cargo/bin:$HERMES_HOME_DIR/go/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin" \
      bash -lc "$command"
}

install_hermes_agent() {
  local -a args=(--skip-setup --branch "$HERMES_BRANCH")
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

install_playwright_system_deps_via_upstream() {
  if [[ "$HERMES_INSTALL_PLAYWRIGHT_SYSTEM_DEPS" != "1" ]]; then
    return
  fi

  local install_dir="$HERMES_DATA_DIR/hermes-agent"
  local npx_bin="$HERMES_HOME_DIR/.local/bin/npx"
  [[ -x "$npx_bin" && -d "$install_dir" ]] || return

  log "Letting Playwright verify/install remaining Chromium system dependencies"
  HOME=/root \
  PATH="$HERMES_HOME_DIR/.local/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin" \
    bash -lc "cd $(printf '%q' "$install_dir") && npx playwright install-deps chromium" || \
    warn "playwright install-deps failed; browser tools may need manual system packages"
}

install_gateway_service() {
  local python_bin="$HERMES_DATA_DIR/hermes-agent/venv/bin/python"
  [[ -x "$python_bin" ]] || die "Hermes venv Python not found at $python_bin"

  local -a install_args=(
    --system
    --run-as-user "$HERMES_USER"
    --force
    --start-on-login
  )
  if [[ "$HERMES_START_SERVICE" == "1" ]]; then
    install_args+=(--start-now)
  else
    install_args+=(--no-start-now)
  fi

  log "Installing systemd service $HERMES_SERVICE_NAME running as $HERMES_USER"
  env \
    HOME="$HERMES_HOME_DIR" \
    USER="$HERMES_USER" \
    LOGNAME="$HERMES_USER" \
    SHELL=/bin/bash \
    HERMES_HOME="$HERMES_DATA_DIR" \
    PATH="$HERMES_HOME_DIR/.local/bin:$HERMES_DATA_DIR/node/bin:/usr/local/bin:/usr/bin:/bin" \
    "$python_bin" -m hermes_cli.main gateway install "${install_args[@]}"

  systemctl daemon-reload
  systemctl enable "$HERMES_SERVICE_NAME"

  local unit_path="/etc/systemd/system/$HERMES_SERVICE_NAME"
  [[ -f "$unit_path" ]] || die "expected systemd unit not found: $unit_path"
  grep -Fxq "User=$HERMES_USER" "$unit_path" || die "$unit_path does not run as User=$HERMES_USER"
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

  run_as_hermes "uv --version && node --version && npm --version && npx --version"
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
}

main() {
  require_root
  require_ubuntu_systemd
  require_package_json
  install_system_packages
  ensure_group_and_user
  remove_privileged_groups
  install_sudo_deny_rule
  configure_user_shell
  configure_authorized_keys
  install_hermes_agent
  install_playwright_system_deps_via_upstream
  configure_env_file
  install_gateway_service
  verify_installation

  log "Done."
  log "Service: systemctl status $HERMES_SERVICE_NAME --no-pager"
  log "Logs:    journalctl -u $HERMES_SERVICE_NAME -f"
  log "Shell:   sudo -iu $HERMES_USER"
}

main "$@"
