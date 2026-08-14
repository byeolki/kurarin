#!/bin/bash
# Installs the Kurarin virtual audio device.
#
# HAL plug-ins live in a system directory and are loaded by coreaudiod, so this
# needs administrator rights and a restart of the audio daemon. Restarting it
# interrupts audio everywhere on the machine for a moment.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_BUNDLE="$REPO_ROOT/build/Kurarin.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
TARGET_BUNDLE="$INSTALL_DIR/Kurarin.driver"

if [ ! -d "$SOURCE_BUNDLE" ]; then
    echo "error: $SOURCE_BUNDLE not found. Run 'make driver' first." >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "error: this script must run as root. Try: sudo $0" >&2
    exit 1
fi

echo "Installing Kurarin.driver into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_BUNDLE"
cp -R "$SOURCE_BUNDLE" "$TARGET_BUNDLE"
chown -R root:wheel "$TARGET_BUNDLE"
chmod -R 755 "$TARGET_BUNDLE"

echo "Restarting coreaudiod (audio will cut out briefly)"
killall coreaudiod 2>/dev/null || true

# coreaudiod is relaunched by launchd; give it a moment to enumerate plug-ins.
sleep 3

echo
echo "Done. Checking whether the device registered:"
if system_profiler SPAudioDataType 2>/dev/null | grep -q "Kurarin Microphone"; then
    echo "  Kurarin Microphone is present."
else
    echo "  Kurarin Microphone did NOT appear."
    echo "  Check the log with:"
    echo "    log show --last 2m --predicate 'process == \"coreaudiod\"' | grep -i kurarin"
    exit 1
fi
