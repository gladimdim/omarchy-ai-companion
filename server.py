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

    def save_config(self):
        tmp = CONFIG_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.config, f, indent=2)
        os.replace(tmp, CONFIG_FILE)

    def save_slots(self):
        tmp = SLOTS_FILE.with_suffix(".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.slots, f, indent=2)
        os.replace(tmp, SLOTS_FILE)

    def get_pin(self) -> str:
        with self.lock:
            return self.config.get("pin", "1234")

    def generate_new_pin(self) -> str:
        with self.lock:
            new_pin = f"{random.randint(1000, 9999)}"
            self.config["pin"] = new_pin
            self.save_config()
            return new_pin

    def validate_pin(self, pin: str) -> Optional[str]:
        with self.lock:
            if str(pin).strip() == str(self.config.get("pin", "")).strip():
                new_token = secrets.token_hex(24)
                if "paired_tokens" not in self.config:
                    self.config["paired_tokens"] = []
                self.config["paired_tokens"].append(new_token)
                self.save_config()
                return new_token
            return None

    def is_token_valid(self, token: str) -> bool:
        with self.lock:
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

    def get_watch_status(self) -> Dict[str, Any]:
        with self.lock:
            if STATUS_FILE.exists():
                try:
                    with open(STATUS_FILE, "r", encoding="utf-8") as f:
                        return json.load(f)
                except Exception:
                    pass
            return {"connected": False, "status": "Waiting for watch"}

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
                limit_color = lim.get("color") or prov_color

                model_item = {
                    "id": unique_id,
                    "providerId": prov_id,
                    "providerName": prov_name,
                    "title": title,
                    "shortLabel": short_label,
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
            "provider": item.get("providerName", ""),
            "percent": item.get("percent", 0.0),
            "percentInt": item.get("percentInt", 0),
            "valueText": item.get("valueFormatted") or f"{item.get('percentInt', 0)}%",
            "resetsShort": item.get("resetsShort", ""),
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

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0]

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
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length) if content_length > 0 else b"{}"

        try:
            body = json.loads(post_data.decode("utf-8"))
        except Exception:
            body = {}

        if path == "/api/v1/pair":
            pin = body.get("pin", "")
            token = state_mgr.validate_pin(pin)
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
                    "message": "Pairing successful",
                })
            else:
                self._send_json(401, {"status": "error", "error": "Invalid PIN code"})
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
        print(json.dumps(st, indent=2))
        return

    if args.models:
        data = collect_dynamic_llm_data()
        print(json.dumps(data["models"], indent=2))
        return

    run_server(args.port)


if __name__ == "__main__":
    main()
