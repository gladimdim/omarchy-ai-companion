#!/usr/bin/env python3
"""
Omarchy AI Watch Bridge - Server Daemon & Dynamic LLM Collector
Provides local REST API, mDNS discovery, and one-time PIN pairing for Wear OS.
"""

import argparse
import datetime as dt
import glob
import http.server
import json
import os
import re
import secrets
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, NamedTuple, Optional, Tuple

PORT = 8765
SERVICE_NAME = "Omarchy AI Watch Bridge"
MDNS_SERVICE_TYPE = "_omarchy-ai._tcp"

# Wire-format version, shared with the Wear OS app (see Protocol.kt).
#
# Bump this ONLY when a change breaks an older peer: a renamed or removed field,
# a changed unit or meaning, a new required request field, a different pairing
# handshake. Do NOT bump it for additive changes -- both sides read every field
# with a default, so a new field is invisible to an old peer by construction.
#
# It exists because the two halves update through different channels: the watch
# app through Play, the bridge through a git pull. They will drift, and without a
# version the symptom of a breaking change is a watch quietly showing wrong
# numbers instead of saying so.
PROTOCOL_VERSION = 1

STATE_DIR = Path(os.path.expanduser("~/.local/state/omarchy/wearos"))
AGENTS_DIR = Path(os.path.expanduser("~/.local/state/omarchy/agents/usage"))
CONFIG_FILE = STATE_DIR / "config.json"
STATUS_FILE = STATE_DIR / "watch_status.json"
SLOTS_FILE = STATE_DIR / "slots.json"

# The four gauges on the watch face, and the quota each tracks out of the box.
# GaugeSlot in the Wear OS app carries the same four keys and the same defaults.
DEFAULT_SLOTS: Dict[str, str] = {
    "top": "claude:session-5-hour",
    "right": "grok:weekly",
    "bottom": "antigravity:thinking-models-quota",
    "left": "global:today-tokens",
}
SLOT_KEYS = tuple(DEFAULT_SLOTS)


class Provider(NamedTuple):
    """How one AI provider is named and coloured wherever it is shown."""

    short: str   # fits a bare gauge, e.g. "AGY"
    full: str    # fits the roomier arc label, e.g. "Antigravity"
    color: str


# One row per provider. These used to be three parallel dicts keyed by the same
# ids, which is how a provider could end up with a colour but no short name.
PROVIDERS: Dict[str, Provider] = {
    "claude": Provider("Claude", "Claude", "#D97757"),
    "grok": Provider("Grok", "Grok", "#38BDF8"),
    "antigravity": Provider("AGY", "Antigravity", "#A855F7"),
    "codex": Provider("Codex", "Codex", "#10B981"),
    "fireworks": Provider("Firewks", "Fireworks", "#F59E0B"),
    "opencode": Provider("OpenCd", "OpenCode", "#EC4899"),
    "gemini": Provider("Gemini", "Gemini", "#4285F4"),
    "ollama": Provider("Ollama", "Ollama", "#FFFFFF"),
    "deepseek": Provider("DeepSeek", "DeepSeek", "#4E8BF5"),
}
UNKNOWN_PROVIDER_COLOR = "#38BDF8"

# Colours for the two aggregate gauges, which belong to no single provider.
TOKENS_COLOR = "#9ECE6A"
SESSIONS_COLOR = "#A855F7"

# The aggregate gauges are counters, not quotas, so they need a ceiling to draw
# an arc against. A heavy day is the scale, not a limit anyone is enforcing.
TOKENS_FULL_SCALE = 50_000_000
SESSIONS_FULL_SCALE = 10

# Roughly how many characters fit on one 80-degree complication arc alongside the
# value, at the watch face's font size. Longer labels get trimmed to the provider.
DETAIL_LABEL_MAX = 17

# Which quota window a limit's title describes: the keywords to look for, then the
# terse form for a bare gauge and the roomier one for the arc label. Order matters,
# since "Flash thinking" should read as Flash.
LIMIT_WINDOWS: Tuple[Tuple[Tuple[str, ...], str, str], ...] = (
    (("flash",), "Flash", "Flash"),
    (("thinking",), "Think", "Think"),
    (("session", "5-hour", "5h"), "5h", "5h"),
    (("weekly", "7-day"), "Wk", "1 Wk"),
    (("monthly",), "Mo", "1 Mo"),
    (("daily", "today"), "Today", "Today"),
    (("build",), "Bld", "Build"),
    (("chat",), "Chat", "Chat"),
)


def provider_of(provider_id: str, display_name: str = "") -> Provider:
    """The naming and colour for a provider, inventing sane ones if unknown."""
    known = PROVIDERS.get(provider_id)
    if known:
        return known
    name = display_name or provider_id.capitalize()
    return Provider(short=name[:7], full=name, color=UNKNOWN_PROVIDER_COLOR)


def slugify(text: str) -> str:
    s = re.sub(r"[^\w\s-]", "", text).strip().lower()
    return re.sub(r"[-\s]+", "-", s)


def get_local_ip() -> str:
    """Detect local IP on the active LAN interface."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Does not actually connect, just determines route
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


def _run_quiet(args: List[str], timeout: float = 2) -> subprocess.CompletedProcess:
    return subprocess.run(
        args, capture_output=True, text=True, timeout=timeout, check=False,
    )


def _cmd_ok(args: List[str], timeout: float = 2) -> bool:
    try:
        return _run_quiet(args, timeout=timeout).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _ufw_enabled() -> bool:
    conf = Path("/etc/ufw/ufw.conf")
    if not conf.is_file():
        return False
    try:
        return any(line.strip() == "ENABLED=yes" for line in conf.read_text().splitlines())
    except OSError:
        return False


def _ufw_allows(proto: str, port: int) -> bool:
    rules = Path("/etc/ufw/user.rules")
    if not rules.is_file():
        return False
    try:
        text = rules.read_text()
    except OSError:
        return False
    return re.search(rf"-p {re.escape(proto)} .*--dport {port} -j ACCEPT", text) is not None


def _bridge_ping(port: int) -> Optional[Dict[str, Any]]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/ping", timeout=1) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def collect_setup_status(port: int = PORT) -> Dict[str, Any]:
    """What the widget installer draws: each laptop-side step, and whether it is ok.

    Kept fast on purpose. The widget polls this while the panel is open, so it
    must not run avahi-browse or anything else that waits on the network.
    """
    lan_ip = get_local_ip()
    python_ok = shutil.which("python3") is not None
    unit_active = _cmd_ok(["systemctl", "--user", "is-active", "--quiet",
                           "omarchy-wearos-server.service"])
    unit_enabled = _cmd_ok(["systemctl", "--user", "is-enabled", "--quiet",
                            "omarchy-wearos-server.service"])
    ping = _bridge_ping(port)
    listening = ping is not None
    daemon_ok = python_ok and unit_active and listening

    if not python_ok:
        daemon_detail = "python3 is not on PATH."
        daemon_fixable = False
    elif not unit_active and not listening:
        daemon_detail = "The background service is not running. The watch has nothing to connect to."
        daemon_fixable = True
    elif unit_active and not listening:
        daemon_detail = "The service is up but nothing answered on port %d. Check the journal." % port
        daemon_fixable = True
    elif listening and not unit_active:
        daemon_detail = "Something is answering on port %d, but the user systemd unit is not active." % port
        daemon_fixable = True
    else:
        daemon_detail = "Running on %s:%d%s." % (
            lan_ip, port, " and enabled at login" if unit_enabled else "",
        )
        daemon_fixable = False

    ufw_on = _ufw_enabled()
    firewalld_on = _cmd_ok(["systemctl", "is-active", "--quiet", "firewalld"])
    ufw_tcp = _ufw_allows("tcp", port) if ufw_on else False
    ufw_udp = _ufw_allows("udp", 5353) if ufw_on else False
    firewalld_tcp = (
        _cmd_ok(["firewall-cmd", "--query-port=%d/tcp" % port]) if firewalld_on else False
    )

    if ufw_on:
        firewall_kind = "ufw"
        firewall_ok = ufw_tcp
        firewall_fixable = not ufw_tcp
        if ufw_tcp and ufw_udp:
            firewall_detail = "UFW allows TCP %d and UDP 5353." % port
        elif ufw_tcp:
            firewall_detail = "UFW allows TCP %d. UDP 5353 is not explicitly open (multicast mDNS may still work)." % port
        else:
            firewall_detail = (
                "UFW is on and is dropping TCP %d from the network. "
                "The watch's scan and any mDNS hit will be blocked." % port
            )
    elif firewalld_on:
        firewall_kind = "firewalld"
        firewall_ok = firewalld_tcp
        firewall_fixable = not firewalld_tcp
        firewall_detail = (
            "firewalld allows TCP %d." % port
            if firewalld_tcp
            else "firewalld is on and does not allow TCP %d." % port
        )
    else:
        firewall_kind = "none"
        firewall_ok = True
        firewall_fixable = False
        firewall_detail = "No UFW or firewalld is active. Nothing to unlock."

    avahi_bin = shutil.which("avahi-publish") or "/usr/bin/avahi-publish"
    avahi_present = os.path.isfile(avahi_bin)
    avahi_daemon = _cmd_ok(["systemctl", "is-active", "--quiet", "avahi-daemon"])
    avahi_publishing = _cmd_ok(["pgrep", "-f", r"avahi-publish.*_omarchy-ai"])
    mdns_ok = avahi_present and avahi_daemon and avahi_publishing
    if not avahi_present:
        mdns_detail = "avahi-publish is not installed. The watch can still find the laptop by scanning the subnet."
        mdns_fixable = False
    elif not avahi_daemon:
        mdns_detail = "avahi-daemon is stopped, so the laptop is not advertising. Subnet scan still works if the firewall is open."
        mdns_fixable = True
    elif not avahi_publishing:
        mdns_detail = "Avahi is up, but this bridge is not advertising yet. Start the daemon; it launches avahi-publish."
        mdns_fixable = False
    else:
        mdns_detail = "Advertising _omarchy-ai._tcp on %s:%d." % (lan_ip, port)
        mdns_fixable = False

    steps = [
        {
            "id": "daemon",
            "title": "Background daemon",
            "ok": daemon_ok,
            "required": True,
            "fixable": daemon_fixable,
            "action": "daemon",
            "button": "Start daemon",
            "detail": daemon_detail,
            "hint": (
                "The watch talks to a small Python service on this laptop. The bar "
                "widget does not start it — it has to run as a user systemd service "
                "so it stays up after you close this panel."
            ),
        },
        {
            "id": "firewall",
            "title": "Firewall",
            "ok": firewall_ok,
            "required": True,
            "fixable": firewall_fixable,
            "action": "firewall",
            "button": "Unlock firewall",
            "needsPassword": firewall_fixable,
            "detail": firewall_detail,
            "hint": (
                "Omarchy's firewall denies incoming connections by default. The watch "
                "is on Wi-Fi, so it is incoming. Opening TCP %d lets it through. "
                "A system password prompt will appear." % port
            ),
        },
        {
            "id": "mdns",
            "title": "Watch discovery",
            "ok": mdns_ok,
            "required": False,
            "fixable": mdns_fixable,
            "action": "avahi",
            "button": "Start discovery",
            "needsPassword": bool(avahi_present and not avahi_daemon),
            "detail": mdns_detail,
            "hint": (
                "The watch first looks for _omarchy-ai._tcp over mDNS, then sweeps "
                "the subnet for TCP %d. Discovery is a shortcut. The daemon and "
                "firewall are what actually have to work." % port
            ),
        },
    ]
    required_ok = all(step["ok"] for step in steps if step["required"])
    return {
        "ok": required_ok,
        "lanIp": lan_ip,
        "port": port,
        "mdnsPort": 5353,
        "service": SERVICE_NAME,
        "firewall": firewall_kind,
        "unitActive": unit_active,
        "unitEnabled": unit_enabled,
        "steps": steps,
        "tips": [
            {
                "id": "wifi",
                "title": "Same Wi-Fi, not a guest network",
                "body": "The watch and this laptop must share a LAN. Guest / AP-isolated SSIDs block device-to-device traffic.",
            },
            {
                "id": "watch-radio",
                "title": "Turn Wi-Fi on on the watch",
                "body": "A Galaxy Watch parks its Wi-Fi radio while it is on Bluetooth. Open the watch Wi-Fi settings and wait until it has an address.",
            },
            {
                "id": "connect",
                "title": "Tap Connect, then approve here",
                "body": "Open Omarchy AI on the watch and tap Connect. This panel (or a desktop notification) asks you to approve. Nothing is typed on the watch.",
            },
        ],
    }


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json_atomically(path: Path, data: Any):
    """Write via a temp file and rename, so a reader never sees half a file.

    Both the widget and the CLI read these while the daemon writes them.

    Mode 0600 because config.json holds the pairing tokens and the PIN, and the
    default umask made them readable by every account on the machine.
    """
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def read_json(path: Path, default: Any) -> Any:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def format_relative_time(resets_at_str: Optional[str]) -> Tuple[str, str]:
    """('resets in 2h 05m', '2h05m') for a reset timestamp, or two empty strings."""
    if not resets_at_str:
        return ("", "")
    try:
        target_dt = dt.datetime.fromisoformat(resets_at_str.replace("Z", "+00:00"))
        total_seconds = int((target_dt - dt.datetime.now(dt.timezone.utc)).total_seconds())

        if total_seconds <= 0:
            return ("resets soon", "now")

        days = total_seconds // 86400
        hours = (total_seconds % 86400) // 3600
        minutes = (total_seconds % 3600) // 60

        if days > 0:
            long_fmt = f"resets in {days}d {hours}h"
            short_fmt = f"{days}d{hours}h" if hours > 0 else f"{days}d"
        elif hours > 0:
            long_fmt = f"resets in {hours}h {minutes}m"
            short_fmt = f"{hours}h{minutes:02d}m" if minutes > 0 else f"{hours}h"
        else:
            long_fmt = f"resets in {minutes}m"
            short_fmt = f"{minutes}m"

        return (long_fmt, short_fmt)
    except Exception:
        return ("", "")


def format_tokens(count: Optional[int]) -> str:
    if not count:
        return "0"
    for threshold, suffix in ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "k")):
        if count >= threshold:
            return f"{count / threshold:.1f}{suffix}"
    return str(count)


def make_labels(provider_id: str, limit_title: str) -> Tuple[str, str]:
    """Name one quota twice: terse for a bare gauge, roomier for the arc label.

    'Claude 5h' fits next to a value on an 80-degree arc; 'Claude Sess' is what
    is left when only the gauge is drawn. Both readings come from the same
    keyword table so the two can no longer disagree about what a limit is called.
    """
    provider = provider_of(provider_id)
    lowered = limit_title.lower()

    short_window = long_window = ""
    for keywords, short_form, long_form in LIMIT_WINDOWS:
        if any(word in lowered for word in keywords):
            short_window, long_window = short_form, long_form
            break
    else:
        words = limit_title.split()
        if words:
            short_window, long_window = words[0][:4], words[0]

    short_label = f"{provider.short} {short_window}".strip()

    detail_label = f"{provider.full} {long_window}".strip()
    if len(detail_label) > DETAIL_LABEL_MAX:
        # Prefer keeping the window readable over truncating it mid-word.
        detail_label = f"{provider.short} {long_window}".strip()

    return short_label, detail_label[:DETAIL_LABEL_MAX]


def _protocol_verdict(status: Dict[str, Any]) -> Dict[str, Any]:
    """Compare the watch's wire version against this bridge's.

    Decided here rather than in the widget so the CLI, the widget and anything
    else reading `--status` cannot disagree about what counts as a mismatch.

    States:
      unknown      no watch has reported its version yet -- nothing to say
      legacy       a watch checked in but reports no version at all, i.e. it was
                   built before PROTOCOL_VERSION existed
      watch_older  the watch speaks an older wire format than this bridge
      watch_newer  the bridge is the one that is behind
      ok           the two agree
    """
    watch = int(status.get("protocolVersion", 0) or 0)

    if watch <= 0:
        # A record written by pairing carries no version because the watch had
        # not spoken yet. Only a heartbeat with no version means an old build.
        state = "legacy" if status.get("source") == "heartbeat" else "unknown"
    elif watch < PROTOCOL_VERSION:
        state = "watch_older"
    elif watch > PROTOCOL_VERSION:
        state = "watch_newer"
    else:
        state = "ok"

    return {
        "protocolVersion": watch,
        "bridgeProtocolVersion": PROTOCOL_VERSION,
        "protocolState": state,
    }


class StateManager:
    """Manages persistent configuration, active PIN, tokens, and watch status."""

    # How long "Add watch" on the laptop stays open for.
    PAIRING_WINDOW_SECONDS = 120

    # A connect request waits this long for someone to approve it.
    PAIR_REQUEST_TTL = 180

    # A watch that has not checked in for this long is linked but not online.
    ONLINE_WINDOW_SECONDS = 15 * 60

    def __init__(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        # Pre-existing installs were created world-readable; narrow them too.
        try:
            STATE_DIR.chmod(0o700)
            for stale in (CONFIG_FILE, STATUS_FILE, SLOTS_FILE):
                if stale.exists():
                    stale.chmod(0o600)
        except OSError:
            pass
        self.lock = threading.Lock()
        self.pending_request: Optional[Dict[str, Any]] = None
        self._config_mtime = 0.0
        self.load()

    # ---- Persistence ----------------------------------------------------

    def load(self):
        with self.lock:
            self.config = read_json(CONFIG_FILE, {})
            if not isinstance(self.config, dict):
                self.config = {}

            # No standing master token. One used to be minted at first run,
            # accepted by every endpoint forever, and never sent by any client:
            # a permanent all-access credential in a file, purely attack
            # surface. Dropped here so existing installs shed it too.
            dirty = self.config.pop("token", None) is not None

            defaults = {"paired_tokens": []}
            for key, value in defaults.items():
                if key not in self.config:
                    self.config[key] = value
                    dirty = True
            if not self.config.get("pin"):
                self.config["pin"] = new_pin()
                dirty = True

            # Only write when something actually changed. The widget shells out
            # to `--status` every few seconds and each run loads this; saving
            # unconditionally rewrote config.json on every poll and made the
            # daemon re-read it as "changed" each time.
            if dirty:
                self.save_config()
            else:
                self._config_mtime = self._current_config_mtime()

            self.slots = read_json(SLOTS_FILE, None)
            if not isinstance(self.slots, dict):
                self.slots = dict(DEFAULT_SLOTS)
                self.save_slots()

    def _current_config_mtime(self) -> float:
        try:
            return CONFIG_FILE.stat().st_mtime
        except OSError:
            return 0.0

    def _refresh_config_if_stale(self):
        """Pick up config.json edits made by another process.

        `server.py --new-pin` and `--pin` run as separate short-lived processes,
        which is how the Omarchy widget talks to this daemon. Without this check the
        daemon keeps validating against the PIN it cached at startup, so the widget
        shows a freshly generated PIN that the watch is then told is invalid -- and
        the daemon's next save_config() silently overwrites the new PIN on disk.

        Caller must already hold self.lock.
        """
        mtime = self._current_config_mtime()
        if not mtime or mtime == self._config_mtime:
            return

        disk = read_json(CONFIG_FILE, None)
        if not isinstance(disk, dict):
            return

        # Keep tokens issued by this process; take the PIN from disk.
        merged_tokens = list(dict.fromkeys(
            list(disk.get("paired_tokens", [])) + list(self.config.get("paired_tokens", []))
        ))
        self.config = disk
        self.config["paired_tokens"] = merged_tokens
        self._config_mtime = mtime

    def save_config(self):
        write_json_atomically(CONFIG_FILE, self.config)
        self._config_mtime = self._current_config_mtime()

    def save_slots(self):
        write_json_atomically(SLOTS_FILE, self.slots)

    # ---- Pairing codes --------------------------------------------------

    def get_pin(self) -> str:
        with self.lock:
            self._refresh_config_if_stale()
            return self.config.get("pin", "1234")

    def generate_new_pin(self) -> str:
        with self.lock:
            self.config["pin"] = new_pin()
            self.save_config()
            return self.config["pin"]

    def validate_pin(self, pin: str) -> Optional[str]:
        with self.lock:
            self._refresh_config_if_stale()
            if str(pin).strip() != str(self.config.get("pin", "")).strip():
                return None
            return self.issue_token()

    # ---- Pairing window -------------------------------------------------

    def open_pairing_window(self) -> float:
        """Let the next watch that asks pair without typing anything.

        Typing a 4-digit code on a watch is the worst input surface in this setup,
        so the deliberate action moves to the laptop, where there is a mouse and a
        real screen. This mirrors Bluetooth pairing mode: a short, explicit window
        the user opens, rather than a standing secret they transcribe.
        """
        with self.lock:
            self._refresh_config_if_stale()
            until = time.time() + self.PAIRING_WINDOW_SECONDS
            self.config["pairing_open_until"] = until
            self.save_config()
            return until

    def pairing_window_remaining(self) -> int:
        with self.lock:
            self._refresh_config_if_stale()
            left = float(self.config.get("pairing_open_until", 0)) - time.time()
            return int(left) if left > 0 else 0

    def pair_via_window(self) -> Optional[str]:
        """Pair with no code at all, if the laptop opened the window."""
        with self.lock:
            self._refresh_config_if_stale()
            if float(self.config.get("pairing_open_until", 0)) <= time.time():
                return None
            token = self.issue_token()
            # One window, one watch. Re-open it on the laptop to add another.
            self.config["pairing_open_until"] = 0
            self.save_config()
            return token

    # ---- Tokens ---------------------------------------------------------

    def issue_token(self) -> str:
        """Mint a pairing token. Caller must already hold self.lock."""
        new_token = secrets.token_hex(24)
        self.config.setdefault("paired_tokens", []).append(new_token)
        self.save_config()
        return new_token

    def has_any_paired_device(self) -> bool:
        with self.lock:
            self._refresh_config_if_stale()
            return bool(self.config.get("paired_tokens"))

    def is_token_valid(self, token: str) -> bool:
        with self.lock:
            self._refresh_config_if_stale()
            if not token:
                return False
            # compare_digest so a token cannot be recovered a byte at a time.
            return any(secrets.compare_digest(token, known)
                       for known in self.config.get("paired_tokens", []))

    def forget_all_devices(self) -> int:
        """Unlink every paired watch and forget it was ever here.

        Also clears the last heartbeat, otherwise the widget keeps showing a
        watch that is no longer allowed to talk to it.
        """
        with self.lock:
            self._refresh_config_if_stale()
            count = len(self.config.get("paired_tokens", []))
            self.config["paired_tokens"] = []
            self.config["pairing_open_until"] = 0
            self.save_config()
            self.pending_request = None
            self._forget_status_file()
            return count

    def forget_token(self, token: str) -> bool:
        """Unlink one watch, identified by the token it authenticates with."""
        with self.lock:
            self._refresh_config_if_stale()
            tokens = self.config.get("paired_tokens", [])
            if token not in tokens:
                return False
            tokens.remove(token)
            self.config["paired_tokens"] = tokens
            self.save_config()
            if not tokens:
                self._forget_status_file()
            return True

    @staticmethod
    def _forget_status_file():
        try:
            STATUS_FILE.unlink()
        except OSError:
            pass

    # ---- Connect requests -----------------------------------------------

    def create_pair_request(self, device_name: str, peer: str = "") -> Dict[str, Any]:
        """Record a watch asking to connect, for a human to approve.

        The watch cannot show a trustworthy prompt for its own pairing, so the
        decision belongs on the laptop, where there is a real screen and a mouse.
        The request is held in memory by the daemon; the CLI reaches it over HTTP
        rather than through a file, so the two can never disagree about its state.
        """
        with self.lock:
            now = time.time()
            existing = self.pending_request
            # A watch that retries should land on the same request, not spawn a
            # queue of duplicates for the user to work through.
            if (existing and existing["status"] == "pending"
                    and existing["device"] == device_name
                    and now - existing["created"] < self.PAIR_REQUEST_TTL):
                return existing

            self.pending_request = {
                "id": secrets.token_hex(8),
                "device": device_name or "A watch",
                "peer": peer,
                "created": now,
                "status": "pending",
                "token": "",
            }
            return self.pending_request

    def get_pair_request(self, request_id: str = "") -> Optional[Dict[str, Any]]:
        with self.lock:
            req = self.pending_request
            if not req or (request_id and req["id"] != request_id):
                return None
            if req["status"] == "pending" and time.time() - req["created"] > self.PAIR_REQUEST_TTL:
                req["status"] = "expired"
            return req

    def resolve_pair_request(self, request_id: str, approve: bool) -> Optional[Dict[str, Any]]:
        with self.lock:
            req = self.pending_request
            if not req or req["id"] != request_id or req["status"] != "pending":
                return None
            if time.time() - req["created"] > self.PAIR_REQUEST_TTL:
                req["status"] = "expired"
                return req
            if approve:
                self._refresh_config_if_stale()
                req["token"] = self.issue_token()
                req["status"] = "approved"
            else:
                req["status"] = "denied"
            return req

    # ---- Watch status ---------------------------------------------------

    def update_watch_status(self, data: Dict[str, Any]):
        with self.lock:
            data["receivedAt"] = utc_now_iso()
            write_json_atomically(STATUS_FILE, data)

    def get_watch_status(self) -> Dict[str, Any]:
        """Describe the watch honestly.

        "connected" used to be a flag written once and never cleared, so the widget
        would claim a watch was there long after it had gone, and claim it was
        waiting even when one was paired. These three states are derived from what
        is actually true: whether a device is paired at all, and how long ago it
        last spoke.
        """
        with self.lock:
            self._refresh_config_if_stale()

            if not self.config.get("paired_tokens"):
                return {
                    "paired": False,
                    "protocolState": "unknown",
                    "bridgeProtocolVersion": PROTOCOL_VERSION,
                    "connected": False,
                    "online": False,
                    "state": "unpaired",
                    "device": "",
                    "status": "Waiting for watch",
                }

            data = read_json(STATUS_FILE, {})
            if not isinstance(data, dict):
                data = {}

            age = None
            last = data.get("lastSync")
            if last:
                try:
                    age = (dt.datetime.now(dt.timezone.utc)
                           - dt.datetime.fromisoformat(last)).total_seconds()
                except Exception:
                    age = None

            online = age is not None and age < self.ONLINE_WINDOW_SECONDS
            data.update({
                "paired": True,
                **_protocol_verdict(data),
                "online": online,
                "connected": online,
                "state": "online" if online else "linked",
                "secondsSinceSync": int(age) if age is not None else -1,
                "device": data.get("device") or "Galaxy Watch",
            })
            return data

    # ---- Gauge assignment -----------------------------------------------

    def set_slots(self, slots: Dict[str, str]):
        with self.lock:
            self.slots.update(slots)
            self.save_slots()

    def get_slots(self) -> Dict[str, str]:
        with self.lock:
            return dict(self.slots)


def new_pin() -> str:
    """A 4-digit pairing code, from the CSPRNG rather than Mersenne Twister."""
    return f"{secrets.randbelow(9000) + 1000}"


state_mgr = StateManager()


def collect_dynamic_llm_data() -> Dict[str, Any]:
    """Dynamically parses all AI providers and limits on the system."""
    providers: List[Dict[str, Any]] = []
    all_models: List[Dict[str, Any]] = []

    total_today_tokens = 0
    total_today_sessions = 0

    for fpath in sorted(glob.glob(str(AGENTS_DIR / "*.json"))):
        data = read_json(Path(fpath), None)
        if not isinstance(data, dict):
            continue

        prov_id = data.get("id") or Path(fpath).stem
        prov_name = data.get("name") or prov_id.capitalize()
        provider = provider_of(prov_id, prov_name)

        today_tokens = data.get("todayTotalTokens", 0) or 0
        today_sessions = data.get("todaySessions", 0) or 0
        total_today_tokens += today_tokens
        total_today_sessions += today_sessions

        raw_limits = data.get("limits", [])
        for idx, lim in enumerate(raw_limits):
            title = lim.get("title") or lim.get("label") or f"Limit {idx + 1}"
            short_label, detail_label = make_labels(prov_id, title)
            resets_at = lim.get("resetsAt", "")
            resets_long, resets_short = format_relative_time(resets_at)
            percent = float(lim.get("percent", 0.0))

            all_models.append({
                "id": f"{prov_id}:{slugify(title)}",
                "providerId": prov_id,
                "providerName": prov_name,
                "title": title,
                "shortLabel": short_label,
                "detailLabel": detail_label,
                "percent": percent,
                "percentInt": int(round(percent * 100)),
                "resetsAt": resets_at,
                "resetsFormatted": resets_long,
                "resetsShort": resets_short,
                "used": lim.get("used"),
                "allowance": lim.get("allowance"),
                "color": lim.get("color") or provider.color,
                "kind": "limit",
            })

        providers.append({
            "id": prov_id,
            "name": prov_name,
            "shortName": provider.short,
            "color": provider.color,
            "ready": data.get("ready", True),
            "todayTokens": today_tokens,
            "todayTokensFormatted": format_tokens(today_tokens),
            "todayPrompts": data.get("todayPrompts", 0) or 0,
            "todaySessions": today_sessions,
            "limitsCount": len(raw_limits),
        })

    all_models.append(_aggregate_gauge(
        gauge_id="global:today-tokens",
        title="Today's Tokens",
        short_label="Tokens",
        detail_label="Tokens Today",
        value=total_today_tokens,
        value_text=format_tokens(total_today_tokens),
        full_scale=TOKENS_FULL_SCALE,
        color=TOKENS_COLOR,
        kind="tokens",
    ))
    all_models.append(_aggregate_gauge(
        gauge_id="global:today-sessions",
        title="Today's Sessions",
        short_label="Sessions",
        detail_label="Sessions Today",
        value=total_today_sessions,
        value_text=str(total_today_sessions),
        full_scale=SESSIONS_FULL_SCALE,
        color=SESSIONS_COLOR,
        kind="sessions",
    ))

    return {
        "timestamp": utc_now_iso(),
        "todayTotalTokens": total_today_tokens,
        "todayTokensFormatted": format_tokens(total_today_tokens),
        "todaySessions": total_today_sessions,
        "providers": providers,
        "models": all_models,
    }


def _aggregate_gauge(gauge_id: str, title: str, short_label: str, detail_label: str,
                     value: int, value_text: str, full_scale: int, color: str,
                     kind: str) -> Dict[str, Any]:
    """A running total across every provider, drawn against a nominal ceiling."""
    percent = min(1.0, value / float(full_scale)) if value else 0.0
    return {
        "id": gauge_id,
        "providerId": "global",
        "providerName": "Total AI",
        "title": title,
        "shortLabel": short_label,
        "detailLabel": detail_label,
        "percent": percent,
        "percentInt": int(round(percent * 100)),
        "value": value,
        "valueFormatted": value_text,
        "resetsFormatted": "today",
        "resetsShort": "today",
        "color": color,
        "kind": kind,
    }


def get_watch_summary_data() -> Dict[str, Any]:
    """Generates the lightweight 4-slot payload for the watchface and complications."""
    full_data = collect_dynamic_llm_data()
    models_by_id = {m["id"]: m for m in full_data["models"]}
    slots_cfg = state_mgr.get_slots()

    def resolve_slot(slot_key: str) -> Dict[str, Any]:
        default_id = DEFAULT_SLOTS[slot_key]
        item = models_by_id.get(slots_cfg.get(slot_key, default_id))
        if not item:
            # Fall back to the default gauge, then to anything at all.
            item = models_by_id.get(default_id) or (
                full_data["models"][0] if full_data["models"] else {})
        return {
            "slot": slot_key,
            "id": item.get("id", ""),
            "title": item.get("shortLabel") or item.get("title", ""),
            "detailLabel": item.get("detailLabel") or item.get("shortLabel") or item.get("title", ""),
            "provider": item.get("providerName", ""),
            "percent": item.get("percent", 0.0),
            "percentInt": item.get("percentInt", 0),
            "valueText": item.get("valueFormatted") or f"{item.get('percentInt', 0)}%",
            "resetsShort": item.get("resetsShort", ""),
            # The watch needs the absolute reset time to tell a genuine quota
            # rollover from the user simply reassigning this gauge, and "kind"
            # to avoid alerting on counters like today's tokens, which sit at
            # 100% by design and never reset to a new window.
            "resetsAt": item.get("resetsAt") or "",
            "kind": item.get("kind", "limit"),
            "color": item.get("color", TOKENS_COLOR),
        }

    return {
        "protocolVersion": PROTOCOL_VERSION,
        "timestamp": full_data["timestamp"],
        "todayTokens": full_data["todayTokensFormatted"],
        "todaySessions": full_data["todaySessions"],
        "slots": {key: resolve_slot(key) for key in SLOT_KEYS},
        "allModelsCount": len(full_data["models"]),
    }


def notify_pair_request(request_id: str, device_name: str):
    """Put the connect request in front of the user, wherever they are looking.

    Omarchy's notifier supports a click action, so approving is one click from
    the toast. It also has Do Not Disturb: only `omarchy-action` (the default
    app name) and critical `notify-send` bypass it. A custom app name is how
    this prompt used to vanish while DND was on.

    The process is waited on. Spawning `omarchy` and immediately returning
    treated a failing child as success, so notify-send never ran as fallback.
    """
    headline = "A watch wants to connect"
    body = f"{device_name} — click to approve"
    approve_cmd = [sys.executable, os.path.abspath(__file__), "--approve", request_id]
    omarchy_bin = shutil.which("omarchy") or "/usr/share/omarchy/bin/omarchy"

    candidates = [
        [omarchy_bin, "notification", "send",
         "-u", "critical",
         "-t", str(StateManager.PAIR_REQUEST_TTL * 1000),
         headline, body,
         "--exec"] + approve_cmd,
        ["notify-send", "-u", "critical",
         headline, f"{device_name} — approve it in the AI Watch widget"],
    ]

    for cmd in candidates:
        try:
            completed = subprocess.run(
                cmd, capture_output=True, text=True, timeout=5, check=False,
            )
        except Exception as exc:
            print(f"Pair notification error ({cmd[0]}): {exc}")
            continue
        if completed.returncode == 0:
            print(f"Pair notification sent via {cmd[0]}: {device_name} id={request_id}")
            return
        err = (completed.stderr or completed.stdout or "").strip()
        print(f"Pair notification failed ({cmd[0]} exit {completed.returncode}): {err}")


class AttemptLimiter:
    """Rate-limits guessing, per source address.

    The pairing code is four digits: ten thousand possibilities, which an
    unthrottled attacker on the same network exhausts in seconds. The code is
    only a fallback path -- the normal flow needs a click on the laptop -- so a
    limit this tight costs a real user nothing and costs an attacker everything.
    """

    MAX_FAILURES = 5
    LOCKOUT_SECONDS = 300
    WINDOW_SECONDS = 900

    def __init__(self):
        self._lock = threading.Lock()
        self._failures: Dict[str, List[float]] = {}

    def locked_out(self, who: str) -> int:
        """Seconds still to wait, or 0."""
        with self._lock:
            recent = self._recent(who)
            if len(recent) < self.MAX_FAILURES:
                return 0
            left = int(recent[-1] + self.LOCKOUT_SECONDS - time.time())
            return max(left, 0)

    def record_failure(self, who: str):
        with self._lock:
            self._recent(who).append(time.time())

    def reset(self, who: str):
        with self._lock:
            self._failures.pop(who, None)

    def _recent(self, who: str) -> List[float]:
        """Caller must hold the lock. Prunes as it goes, so this cannot grow."""
        cutoff = time.time() - self.WINDOW_SECONDS
        kept = [t for t in self._failures.get(who, []) if t > cutoff]
        self._failures[who] = kept
        # An unbounded dict keyed by attacker-chosen source is itself a leak.
        if len(self._failures) > 512:
            for stale in [k for k, v in self._failures.items() if not v]:
                del self._failures[stale]
        return kept


pin_attempts = AttemptLimiter()

# A connect request raises a desktop notification with a one-click approve
# action. create_pair_request() collapses retries from the same device name, but
# a caller that varies the name gets a fresh notification every time -- a way to
# bury the user in prompts until one is clicked by accident. Three tries per
# source in fifteen minutes is far more than a real watch needs.
request_attempts = AttemptLimiter()
request_attempts.MAX_FAILURES = 3


def clean_device_name(raw: Any) -> str:
    """A watch names itself, so treat that name as hostile text.

    It reaches a desktop notification and the widget, and arrives from any
    device that can reach the pairing endpoint. Control characters are stripped
    so it cannot forge extra lines in a notification, and the length is capped
    so it cannot push the real text off screen.
    """
    text = "".join(ch for ch in str(raw or "") if ch.isprintable())
    return " ".join(text.split())[:48]


def bearer_token(headers) -> str:
    """The token from an `Authorization: Bearer ...` header, or an empty string."""
    header = headers.get("Authorization", "")
    return header[7:].strip() if header.lower().startswith("bearer ") else ""


class ApiHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler for Wear OS communication."""

    # Reachable without a token: identifying the service and asking to pair.
    # /ping must stay open so a watch can find this laptop by sweeping the subnet.
    OPEN_PATHS = {
        "/api/v1/ping",
        "/api/v1/pair",
        "/api/v1/pair/state",
        "/api/v1/pair/poll",
        "/api/v1/pair/unlink",
    }

    # Driven from the laptop, so they must come from this machine.
    LOCAL_ONLY_PATHS = {
        # Opening the pairing window is the one deliberate act that authorises a
        # new device. Reachable from the network it undid the entire model: any
        # host on the LAN could open the window and immediately pair itself, with
        # no PIN and no click. Nothing calls it over HTTP -- the widget drives it
        # through `--pair-mode` -- so it is laptop-only, like the rest of these.
        "/api/v1/pair/open",
        "/api/v1/pair/forget",
        "/api/v1/pair/approve",
        "/api/v1/pair/deny",
    }

    def _send_json(self, status_code: int, data: Any):
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        # Deliberately no Access-Control-Allow-Origin. The only clients are a
        # native watch app and a local CLI, neither of which is bound by CORS.
        # Sending "*" let any page the user visited script this API from their
        # browser, on their own network, with their own machine as the origin.
        self.end_headers()
        self.wfile.write(payload)

    def _is_local_request(self) -> bool:
        return self.client_address[0] in ("127.0.0.1", "::1")

    def _authorized(self, path: str) -> bool:
        """Enforce the bearer token the watch has always been sending.

        The token was issued at pairing and sent on every request, but never
        checked, which left every endpoint on this machine open to anyone on the
        network. Local callers stay allowed so the Omarchy widget keeps working,
        and an install with no paired device yet is allowed so a fresh setup is
        not locked out before it can pair.
        """
        if path in self.OPEN_PATHS or self._is_local_request():
            return True
        if not state_mgr.has_any_paired_device():
            return True
        return state_mgr.is_token_valid(bearer_token(self.headers))

    def _reject_unauthorized(self):
        self._send_json(401, {
            "status": "error",
            "error": "not_paired",
            "message": "This watch is not paired with this laptop.",
        })

    def do_OPTIONS(self):
        # Answered so a probe gets a clean response, but with no CORS grant:
        # a browser is not a supported client here.
        self.send_response(204)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self._dispatch(self.GET_ROUTES, body=None)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            body = {}
        if not isinstance(body, dict):
            body = {}
        self._dispatch(self.POST_ROUTES, body)

    def _dispatch(self, routes: Dict[str, str], body: Optional[Dict[str, Any]]):
        """Route one request. Both verbs share the auth gate and the 404."""
        path = self.path.split("?")[0]

        if not self._authorized(path):
            self._reject_unauthorized()
            return
        if path in self.LOCAL_ONLY_PATHS and not self._is_local_request():
            self._reject_unauthorized()
            return

        handler_name = routes.get(path)
        if not handler_name:
            self._send_json(404, {"error": "Not found"})
            return

        handler: Callable = getattr(self, handler_name)
        handler(body) if body is not None else handler()

    # ---- GET handlers ---------------------------------------------------

    def get_ping(self):
        self._send_json(200, {
            "status": "ok",
            "service": SERVICE_NAME,
            "protocolVersion": PROTOCOL_VERSION,
            "hostname": socket.gethostname(),
            "ip": get_local_ip(),
            "time": utc_now_iso(),
        })

    def get_pair_poll(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        req = state_mgr.get_pair_request((query.get("id") or [""])[0])
        if not req:
            self._send_json(404, {"status": "unknown"})
            return

        payload = {"status": req["status"]}
        if req["status"] == "approved":
            payload.update({
                "token": req["token"],
                "hostname": socket.gethostname(),
                "serverIp": get_local_ip(),
            })
        self._send_json(200, payload)

    def get_pair_state(self):
        remaining = state_mgr.pairing_window_remaining()
        body = {
            "pairingOpen": remaining > 0,
            "secondsRemaining": remaining,
            "hostname": socket.gethostname(),
        }
        req = state_mgr.get_pair_request()
        if req and req["status"] == "pending":
            body["pendingRequest"] = {
                "id": req["id"],
                "device": req["device"],
                "secondsLeft": int(
                    StateManager.PAIR_REQUEST_TTL - (time.time() - req["created"])
                ),
            }
        self._send_json(200, body)

    def get_models(self):
        data = collect_dynamic_llm_data()
        self._send_json(200, {
            "models": data["models"],
            "providers": data["providers"],
            "slots": state_mgr.get_slots(),
        })

    def get_watch_summary(self):
        self._send_json(200, get_watch_summary_data())

    def get_status(self):
        self._send_json(200, full_status())

    # ---- POST handlers --------------------------------------------------

    def post_pair_open(self, body):
        until = state_mgr.open_pairing_window()
        self._send_json(200, {
            "status": "open",
            "secondsRemaining": int(until - time.time()),
        })

    def post_pair(self, body):
        # Preferred path: the user clicked "Add watch" on the laptop, so the
        # watch pairs with nothing to type. A code still pairs outright, for
        # setups driven from a terminal with no widget on screen.
        pin = body.get("pin", "")
        peer = self.client_address[0]

        if pin:
            waiting = pin_attempts.locked_out(peer)
            if waiting:
                self._send_json(429, {
                    "status": "error",
                    "error": "too_many_attempts",
                    "message": f"Too many wrong codes. Try again in {waiting}s.",
                    "retryAfter": waiting,
                })
                return

        token = state_mgr.validate_pin(pin) if pin else None
        if pin:
            if token:
                pin_attempts.reset(peer)
            else:
                pin_attempts.record_failure(peer)
        method = "pin" if token else ""

        # Otherwise the laptop asked for this watch already ("Add another watch").
        if token is None:
            token = state_mgr.pair_via_window()
            if token:
                method = "window"

        if token:
            device_name = clean_device_name(body.get("deviceName")) or "Wear OS Watch"
            state_mgr.update_watch_status({
                "connected": True,
                "paired": True,
                "source": "pair",
                "device": device_name,
                "battery": body.get("battery", 100),
                "lastSync": utc_now_iso(),
                # Sent by watches that know about versioning, so a mismatch is
                # visible from the moment of pairing rather than a sync later.
                "protocolVersion": int(body.get("protocolVersion", 0) or 0),
            })
            self._send_json(200, {
                "status": "paired",
                "token": token,
                "hostname": socket.gethostname(),
                "serverIp": get_local_ip(),
                "method": method,
                "message": "Pairing successful",
            })
        elif pin:
            self._send_json(401, {
                "status": "error",
                "error": "invalid_pin",
                "message": "That code did not match.",
            })
        else:
            # Ask the human instead of refusing. The watch waits on the poll
            # endpoint while the laptop shows a notification and a prompt.
            waiting = request_attempts.locked_out(peer)
            if waiting:
                self._send_json(429, {
                    "status": "error",
                    "error": "too_many_requests",
                    "message": f"Too many connect requests. Try again in {waiting}s.",
                    "retryAfter": waiting,
                })
                return

            req = state_mgr.create_pair_request(
                clean_device_name(body.get("deviceName")) or "A watch", peer)
            if req["status"] == "pending":
                request_attempts.record_failure(peer)
                print(f"Pair request from {peer}: {req['device']} id={req['id']}")
                notify_pair_request(req["id"], req["device"])
            self._send_json(202, {
                "status": "pending",
                "requestId": req["id"],
                "message": "Approve this watch on your laptop.",
            })

    def post_pair_forget(self, body):
        removed = state_mgr.forget_all_devices()
        self._send_json(200, {"status": "forgotten", "removed": removed})

    def post_pair_unlink(self, body):
        # Driven from the watch: it unlinks itself using its own token, so a
        # device can always walk away without needing the laptop.
        ok = state_mgr.forget_token(bearer_token(self.headers))
        self._send_json(200 if ok else 404, {
            "status": "unlinked" if ok else "not_paired",
        })

    def post_pair_approve(self, body):
        self._resolve_pair(body, approve=True)

    def post_pair_deny(self, body):
        self._resolve_pair(body, approve=False)

    def _resolve_pair(self, body, approve: bool):
        req = state_mgr.resolve_pair_request(body.get("id", ""), approve)
        if not req:
            self._send_json(404, {"status": "error", "error": "no_such_request"})
            return
        if req["status"] == "approved":
            # The device that asked, not the widget that answered.
            request_attempts.reset(req.get("peer", ""))
            state_mgr.update_watch_status({
                "connected": True,
                "paired": True,
                "source": "pair",
                "device": req["device"],
                "battery": 100,
                "lastSync": utc_now_iso(),
            })
        self._send_json(200, {"status": req["status"], "device": req["device"]})

    def post_heartbeat(self, body):
        status = {
            "connected": True,
            "paired": True,
            "source": "heartbeat",
            "device": clean_device_name(body.get("device")) or "Galaxy Watch",
            "battery": body.get("battery", 100),
            "isCharging": body.get("isCharging", False),
            "lastSync": utc_now_iso(),
            # Absent from any watch built before versioning existed, which is
            # exactly the case get_watch_status() reports as "legacy".
            "protocolVersion": int(body.get("protocolVersion", 0) or 0),
            "appVersion": clean_device_name(body.get("appVersion"))[:16],
        }
        for key in SLOT_KEYS:
            status[f"slot{key.capitalize()}"] = body.get(f"slot{key.capitalize()}", "")
        state_mgr.update_watch_status(status)
        self._send_json(200, {"status": "acknowledged"})

    def post_slots(self, body):
        raw = body.get("slots", {})
        # Only the four gauges that exist, with values shaped like a model id.
        # Anything else was previously merged into slots.json verbatim, letting
        # a caller grow the file with keys the widget never reads.
        new_slots = {
            key: str(value)[:128]
            for key, value in (raw.items() if isinstance(raw, dict) else [])
            if key in SLOT_KEYS and isinstance(value, str)
        }
        if new_slots:
            state_mgr.set_slots(new_slots)
        self._send_json(200, {"status": "updated", "slots": state_mgr.get_slots()})

    def post_pin_regenerate(self, body):
        self._send_json(200, {"pin": state_mgr.generate_new_pin()})

    GET_ROUTES = {
        "/api/v1/ping": "get_ping",
        "/api/v1/pair/poll": "get_pair_poll",
        "/api/v1/pair/state": "get_pair_state",
        "/api/v1/models": "get_models",
        "/api/v1/watch/summary": "get_watch_summary",
        "/api/v1/status": "get_status",
    }

    POST_ROUTES = {
        "/api/v1/pair": "post_pair",
        "/api/v1/pair/open": "post_pair_open",
        "/api/v1/pair/forget": "post_pair_forget",
        "/api/v1/pair/unlink": "post_pair_unlink",
        "/api/v1/pair/approve": "post_pair_approve",
        "/api/v1/pair/deny": "post_pair_deny",
        "/api/v1/watch/heartbeat": "post_heartbeat",
        "/api/v1/slots": "post_slots",
        "/api/v1/pin/regenerate": "post_pin_regenerate",
    }

    def log_message(self, fmt, *args):
        # Quiet standard HTTP logs
        return


def full_status() -> Dict[str, Any]:
    """Everything the Omarchy widget draws, in one payload."""
    data = collect_dynamic_llm_data()
    data["protocolVersion"] = PROTOCOL_VERSION
    data["watchStatus"] = state_mgr.get_watch_status()
    data["pin"] = state_mgr.get_pin()
    # The widget renders the four gauge assignments from this. Without it the
    # widget silently falls back to its hardcoded defaults and shows a
    # configuration the user never chose.
    data["slots"] = state_mgr.get_slots()
    return data


def start_mdns_broadcast():
    """Advertises _omarchy-ai._tcp over Avahi/mDNS so Wear OS auto-discovers it."""
    try:
        return subprocess.Popen(
            [
                "/usr/bin/avahi-publish", "-s",
                f"Omarchy AI ({socket.gethostname()})",
                MDNS_SERVICE_TYPE,
                str(PORT),
                f"model={socket.gethostname()}",
                "version=1.0",
            ],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception as e:
        print(f"Warning: mDNS advertising via avahi-publish failed: {e}")
        return None


def run_server(port: int = PORT):
    # Without SO_REUSEADDR a restart races the previous process releasing the
    # port, and systemd's retry makes the daemon look like it is flapping.
    socketserver.TCPServer.allow_reuse_address = True
    server = socketserver.TCPServer(("0.0.0.0", port), ApiHandler)

    print(f"🚀 Omarchy AI Watch Bridge running on http://{get_local_ip()}:{port}")
    print(f"🔑 Active Pairing PIN: {state_mgr.get_pin()}")
    print(f"📡 mDNS Service: {MDNS_SERVICE_TYPE}")

    mdns_proc = start_mdns_broadcast()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if mdns_proc:
            mdns_proc.terminate()


def ask_daemon(port: int, path: str, payload: Optional[Dict[str, Any]] = None,
               timeout: float = 5) -> Dict[str, Any]:
    """Speak to the running daemon over HTTP rather than editing its files.

    Every command below mutates state the daemon holds in memory. A second
    process writing config.json or slots.json behind its back is how the PIN used
    to drift out of sync with what the widget was showing.
    """
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception as exc:
        return {"status": "error", "error": str(exc)}


def main():
    parser = argparse.ArgumentParser(description="Omarchy AI Watch Bridge")
    parser.add_argument("--port", type=int, default=PORT, help="Port to bind to")
    parser.add_argument("--pin", action="store_true", help="Print active PIN")
    parser.add_argument("--new-pin", action="store_true", help="Generate and print new PIN")
    parser.add_argument("--status", action="store_true", help="Print current status JSON")
    parser.add_argument("--setup-status", action="store_true",
                        help="Print laptop installer checks as JSON")
    parser.add_argument("--models", action="store_true", help="Print available dynamic models")
    parser.add_argument("--set-slot", nargs=2, metavar=("SLOT", "MODEL_ID"),
                        help="Assign a model to one of the four gauges")
    parser.add_argument("--forget", action="store_true",
                        help="Unlink every paired watch")
    parser.add_argument("--approve", metavar="ID",
                        help="Approve a pending watch connect request")
    parser.add_argument("--deny", metavar="ID",
                        help="Deny a pending watch connect request")
    parser.add_argument("--pair-mode", action="store_true",
                        help="Open a short window so the next watch can pair with no code")
    args = parser.parse_args()

    if args.pin:
        print(state_mgr.get_pin())
        return

    if args.new_pin:
        print(state_mgr.generate_new_pin())
        return

    if args.setup_status:
        print(json.dumps(collect_setup_status(args.port)))
        return

    if args.status:
        status = full_status()
        # Read the pending request from the daemon, which owns it.
        live = ask_daemon(args.port, "/api/v1/pair/state", timeout=1)
        status["pendingRequest"] = live.get("pendingRequest")
        status["pairingOpen"] = live.get("pairingOpen", False)
        status["pairingSecondsRemaining"] = live.get("secondsRemaining", 0)
        print(json.dumps(status, indent=2))
        return

    if args.models:
        print(json.dumps(collect_dynamic_llm_data()["models"], indent=2))
        return

    if args.set_slot:
        slot, model_id = args.set_slot
        print(json.dumps(ask_daemon(args.port, "/api/v1/slots", {"slots": {slot: model_id}})))
        return

    if args.forget:
        print(json.dumps(ask_daemon(args.port, "/api/v1/pair/forget", {})))
        return

    if args.approve or args.deny:
        endpoint = "approve" if args.approve else "deny"
        request_id = args.approve or args.deny
        print(json.dumps(
            ask_daemon(args.port, f"/api/v1/pair/{endpoint}", {"id": request_id})))
        return

    if args.pair_mode:
        until = state_mgr.open_pairing_window()
        print(json.dumps({
            "pairingOpen": True,
            "secondsRemaining": int(until - time.time()),
        }))
        return

    run_server(args.port)


if __name__ == "__main__":
    main()
