#!/bin/sh
# Downloads the latest Clawdmeter release and installs it into Applications.
set -e

if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
    echo "Clawdmeter needs macOS 26 or later." >&2
    exit 1
fi

dest=/Applications
[ -w "$dest" ] || dest="$HOME/Applications"
mkdir -p "$dest"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Downloading Clawdmeter..."
curl -fsSL https://github.com/tangheng05/clawdmeter/releases/latest/download/Clawdmeter.zip -o "$tmp/Clawdmeter.zip"
ditto -x -k "$tmp/Clawdmeter.zip" "$tmp"

pkill -x ClawdmeterApp 2>/dev/null || true
rm -rf "$dest/Clawdmeter.app"
mv "$tmp/Clawdmeter.app" "$dest/"
xattr -dr com.apple.quarantine "$dest/Clawdmeter.app" 2>/dev/null || true
open "$dest/Clawdmeter.app"

echo "Installed to $dest. Look for the orange Clawd in your menu bar."
