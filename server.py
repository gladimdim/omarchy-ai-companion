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
import random
import re
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

PORT = 8765
SERVICE_NAME = "Omarchy AI Watch Bridge"
STATE_DIR = Path(os.path.expanduser("~/.local/state/omarchy/wearos"))
AGENTS_DIR = Path(os.path.expanduser("~/.local/state/omarchy/agents/usage"))
CONFIG_FILE = STATE_DIR / "config.json"
STATUS_FILE = STATE_DIR / "watch_status.json"
SLOTS_FILE = STATE_DIR / "slots.json"

PROVIDER_COLORS = {
    "claude": "#D97757",
    "grok": "#38BDF8",
    "antigravity": "#A855F7",
    "codex": "#10B981",
    "fireworks": "#F59E0B",
    "opencode": "#EC4899",
    "gemini": "#4285F4",
    "ollama": "#FFFFFF",
    "deepseek": "#4E8BF5",
}

PROVIDER_SHORT_NAMES = {
    "claude": "Claude",
    "grok": "Grok",
    "antigravity": "AGY",
    "codex": "Codex",
    "fireworks": "Firewks",
    "opencode": "OpenCd",
    "gemini": "Gemini",
    "ollama": "Ollama",
    "deepseek": "DeepSeek",
}


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


def format_relative_time(resets_at_str: Optional[str]) -> Tuple[str, str]:
    if not resets_at_str:
        return ("", "")
    try:
        clean_str = resets_at_str.replace("Z", "+00:00")
        target_dt = dt.datetime.fromisoformat(clean_str)
        now_dt = dt.datetime.now(dt.timezone.utc)
        diff = target_dt - now_dt
        total_seconds = int(diff.total_seconds())

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
    if count >= 1_000_000_000:
        return f"{count / 1_000_000_000:.1f}B"
    if count >= 1_000_000:
        return f"{count / 1_000_000:.1f}M"
    if count >= 1_000:
        return f"{count / 1_000:.1f}k"
    return str(count)


def make_short_label(provider_id: str, limit_title: str) -> str:
    p_short = PROVIDER_SHORT_NAMES.get(provider_id, provider_id.capitalize())
    t_lower = limit_title.lower()

    if "session" in t_lower or "5-hour" in t_lower or "5h" in t_lower:
        return f"{p_short} 5h"
    if "weekly" in t_lower or "7-day" in t_lower:
        return f"{p_short} Wk"
    if "thinking" in t_lower:
        return "AGY Think"
    if "flash" in t_lower:
        return "AGY Flash"
    if "build" in t_lower:
        return f"{p_short} Bld"
    if "chat" in t_lower:
        return f"{p_short} Chat"

    words = limit_title.split()
    if words:
        return f"{p_short} {words[0][:4]}"
    return p_short


PROVIDER_FULL_NAMES = {
    "claude": "Claude",
    "grok": "Grok",
    "antigravity": "Antigravity",
    "codex": "Codex",
    "fireworks": "Fireworks",
    "opencode": "OpenCode",
    "gemini": "Gemini",
    "ollama": "Ollama",
    "deepseek": "DeepSeek",
    "global": "",
}

# Roughly how many characters fit on one 80-degree complication arc alongside the
# value, at the watch face's font size. Longer labels get trimmed to the provider.
DETAIL_LABEL_MAX = 17


def make_detail_label(provider_id: str, limit_title: str) -> str:
    """Provider plus the limit it tracks, e.g. 'Claude 5h', 'Antigravity 1 Wk'.

    make_short_label() abbreviates hard ('AGY Think') to fit a bare gauge. This is
    the roomier version the watch face shows next to the value, so the wearer can
    tell which model and which quota window an arc refers to without opening the app.
    """
    provider = PROVIDER_FULL_NAMES.get(provider_id, provider_id.capitalize())
    t = limit_title.lower()

    if "flash" in t:
        window = "Flash"
    elif "thinking" in t:
        window = "Think"
    elif "5-hour" in t or "5h" in t or "session" in t:
        window = "5h"
    elif "weekly" in t or "7-day" in t:
        window = "1 Wk"
    elif "monthly" in t:
        window = "1 Mo"
    elif "daily" in t or "today" in t:
        window = "Today"
    elif "build" in t:
        window = "Build"
    elif "chat" in t:
        window = "Chat"
    else:
        words = limit_title.split()
        window = words[0] if words else ""

    label = f"{provider} {window}".strip()
    if len(label) > DETAIL_LABEL_MAX:
        # Prefer keeping the window readable over truncating it mid-word.
        label = f"{PROVIDER_SHORT_NAMES.get(provider_id, provider)} {window}".strip()
    return label[:DETAIL_LABEL_MAX]


class StateManager:
    """Manages persistent configuration, active PIN, tokens, and watch status."""

    def __init__(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.load()

    def load(self):
        with self.lock:
            if CONFIG_FILE.exists():
                try:
                    with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                        self.config = json.load(f)
                except Exception:
                    self.config = {}
            else:
                self.config = {}

            if "pin" not in self.config or not self.config["pin"]:
                self.config["pin"] = f"{random.randint(1000, 9999)}"
            if "paired_tokens" not in self.config:
                self.config["paired_tokens"] = []
            if "token" not in self.config:
                self.config["token"] = secrets.token_hex(16)

            self.save_config()
            self._config_mtime = self._current_config_mtime()

            # Load default slot mapping (Top, Right, Bottom, Left)
            if SLOTS_FILE.exists():
                try:
                    with open(SLOTS_FILE, "r", encoding="utf-8") as f:
                        self.slots = json.load(f)
                except Exception:
                    self.slots = self._default_slots()
            else:
                self.slots = self._default_slots()
                self.save_slots()

    def _default_slots(self) -> Dict[str, str]:
        return {
            "top": "claude:session-5-hour",
            "right": "grok:weekly",
            "bottom": "antigravity:thinking-models-quota",
            "left": "global:today-tokens",
        }

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
        if mtime and mtime != getattr(self, "_config_mtime", 0.0):
            try:
                with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                    disk = json.load(f)
            except Exception:
                return
            # Keep tokens issued by this process; take the PIN from disk.
            merged_tokens = list(dict.fromkeys(
                list(disk.get("paired_tokens", [])) + list(self.config.get("paired_tokens", []))
            ))
            self.config = disk
            self.config["paired_tokens"] = merged_tokens
            self._config_mtime = mtime

    def save_config(self):
        tmp = CONFIG_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.config, f, indent=2)
        os.replace(tmp, CONFIG_FILE)
        self._config_mtime = self._current_config_mtime()

    def save_slots(self):
        tmp = SLOTS_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.slots, f, indent=2)
        os.replace(tmp, SLOTS_FILE)

    def get_pin(self) -> str:
        with self.lock:
            self._refresh_config_if_stale()
            return self.config.get("pin", "1234")

    def generate_new_pin(self) -> str:
        with self.lock:
            new_pin = f"{random.randint(1000, 9999)}"
            self.config["pin"] = new_pin
            self.save_config()
            return new_pin

    # How long "Add watch" on the laptop stays open for.
    PAIRING_WINDOW_SECONDS = 120

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

    def close_pairing_window(self):
        with self.lock:
            self.config["pairing_open_until"] = 0
            self.save_config()

    def issue_token(self) -> str:
        """Mint a pairing token. Caller must already hold self.lock."""
        new_token = secrets.token_hex(24)
        self.config.setdefault("paired_tokens", []).append(new_token)
        self.save_config()
        return new_token

    # A connect request waits this long for someone to approve it.
    PAIR_REQUEST_TTL = 180

    def create_pair_request(self, device_name: str) -> Dict[str, Any]:
        """Record a watch asking to connect, for a human to approve.

        The watch cannot show a trustworthy prompt for its own pairing, so the
        decision belongs on the laptop, where there is a real screen and a mouse.
        The request is held in memory by the daemon; the CLI reaches it over HTTP
        rather than through a file, so the two can never disagree about its state.
        """
        with self.lock:
            now = time.time()
            existing = getattr(self, "pending_request", None)
            # A watch that retries should land on the same request, not spawn a
            # queue of duplicates for the user to work through.
            if (existing and existing["status"] == "pending"
                    and existing["device"] == device_name
                    and now - existing["created"] < self.PAIR_REQUEST_TTL):
                return existing

            self.pending_request = {
                "id": secrets.token_hex(8),
                "device": device_name or "A watch",
                "created": now,
                "status": "pending",
                "token": "",
            }
            return self.pending_request

    def get_pair_request(self, request_id: str = "") -> Optional[Dict[str, Any]]:
        with self.lock:
            req = getattr(self, "pending_request", None)
            if not req:
                return None
            if request_id and req["id"] != request_id:
                return None
            if req["status"] == "pending" and time.time() - req["created"] > self.PAIR_REQUEST_TTL:
                req["status"] = "expired"
            return req

    def resolve_pair_request(self, request_id: str, approve: bool) -> Optional[Dict[str, Any]]:
        with self.lock:
            req = getattr(self, "pending_request", None)
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

    def pair_first_device(self) -> Optional[str]:
        """Pair the very first watch with no ceremony at all.

        Until one device is paired there is nothing to protect: every endpoint is
        already open to an unpaired caller because the token gate cannot lock out
        a fresh install. Demanding a click on the laptop before the first watch can
        connect therefore buys no security, and it is the step that makes setup feel
        broken -- the watch tells you to go and press something you then have to
        hunt for.

        Once a device is paired this stops applying and adding another needs the
        deliberate "Add watch" window.
        """
        with self.lock:
            self._refresh_config_if_stale()
            if self.config.get("paired_tokens"):
                return None
            return self.issue_token()

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

    def has_any_paired_device(self) -> bool:
        with self.lock:
            self._refresh_config_if_stale()
            return bool(self.config.get("paired_tokens"))

    def validate_pin(self, pin: str) -> Optional[str]:
        with self.lock:
            self._refresh_config_if_stale()
            if str(pin).strip() == str(self.config.get("pin", "")).strip():
                new_token = secrets.token_hex(24)
                if "paired_tokens" not in self.config:
                    self.config["paired_tokens"] = []
                self.config["paired_tokens"].append(new_token)
                self.save_config()
                return new_token
            return None

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
            try:
                STATUS_FILE.unlink()
            except OSError:
                pass
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
                try:
                    STATUS_FILE.unlink()
                except OSError:
                    pass
            return True

    def is_token_valid(self, token: str) -> bool:
        with self.lock:
            self._refresh_config_if_stale()
            if not token:
                return False
            paired = self.config.get("paired_tokens", [])
            master = self.config.get("token", "")
            return token in paired or token == master

    def update_watch_status(self, data: Dict[str, Any]):
        with self.lock:
            data["receivedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
            tmp = STATUS_FILE.with_suffix(".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            os.replace(tmp, STATUS_FILE)

    # A watch that has not checked in for this long is linked but not online.
    ONLINE_WINDOW_SECONDS = 15 * 60

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
            paired = bool(self.config.get("paired_tokens"))

            data: Dict[str, Any] = {}
            if STATUS_FILE.exists():
                try:
                    with open(STATUS_FILE, "r", encoding="utf-8") as f:
                        data = json.load(f)
                except Exception:
                    data = {}

            if not paired:
                return {
                    "paired": False,
                    "connected": False,
                    "online": False,
                    "state": "unpaired",
                    "device": "",
                    "status": "Waiting for watch",
                }

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
                "online": online,
                "connected": online,
                "state": "online" if online else "linked",
                "secondsSinceSync": int(age) if age is not None else -1,
                "device": data.get("device") or "Galaxy Watch",
            })
            return data

    def set_slots(self, slots: Dict[str, str]):
        with self.lock:
            self.slots.update(slots)
            self.save_slots()

    def get_slots(self) -> Dict[str, str]:
        with self.lock:
            return dict(self.slots)


state_mgr = StateManager()


def collect_dynamic_llm_data() -> Dict[str, Any]:
    """Dynamically parses all AI providers and limits on the system."""
    providers: List[Dict[str, Any]] = []
    all_models: List[Dict[str, Any]] = []

    total_today_tokens = 0
    total_today_prompts = 0
    total_today_sessions = 0

    if AGENTS_DIR.exists():
        json_files = sorted(glob.glob(str(AGENTS_DIR / "*.json")))
        for fpath in json_files:
            try:
                with open(fpath, "r", encoding="utf-8") as fp:
                    data = json.load(fp)
            except Exception:
                continue

            prov_id = data.get("id") or Path(fpath).stem
            prov_name = data.get("name") or prov_id.capitalize()
            prov_color = PROVIDER_COLORS.get(prov_id, "#38BDF8")
            ready = data.get("ready", True)

            today_tokens = data.get("todayTotalTokens", 0) or 0
            today_prompts = data.get("todayPrompts", 0) or 0
            today_sessions = data.get("todaySessions", 0) or 0

            total_today_tokens += today_tokens
            total_today_prompts += today_prompts
            total_today_sessions += today_sessions

            raw_limits = data.get("limits", [])
            for idx, lim in enumerate(raw_limits):
                title = lim.get("title") or lim.get("label") or f"Limit {idx + 1}"
                limit_slug = slugify(title)
                unique_id = f"{prov_id}:{limit_slug}"

                percent = float(lim.get("percent", 0.0))
                resets_at = lim.get("resetsAt", "")
                resets_long, resets_short = format_relative_time(resets_at)
                short_label = make_short_label(prov_id, title)
                detail_label = make_detail_label(prov_id, title)
                limit_color = lim.get("color") or prov_color

                model_item = {
                    "id": unique_id,
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
                    "color": limit_color,
                    "kind": "limit",
                }
                all_models.append(model_item)

            providers.append({
                "id": prov_id,
                "name": prov_name,
                "shortName": PROVIDER_SHORT_NAMES.get(prov_id, prov_name[:7]),
                "color": prov_color,
                "ready": ready,
                "todayTokens": today_tokens,
                "todayTokensFormatted": format_tokens(today_tokens),
                "todayPrompts": today_prompts,
                "todaySessions": today_sessions,
                "limitsCount": len(raw_limits),
            })

    # Add virtual items (Total Tokens, Daily Sessions)
    all_models.append({
        "id": "global:today-tokens",
        "providerId": "global",
        "providerName": "Total AI",
        "title": "Today's Tokens",
        "shortLabel": "Tokens",
        "detailLabel": "Tokens Today",
        "percent": min(1.0, total_today_tokens / 50_000_000.0) if total_today_tokens else 0.0,
        "percentInt": int(round(min(1.0, total_today_tokens / 50_000_000.0) * 100)),
        "value": total_today_tokens,
        "valueFormatted": format_tokens(total_today_tokens),
        "resetsFormatted": "today",
        "resetsShort": "today",
        "color": "#9ECE6A",
        "kind": "tokens",
    })

    all_models.append({
        "id": "global:today-sessions",
        "providerId": "global",
        "providerName": "Total AI",
        "title": "Today's Sessions",
        "shortLabel": "Sessions",
        "detailLabel": "Sessions Today",
        "percent": min(1.0, total_today_sessions / 10.0) if total_today_sessions else 0.0,
        "percentInt": int(round(min(1.0, total_today_sessions / 10.0) * 100)),
        "value": total_today_sessions,
        "valueFormatted": str(total_today_sessions),
        "resetsFormatted": "today",
        "resetsShort": "today",
        "color": "#A855F7",
        "kind": "sessions",
    })

    return {
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
        "todayTotalTokens": total_today_tokens,
        "todayTokensFormatted": format_tokens(total_today_tokens),
        "todaySessions": total_today_sessions,
        "providers": providers,
        "models": all_models,
    }


def get_watch_summary_data() -> Dict[str, Any]:
    """Generates the lightweight 4-slot payload for the watchface and complications."""
    full_data = collect_dynamic_llm_data()
    models_by_id = {m["id"]: m for m in full_data["models"]}
    slots_cfg = state_mgr.get_slots()

    def resolve_slot(slot_key: str, default_id: str) -> Dict[str, Any]:
        item_id = slots_cfg.get(slot_key, default_id)
        item = models_by_id.get(item_id)
        if not item:
            # Fallback to first available model or default
            item = models_by_id.get(default_id) or (full_data["models"][0] if full_data["models"] else {})
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
            "color": item.get("color", "#9ECE6A"),
        }

    slots_payload = {
        "top": resolve_slot("top", "claude:session-5-hour"),
        "right": resolve_slot("right", "grok:weekly"),
        "bottom": resolve_slot("bottom", "antigravity:thinking-models-quota"),
        "left": resolve_slot("left", "global:today-tokens"),
    }

    return {
        "timestamp": full_data["timestamp"],
        "todayTokens": full_data["todayTokensFormatted"],
        "todaySessions": full_data["todaySessions"],
        "slots": slots_payload,
        "allModelsCount": len(full_data["models"]),
    }


def notify_pair_request(request_id: str, device_name: str):
    """Put the connect request in front of the user, wherever they are looking.

    Omarchy's own notifier is preferred because it supports a click action, so
    approving is one click straight from the notification. notify-send is the
    fallback on a plain desktop.
    """
    headline = "A watch wants to connect"
    body = f"{device_name} - click to approve"
    approve_cmd = [sys.executable, os.path.abspath(__file__), "--approve", request_id]

    try:
        subprocess.Popen(
            ["omarchy", "notification", "send",
             "--app-name", "Omarchy AI Watch",
             "-u", "critical",
             "-t", str(StateManager.PAIR_REQUEST_TTL * 1000),
             headline, body,
             "--exec"] + approve_cmd,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return
    except Exception:
        pass

    try:
        subprocess.Popen(
            ["notify-send", "-a", "Omarchy AI Watch", "-u", "critical",
             headline, f"{device_name} - approve it in the AI Watch widget"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


class ApiHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Request Handler for Wear OS communication."""

    def _send_json(self, status_code: int, data: Any):
        payload = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()
        self.wfile.write(payload)

    # Reachable without a token: identifying the service and asking to pair.
    # /ping must stay open so a watch can find this laptop by sweeping the subnet.
    OPEN_PATHS = {
        "/api/v1/ping",
        "/api/v1/pair",
        "/api/v1/pair/open",
        "/api/v1/pair/state",
        "/api/v1/pair/poll",
        "/api/v1/pair/unlink",
    }

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
        header = self.headers.get("Authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        return state_mgr.is_token_valid(token)

    def _reject_unauthorized(self):
        self._send_json(401, {
            "status": "error",
            "error": "not_paired",
            "message": "This watch is not paired with this laptop.",
        })

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]

        if not self._authorized(path):
            self._reject_unauthorized()
            return

        if path == "/api/v1/pair/poll":
            from urllib.parse import urlparse, parse_qs
            req_id = (parse_qs(urlparse(self.path).query).get("id") or [""])[0]
            req = state_mgr.get_pair_request(req_id)
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
            return

        if path == "/api/v1/pair/state":
            remaining = state_mgr.pairing_window_remaining()
            req = state_mgr.get_pair_request()
            body = {
                "pairingOpen": remaining > 0,
                "secondsRemaining": remaining,
                "hostname": socket.gethostname(),
            }
            if req and req["status"] == "pending":
                body["pendingRequest"] = {
                    "id": req["id"],
                    "device": req["device"],
                    "secondsLeft": int(
                        StateManager.PAIR_REQUEST_TTL - (time.time() - req["created"])
                    ),
                }
            self._send_json(200, body)
            return

        if path == "/api/v1/ping":
            self._send_json(200, {
                "status": "ok",
                "service": SERVICE_NAME,
                "hostname": socket.gethostname(),
                "ip": get_local_ip(),
                "time": dt.datetime.now(dt.timezone.utc).isoformat()
            })
            return

        if path == "/api/v1/models":
            data = collect_dynamic_llm_data()
            self._send_json(200, {
                "models": data["models"],
                "providers": data["providers"],
                "slots": state_mgr.get_slots()
            })
            return

        if path == "/api/v1/watch/summary":
            summary = get_watch_summary_data()
            self._send_json(200, summary)
            return

        if path == "/api/v1/status":
            full = collect_dynamic_llm_data()
            full["watchStatus"] = state_mgr.get_watch_status()
            full["pin"] = state_mgr.get_pin()
            full["slots"] = state_mgr.get_slots()
            self._send_json(200, full)
            return

        self._send_json(404, {"error": "Not found"})

    def do_POST(self):
        path = self.path.split("?")[0]

        if not self._authorized(path):
            self._reject_unauthorized()
            return
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length) if content_length > 0 else b"{}"

        try:
            body = json.loads(post_data.decode("utf-8"))
        except Exception:
            body = {}

        if path == "/api/v1/pair/open":
            until = state_mgr.open_pairing_window()
            self._send_json(200, {
                "status": "open",
                "secondsRemaining": int(until - time.time()),
            })
            return

        if path == "/api/v1/pair":
            # Preferred path: the user clicked "Add watch" on the laptop, so the
            # watch pairs with nothing to type. A PIN is still accepted for setups
            # driven from a terminal with no widget on screen.
            # A code still pairs outright, for setups driven from a terminal.
            pin = body.get("pin", "")
            token = state_mgr.validate_pin(pin) if pin else None
            method = "pin" if token else ""

            # Otherwise the laptop asked for this watch already ("Add another
            # watch"), or the watch is asking now and a human decides.
            if token is None:
                token = state_mgr.pair_via_window()
                if token:
                    method = "window"
            if token:
                device_name = body.get("deviceName", "Wear OS Watch")
                state_mgr.update_watch_status({
                    "connected": True,
                    "paired": True,
                    "device": device_name,
                    "battery": body.get("battery", 100),
                    "lastSync": dt.datetime.now(dt.timezone.utc).isoformat(),
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
                req = state_mgr.create_pair_request(body.get("deviceName", "A watch"))
                if req["status"] == "pending":
                    notify_pair_request(req["id"], req["device"])
                self._send_json(202, {
                    "status": "pending",
                    "requestId": req["id"],
                    "message": "Approve this watch on your laptop.",
                })
            return

        if path == "/api/v1/pair/forget":
            # Driven from the laptop, so it must come from this machine.
            if not self._is_local_request():
                self._reject_unauthorized()
                return
            removed = state_mgr.forget_all_devices()
            self._send_json(200, {"status": "forgotten", "removed": removed})
            return

        if path == "/api/v1/pair/unlink":
            # Driven from the watch: it unlinks itself using its own token, so a
            # device can always walk away without needing the laptop.
            header = self.headers.get("Authorization", "")
            token = header[7:].strip() if header.lower().startswith("bearer ") else ""
            ok = state_mgr.forget_token(token)
            self._send_json(200 if ok else 404, {
                "status": "unlinked" if ok else "not_paired",
            })
            return

        if path == "/api/v1/pair/approve" or path == "/api/v1/pair/deny":
            if not self._is_local_request():
                self._reject_unauthorized()
                return
            approve = path.endswith("approve")
            req = state_mgr.resolve_pair_request(body.get("id", ""), approve)
            if req and req["status"] == "approved":
                state_mgr.update_watch_status({
                    "connected": True,
                    "paired": True,
                    "device": req["device"],
                    "battery": 100,
                    "lastSync": dt.datetime.now(dt.timezone.utc).isoformat(),
                })
            if not req:
                self._send_json(404, {"status": "error", "error": "no_such_request"})
            else:
                self._send_json(200, {"status": req["status"], "device": req["device"]})
            return

        if path == "/api/v1/watch/heartbeat":
            state_mgr.update_watch_status({
                "connected": True,
                "paired": True,
                "device": body.get("device", "Galaxy Watch"),
                "battery": body.get("battery", 100),
                "isCharging": body.get("isCharging", False),
                "lastSync": dt.datetime.now(dt.timezone.utc).isoformat(),
                "slotTop": body.get("slotTop", ""),
                "slotRight": body.get("slotRight", ""),
                "slotBottom": body.get("slotBottom", ""),
                "slotLeft": body.get("slotLeft", ""),
            })
            self._send_json(200, {"status": "acknowledged"})
            return

        if path == "/api/v1/slots":
            new_slots = body.get("slots", {})
            if new_slots:
                state_mgr.set_slots(new_slots)
            self._send_json(200, {"status": "updated", "slots": state_mgr.get_slots()})
            return

        if path == "/api/v1/pin/regenerate":
            new_pin = state_mgr.generate_new_pin()
            self._send_json(200, {"pin": new_pin})
            return

        self._send_json(404, {"error": "Not found"})

    def log_message(self, format, *args):
        # Quiet standard HTTP logs
        return


def start_mdns_broadcast():
    """Advertises _omarchy-ai._tcp over Avahi/mDNS so Wear OS auto-discovers it."""
    try:
        cmd = [
            "/usr/bin/avahi-publish",
            "-s",
            f"Omarchy AI ({socket.gethostname()})",
            "_omarchy-ai._tcp",
            str(PORT),
            f"model={socket.gethostname()}",
            "version=1.0",
        ]
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return proc
    except Exception as e:
        print(f"Warning: mDNS advertising via avahi-publish failed: {e}")
        return None


def run_server(port: int = PORT):
    # Without SO_REUSEADDR a restart races the previous process releasing the
    # port, and systemd's retry makes the daemon look like it is flapping.
    socketserver.TCPServer.allow_reuse_address = True
    server = socketserver.TCPServer(("0.0.0.0", port), ApiHandler)
    server.allow_reuse_address = True
    local_ip = get_local_ip()
    pin = state_mgr.get_pin()

    print(f"🚀 Omarchy AI Watch Bridge running on http://{local_ip}:{port}")
    print(f"🔑 Active Pairing PIN: {pin}")
    print(f"📡 mDNS Service: _omarchy-ai._tcp")

    mdns_proc = start_mdns_broadcast()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if mdns_proc:
            mdns_proc.terminate()


def main():
    parser = argparse.ArgumentParser(description="Omarchy AI Watch Bridge")
    parser.add_argument("--port", type=int, default=PORT, help="Port to bind to")
    parser.add_argument("--pin", action="store_true", help="Print active PIN")
    parser.add_argument("--new-pin", action="store_true", help="Generate and print new PIN")
    parser.add_argument("--status", action="store_true", help="Print current status JSON")
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

    if args.status:
        st = collect_dynamic_llm_data()
        st["watchStatus"] = state_mgr.get_watch_status()
        st["pin"] = state_mgr.get_pin()
        # The widget renders the four gauge assignments from this. Without it the
        # widget silently falls back to its hardcoded defaults and shows a
        # configuration the user never chose.
        st["slots"] = state_mgr.get_slots()
        # Read the pending request from the daemon, which owns it.
        try:
            import urllib.request
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{args.port}/api/v1/pair/state", timeout=3) as resp:
                live = json.loads(resp.read().decode())
            st["pendingRequest"] = live.get("pendingRequest")
            st["pairingOpen"] = live.get("pairingOpen", False)
            st["pairingSecondsRemaining"] = live.get("secondsRemaining", 0)
        except Exception:
            st["pendingRequest"] = None
        print(json.dumps(st, indent=2))
        return

    # These mutate live daemon state, so they go over HTTP to the running daemon
    # rather than touching files. A second process editing state behind the
    # daemon's back is how the PIN used to drift out of sync.
    if args.set_slot:
        # Goes through the daemon so its in-memory slots stay in step with disk;
        # a second process writing slots.json behind its back would diverge.
        import urllib.request
        slot, model_id = args.set_slot
        payload = json.dumps({"slots": {slot: model_id}}).encode()
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{args.port}/api/v1/slots",
                data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                print(resp.read().decode())
        except Exception as exc:
            print(json.dumps({"status": "error", "error": str(exc)}))
        return

    if args.forget:
        import urllib.request
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{args.port}/api/v1/pair/forget",
                data=b"{}", headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                print(resp.read().decode())
        except Exception as exc:
            print(json.dumps({"status": "error", "error": str(exc)}))
        return

    if args.approve or args.deny:
        import urllib.request
        request_id = args.approve or args.deny
        endpoint = "approve" if args.approve else "deny"
        payload = json.dumps({"id": request_id}).encode()
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{args.port}/api/v1/pair/{endpoint}",
                data=payload, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                print(resp.read().decode())
        except Exception as exc:
            print(json.dumps({"status": "error", "error": str(exc)}))
        return

    if args.pair_mode:
        until = state_mgr.open_pairing_window()
        print(json.dumps({
            "pairingOpen": True,
            "secondsRemaining": int(until - time.time()),
        }))
        return

    if args.models:
        data = collect_dynamic_llm_data()
        print(json.dumps(data["models"], indent=2))
        return

    run_server(args.port)


if __name__ == "__main__":
    main()
