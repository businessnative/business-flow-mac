#!/bin/bash
# Business Flow — .app és .dmg építése SwiftPM-mel (Xcode nélkül, Command Line Tools elég).
# Használat: scripts/build-app.sh   → dist/Business Flow.app, dist/Business-Flow-<verzió>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.4.1}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/Business Flow.app"

echo "▸ swift build (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/BNFlow"

echo "▸ .app összeállítása"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/BNFlow"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/Fonts/*.otf "$APP/Contents/Resources/Fonts/"
cp LICENSES/Geist-OFL.txt LICENSES/Lucide-ISC.txt "$APP/Contents/Resources/"

echo "▸ ikon"
TMP="$(mktemp -d)"
swift scripts/make-icon.swift "$TMP/AppIcon.iconset" >/dev/null
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

echo "▸ ad-hoc aláírás"
# Állandó „designated requirement” (csak a bundle ID): így a Kulcskarika-hozzáférés és az
# Adatvédelmi engedélyek (TCC) újraépítés után is megmaradnak. Személyes használatra szánt kompromisszum.
# Stabil helyi aláíró identitás (önaláírt „Business Flow Local Signing”, külön kulcskarikában):
# a designated requirement (bundle ID + tanúsítvány) buildről buildre azonos, így a Kulcskarika-ACL és a TCC
# engedélyek megmaradnak. Ha az identitás hiányzik, ad-hoc aláírás (tartalék).
SIGN_KC="$HOME/Library/Keychains/business-flow-signing.keychain-db"
SIGN_PASS="$HOME/.config/business-flow/signing-keychain.pass"
SIGN_NAME="Business Flow Local Signing"
SIGN_ID=""
if [ -f "$SIGN_KC" ]; then
  [ -f "$SIGN_PASS" ] && security unlock-keychain -p "$(cat "$SIGN_PASS")" "$SIGN_KC" 2>/dev/null || true
  SIGN_ID=$(security find-identity -p codesigning "$SIGN_KC" 2>/dev/null | awk -v n="\"$SIGN_NAME\"" 'index($0,n){print $2; exit}')
fi
if [ -n "$SIGN_ID" ]; then
  echo "aláírás: $SIGN_NAME ($SIGN_ID)"
  codesign --force --deep --keychain "$SIGN_KC" --sign "$SIGN_ID" --identifier com.example.businessflow "$APP"
else
  echo "aláírás: ad-hoc (nincs helyi identitás)"
  codesign --force --deep --sign - --identifier com.example.businessflow \
    -r='designated => identifier "com.example.businessflow"' "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

echo "▸ dmg"
DMG="dist/Business-Flow-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Business Flow" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✓ $APP"
echo "✓ $DMG"
