# Contributing to android17-tbnetbridge

Root-first, measured-only. Every feature here shipped as a verified number on
a real device before it is called done — the lab-note rule ("measured or it
doesn't ship") applies to every PR.

## The short version

- Fork, branch, PR against `main`. Keep commits small and honest.
- Every change must run `diagnose.sh` on at least one device and the log must
  show `armed: ... carrier=1` before/after.
- No device-identifying data in code, docs, or commit messages: no MACs, no
  LAN/tailnet IPs, no machine names, no serials. The README's scrub rules are
  the review gate.
- Open a [compatibility issue](https://github.com/ebowwa/android17-tbnetbridge/issues)
  with the `diagnose.sh` output when a new device doesn't pass — that output
  is the single most useful artifact you can contribute.

Related: this module is the Android half of a two-part feature. The macOS
half (Gauge + TBNetBridge plugin) is distributed separately —
https://secondsee.com/downloads/gauge. See the README's License section.

## The insane additions (the task list)

These are the features worth building, hardest first. Each is grounded in a
wall measured during the cable war; each is a self-contained PR-sized chunk.

### Tier 1 — push past the measured ceilings

- **Enable hardware checksum offload on the NCM gadget.** The wire runs at
  ~400 Mbps because the gadget has no tx/rx checksum offload (measured: off
  [fixed], software-checksummed every packet; 5 Gbps wire, 0.4 Gbps
  practical). Options: kernel module param on supported dwc3 kernels,
  ethtool-unlock attempt, or a kernel patch + Magisk kernel-module zip.
  Success = single-stream > 1 Gbps on the same phone. This is the biggest
  single unlock in the project.
- **Two-way wire.** Make the phone's cellular available to the mini over the
  same cable (reverse of the current direction), NAT'd out the mini's Wi-Fi
  when its ethernet uplink dies. The full duplex the cable is capable of.
- **Multi-phone multi-cable aggregation.** N phones on N cables to the same
  mini, each its own /24, pf multipath or ECMP across them. Turns the wire
  array into one load-balanced uplink. Needs a per-cable management table the
  TBNetBridge plugin can read.

### Tier 2 — remove the hacks, keep the result

- **Zygisk/root framework patch instead of the rename dance.** The reason we
  rename `ncmN`→`usb0` is Android's EthernetNetworkFactory filter
  `(usb|eth)\d+` (measured: empty "Tracking interfaces:" until renamed). A
  Zygisk module that patches EthernetTracker to accept ncm interfaces would
  delete the rename path entirely and make ANY gadget name adoptable.
- **udev/uevent-driven re-arm instead of the 5 s poll.** The daemon polls
  `/sys/class/udc/$UDC/state` every 5 s (measured re-arm ~12 s). Listening on
  netlink uevents would re-arm within ~1 s of a replug — near-zero-downtime
  unplug/replug. The poll remains as the fallback watchdog.
- **Boot-time race hardening.** The HAL may start after the module's
  service.sh on slow boots; the freeze-then-wire order assumes the HAL exists.
  Gate arming on "HAL process present" with a bounded wait, and persist the
  last-good state so a reboot re-arms from known-good instead of scanning.

### Tier 3 — automation and ergonomics

- **Wi-Fi kill-switch orchestration.** The original vision: when the wire is
  validated, disable Wi-Fi; on wire loss, re-enable it. Wire state →
  `cmd wifi set-wifi-enabled` transitions, with hysteresis so a flapping cable
  doesn't toggle Wi-Fi repeatedly.
- **Throughput telemetry.** Periodic iperf-style probe over the wire; expose
  `{mbps_down, mbps_up, latency, state}` in `/data/local/tmp/wire-uplink.json`
  so the mini's TBNetBridge plugin can render the wire's live health instead
  of only link state.
- **Config GUI.** A tiny local surface (`wire-uplink.conf` editor) so adding a
  device override isn't a text-editor task on-device.
- **Magisk-Modules-Repo release.** Package the zip for community install
  (id stays `android17tbnetbridge`); CI that builds + signs the release zip.

## Cross-device maintenance / support

This module must earn "runs on YOUR device", not assume it. The contract:

### The device qualification loop

1. Run `diagnose.sh` on the new device. Attach the output to a
   [compatibility issue](https://github.com/ebowwa/android17-tbnetbridge/issues)
   — this is the primary contribution; it feeds the matrix below.
2. If `READY` → install (zip or standalone), reboot, and confirm
   `tail /data/local/tmp/wire-uplink.log` shows `armed` within ~60 s.
3. If `NOT READY` → the failing gate tells you the class of problem. Try a
   `wire-uplink.conf` override (UDC/GADGET/CFG/NCM/INTERVAL keys) **before**
   touching code; only change code when an override cannot express the fix.
4. Record the result in the device matrix (below) — every qualified device
   becomes the regression reference for its layout class.

### The device matrix (extend with each qualification)

| device | Android | rooted-by | UDC | configfs mount | gadget | ncm support | HAL names | overrides needed | result |
|---|---|---|---|---|---|---|---|---|---|
| Pixel 10a | 17 | Magisk 30.7 | 11210000.dwc3 | /config | g1 | ncm.wire self-owned | android.hardware.usb.{gadget-,}service | none | READY |

### Known variance classes (gates to keep an eye on)

- **configfs mount point**: `/config` (AOSP default) vs `/sys/kernel/config`
  (older or custom kernels). The fallback is code; it wants a real device to
  prove it.
- **UDC naming**: `*dwc3` is one vendor layout; xhci/other SoCs differ. The
  sysfs discovery reads `/sys/class/udc/*` — fine, but the getprop fallback
  (`sys.usb.controller`) is vendor-optional and must not become the only
  source.
- **USB HAL naming**: `android.hardware.usb.gadget-service` and
  `android.hardware.usb-service` are the AOSP names; OEMs ship vendor HALs
  (Samsung/Xiaomi/OnePlus variants). `pidof` candidates in `diagnose.sh` are a
  heuristic — extend the list rather than assume.
- **qmult writability**: some kernels lock qmult after first instantiation
  (measured on one instance; the module's own instance avoids it). A device
  where the lock is global needs the qmult step made non-fatal.
- **Magisk version drift**: module.prop conventions shift; test the zip across
  Magisk versions, not just the one it was built under.
- **Android version drift**: EthernetTracker's filter and netd behavior change
  per release — Android 14/15/16/17 need at least a smoke qualification,
  because the rename-to-usb0 rule is tuned to current behavior.

### Maintenance duties

- Keep `diagnose.sh` the source of truth for gates; code changes that add a
  new assumption MUST add a corresponding gate.
- Keep the zip build green: `sh package.sh` must succeed and the unzip listing
  must match the repo tree.
- Scrub discipline on every commit: MAC/IP/machine-name patterns are banned in
  code, docs, and messages (the repo flipped public; history rewrite is not a
  maintenance habit).
- Refresh the matrix when a device drops off or an OS update changes a gate.

## Definition of done

- Log line `armed: <dev> carrier=1` on at least one device.
- `diagnose.sh` passes on that device (or the failure is a documented, filed
  device-class gap).
- `sh package.sh` builds.
- No scrub violations; no new private-repo or machine references.