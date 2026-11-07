#!/usr/bin/env bash
#
# airlift-proxy.sh
#
# Point Docker, Ollama, pacman, apt, npm, pip and git at an Airlift phone proxy
# (or undo it), and print ready-to-paste commands for everything else.
#
# Usage:
#   airlift-proxy.sh on  [PHONE_IP] [-t targets] [-p http_port] [-s socks_port] [-y] [--no-restart]
#   airlift-proxy.sh off [-t targets] [-y] [--no-restart]
#   airlift-proxy.sh status
#   airlift-proxy.sh print [PHONE_IP]
#   eval "$(airlift-proxy.sh env on PHONE_IP)"     # set the proxy in THIS shell
#   eval "$(airlift-proxy.sh env off)"             # unset it again
#
# Targets (comma separated, default: all):
#   docker         Docker daemon (systemd drop-in, restarts docker)
#   docker-client  ~/.docker/config.json (proxy passed into containers)
#   ollama         Ollama service (systemd drop-in, restarts ollama)
#   pacman         XferCommand in /etc/pacman.conf (Arch)
#   apt            /etc/apt/apt.conf.d/95airlift-proxy (Debian/Ubuntu)
#   npm | pip | git   user-level config
#
# Run it as your normal user. It calls sudo only for the system-level targets.

set -euo pipefail

SELF=$(basename "$0")
HTTP_PORT=8080
SOCKS_PORT=1080
IP=""
HTTP_URL=""
YES=0
NORESTART=0
ENVMODE=""
TARGETS=()
ALL_TARGETS=(docker docker-client ollama pacman apt npm pip git)
MARK="airlift-proxy"

SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"
APT_FILE="${APT_FILE:-/etc/apt/apt.conf.d/95airlift-proxy}"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/airlift"
STATE_FILE="$STATE_DIR/state"
DOCKER_CFG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

if [[ -t 2 ]]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  G=""; Y=""; R=""; N=""
fi
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*" >&2; }
skip() { printf '  %s-%s %s (skipped)\n' "$Y" "$N" "$*" >&2; }
warn() { printf '%swarning:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# When logged in as real root there is no sudo to call.
if (( EUID == 0 )); then
  sudo() { "$@"; }
fi

usage() {
  sed -n '/^# airlift-proxy.sh/,/^# Run it as your normal user/p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------- helpers

valid_ip() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

confirm() {
  (( YES )) && return 0
  [[ -t 0 ]] || return 1
  local a
  read -r -p "$1 [y/N] " a
  [[ $a =~ ^[Yy]$ ]]
}

ask_ip() {
  local def="" gw="" a
  [[ -t 0 ]] || die "No IP given. Usage: $SELF $ACTION <phone-ip>"
  [[ -f $STATE_FILE ]] && def=$(sed -n 's/^LAST_IP=//p' "$STATE_FILE" | head -1)
  gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}' || true)
  if [[ -z $def ]]; then def=$gw; fi
  if [[ -n $gw ]]; then
    printf 'Your default gateway is %s (when you are on the phone'"'"'s Wi-Fi, that is usually the phone).\n' "$gw" >&2
  fi
  if [[ -n $def ]]; then
    read -r -p "Phone IP shown in Airlift [$def]: " a
    IP=${a:-$def}
  else
    read -r -p "Phone IP shown in Airlift: " a
    IP=$a
  fi
}

setup_url() {
  valid_ip "$IP" || die "'$IP' is not a valid IPv4 address"
  valid_port "$HTTP_PORT" || die "'$HTTP_PORT' is not a valid port"
  valid_port "$SOCKS_PORT" || die "'$SOCKS_PORT' is not a valid port"
  HTTP_URL="http://$IP:$HTTP_PORT"
}

save_state() {
  mkdir -p "$STATE_DIR"
  printf 'LAST_IP=%s\n' "$IP" > "$STATE_FILE"
}

check_proxy() {
  command -v curl >/dev/null 2>&1 || return 0
  printf 'Testing the proxy at %s ... ' "$HTTP_URL" >&2
  if curl -fsS -m 10 -x "$HTTP_URL" --head -o /dev/null https://example.com 2>/dev/null; then
    echo "ok" >&2
    return 0
  fi
  echo "FAILED" >&2
  warn "Could not reach the internet through $HTTP_URL."
  warn "Check: the Airlift app shows 'Stop sharing', this machine is on its Wi-Fi, the IP is right, and the phone has mobile data."
  confirm "Apply the settings anyway?"
}

has_unit() {
  command -v systemctl >/dev/null 2>&1 && systemctl cat "$1.service" >/dev/null 2>&1
}

sd() {
  if command -v systemctl >/dev/null 2>&1; then sudo systemctl "$@"; fi
}

restart_unit() {
  local unit=$1 warning=${2:-}
  has_unit "$unit" || return 0
  if ! systemctl is-active --quiet "$unit"; then
    ok "$unit is not running; the setting applies when it next starts"
    return 0
  fi
  if (( NORESTART )); then
    warn "$unit not restarted. Apply with: sudo systemctl restart $unit"
    return 0
  fi
  if [[ -n $warning ]] && ! confirm "$warning Restart $unit now?"; then
    warn "$unit not restarted. Apply with: sudo systemctl restart $unit"
    return 0
  fi
  sudo systemctl restart "$unit"
  ok "restarted $unit"
}

# dropin <unit> <on|off> <file-content> [restart-warning]
dropin() {
  local unit=$1 mode=$2 content=$3 warning=${4:-}
  local dir="$SYSTEMD_DIR/$unit.service.d"
  local file="$dir/airlift-proxy.conf"
  if ! has_unit "$unit" && [[ ! -f $file ]]; then
    skip "$unit (service not found)"
    return 0
  fi
  if [[ $mode == on ]]; then
    sudo mkdir -p "$dir"
    printf '%b' "$content" | sudo tee "$file" >/dev/null
  else
    sudo rm -f "$file"
    sudo rmdir --ignore-fail-on-non-empty "$dir" 2>/dev/null || true
  fi
  sd daemon-reload
  restart_unit "$unit" "$warning"
  ok "$unit service: proxy $mode"
}

# ---------------------------------------------------------------- targets

t_docker() {
  local c=""
  if [[ $1 == on ]]; then
    c="[Service]\nEnvironment=\"HTTP_PROXY=$HTTP_URL\"\nEnvironment=\"HTTPS_PROXY=$HTTP_URL\"\nEnvironment=\"NO_PROXY=localhost,127.0.0.1\"\n"
  fi
  dropin docker "$1" "$c" "Restarting Docker stops running containers unless live-restore is enabled."
}

t_docker_client() {
  local mode=$1
  if ! command -v python3 >/dev/null 2>&1; then
    skip "docker client config (python3 not found)"
    return 0
  fi
  if [[ $mode == off && ! -f $DOCKER_CFG ]]; then
    skip "docker client config (no $DOCKER_CFG)"
    return 0
  fi
  [[ $mode == on ]] && mkdir -p "$(dirname "$DOCKER_CFG")"
  python3 - "$DOCKER_CFG" "$mode" "$HTTP_URL" <<'PY' || die "Could not update $DOCKER_CFG"
import json, os, sys
path, mode, url = sys.argv[1:4]
data = {}
if os.path.exists(path):
    with open(path) as fh:
        txt = fh.read().strip()
    if txt:
        try:
            data = json.loads(txt)
        except ValueError:
            sys.exit(path + " is not valid JSON; fix it first")
if mode == "on":
    p = data.setdefault("proxies", {}).setdefault("default", {})
    p["httpProxy"] = url
    p["httpsProxy"] = url
    p["noProxy"] = "localhost,127.0.0.1"
else:
    proxies = data.get("proxies", {})
    proxies.pop("default", None)
    if proxies:
        data["proxies"] = proxies
    else:
        data.pop("proxies", None)
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
if os.path.exists(path):
    os.chmod(tmp, os.stat(path).st_mode)
os.replace(tmp, path)
PY
  ok "docker client config ($DOCKER_CFG): proxy $mode (affects containers started from now on)"
}

t_ollama() {
  local c=""
  if [[ $1 == on ]]; then
    c="[Service]\nEnvironment=\"HTTPS_PROXY=$HTTP_URL\"\n"
  fi
  dropin ollama "$1" "$c"
}

t_pacman() {
  local mode=$1
  if [[ ! -f $PACMAN_CONF ]]; then
    skip "pacman (no $PACMAN_CONF)"
    return 0
  fi
  if [[ $mode == on ]]; then
    command -v curl >/dev/null 2>&1 || { skip "pacman (curl not installed)"; return 0; }
    if grep -E '^[[:space:]]*XferCommand' "$PACMAN_CONF" | grep -v "# $MARK" | grep -q .; then
      skip "pacman (you already have your own XferCommand in $PACMAN_CONF)"
      return 0
    fi
    [[ -f $PACMAN_CONF.airlift.bak ]] || sudo cp -p "$PACMAN_CONF" "$PACMAN_CONF.airlift.bak"
    sudo sed -i "/# $MARK\$/d" "$PACMAN_CONF"
    sudo sed -i "/^\[options\]/a XferCommand = /usr/bin/curl --socks5-hostname $IP:$SOCKS_PORT -L -C - -f -o %o %u # $MARK" "$PACMAN_CONF"
    if grep -q "# $MARK\$" "$PACMAN_CONF"; then
      ok "pacman: downloads go through SOCKS5 $IP:$SOCKS_PORT (backup: $PACMAN_CONF.airlift.bak)"
    else
      warn "pacman: could not find an [options] section in $PACMAN_CONF; nothing changed"
    fi
  else
    if grep -q "# $MARK\$" "$PACMAN_CONF"; then
      sudo sed -i "/# $MARK\$/d" "$PACMAN_CONF"
      ok "pacman: proxy off"
    else
      skip "pacman (nothing to remove)"
    fi
  fi
}

t_apt() {
  local mode=$1
  if ! command -v apt-get >/dev/null 2>&1 && [[ ! -f $APT_FILE ]]; then
    skip "apt (not installed)"
    return 0
  fi
  if [[ $mode == on ]]; then
    sudo mkdir -p "$(dirname "$APT_FILE")"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$HTTP_URL" "$HTTP_URL" | sudo tee "$APT_FILE" >/dev/null
  else
    sudo rm -f "$APT_FILE"
  fi
  ok "apt: proxy $mode"
}

t_npm() {
  local mode=$1
  command -v npm >/dev/null 2>&1 || { skip "npm (not installed)"; return 0; }
  if [[ $mode == on ]]; then
    if ! { npm config set proxy "$HTTP_URL" && npm config set https-proxy "$HTTP_URL"; } >/dev/null 2>&1; then
      warn "npm: could not set the proxy (run: npm config set proxy $HTTP_URL)"
      return 0
    fi
  else
    npm config delete proxy >/dev/null 2>&1 || true
    npm config delete https-proxy >/dev/null 2>&1 || true
  fi
  ok "npm: proxy $mode"
}

t_pip() {
  local mode=$1 pip
  pip=$(command -v pip3 || command -v pip || true)
  [[ -n $pip ]] || { skip "pip (not installed)"; return 0; }
  if [[ $mode == on ]]; then
    if ! "$pip" config set global.proxy "$HTTP_URL" >/dev/null 2>&1; then
      warn "pip: could not set the proxy (run: pip config set global.proxy $HTTP_URL)"
      return 0
    fi
  else
    "$pip" config unset global.proxy >/dev/null 2>&1 || true
  fi
  ok "pip: proxy $mode"
}

t_git() {
  local mode=$1
  command -v git >/dev/null 2>&1 || { skip "git (not installed)"; return 0; }
  if [[ $mode == on ]]; then
    if ! git config --global http.proxy "$HTTP_URL" 2>/dev/null; then
      warn "git: could not set the proxy (run: git config --global http.proxy $HTTP_URL)"
      return 0
    fi
  else
    git config --global --unset http.proxy 2>/dev/null || true
  fi
  ok "git: proxy $mode"
}

resolve_targets() {
  local t out=()
  if (( ${#TARGETS[@]} == 0 )); then
    TARGETS=("${ALL_TARGETS[@]}")
    return 0
  fi
  for t in "${TARGETS[@]}"; do
    if [[ $t == all ]]; then
      out=("${ALL_TARGETS[@]}")
      break
    fi
    printf '%s\n' "${ALL_TARGETS[@]}" | grep -qx -- "$t" \
      || die "unknown target '$t' (valid: ${ALL_TARGETS[*]} or all)"
    out+=("$t")
  done
  TARGETS=("${out[@]}")
}

need_sudo() {
  local t need=0
  for t in "${TARGETS[@]}"; do
    case $t in docker|ollama|pacman|apt) need=1 ;; esac
  done
  (( need )) || return 0
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "sudo is required for: ${TARGETS[*]}"
    sudo -v
  fi
}

run_targets() {
  local t
  for t in "${TARGETS[@]}"; do
    "t_${t//-/_}" "$1"
  done
}

guard_not_sudo() {
  if (( EUID == 0 )) && [[ -n ${SUDO_USER:-} ]]; then
    die "Don't run this with sudo. Run it as your normal user; it calls sudo where needed. (Otherwise npm/pip/git/docker settings land in root's home.)"
  fi
}

# --------------------------------------------------------------- commands

cmd_on() {
  guard_not_sudo
  [[ -n $IP ]] || ask_ip
  setup_url
  resolve_targets
  check_proxy || die "Aborted. Nothing was changed."
  need_sudo
  printf 'Enabling proxy %s (SOCKS5 %s:%s)\n' "$HTTP_URL" "$IP" "$SOCKS_PORT" >&2
  run_targets on
  save_state
  cat >&2 <<EOF

Done. Next steps:
  - This terminal:   eval "\$($SELF env on $IP)"
  - Containers that were already running keep their old settings; restart them.
  - Ollama started by hand (ollama serve) is not affected:
        HTTPS_PROXY=$HTTP_URL ollama serve
  - When you're finished: $SELF off, then tap Stop sharing in Airlift.
EOF
}

cmd_off() {
  guard_not_sudo
  resolve_targets
  need_sudo
  echo "Removing proxy settings" >&2
  run_targets off
  cat >&2 <<EOF

Done. Don't forget:
  - Open terminals keep their variables:   eval "\$($SELF env off)"
  - Remove the proxy on any other device you connected (Wi-Fi settings -> Proxy -> None).
  - Check what's left with:                $SELF status
EOF
}

row() { printf '  %-15s %s\n' "$1" "$2"; }

cmd_status() {
  local v f
  echo "Proxy settings on this machine:"

  v=$(env | grep -iE '^(http|https|no|all)_proxy=' | tr '\n' ' ' || true)
  row "shell env" "${v:-not set}"

  for u in docker ollama; do
    f="$SYSTEMD_DIR/$u.service.d/airlift-proxy.conf"
    if [[ -f $f ]]; then
      v=$(sed -n 's/.*HTTPS_PROXY=\([^"]*\)".*/\1/p' "$f" | head -1)
      row "$u service" "ON  ($v)"
    elif has_unit "$u"; then
      row "$u service" "off"
    else
      row "$u service" "not installed"
    fi
  done

  if [[ -f $DOCKER_CFG ]] && grep -q '"httpProxy"' "$DOCKER_CFG"; then
    v=$(sed -n 's/.*"httpProxy": *"\([^"]*\)".*/\1/p' "$DOCKER_CFG" | head -1)
    row "docker client" "ON  ($v)"
  else
    row "docker client" "off"
  fi

  if [[ -f $PACMAN_CONF ]] && grep -q "# $MARK\$" "$PACMAN_CONF"; then
    v=$(grep "# $MARK\$" "$PACMAN_CONF" | sed -n 's/.*--socks5-hostname \([^ ]*\).*/\1/p')
    row "pacman" "ON  (socks5 $v)"
  elif [[ -f $PACMAN_CONF ]]; then
    row "pacman" "off"
  fi

  if [[ -f $APT_FILE ]]; then
    v=$(sed -n 's/^Acquire::http::Proxy "\(.*\)";/\1/p' "$APT_FILE" | head -1)
    row "apt" "ON  ($v)"
  elif command -v apt-get >/dev/null 2>&1; then
    row "apt" "off"
  fi

  if command -v npm >/dev/null 2>&1; then
    v=$(npm config get proxy 2>/dev/null || true)
    [[ $v == null || -z $v ]] && row "npm" "off" || row "npm" "ON  ($v)"
  fi

  f=$(command -v pip3 || command -v pip || true)
  if [[ -n $f ]]; then
    v=$("$f" config get global.proxy 2>/dev/null || true)
    [[ -z $v ]] && row "pip" "off" || row "pip" "ON  ($v)"
  fi

  if command -v git >/dev/null 2>&1; then
    v=$(git config --global --get http.proxy 2>/dev/null || true)
    [[ -z $v ]] && row "git" "off" || row "git" "ON  ($v)"
  fi
}

cmd_print() {
  [[ -n $IP ]] || ask_ip
  setup_url
  sed -e "s|{HTTP_URL}|$HTTP_URL|g" -e "s|{IP}|$IP|g" -e "s|{SOCKS}|$SOCKS_PORT|g" -e "s|{SELF}|$SELF|g" <<'EOF'
# Airlift proxy: {HTTP_URL} (HTTP)   {IP}:{SOCKS} (SOCKS5)

## Everything this script manages (docker, ollama, pacman, apt, npm, pip, git)
{SELF} on {IP}
{SELF} off

## This shell only
export http_proxy={HTTP_URL} https_proxy={HTTP_URL} no_proxy=localhost,127.0.0.1
export HTTP_PROXY=$http_proxy HTTPS_PROXY=$https_proxy NO_PROXY=$no_proxy
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY    # undo

## One-off commands (no config changes)
curl -x {HTTP_URL} https://example.com
curl --socks5-hostname {IP}:{SOCKS} https://example.com
sudo env http_proxy={HTTP_URL} https_proxy={HTTP_URL} pacman -Syu
sudo -E apt-get update                       # after exporting the variables above
git -c http.proxy={HTTP_URL} clone <url>
pip install --proxy {HTTP_URL} <package>
npm install --proxy {HTTP_URL} --https-proxy {HTTP_URL} <package>
HTTPS_PROXY={HTTP_URL} ollama serve          # Ollama started by hand
EOF
}

cmd_env() {
  case $ENVMODE in
    on)
      [[ -n $IP ]] || ask_ip
      setup_url
      printf 'export http_proxy=%s https_proxy=%s HTTP_PROXY=%s HTTPS_PROXY=%s\n' \
        "$HTTP_URL" "$HTTP_URL" "$HTTP_URL" "$HTTP_URL"
      printf 'export no_proxy=localhost,127.0.0.1 NO_PROXY=localhost,127.0.0.1\n'
      ;;
    off)
      echo 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY'
      ;;
    *)
      die "usage: eval \"\$($SELF env on <phone-ip>)\"   or   eval \"\$($SELF env off)\""
      ;;
  esac
}

# ------------------------------------------------------------------- main

ACTION=${1:-}
[[ $# -gt 0 ]] && shift
if [[ $ACTION == env ]]; then
  ENVMODE=${1:-}
  [[ $# -gt 0 ]] && shift
fi

while (( $# )); do
  case $1 in
    -t|--targets)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      IFS=',' read -r -a TARGETS <<<"$2"
      shift
      ;;
    -p|--http-port)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      HTTP_PORT=$2
      shift
      ;;
    -s|--socks-port)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      SOCKS_PORT=$2
      shift
      ;;
    -y|--yes) YES=1 ;;
    --no-restart) NORESTART=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *)
      [[ -z $IP ]] || die "unexpected argument '$1'"
      IP=$1
      ;;
  esac
  shift
done

case $ACTION in
  on)     cmd_on ;;
  off)    cmd_off ;;
  status) cmd_status ;;
  print)  cmd_print ;;
  env)    cmd_env ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command '$ACTION' (try --help)" ;;
esac
