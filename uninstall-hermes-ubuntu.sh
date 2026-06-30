#!/usr/bin/env bash
set -Eeuo pipefail

# Idempotent teardown for setup-hermes-ubuntu.sh.
#
# Default package behavior is conservative:
# - remove the Hermes user, home, service, sudoers rule, and setup state;
# - purge only apt packages recorded as newly installed by setup.
#
# To purge every installed apt package listed in hermes-packages.json, even if
# it existed before Hermes setup, run with:
#   HERMES_PURGE_ALL_LISTED_PACKAGES=1 sudo -E bash uninstall-hermes-ubuntu.sh
#
# If the package manifest is elsewhere, pass HERMES_PACKAGE_JSON=/path/to/hermes-packages.json.

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_GROUP="${HERMES_GROUP:-$HERMES_USER}"
HERMES_HOME_DIR="${HERMES_HOME_DIR:-/home/$HERMES_USER}"
HERMES_DATA_DIR="${HERMES_DATA_DIR:-$HERMES_HOME_DIR/.hermes}"
HERMES_WORK_DIR="${HERMES_WORK_DIR:-$HERMES_HOME_DIR/work}"
HERMES_SERVICE_NAME="${HERMES_SERVICE_NAME:-hermes-gateway.service}"
HERMES_REMOVE_APT_PACKAGES="${HERMES_REMOVE_APT_PACKAGES:-1}"
HERMES_PURGE_ALL_LISTED_PACKAGES="${HERMES_PURGE_ALL_LISTED_PACKAGES:-0}"
HERMES_REMOVE_USER="${HERMES_REMOVE_USER:-1}"
HERMES_REMOVE_HOME="${HERMES_REMOVE_HOME:-1}"
HERMES_KILL_USER_PROCESSES="${HERMES_KILL_USER_PROCESSES:-1}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P || pwd)"
DEFAULT_PACKAGE_JSON="$SCRIPT_DIR/hermes-packages.json"
if [[ ! -f "$DEFAULT_PACKAGE_JSON" && -f "$PWD/hermes-packages.json" ]]; then
  DEFAULT_PACKAGE_JSON="$PWD/hermes-packages.json"
fi
HERMES_PACKAGE_JSON="${HERMES_PACKAGE_JSON:-$DEFAULT_PACKAGE_JSON}"
HERMES_STATE_DIR="${HERMES_STATE_DIR:-/var/lib/hermes-setup}"
HERMES_APT_INSTALLED_BY_US_FILE="${HERMES_APT_INSTALLED_BY_US_FILE:-$HERMES_STATE_DIR/apt-installed-by-hermes.txt}"

log() {
  printf '[hermes-uninstall] %s\n' "$*"
}

warn() {
  printf '[hermes-uninstall] WARN: %s\n' "$*" >&2
}

die() {
  printf '[hermes-uninstall] ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "run as root, e.g. sudo -E bash uninstall-hermes-ubuntu.sh"
  fi
}

json_available() {
  command -v python3 >/dev/null 2>&1 && [[ -r "$HERMES_PACKAGE_JSON" ]]
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

apt_package_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -Fxq "install ok installed"
}

stop_and_remove_service() {
  log "Removing systemd service $HERMES_SERVICE_NAME"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$HERMES_SERVICE_NAME" >/dev/null 2>&1 || true
  fi

  rm -f "/etc/systemd/system/$HERMES_SERVICE_NAME"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl reset-failed "$HERMES_SERVICE_NAME" >/dev/null 2>&1 || true
  fi
}

kill_user_processes() {
  [[ "$HERMES_KILL_USER_PROCESSES" == "1" ]] || return 0
  id "$HERMES_USER" >/dev/null 2>&1 || return 0

  log "Stopping processes owned by $HERMES_USER"
  pkill -TERM -u "$HERMES_USER" >/dev/null 2>&1 || true
  sleep 2
  pkill -KILL -u "$HERMES_USER" >/dev/null 2>&1 || true
}

remove_sudoers_rule() {
  log "Removing sudoers deny rule"
  rm -f "/etc/sudoers.d/99-${HERMES_USER}-no-sudo"
}

safe_remove_dir() {
  local path="$1"
  [[ -n "$path" && "$path" != "/" && "$path" != "/home" ]] || die "refusing to remove unsafe path: $path"
  case "$path" in
    /home/*|/var/lib/hermes-setup|/var/lib/hermes-setup/*)
      if [[ -e "$path" ]]; then
        rm -rf --one-file-system "$path"
      fi
      ;;
    *)
      warn "refusing to remove non-standard path without HERMES_FORCE_REMOVE_NONSTANDARD_PATHS=1: $path"
      if [[ "${HERMES_FORCE_REMOVE_NONSTANDARD_PATHS:-0}" == "1" && -e "$path" ]]; then
        rm -rf --one-file-system "$path"
      fi
      ;;
  esac
}

remove_user_and_home() {
  if [[ "$HERMES_REMOVE_USER" == "1" ]] && id "$HERMES_USER" >/dev/null 2>&1; then
    log "Removing user $HERMES_USER"
    userdel --remove "$HERMES_USER" >/dev/null 2>&1 || userdel "$HERMES_USER" >/dev/null 2>&1 || true
  fi

  if [[ "$HERMES_REMOVE_HOME" == "1" ]]; then
    log "Removing Hermes home/data directories"
    safe_remove_dir "$HERMES_HOME_DIR"
  else
    safe_remove_dir "$HERMES_DATA_DIR"
    safe_remove_dir "$HERMES_WORK_DIR"
  fi

  if getent group "$HERMES_GROUP" >/dev/null; then
    log "Removing group $HERMES_GROUP if unused"
    groupdel "$HERMES_GROUP" >/dev/null 2>&1 || true
  fi
}

packages_from_state() {
  [[ -r "$HERMES_APT_INSTALLED_BY_US_FILE" ]] || return 0
  awk 'NF && $1 !~ /^#/' "$HERMES_APT_INSTALLED_BY_US_FILE" | sort -u
}

packages_from_manifest() {
  json_available || die "package manifest not found or python3 unavailable: $HERMES_PACKAGE_JSON"
  {
    json_list apt.base apt.agent_tools apt.browser apt.office_optional
    while IFS=$'\t' read -r -a alternatives; do
      printf '%s\n' "${alternatives[@]}"
    done < <(json_alternatives apt.browser_alternatives)
  } | awk 'NF' | sort -u
}

purge_apt_packages() {
  [[ "$HERMES_REMOVE_APT_PACKAGES" == "1" ]] || return 0

  local -a candidates=()
  if [[ "$HERMES_PURGE_ALL_LISTED_PACKAGES" == "1" ]]; then
    log "Collecting all installed packages listed in $HERMES_PACKAGE_JSON"
    mapfile -t candidates < <(packages_from_manifest)
  else
    if [[ ! -r "$HERMES_APT_INSTALLED_BY_US_FILE" ]]; then
      warn "No package state file found at $HERMES_APT_INSTALLED_BY_US_FILE; leaving apt packages installed"
      return 0
    fi
    log "Collecting packages recorded as installed by setup"
    mapfile -t candidates < <(packages_from_state)
  fi

  local -a installed=()
  local pkg
  for pkg in "${candidates[@]}"; do
    if apt_package_installed "$pkg"; then
      installed+=("$pkg")
    fi
  done

  if ((${#installed[@]} == 0)); then
    log "No recorded apt packages are currently installed"
    return 0
  fi

  log "Purging apt packages: ${installed[*]}"
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get purge -y "${installed[@]}"
  apt-get autoremove -y --purge
}

remove_state() {
  log "Removing setup state"
  safe_remove_dir "$HERMES_STATE_DIR"
}

main() {
  require_root
  stop_and_remove_service
  kill_user_processes
  remove_sudoers_rule
  remove_user_and_home
  purge_apt_packages
  remove_state
  log "Done."
}

main "$@"
