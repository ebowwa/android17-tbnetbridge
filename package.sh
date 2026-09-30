#!/bin/sh
# package.sh — build the Magisk module zip from this directory.
#   ./package.sh            -> android17-tbnetbridge-vX.Y.Z.zip in ../dist/
# Layout per the Magisk module spec: module.prop at zip root, service.sh
# executed at boot, README/docs are inert extras.

set -e
cd "$(dirname "$0")"
VERSION=$(grep '^version=' module.prop | cut -d= -f2)
OUT=../dist/android17-tbnetbridge-${VERSION}.zip
mkdir -p ../dist

FILES="module.prop service.sh wire-uplink.conf.example README.md diagnose.sh"

# validate required entries
for k in id name version versionCode author description; do
  grep -q "^$k=" module.prop || { echo "module.prop missing $k"; exit 1; }
done
grep -q '^id=android17tbnetbridge$' module.prop || { echo "module id mismatch — zip id must match for Magisk updates"; exit 1; }

rm -f "$OUT"
if command -v zip >/dev/null 2>&1; then
  zip -q -r "$OUT" $FILES
else
  # fallback: python zipfile (present on Android via toybox? no — use tar+python if available)
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif [ -x /data/data/com.termux/files/usr/lib/hermes-agent/venv/bin/python ]; then
    PY=/data/data/com.termux/files/usr/lib/hermes-agent/venv/bin/python
  elif [ -x /data/data/com.termux/files/usr/bin/python ]; then
    PY=/data/data/com.termux/files/usr/bin/python
  else
    PY=""
  fi
  if [ -n "$PY" ]; then
    "$PY" - "$OUT" $FILES <<'EOF'
import sys, zipfile
out, files = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f)
EOF
  else
    echo "no zip/python3 found — cannot package"; exit 1
  fi
fi
echo "packaged: $OUT ($(du -h "$OUT" | cut -f1))"
echo "install on device: Magisk app -> Modules -> Install from storage -> $OUT"