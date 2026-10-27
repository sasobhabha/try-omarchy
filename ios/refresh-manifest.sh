#!/bin/bash
# Copy download.json out of a Try Omarchy DMG into the iOS app.
# The device never opens the DMG; it downloads the parts named in this file.
#
#   ios/refresh-manifest.sh /path/to/TryOmarchy.dmg

set -euo pipefail

dmg=${1:?usage: ios/refresh-manifest.sh TryOmarchy.dmg}
root=$(cd "$(dirname "$0")/.." && pwd)
destination="$root/ios/Resources/guest/download.json"

mount=$(mktemp -d)
diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$mount" "$dmg" >/dev/null
cleanup() { diskutil eject "$mount" >/dev/null || hdiutil detach "$mount" >/dev/null || true; rm -rf "$mount"; }
trap cleanup EXIT
source=$(find "$mount" -path '*/Contents/Resources/guest/download.json' -print -quit)
[[ -n $source ]] || { echo "refresh-manifest: download.json is not in the DMG" >&2; exit 1; }
cp "$source" "$destination"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$destination"
echo "updated $destination"
