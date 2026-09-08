# ⌚ Omarchy AI Watch Bridge (Omarchy Plugin)

> **Live AI usage on your wrist.**
> Omarchy Quickshell dock widget and local API bridge for Samsung Galaxy Watch and
> other Wear OS devices.

The watch app and watch face live in a separate repository,
[`ai-omarchy-wearos`](../ai-omarchy-wearos).

---

## 🌟 Features

- **Watch status in the Omarchy dock.** One icon that carries the connection
  state, plus a panel with a live miniature of the watch face as it looks right
  now on the wrist.
- **Pairing with nothing typed on the watch.** The watch asks, the laptop
  approves — with a click in the widget or straight from the notification.
- **Dynamic AI quota aggregator.** Discovers every AI CLI agent reporting usage
  under `~/.local/state/omarchy/agents/usage` (Claude Code, Antigravity, Grok,
  Codex, Gemini, and anything else that writes the same shape).
- **Four-gauge mapping.** Supplies the quota behind each of the four arcs on the
  watch face (Top 12h, Right 3h, Bottom 6h, Left 9h), reassignable from the
  widget or from the watch.
- **Zero-dependency Python daemon.** Standard library only (`http.server`,
  `socket`), on port `8765`.

---

## What this plugin runs on your machine

Omarchy plugins run unsandboxed inside the long-lived shell process, so it is
worth being plain about what this one does:

- **A bar widget** (`Widget.qml`) that shells out to `server.py` for its data.
  It runs no other command and reads no file outside this plugin directory.
- **A local daemon** (`server.py`, Python 3 standard library only) that you
  install as a *user* systemd service. It listens on **TCP 8765 on all
  interfaces**, because a watch on your Wi-Fi has to reach it. It runs as your
  user, never as root.
- **State** in `~/.local/state/omarchy/wearos/`, mode `0600`: the pairing
  tokens, the fallback code, and the last heartbeat.

It reads AI usage from `~/.local/state/omarchy/agents/usage/*.json`, which the
agent tools already write. It makes **no outbound connections** — no telemetry,
no update check, no analytics. Everything it serves stays on your network.

### How the listener is protected

| | |
|---|---|
| Every data endpoint | needs the bearer token issued at pairing |
| Approving, denying, forgetting, opening the pairing window | **localhost only** — these are decisions that belong on the laptop |
| Open without a token | `ping`, and the pairing handshake a watch must reach before it has a token |
| Fallback 4-digit code | 5 wrong tries per source address, then a 5-minute lockout |
| Connect requests | 3 per source address per 15 minutes, so nobody can bury you in approval prompts |
| CORS | none, deliberately — a web page cannot script this API from your browser |

Until the first device is paired there is nothing to protect and the endpoints
are open; from the moment a watch is paired, the token is required.

---

## 🚀 Setup

### 1. Enable the plugin in the Omarchy shell

The directory name must match the `id` in `manifest.json`:

```bash
ln -s "$(pwd)" ~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch
omarchy restart shell
```

### 2. Enable the background daemon (systemd)

```bash
mkdir -p ~/.config/systemd/user
cp omarchy-wearos-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now omarchy-wearos-server.service
```

The unit runs `server.py` out of the plugin directory above, so the symlink has
to exist first.

### 3. Verify

```bash
python3 server.py --status
```

### Removing it

The systemd service outlives the plugin directory, so stop it **before**
removing the plugin — otherwise it is left restarting a script that no longer
exists:

```bash
systemctl --user disable --now omarchy-wearos-server.service
rm ~/.config/systemd/user/omarchy-wearos-server.service
systemctl --user daemon-reload

omarchy plugin remove gladimdim.omarchy-ai-watch
rm -rf ~/.local/state/omarchy/wearos      # pairing tokens and cached state
```

Unlink the watch from the widget first if you want it to forget the pairing
cleanly; otherwise unlink from the watch itself, which works offline.

---

## Connecting a watch

On the watch, open Omarchy AI and tap **Connect**. The laptop raises a
notification and shows a prompt in the widget; click **Approve** and the watch is
linked. That is the whole setup — nothing is typed on the watch.

To add a second watch without waiting for a prompt, click **Add another watch**
in the widget first. That opens a 120-second window during which the next watch
that asks is issued a token without anyone approving it. The window closes as
soon as one watch takes it, so a second device cannot slip in behind the first.

A 4-digit code still works, behind **Use a code instead** on the watch, for
setups driven from a terminal with no widget on screen.

### Why it is built this way

- **The laptop approves, not the watch.** A four-digit keypad on a watch is the
  worst input surface in the setup, and it was the step that failed most often.
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
  failed setup. The app says so and offers the Wi-Fi settings screen.

---

## Protocol versioning

The two halves update through different channels -- the watch app through Play,
this bridge through a git pull -- so they drift. `PROTOCOL_VERSION` in
`server.py` and `Protocol.kt` lets the widget say so instead of letting a watch
quietly render numbers it half understands.

It is bumped **only** on a breaking change. Additive fields need no bump, because
both sides read every field with a default. The widget shows a banner when the
watch reports an older or newer version than this bridge, and stays silent
otherwise.

---

## 🔒 Authentication

Pairing issues a 24-byte random bearer token, and every data endpoint checks it
with a constant-time compare. See the table above for exactly what is open.

Open without a token, by necessity: `/api/v1/ping`, and the pairing handshake a
watch must complete before it holds one — `/api/v1/pair`, `/api/v1/pair/state`,
`/api/v1/pair/poll`, plus `/api/v1/pair/unlink`, which a watch uses to hand its
own token back. Requests from localhost are always allowed so the widget keeps
working, and an install with no paired device yet is allowed so a fresh setup
cannot lock itself out.

**Opening the pairing window, approving, denying and forgetting are localhost
only.** They are the acts that authorise a device, and they belong on the
machine with the screen. `/api/v1/pair/open` was reachable from the network in
an earlier build, which let anything on the LAN open the window and pair itself
with no code and no click; it is now refused like the rest.

The token authenticates the watch to the laptop. It does not encrypt the
traffic, which is quota percentages and reset times, and never leaves your LAN —
a self-hosted service on a home network has no certificate a device could
verify. Treat your local network as you would for any other device on it.

---

## Command line

| Command | Purpose |
| --- | --- |
| `server.py` | Run the daemon (this is what the systemd unit does). |
| `server.py --status` | Everything the widget draws, as JSON. |
| `server.py --models` | Every quota discovered on this machine. |
| `server.py --pin` / `--new-pin` | Show or regenerate the 4-digit code. |
| `server.py --pair-mode` | Open the "add a watch" window. |
| `server.py --approve ID` / `--deny ID` | Answer a pending connect request. |
| `server.py --set-slot SLOT MODEL_ID` | Reassign one of the four gauges. |
| `server.py --forget` | Unlink every paired watch. |

Everything that changes live state goes through the running daemon over HTTP
rather than editing its files, so a second process cannot leave the daemon
holding a different idea of the truth than what is on disk.
