#!/usr/bin/env bash
# Install, check, or remove the Omarchy AI Watch Bridge on this laptop.
#
# The Wear OS app finds the laptop in two ways:
#   1. mDNS/DNS-SD for _omarchy-ai._tcp (UDP 5353)
#   2. a subnet sweep of TCP 8765 /api/v1/ping
# Either path still needs TCP 8765 open from the watch. A default-deny
# firewall (UFW on Omarchy) is the usual reason the watch sees nothing.
set -euo pipefail

PORT=8765
MDNS_PORT=5353
PLUGIN_ID="gladimdim.omarchy-ai-watch"
UNIT_NAME="omarchy-wearos-server.service"
UFW_TCP_COMMENT="omarchy-ai-watch"
UFW_UDP_COMMENT="omarchy-ai-watch-mdns"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${OMARCHY_AI_WATCH_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/$PLUGIN_ID}"
USER_UNIT_DIR="$HOME/.config/systemd/user"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check] [--json] [--fix WHAT] [--remove]

  (no args)        Enable the user daemon, open the firewall if one is active,
                   and verify the bridge is reachable on this laptop's LAN address.
  --check          Print diagnostics only. Makes no changes.
  --check --json   Same checks as JSON (what the bar widget polls).
  --fix daemon     Install and start the user systemd unit. No root.
  --fix firewall   Open TCP $PORT and UDP $MDNS_PORT (sudo / pkexec).
  --fix avahi      Start avahi-daemon if it is installed (may need root).
  --fix all        Daemon, avahi, then firewall.
  --remove         Stop the daemon and drop the firewall rules this script added.

Run this after:

  omarchy plugin add https://github.com/gladimdim/omarchy-ai-companion.git --enable
EOF
}

log() { printf '==> %s\n' "$*"; }
ok()  { printf '    [ok]  %s\n' "$*"; }
bad() { printf '    [!!]  %s\n' "$*"; }
info(){ printf '    [--]  %s\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

lan_ipv4() {
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || true
  if [[ -z "$ip" || "$ip" == 127.* ]]; then
    ip="$(ip -4 -br addr show up 2>/dev/null | awk '$1!="lo" && $3 !~ /^100\./ {print $3; exit}' | cut -d/ -f1)"
  fi
  printf '%s' "$ip"
}

# Root for firewall / avahi. Prefer sudo on a real terminal so the password
# prompt works; pkexec when there is no TTY (agent, GUI).
as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif [[ -t 0 ]] && need_cmd sudo; then
    sudo "$@"
  elif need_cmd pkexec; then
    pkexec "$@"
  elif need_cmd sudo; then
    sudo "$@"
  else
    return 1
  fi
}

resolve_plugin_dir() {
  if [[ -f "$PLUGIN_DIR/server.py" && -f "$PLUGIN_DIR/$UNIT_NAME" ]]; then
    return 0
  fi
  if [[ -f "$SCRIPT_DIR/server.py" && -f "$SCRIPT_DIR/$UNIT_NAME" ]]; then
    PLUGIN_DIR="$SCRIPT_DIR"
    return 0
  fi
  return 1
}

ufw_active() {
  need_cmd ufw || return 1
  # ENABLED=yes in the conf is enough; `ufw status` needs root.
  [[ -f /etc/ufw/ufw.conf ]] && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf
}

firewalld_active() {
  need_cmd firewall-cmd || return 1
  systemctl is-active --quiet firewalld 2>/dev/null
}

ufw_has_port() {
  local proto="$1" port="$2"
  local rules="/etc/ufw/user.rules"
  [[ -r "$rules" ]] || return 1
  grep -Eq -- "-p ${proto} .*--dport ${port} -j ACCEPT" "$rules"
}

install_daemon() {
  if ! resolve_plugin_dir; then
    bad "Plugin files not found. Install it first:"
    info "omarchy plugin add https://github.com/gladimdim/omarchy-ai-companion.git --enable"
    exit 1
  fi
  log "Plugin directory: $PLUGIN_DIR"

  if ! need_cmd python3; then
    bad "python3 is not on PATH"
    exit 1
  fi

  mkdir -p "$USER_UNIT_DIR"
  ln -sfn "$PLUGIN_DIR/$UNIT_NAME" "$USER_UNIT_DIR/$UNIT_NAME"
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"
  ok "user unit $UNIT_NAME enabled and started"
}

ensure_avahi() {
  if ! need_cmd avahi-publish; then
    bad "avahi-publish is missing. On Arch/Omarchy: sudo pacman -S avahi"
    info "The watch can still find the laptop by sweeping TCP $PORT, so this is optional."
    return 0
  fi
  if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    ok "avahi-daemon is running"
    return 0
  fi
  log "Starting avahi-daemon (needs root)"
  if as_root systemctl enable --now avahi-daemon; then
    ok "avahi-daemon started"
  else
    bad "Could not start avahi-daemon. mDNS advertising will not work."
    info "The watch still sweeps TCP $PORT, so open that port anyway."
  fi
}

open_firewall() {
  if ufw_active; then
    log "UFW is enabled; allowing TCP $PORT and UDP $MDNS_PORT"
    if ufw_has_port tcp "$PORT" && ufw_has_port udp "$MDNS_PORT"; then
      ok "UFW already allows $PORT/tcp and $MDNS_PORT/udp"
      return 0
    fi
    # One elevation for both rules so the password prompt appears once.
    if as_root /bin/bash -c "
      set -e
      /usr/bin/ufw status | grep -q '${PORT}/tcp' || /usr/bin/ufw allow ${PORT}/tcp comment '${UFW_TCP_COMMENT}'
      /usr/bin/ufw status | grep -q '${MDNS_PORT}/udp' || /usr/bin/ufw allow ${MDNS_PORT}/udp comment '${UFW_UDP_COMMENT}'
    "; then
      ok "UFW rules in place for $PORT/tcp and $MDNS_PORT/udp"
      return 0
    fi
    bad "Could not change UFW (sudo or a polkit prompt is required)."
    info "sudo ufw allow ${PORT}/tcp comment '${UFW_TCP_COMMENT}'"
    info "sudo ufw allow ${MDNS_PORT}/udp comment '${UFW_UDP_COMMENT}'"
    return 1
  fi

  if firewalld_active; then
    log "firewalld is active; allowing TCP $PORT and the mdns service"
    if as_root /bin/bash -c "
      set -e
      /usr/bin/firewall-cmd --permanent --add-port=${PORT}/tcp
      /usr/bin/firewall-cmd --permanent --add-service=mdns
      /usr/bin/firewall-cmd --reload
    "; then
      ok "firewalld allows $PORT/tcp and mdns"
      return 0
    fi
    bad "Could not change firewalld (sudo or a polkit prompt is required)."
    info "sudo firewall-cmd --permanent --add-port=${PORT}/tcp"
    info "sudo firewall-cmd --permanent --add-service=mdns"
    info "sudo firewall-cmd --reload"
    return 1
  fi

  info "No active UFW or firewalld. If you use nftables/iptables by hand, allow:"
  info "  TCP $PORT  (bridge)   UDP $MDNS_PORT (mDNS)"
}

close_firewall() {
  if ufw_active; then
    log "Removing UFW rules this script added"
    as_root /bin/bash -c "
      /usr/bin/ufw delete allow ${PORT}/tcp || true
      /usr/bin/ufw delete allow ${MDNS_PORT}/udp || true
    " || true
    ok "UFW rules removed (ignore errors if they were already gone)"
    return 0
  fi
  if firewalld_active; then
    log "Removing firewalld port $PORT/tcp"
    as_root /bin/bash -c "
      /usr/bin/firewall-cmd --permanent --remove-port=${PORT}/tcp || true
      /usr/bin/firewall-cmd --reload || true
    " || true
    info "Left the firewalld mdns service in place; other apps may use it."
    return 0
  fi
  info "No active UFW or firewalld to clean up."
}

remove_daemon() {
  log "Stopping user unit $UNIT_NAME"
  systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  rm -f "$USER_UNIT_DIR/$UNIT_NAME"
  systemctl --user daemon-reload
  ok "daemon stopped and unit removed"
}

check() {
  local failed=0
  log "Diagnostics"

  if resolve_plugin_dir; then
    ok "plugin files at $PLUGIN_DIR"
  else
    bad "plugin files not found under $HOME/.config/omarchy/plugins/$PLUGIN_ID"
    failed=1
  fi

  if need_cmd python3; then
    ok "python3: $(command -v python3)"
  else
    bad "python3 missing"
    failed=1
  fi

  if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    ok "avahi-daemon active"
  else
    bad "avahi-daemon is not running (mDNS advertising will fail)"
    failed=1
  fi

  if need_cmd avahi-publish; then
    ok "avahi-publish: $(command -v avahi-publish)"
  else
    bad "avahi-publish missing"
    failed=1
  fi

  if systemctl --user is-active --quiet "$UNIT_NAME" 2>/dev/null; then
    ok "user unit $UNIT_NAME is active"
  else
    bad "user unit $UNIT_NAME is not running"
    info "The bar widget does not start the daemon. Run this script with no args."
    failed=1
  fi

  if ss -tln | grep -q ":${PORT} "; then
    ok "listening on TCP $PORT"
  else
    bad "nothing is listening on TCP $PORT"
    failed=1
  fi

  local ping
  if ping="$(curl -fsS -m 2 "http://127.0.0.1:${PORT}/api/v1/ping" 2>/dev/null)"; then
    ok "localhost /api/v1/ping -> $ping"
  else
    bad "localhost /api/v1/ping failed"
    failed=1
  fi

  local ip
  ip="$(lan_ipv4)"
  if [[ -n "$ip" ]]; then
    info "LAN IPv4: $ip"
  else
    bad "could not determine a LAN IPv4 address"
    failed=1
  fi

  if ufw_active; then
    info "UFW is enabled"
    if ufw_has_port tcp "$PORT"; then
      ok "UFW allows $PORT/tcp"
    else
      bad "UFW is enabled and does not allow $PORT/tcp"
      info "The watch's subnet sweep and any mDNS hit will be dropped."
      info "Fix: sudo ufw allow ${PORT}/tcp comment '${UFW_TCP_COMMENT}'"
      failed=1
    fi
    if ufw_has_port udp "$MDNS_PORT"; then
      ok "UFW allows $MDNS_PORT/udp"
    else
      info "UFW has no explicit $MDNS_PORT/udp rule (multicast mDNS is often allowed anyway)"
    fi
  elif firewalld_active; then
    info "firewalld is active"
    if firewall-cmd --query-port="${PORT}/tcp" >/dev/null 2>&1; then
      ok "firewalld allows $PORT/tcp"
    else
      bad "firewalld does not allow $PORT/tcp"
      failed=1
    fi
  else
    info "No UFW or firewalld active"
  fi

  if need_cmd avahi-browse && systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    local browse
    browse="$(timeout 4 avahi-browse -t -r _omarchy-ai._tcp 2>/dev/null || true)"
    if printf '%s\n' "$browse" | grep -q "_omarchy-ai._tcp"; then
      ok "mDNS is advertising _omarchy-ai._tcp"
      printf '%s\n' "$browse" | sed 's/^/        /'
    else
      bad "avahi-browse did not see _omarchy-ai._tcp"
      info "The daemon starts avahi-publish. Is the unit running?"
      failed=1
    fi
  fi

  cat <<EOF

Watch checklist (this script cannot do these for you):
  - Watch and laptop on the same Wi-Fi, not a guest/AP-isolated SSID
  - Watch Wi-Fi actually on (Galaxy Watch parks it while on Bluetooth)
  - On the watch: Omarchy AI -> Connect

EOF
  return "$failed"
}

json_status() {
  resolve_plugin_dir || true
  local py="$PLUGIN_DIR/server.py"
  if [[ ! -f "$py" ]]; then
    py="$SCRIPT_DIR/server.py"
  fi
  exec python3 "$py" --setup-status
}

fix_one() {
  case "$1" in
    daemon)   install_daemon ;;
    firewall) open_firewall ;;
    avahi)    ensure_avahi ;;
    all|"")
      install_daemon
      ensure_avahi
      open_firewall || true
      sleep 1
      ;;
    *)
      bad "Unknown --fix target: $1"
      usage
      exit 2
      ;;
  esac
}

JSON=0
CHECK=0
REMOVE=0
FIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    --check) CHECK=1 ;;
    --remove) REMOVE=1 ;;
    --fix)
      if [[ $# -ge 2 && "$2" != --* ]]; then
        FIX="$2"
        shift
      else
        FIX=all
      fi
      ;;
    --fix-daemon) FIX=daemon ;;
    --fix-firewall) FIX=firewall ;;
    --fix-avahi) FIX=avahi ;;
    --fix-all) FIX=all ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [[ "$REMOVE" -eq 1 ]]; then
  close_firewall
  remove_daemon
  log "Done. Pairing state is still in ~/.local/state/omarchy/wearos/"
  exit 0
fi

if [[ -n "$FIX" ]]; then
  fix_one "$FIX"
  if [[ "$JSON" -eq 1 ]]; then
    json_status
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    check
    exit $?
  fi
  exit 0
fi

if [[ "$CHECK" -eq 1 || "$JSON" -eq 1 ]]; then
  if [[ "$JSON" -eq 1 ]]; then
    json_status
  fi
  check
  exit $?
fi

install_daemon
ensure_avahi
open_firewall || true
sleep 1
if check; then
  log "Ready. On the watch open Omarchy AI and tap Connect."
else
  log "Setup ran, but something still looks wrong. See the [!!] lines above."
  exit 1
fi
