#!/bin/bash
# Egységtesztek Xcode nélkül (Command Line Tools): a Swift Testing keretrendszer a CLT-ben van, csak az útvonalat kell megadni.
set -euo pipefail
cd "$(dirname "$0")/.."
F="$(xcode-select -p)/Library/Developer/Frameworks"
if [ -d "$F/Testing.framework" ]; then
  swift test -Xswiftc -F -Xswiftc "$F" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
else
  swift test "$@"
fi
