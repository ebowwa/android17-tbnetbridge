#!/system/bin/sh
# diagnose.sh — one-shot compatibility report for the wire-uplink module.
# Run on ANY rooted device before installing/trusting the module:
#   sh diagnose.sh
# Prints each gate with OK/FAIL/MISS and exits nonzero if any gate is FAIL.
# Designed to be slow-path-free (no binder, no loops, no network): the worst
# thing a diagnosis can do is hang.

GADGET_CFG=""
UDC=""
NCM_INSTANCE=""
HAL_FOUND=""

log() { printf "%s\n" "$*"; }
note() { printf "  %-40s %s\n" "$1" "$2"; }

echo "== android17-tbnetbridge diagnose =="
echo "time: $(date +%Y-%m-%dT%H:%M:%S%z)"

# 0. root + magisk
if [ "$(id -u)" = "0" ]; then
  note "root" "OK"
else
  note "root" "FAIL (need root)"
fi
MAG=$(magisk -V 2>/dev/null)
if [ -n "$MAG" ]; then
  note "magisk" "OK (v$MAG)"
else
  note "magisk" "MISS (not required for diagnose, required for boot service)"
fi

# 1. configfs mount point (either /config or /sys/kernel/config)
for base in /config /sys/kernel/config; do
  if [ -d "$base/usb_gadget" ]; then
    GADGET_CFG="$base"
    break
  fi
done
if [ -n "$GADGET_CFG" ]; then
  note "configfs" "OK ($GADGET_CFG/usb_gadget)"
else
  note "configfs" "FAIL (no usb_gadget under /config or /sys/kernel/config)"
fi

# 2. gadget root
GADGET=$GADGET_CFG/usb_gadget/g1
if [ ! -d "$GADGET/functions" ] || [ ! -d "$GADGET/configs" ]; then
  GADGET=$(ls -d "$GADGET_CFG"/usb_gadget/g* 2>/dev/null | head -1)
fi
if [ -n "$GADGET" ] && [ -d "$GADGET/configs" ]; then
  note "gadget root" "OK ($GADGET)"
  echo "  functions: $(ls "$GADGET"/functions/ 2>/dev/null | tr '\n' ' ')"
  echo "  configs:   $(ls -d "$GADGET"/configs/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
else
  note "gadget root" "FAIL"
fi

# 3. UDC (sysfs first — the ground truth; getprop is a convenience)
UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
if [ -n "$UDC" ]; then
  note "udc (sysfs)" "OK ($UDC)"
else
  note "udc (sysfs)" "FAIL"
fi
CTRL=$(getprop sys.usb.controller 2>/dev/null)
[ -n "$CTRL" ] && note "udc (prop)" "OK ($CTRL)"

# 4. is the gadget currently bound?
if [ -n "$UDC" ] && [ "$(cat "/sys/class/udc/$UDC/state" 2>/dev/null)" = "configured" ]; then
  note "gadget bound" "yes (configured)"
fi

# 5. does an NCM instance exist / can we create one? (module makes ncm.wire)
if [ -d "$GADGET/functions/ncm.wire" ]; then
  NCM_INSTANCE="$GADGET/functions/ncm.wire"
  note "ncm.wire" "OK (exists)"
elif ls "$GADGET"/functions/ 2>/dev/null | grep -q "^ncm\."; then
  NCM_INSTANCE=$(ls -d "$GADGET"/functions/ncm.* 2>/dev/null | head -1)
  note "ncm.wire" "MISS — will create; existing instance: $(basename "$NCM_INSTANCE")"
else
  # probe: can configfs create an ncm instance at all? (kernel must have NCM)
  PROBE=ncm.probe.$$
  if mkdir "$GADGET/functions/$PROBE" 2>/dev/null; then
    rmdir "$GADGET/functions/$PROBE" 2>/dev/null
    note "ncm kernel support" "OK (create/remove probe passed)"
    note "ncm.wire" "MISS — will create on first arm"
  else
    note "ncm kernel support" "FAIL (CONFIG_USB_CONFIGFS_NCM likely off)"
  fi
fi

# 6. HAL name(s) — detect without binder (pidof only; service list can hang)
found=""
for h in android.hardware.usb.gadget-service android.hardware.usb-service \
         android.hardware.usb.gadget@2.0-service vendor.usb-gadget-hal; do
  for p in $(pidof "$h" 2>/dev/null); do
    found="$found $h($p)"
  done
done
if [ -n "$found" ]; then
  HAL_FOUND=1
  note "usb HAL" "OK:$found"
else
  note "usb HAL" "MISS (no matching pidof — module freezes HAL; if absent, integrate differently)"
fi

# 7. EthernetTracker target filter hint (adoptable name pattern)
note "tracker filter" "(usb|eth)\d+ — module renames ncmN->usb0 when needed"

echo
echo "== verdict =="
FAILS=0
[ "$(id -u)" = "0" ] || FAILS=$((FAILS+1))
[ -n "$GADGET_CFG" ] || FAILS=$((FAILS+1))
[ -n "$GADGET" ] || FAILS=$((FAILS+1))
[ -n "$UDC" ] || FAILS=$((FAILS+1))
[ -n "$NCM_INSTANCE" ] || { ls "$GADGET"/functions/ 2>/dev/null | grep -q "^ncm\." && : || FAILS=$((FAILS+1)); }
if [ "$FAILS" = "0" ]; then
  echo "READY — module should install and arm on this device."
  exit 0
else
  echo "NOT READY — $FAILS gate(s) failed. Fix before installing."
  exit 1
fi