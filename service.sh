#!/system/bin/sh
# wire-uplink.sh — persist the Pixel's USB-NCM uplink to the mini.
# Runs at boot via Magisk service.d / module service.sh; re-arms the gadget
# whenever the cable is present but the link is down. Root only.
#
# Why this file exists: Android's gadget HAL owns configfs and, on every
# USB (re)connect, re-applies its configured function (adb), tearing down
# the NCM function we need. Fix: freeze the HAL, wire a self-owned NCM
# function as function1 of the active config, bind the UDC, bring the
# netdev up. Repeat forever in the background.
#
# Portability: path detection replaces hardcoding where possible.
#   - UDC:     getprop sys.usb.controller (fallback WIRE_UPLINK_UDC)
#   - gadget:  first dir under /config/usb_gadget
#   - config:  the config dir whose function list holds ffs.adb (the HAL's
#              active config), else configs/b.1, else the first config
#   - ncm fn:  the module's own instance, created if absent — named
#              functions/ncm.wire so no collision with HAL-managed gs*
#   - qmult:   set to 32 on arm (best effort, verify)
#   - ifname:  Android's EthernetNetworkFactory only adopts (usb|eth)\d+;
#              usb%d templated netdevs qualify, ncmN names get renamed.
#
# SAFETY: only touches the gadget HAL + configfs; no data loss. After 3
# failed arm attempts it restores HAL-managed adb rather than wedging the
# gadget permanently.

MODDIR=${0%/*}

HAL1=android.hardware.usb.gadget-service
HAL2=android.hardware.usb-service
LOG=${WIRE_UPLINK_LOG:-/data/local/tmp/wire-uplink.log}

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

# ---- optional per-device override file (ports/env-less customization) ----
# Format: KEY=value lines; keys: UDC, GADGET, CFG, NCM, INTERVAL, HAL1, HAL2
for conf in "$MODDIR/wire-uplink.conf" "${WIRE_UPLINK_CONF:-/data/local/tmp/wire-uplink.conf}"; do
  [ -f "$conf" ] && . "$conf" 2>/dev/null && log "config: $conf"
done

# ---- path discovery (runs once, sysfs-first — see diagnose.sh) ----
UDC=${WIRE_UPLINK_UDC:-$UDC}
[ -n "$UDC" ] || UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)          # ground truth
[ -n "$UDC" ] || UDC=$(getprop sys.usb.controller 2>/dev/null)             # convenience
[ -n "$UDC" ] || UDC=11210000.dwc3

CFGFS=$(ls -d /config/usb_gadget 2>/dev/null || ls -d /sys/kernel/config/usb_gadget 2>/dev/null)
GADGET=${GADGET:-$(ls -d "$CFGFS"/g* 2>/dev/null | head -1)}
[ -n "$GADGET" ] || GADGET="$CFGFS/g1"
[ -d "$GADGET" ] || { log "no gadget dir under $CFGFS — abort"; exit 1; }

# pick the config that holds ffs.adb (the HAL's active config)
CFG=""
for c in "$GADGET"/configs/*/; do
  [ -d "$c" ] || continue
  for f in "$c"function*; do
    [ -L "$f" ] || continue
    t=$(readlink "$f" 2>/dev/null)
    case "$t" in
      *ffs.adb*) CFG="$c" ;;
    esac
  done
done
[ -n "$CFG" ] || CFG="$GADGET/configs/b.1"
[ -d "$CFG" ] || CFG=$(ls -d "$GADGET"/configs/*/ 2>/dev/null | head -1)
[ -n "$CFG" ] || { log "no config dir found under $GADGET"; exit 1; }

# module-owned NCM instance: create if absent (avoids HAL-managed gs* names)
NCM=$GADGET/functions/ncm.wire
[ -d "$NCM" ] || mkdir -p "$NCM" 2>/dev/null
[ -d "$NCM" ] || NCM=$(ls -d "$GADGET"/functions/ncm.* 2>/dev/null | head -1)
[ -n "$NCM" ] || { log "no ncm function available and could not create one"; exit 1; }

log "wire-uplink starts: udc=$UDC gadget=$GADGET cfg=$CFG ncm=$NCM"

freeze_hal() {
  for p in $(pidof "$HAL1" "$HAL2" 2>/dev/null); do
    kill -STOP "$p" 2>/dev/null
  done
}

thaw_hal() {
  for p in $(pidof "$HAL1" "$HAL2" 2>/dev/null); do
    kill -CONT "$p" 2>/dev/null
  done
}

find_netdev() {
  for d in $(ls /sys/class/net/ 2>/dev/null | grep -E "^(usb|eth|ncm)[0-9]*$"); do
    case "$d" in
      usb[0-9]*|eth[0-9]*) echo "$d"; return 0 ;;
    esac
  done
  echo ""
}

bind_udc() {
  echo "$UDC" > "$GADGET/UDC" 2>/dev/null
  sleep 3
  # verify the bind actually took — a silent no-op here means a stale
  # instance pinned the name and the gadget never bound (see wire_ncm)
  [ "$(cat "$GADGET/UDC" 2>/dev/null)" = "$UDC" ]
}

wire_ncm() {
  # UDC must be UNBOUND before touching configfs function links
  echo "" > "$GADGET/UDC" 2>/dev/null; sleep 1

  # Drop HAL-managed ncm instances that could pin usbN netdev names from
  # previous runs (bind then fails silently). Keep the module-owned one.
  for f in $(ls "$GADGET"/functions/ 2>/dev/null | grep -E "^ncm\."); do
    if [ "$f" != "$(basename "$NCM")" ]; then
      rmdir "$GADGET/functions/$f" 2>/dev/null && log "removed stale $f"
    fi
  done

  # qmult: higher throughput (default 5 caps the wire); best effort + verify
  oldq=$(cat "$NCM/qmult" 2>/dev/null)
  echo 32 > "$NCM/qmult" 2>/dev/null
  [ "$(cat "$NCM/qmult" 2>/dev/null)" = "32" ] || log "qmult write failed (kept $oldq)"

  rm -f "$CFG/function1" 2>/dev/null
  ln -s "$NCM" "$CFG/function1" 2>/dev/null || { echo "" > "$GADGET/UDC" 2>/dev/null; return 1; }
  bind_udc || { log "UDC bind did not stick"; return 1; }

  # bring up every candidate and find the one with carrier
  for d in $(ls /sys/class/net/ 2>/dev/null | grep -E "^(usb|eth|ncm)[0-9]*$"); do
    ip link set "$d" up 2>/dev/null
  done
  sleep 2
  DEV=""
  for d in $(ls /sys/class/net/ 2>/dev/null | grep -E "^(usb|eth|ncm)[0-9]*$"); do
    if [ "$(cat /sys/class/net/$d/carrier 2>/dev/null)" = "1" ]; then
      case "$d" in
        usb[0-9]*|eth[0-9]*) DEV="$d"; break ;;
        ncm[0-9]*) [ -z "$DEV" ] && DEV="$d" ;;
      esac
    fi
  done
  [ -n "$DEV" ] || { log "no live netdev after bind"; return 1; }

  # ncmN names don't match Android's (usb|eth)\d+ filter -> rename to usb0
  case "$DEV" in
    ncm[0-9]*)
      ip link set "$DEV" down 2>/dev/null
      ip link set "$DEV" name usb0 2>/dev/null
      # rename drops carrier; rebind restores it
      echo "" > "$GADGET/UDC" 2>/dev/null; sleep 1
      bind_udc || { log "rebind after rename failed"; return 1; }
      ip link set usb0 up 2>/dev/null; sleep 2
      DEV=usb0
      ;;
  esac

  if [ "$(cat /sys/class/net/$DEV/carrier 2>/dev/null)" = "1" ]; then
    log "armed: $DEV carrier=1"
    return 0
  fi
  log "armed but no carrier (cable out?)"
  return 1
}

restore_adb() {
  rm -f "$CFG/function1" 2>/dev/null
  echo "$UDC" > "$GADGET/UDC" 2>/dev/null
  thaw_hal
  setprop sys.usb.config adb
  setprop persist.sys.usb.config adb
}

FAILS=0
while true; do
  UDC_STATE=$(cat "/sys/class/udc/$UDC/state" 2>/dev/null)
  if [ "$UDC_STATE" = "bound" ] \
     || [ "$UDC_STATE" = "configured" ] \
     || [ -n "$(find_netdev)" ]; then
    CARRIER=""
    for d in $(ls /sys/class/net/ 2>/dev/null | grep -E "^(usb|eth)[0-9]*$"); do
      [ "$(cat /sys/class/net/$d/carrier 2>/dev/null)" = "1" ] && CARRIER=1
    done
    if [ "$CARRIER" != "1" ]; then
      freeze_hal
      if wire_ncm; then
        FAILS=0
      else
        FAILS=$((FAILS+1))
        if [ $FAILS -ge 3 ]; then
          log "3 fails -> restore adb"
          restore_adb
          FAILS=0
        fi
      fi
    fi
  else
    # no cable / unbound: keep HAL normal so adb/charging work
    thaw_hal
  fi
  sleep "${INTERVAL:-5}"
done