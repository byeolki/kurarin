#!/bin/bash
# Removes the Kurarin virtual audio device and restarts the audio daemon.

set -euo pipefail

TARGET_BUNDLE="/Library/Audio/Plug-Ins/HAL/Kurarin.driver"

if [ "$EUID" -ne 0 ]; then
    echo "error: this script must run as root. Try: sudo $0" >&2
    exit 1
fi

if [ ! -d "$TARGET_BUNDLE" ]; then
    echo "Kurarin.driver is not installed."
    exit 0
fi

echo "Removing $TARGET_BUNDLE"
rm -rf "$TARGET_BUNDLE"

echo "Restarting coreaudiod (audio will cut out briefly)"
killall coreaudiod 2>/dev/null || true

echo "Done."
