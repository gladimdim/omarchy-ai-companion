# Omarchy AI Watch Bridge

Bar widget and local bridge that puts your AI coding quotas on a Wear OS watch face.

The watch app lives in [`ai-omarchy-wearos`](https://github.com/gladimdim/ai-omarchy-wearos).

## Install

```bash
omarchy plugin add https://github.com/gladimdim/omarchy-ai-companion.git --enable
```

Then enable the background daemon:

```bash
mkdir -p ~/.config/systemd/user
cp ~/.config/omarchy/plugins/gladimdim.omarchy-ai-watch/omarchy-wearos-server.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now omarchy-wearos-server.service
```

On the watch, open Omarchy AI and tap **Connect**. Approve the prompt in the bar widget or the desktop notification.

## Remove

Stop the daemon before removing the plugin:

```bash
systemctl --user disable --now omarchy-wearos-server.service
rm ~/.config/systemd/user/omarchy-wearos-server.service
systemctl --user daemon-reload

omarchy plugin remove gladimdim.omarchy-ai-watch
rm -rf ~/.local/state/omarchy/wearos
```
