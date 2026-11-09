#!/bin/bash
# Set YOUR OWN bundle identifier everywhere (replaces the neutral placeholder com.example.businessflow).
# Usage: scripts/set-bundle-id.sh com.yourname.businessflow
# Run it once, right after cloning, BEFORE the first build/launch. Works on macOS and Linux (uses perl).
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="${1:-}"
OLD="com.example"".businessflow"   # split on purpose, so this script never rewrites itself
if ! [[ "$NEW" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "Usage: $0 com.yourname.businessflow   (reverse-DNS: letters, digits, hyphens, dots)" >&2; exit 1
fi
FILES=$(grep -rIl --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=.build --exclude-dir=dist \
  --exclude=README.md --exclude=SECURITY.md --exclude=set-bundle-id.sh -F "$OLD" . || true)
if [ -z "$FILES" ]; then echo "Placeholder $OLD not found (already changed?)."; exit 0; fi
while IFS= read -r f; do OLD="$OLD" NEW="$NEW" perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$f"; echo "  updated: $f"; done <<< "$FILES"
echo "Bundle ID set to $NEW"
