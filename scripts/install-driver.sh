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

# cp preserves extended attributes, and a quarantined plug-in is not refused
# so much as ignored: coreaudiod passes over it during its scan and logs
# nothing at all, which looks exactly like a driver that failed to build.
# The attribute attaches on its own, so it is cleared on the installed copy
# rather than trusted to be absent. xattr has no -r flag.
find "$TARGET_BUNDLE" -exec xattr -c {} +
codesign --force --sign - --timestamp=none "$TARGET_BUNDLE" >/dev/null 2>&1

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
    echo
    echo "  What coreaudiod says about it:"
    echo "    log show --last 2m --predicate 'process == \"coreaudiod\"' | grep -i kurarin"
    echo
    echo "  No mention of Kurarin at all means the plug-in was never examined,"
    echo "  rather than examined and rejected. Check for a quarantine flag:"
    echo "    xattr $TARGET_BUNDLE"
    echo "  and for a blocked-software prompt in System Settings, Privacy &"
    echo "  Security, which needs an explicit Allow before the next attempt."
    exit 1
fi
