# android17-tbnetbridge

USB NCM **wire-uplink** for a rooted Android phone (Pixel 10a / Android 17
verified) served by a macOS TBNetBridge gateway (the mini): the phone's
internet runs over the physical USB-C/TB5 cable instead of Wi-Fi, and the
link re-arms itself on boot and on every replug.

This is the Android half of the fleet's TB-net feature. The macOS half is the
TBNetBridge plugin (a Gauge plugin running on the mini, the fleet's hub
machine): it watches the bridge path and heals NAT-anchor drift. This module
owns the phone side: it makes the gadget present an adoptable ethernet link
and keeps it alive. The full measured story of both halves is in the lab-note
war report linked under References.

**Portability:** the script detects its environment instead of assuming one
device — UDC from `getprop sys.usb.controller`, gadget dir auto-found, the
active config picked by scanning for the HAL's `ffs.adb` function, and a
self-owned NCM function instance (`functions/ncm.wire`) created on first arm
so it never collides with HAL-managed instance names. Anything with a Linux
USB gadget (dwc3 or compatible UDC) and Android configfs should work; the
Pixel 10a is the verified reference.

Measured (Series 9, part 5 — the cable war):
- ~400 Mbps internet over the wire, ~460 Mbps wire-only; the ceiling is the
  phone's USB-NCM gadget (no hardware checksum offload), not the cable.
- Auto-heal on replug: ~12 s re-arm, lease + validation restored without
  intervention.

## What it does

The gadget HAL (android.hardware.usb.gadget-service) owns configfs and, on
every USB (re)connect, re-applies its configured function (`adb`), tearing
down the NCM function. This module:

1. Freezes the gadget HAL (SIGSTOP) so it stops reverting configfs.
2. Wires a self-owned NCM instance (`ncm.wire`, qmult=32 — higher aggregate
   throughput than the locked qmult=5 instances) as `configs/b.1/function1`.
3. Binds the UDC, brings up the netdev, and — because Android's
   EthernetNetworkFactory only adopts `(usb|eth)\d+` interfaces — renames
   `ncmN` to `usb0` when needed.
4. Loops every 5 s: if the cable is present but carrier is down, re-arms;
   if the cable is out, thaws the HAL so adb/charging work normally.
5. After 3 failed arm attempts, restores HAL-managed adb rather than
   wedging the gadget permanently.

## Install

As a Magisk module — build the zip, install from the Magisk app:

```sh
sh package.sh            # -> ../dist/android17-tbnetbridge-vX.Y.Z.zip
# Magisk app -> Modules -> Install from storage -> pick the zip
```

Or standalone (no zip needed, same script):

```sh
cp service.sh /data/adb/service.d/wire-uplink.sh
chmod 700 /data/adb/service.d/wire-uplink.sh
# starts at next boot; or run it now (setsid so it survives this shell):
setsid sh /data/adb/service.d/wire-uplink.sh </dev/null >/dev/null 2>&1 &
```

**Before installing on a NEW device, validate it:**

```sh
su -c 'sh diagnose.sh'   # prints every gate + verdict (READY / NOT READY)
```

If a device fails a gate (e.g. different configfs path, no ncm kernel
support), fix that first — or override the mis-detected value in the
per-device config file (see `wire-uplink.conf.example`). File a
[compatibility issue](https://github.com/ebowwa/android17-tbnetbridge/issues)
with the diagnose output when a device needs a new override: that's how the
module learns the fleet.

Requires: root (Magisk), a USB-C/TB5 cable to a macOS host running the
TBNetBridge gateway (bootpd + pf NAT for a dedicated /24 + a Manual network
service on the USB port).

## Configuration

| env | default | meaning |
|---|---|---|
| `WIRE_UPLINK_UDC` | `getprop sys.usb.controller` (fallback `11210000.dwc3`) | the UDC node to bind |
| `WIRE_UPLINK_LOG` | `/data/local/tmp/wire-uplink.log` | log path |

## Safety

- Only touches the gadget HAL + configfs. No data loss.
- 3-strike fallback to adb keeps the gadget usable if arming fails.
- While armed, USB-adb is paused (HAL frozen); unplug the cable (or stop the
  loop) and adb works again immediately.

## Files

- `module.prop` — Magisk manifest (id must stay `android17tbnetbridge`)
- `service.sh` — the boot/replug loop (also runs standalone from
  `/data/adb/service.d/`); auto-detects UDC/gadget/config, loads optional
  per-device `wire-uplink.conf`
- `diagnose.sh` — one-shot compatibility report for new devices (run before
  installing; no binder/loops — it cannot hang)
- `wire-uplink.conf.example` — per-device override keys (UDC, GADGET, CFG,
  NCM, INTERVAL, HAL1, HAL2)
- `package.sh` — builds the Magisk module zip into `../dist/`

## Adding a device to the fleet

1. On the new phone: `su -c 'sh diagnose.sh'` — attach the output.
2. If READY: install (zip or standalone) + reboot; verify
   `tail /data/local/tmp/wire-uplink.log` after boot shows `armed`.
3. If NOT READY: the failing gate tells you what. Try a config override
   before changing code; open an issue with the diagnose output either way so
   the module learns the new layout in the next version.

## Version history

- v0.3.0 — multi-device groundwork: `diagnose.sh` gate checker,
  sysfs-first UDC discovery, configfs-mount fallback, per-device
  `wire-uplink.conf` overrides, INTERVAL config, `package.sh` zip builder.
  Verified reload on the Pixel 10a.
- v0.2.0 — portability: auto-detect UDC/gadget/config; self-owned NCM
  instance (`ncm.wire`) created on arm; qmult set+verified by the script;
  bind now verified (silent no-op caught); fixed the log's stale-name
  double-prefix. Verified cold-start + replug on the Pixel 10a.
- v0.1.1 — fixed cold-start: stale ncm function instances from earlier runs
  pinned the usbN name and made the UDC bind fail silently; the script now
  removes stale instances on every arm. Also: bind requires UDC unbound
  first (configfs refuses link replacement while bound).
- v0.1.0 — first verified release (Sep 30, 2026): ~12 s replug re-arm,
  ~400 Mbps over the wire, 3-strike adb fallback.

## References

- War story (both halves, measured): [Series 9, part 5 — the cable
  war](https://gist.github.com/ebowwa/34b3ed7768952b4c4a1b9e46a2bc5648)
- Companion issue (fresh-device validation gaps): this repo's
  [issue #1](https://github.com/ebowwa/android17-tbnetbridge/issues/1)