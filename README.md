# Omarchy AI Watch Bridge

Bar widget and local bridge that puts your AI coding quotas on a Wear OS watch face.

The watch app lives in [`ai-omarchy-wearos`](https://github.com/gladimdim/ai-omarchy-wearos).

## Install

```bash
omarchy plugin add https://github.com/gladimdim/omarchy-ai-companion.git --enable
```

Open the **AI Watch** widget in the bar and use the **Setup** tab. It checks the
daemon, the firewall, and mDNS, explains each one, and has buttons to fix what
is missing (firewall changes pop a system password prompt).

The same steps from a terminal:

```bash
~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch/setup.sh
```

`setup.sh` is the repeatable part. On every laptop it:

1. Enables the **user** systemd daemon (`omarchy-wearos-server.service`)
2. Starts **Avahi** if it is installed but not running (mDNS advertising)
3. Opens the firewall if one is active:
   - **TCP 8765** — the bridge the watch talks to
   - **UDP 5353** — mDNS / DNS-SD (`_omarchy-ai._tcp`)
4. Checks that `/api/v1/ping` answers and that Avahi is publishing the service

It supports **UFW** (Omarchy's default) and **firewalld**. Opening ports needs
root once; the script uses `sudo` in a terminal or `pkexec` if there is no TTY.

Re-run it any time. It is idempotent. `setup.sh --check` prints diagnostics
without changing anything.

From a git checkout of this repo you can run `./setup.sh` instead; it uses the
checkout if the plugin directory is not there yet.

On the watch, open Omarchy AI and tap **Connect**. Approve the prompt in the bar
widget or the desktop notification. The watch and laptop must be on the **same
Wi-Fi**.

## What the watch actually needs

The bar widget only talks to the daemon on localhost. It does **not** start it.
The watch finds the laptop in two ways, both of which fail if TCP 8765 is
closed to the LAN:

| Path | Port | Role |
| --- | --- | --- |
| mDNS `_omarchy-ai._tcp` | UDP 5353 | Fast path. Wear OS NSD is flaky, so this is best-effort. |
| Subnet sweep of `/api/v1/ping` | TCP 8765 | The reliable path. Every host on the watch's /24 is probed. |

A default-deny UFW with no `8765/tcp` rule is the usual reason a new laptop's
watch shows nothing, even when the widget looks fine.

### Manual firewall (if you skip the script)

UFW:

```bash
sudo ufw allow 8765/tcp comment 'omarchy-ai-watch'
sudo ufw allow 5353/udp comment 'omarchy-ai-watch-mdns'
sudo ufw reload
```

firewalld:

```bash
sudo firewall-cmd --permanent --add-port=8765/tcp
sudo firewall-cmd --permanent --add-service=mdns
sudo firewall-cmd --reload
```

### Manual daemon (if you skip the script)

```bash
mkdir -p ~/.config/systemd/user
ln -sfn ~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch/omarchy-wearos-server.service \
  ~/.config/systemd/user/omarchy-wearos-server.service
systemctl --user daemon-reload
systemctl --user enable --now omarchy-wearos-server.service
```

## Troubleshooting

```bash
~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch/setup.sh --check
```

| Symptom | Likely cause |
| --- | --- |
| Widget shows a PIN / status, watch finds nothing | Firewall blocking **TCP 8765** from the LAN (localhost still works) |
| `setup.sh --check` says the user unit is not running | Daemon never enabled; the widget does not launch it |
| `avahi-browse` does not list `_omarchy-ai._tcp` | `avahi-daemon` stopped, or `avahi-publish` missing (`sudo pacman -S avahi`) |
| Watch says it is not on Wi-Fi | Galaxy Watch parks Wi-Fi while tethered over Bluetooth — turn Wi-Fi on on the watch |
| Same SSID, still invisible | Guest / AP isolation on the router: clients cannot talk to each other |

The daemon listens on `0.0.0.0:8765` as your user, never as root. State lives
in `~/.local/state/omarchy/wearos/` (`0600`).

## Play Store

This repo is **not** a Play app. The Wear OS app and the watch face are two
separate Play listings, published from
[`ai-omarchy-wearos/store`](https://github.com/gladimdim/ai-omarchy-wearos/tree/main/store).

What you do here around a Play submission (privacy policy URL, reviewer setup,
`PLAY_URL` after the Wear OS app is live) is in [`store/README.md`](store/README.md).

## Remove

```bash
~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch/setup.sh --remove
omarchy plugin remove gladimdim.omarchy-ai-watch
rm -rf ~/.local/state/omarchy/wearos
```
