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

## Connecting a watch

On the laptop, click **Add watch** in the Omarchy widget. On the watch, open
Omarchy AI and tap **Connect**. That is the whole setup. Nothing is typed on the
watch.

"Add watch" opens a 120-second window during which the next watch that asks is
issued a token. The window closes as soon as one watch takes it, so a second
device cannot slip in behind the first. Click it again to add another watch.

A 4-digit code still works, behind "Use a code instead" on the watch, for setups
driven from a terminal with no widget on screen.

### Why it is built this way

- **The laptop asks, not the watch.** A four-digit keypad on a watch is the worst
  input surface in the setup, and it was the step that failed most often.
- **The watch finds the laptop by sweeping the subnet**, not by service discovery.
  Wear OS mDNS reports the wrong port often enough that the app already had to
  hardcode one, and it silently returns nothing often enough that the user cannot
  tell a missing laptop from a flaky lookup. Every host on the watch's network is
  asked `/api/v1/ping`, which needs no credentials and names the service. That is
  deterministic and takes about a second. mDNS still runs as a fast path.
- **The stored address heals itself.** DHCP moves the laptop. On a failed sync the
  watch re-sweeps and quietly updates what it has, so there is no "reconnect" step.
- **Wi-Fi is diagnosed, not guessed at.** A Galaxy Watch parks its Wi-Fi radio while
  tethered to a phone over Bluetooth, which was the single most common cause of a
  failed setup. The app now says so and offers the Wi-Fi settings screen.

### Authentication

The bearer token issued at pairing is now **enforced**. It was previously issued,
sent by the watch on every request, and never checked, which left every endpoint
readable and writable by anyone on the network.

Open without a token: `/api/v1/ping`, `/api/v1/pair`, `/api/v1/pair/open`,
`/api/v1/pair/state`. Requests from localhost are always allowed so the widget
keeps working, and an install with no paired device yet is allowed so a fresh
setup cannot lock itself out.

### Endpoints added

| Endpoint | Purpose |
| --- | --- |
| `POST /api/v1/pair/open` | Open the pairing window. |
| `GET /api/v1/pair/state` | Whether the window is open, and for how long. |
| `server.py --pair-mode` | Same as `pair/open`, for the widget's CLI plumbing. |
