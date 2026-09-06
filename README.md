# ⌚ Omarchy AI Watch Bridge (Omarchy Plugin)

> **Live AI Usage on your wrist.**  
> Official Omarchy Quickshell dock widget & local API bridge for Samsung Galaxy Watch and Wear OS devices.

---

## 🌟 Features

- **Real-Time Watch Status in Omarchy Dock**: See watch connection status, battery percentage, and synchronization health.
- **One-Time Zero-Configuration Pairing**: mDNS (`avahi`) zero-conf auto-discovery plus a simple 4-digit PIN handshake. No typing IP addresses on the watch.
- **Dynamic AI Quota Aggregator**: Discovers all active AI CLI agents and models on your system (Claude Code, Antigravity, Grok, Codex, OpenAI, etc.).
- **Watch Face 4-Gauge Mapping**: Dynamically supplies quota data for the 4 circular gauges on the Wear OS watch face (Top: 12h, Right: 3h, Bottom: 6h, Left: 9h).
- **Zero-Dependency Python Daemon**: Runs directly on Python 3 standard library (`http.server` & `socket`) on port `8765`.

---

## 🚀 Quick Setup & Installation

### 1. Enable Plugin in Omarchy Shell
Link the plugin into your Omarchy user plugins folder:

```bash
ln -s /home/gladimdim/Github/omarchy-ai-watch/omarchy-plugin ~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch
omarchy restart shell
```

### 2. Enable the Background Daemon (systemd)
```bash
mkdir -p ~/.config/systemd/user
cp omarchy-wearos-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now omarchy-wearos-server.service
```

### 3. Verify Server
```bash
python3 server.py --status
```

---

## 🔒 Security
Pairing requires entering the 4-digit PIN generated on the laptop into the watch. Once verified, an encrypted local auth token is granted for all future Wi-Fi requests.
