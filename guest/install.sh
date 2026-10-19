#!/bin/sh
# Run inside the Linux install (natively or in try mode) as your desktop user: sets up the
# shared clipboard for try mode. Asks for sudo once, for the udev rule. Needs wl-clipboard.
set -e
here=$(dirname "$(readlink -f "$0")")
command -v wl-paste > /dev/null || echo "note: install wl-clipboard too (pacman -S wl-clipboard)"
install -Dm 755 "$here/../clipsync.sh" "$HOME/.local/bin/clipsync.sh"
install -Dm 644 "$here/linuxdrives-clipsync.desktop" "$HOME/.config/autostart/linuxdrives-clipsync.desktop"
sudo install -m 644 "$here/70-linuxdrives-clipboard.rules" /etc/udev/rules.d/70-linuxdrives-clipboard.rules
sudo udevadm control --reload
sudo udevadm trigger -s virtio-ports || true
echo "done - the clipboard starts with your next login in try mode"
