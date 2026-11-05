#!/bin/sh
# Copies the originals the app has saved on the phone into Fixtures/originals (git-ignored).
# Usage: scripts/pull-originals.sh <device name or id from `xcrun devicectl list devices`>
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "usage: $0 <device>" >&2; exit 2; }
prefix=$(sed -n -E 's/^BUNDLE_ID_PREFIX *= *//p' Local.xcconfig)
mkdir -p Fixtures/originals
xcrun devicectl device copy from \
  --device "$1" \
  --domain-type appDataContainer \
  --domain-identifier "$prefix.groovycamera" \
  --source Documents/originals \
  --destination Fixtures/originals
