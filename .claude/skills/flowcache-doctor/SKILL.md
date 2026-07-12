---
name: flowcache-doctor
description: Diagnose and fix the Broadcom flow-cache roam blackhole on ASUS routers — use when a specific LAN host (NAS, Plex, printer, server) is suddenly unreachable from a Wi-Fi device while everything else works, especially after moving around the house, or when SSH connects and shows a banner but then freezes. Guides diagnosis over SSH to the router, the one-command temporary fix, and installing the automatic fix (requires Asuswrt-Merlin).
---

# flowcache-doctor — diagnosis & fix guide

You are helping the user determine whether they're hitting the Broadcom
flow-cache roam blackhole (see this repo's README for the full mechanism),
and if so, fix it. Work stepwise; report findings between steps. Everything
router-side happens over SSH — ask the user for their router address and SSH
username if not known. Never run a global `fcctl flush` without telling the
user first; prefer per-MAC operations.

## 1. Symptom triage (no tools needed)

Strong signals (all should hold):
- ONE specific LAN host is unreachable from ONE Wi-Fi client; other hosts and
  the internet work from the same client, and the "dead" host is fine from
  other machines (verify via a second device if available).
- The client roamed recently: moved rooms, or Wi-Fi shows a different band
  than before (macOS: Option-click the Wi-Fi icon — 5 GHz vs 6 GHz channel;
  channels 1-13 = 2.4 GHz, 32-177 = 5 GHz, 6 GHz shown explicitly).
- SSH/TCP to the dead host connects then freezes (banner, then nothing), or
  times out; ping shows 100% loss.
- Router is Broadcom-based ASUS (Wi-Fi 7 BE-series especially; AX also seen).

Counter-signals (investigate other causes instead): the host is down for
everyone; wired clients also affected; the whole internet is down; it never
recovers after a router reboot.

## 2. Confirm the anatomy (from the affected client)

```sh
ping -c 3 <dead-host-ip>          # expect: 100% loss
arp -n <dead-host-ip>             # expect: MAC resolved (ARP works!)
traceroute -w 2 -m 4 <dead-host-ip>  # often WORKS while ping fails — flow-selective
```

ARP resolving + ping dead + traceroute alive = textbook. (Traceroute probes
are short-lived flows that never get promoted into the broken fast path.)

## 3. Router-side proof (SSH to the router)

Requires SSH enabled: router web UI → Administration → System → Enable SSH =
LAN only. Then, with the client's Wi-Fi MAC (macOS: `ifconfig en0 | grep
ether`; the router's client list also shows it):

```sh
# which radio is the client REALLY on?
for i in /sys/class/net/br0/brif/wl*; do b=$(basename $i); echo "-- $b"; wl -i $b assoclist; done
# which port does the forwarding layer THINK it's on?
brctl showmacs br0 | grep -i <client-mac>
for f in /sys/class/net/br0/brif/*/port_no; do echo "$f: $(cat $f)"; done
```

If the FDB port maps to a different radio than the assoclist shows the
client on — that's the stale binding, photographed. (Absence of a mismatch
does NOT clear the diagnosis: flow-level-only staleness exists. The flush
test below is the decisive check either way.)

## 4. The decisive test — surgical flush

```sh
# on the router, while the problem is live:
fcctl flush --mac <client-mac>
```

Then immediately re-test from the client (`ping <dead-host-ip>`). Instant
recovery = diagnosis CONFIRMED; nothing else produces that signature. If
per-MAC doesn't cure within ~5 s, escalate once: `fcctl flush` (global —
harmless, connections re-learn) and re-test. Recovery after either = same
family. No recovery = different problem; stop here and investigate normally.

## 5. The permanent fix

Requires Asuswrt-Merlin (stock firmware can't run user scripts — if the user
is on stock, point them to https://www.asuswrt-merlin.net/ and this repo's
README "Requirements" section). Verify JFFS scripts: `nvram get
jffs2_scripts` must be `1` (else: web UI → Administration → System → Enable
JFFS custom scripts and configs = Yes → Apply).

Install (on the router):

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

Fresh installs heal automatically out of the box (per-MAC, rate-limited,
never global). If the user prefers to observe before trusting, offer
audit-only mode — detection keeps logging `WOULD FLUSH` lines without
acting:

```sh
/jffs/scripts/roamctl flush off   # audit-only; re-arm with: flush on
```

Verify: `/jffs/scripts/roamctl status` (running, policy on, autoflush as
chosen) and `/jffs/scripts/roamctl log` (a "starting" line; later ROAM /
STALE-FDB / FLUSHED events as roams happen).

## 6. Ongoing / troubleshooting

- What has it seen? `ssh <router> '/jffs/scripts/roamctl log'`
- Daemon lifecycle: `roamctl start|stop|restart|status`, persistent disable:
  `roamctl policy off`, remove entirely: `roamctl uninstall`.
- Deep evidence capture for a live incident (before any flush — useful for
  bug reports upstream): run `extras/blackhole-probe-pack.sh` from the
  affected client after setting its CONFIG variables.
- Interface names differ per model: `BSSLIST` at the top of
  `/jffs/scripts/roam-detect.sh` must match the SSID-carrying BSS interfaces
  (`ls /sys/class/net/br0/brif/`).
