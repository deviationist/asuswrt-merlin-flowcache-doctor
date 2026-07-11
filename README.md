# asuswrt-merlin-flowcache-doctor

**Detects (and will soon auto-heal) the Broadcom flow-cache roam blackhole on
Broadcom-based Asus routers: a Wi-Fi client roams between bands, and traffic
between that client and *specific* LAN hosts silently dies until the router's
flow cache is flushed.**

The bug is in Broadcom's driver, not in any firmware's own code — **stock
AsusWRT and [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) are equally
affected** (Merlin ships the Wi-Fi stack unmodified from Asus's GPL drops).
Merlin is simply where the *fix* can live, since only Merlin lets you run
user scripts on the router — see *Requirements*.

Developed and validated live on an **RT-BE92U** (BCM6765, Merlin 3006.102.8).
The underlying bug lives in Broadcom's closed-source driver blobs, so it very
likely affects **other Broadcom-based Asus routers** too — the Wi-Fi 7 BE-series
(RT-BE96U, RT-BE88U, GT-BE98…) shares the same SDK, and ancestor reports of the
same failure shape exist for AX-era models. If you see the symptoms below on
another model, please open an issue with your model + firmware version.

## Symptoms — how to recognize this bug

After a Wi-Fi client roams between bands (e.g. 5 GHz ↔ 6 GHz under Smart
Connect), typically **20 seconds to 3 minutes later**:

- The client can no longer reach **specific wired LAN hosts** — while other
  hosts, the router itself, and the internet keep working.
- **SSH connects and shows the banner, then freezes** — new TCP connections
  open (first packets take the router's slow path) and die the moment the
  flow is promoted into the poisoned accelerator.
- **`traceroute` to the dead host often works while `ping` fails 100%** —
  short-lived flows never live long enough to be accelerated.
- Wired↔wired traffic between the same hosts is unaffected.
- The problem **never heals on its own** (a code-level quirk actively
  refreshes the stale state), but **roaming back** to the original band can
  make it vanish — the stale binding becomes accidentally correct again.
- `fc flush` / `fcctl flush` on the router fixes it **instantly**. So does
  rebooting the router. Nothing on the affected client or LAN host helps —
  the corruption lives entirely in the router.

## What's actually broken

On Broadcom SoCs, forwarding is accelerated by a flow cache (fcache →
Archer/Crossbow on the BE92U's BCM6765): the first packets of a flow traverse
the full Linux slow path, then a per-flow entry — **pinned at learn time to the
client's radio** (via the pktfwd `d3lut` station table) — short-circuits the
kernel for everything after.

The driver has eviction hooks that are supposed to destroy those entries when
a client roams to another radio. A race can miss them. Worse, the bridge-FDB
aging logic is **inverted**: it asks the accelerator whether the flow saw
traffic and *refreshes* the stale entry if so — stale state that keeps eating
packets keeps re-validating itself. The kernel's own bridge/ARP tables stay
correct the whole time; they're simply not consulted anymore.

No fix exists as of Merlin **3006.102.8** / stock GPL `102_39063`. ASUS is
reportedly aware (relayed via the Merlin team on SNB Forums). The Wi-Fi stack
is closed Broadcom SDK code, so a real fix can only arrive inside a future
GPL blob merge. Until then: this project.

## Requirements — Asuswrt-Merlin

**[Asuswrt-Merlin](https://www.asuswrt-merlin.net/) is required.** The fix
depends on Merlin's user-script hooks (`/jffs/scripts/`, `services-start`),
which stock AsusWRT does not offer — stock firmware gives you no sanctioned
way to run anything at boot.

The bug itself affects stock AsusWRT just the same (same Broadcom blobs). If
you're on stock, your options are rebooting the router whenever it happens —
or switching to Merlin, which we'd encourage anyway: same Asus UI and feature
set, plus user scripts, better VPN support, proper cron (`cru`), Entware
support, and an actively maintained changelog. This tool is one more reason.

Also required: SSH access to the router (Administration → System → Enable
SSH) and **JFFS custom scripts** enabled (Administration → System → Enable
JFFS custom scripts and configs = Yes).

## What it does today (phase 1 — detect & log)

A small daemon (`roam-detect.sh`) iterates every 2 s and compares, for every
associated Wi-Fi client:

- **truth**: which radio the client is actually associated to
  (`wl -i <bss> assoclist`), against
- **belief**: which bridge port the forwarding layer maps its MAC to
  (`brctl showmacs br0`).

It logs to the router's syslog (tag `roam-detect`):

```
roam-detect: ROAM aa:bb:cc:dd:ee:ff wl1.1 -> wl2.1
roam-detect: STALE-FDB aa:bb:cc:dd:ee:ff assoc=wl1.1(port 6) fdb=port 8 <- WOULD FLUSH: fcctl flush --mac aa:bb:cc:dd:ee:ff
roam-detect: RECOVERED aa:bb:cc:dd:ee:ff fdb now matches wl1.1
```

Phase 2 (planned, opt-in): actually run the `fcctl flush --mac` it currently
only logs — the exact per-client invalidation the driver fails to do, with
zero impact on other clients (flows re-learn through the correct path
immediately). Also planned: event-driven detection via `wlceventd`
(`nvram set wlceventd_msglevel=1` surfaces per-assoc syslog events), which
closes the polling detector's known blind spots (see *Limitations*).

## Setup: SSH access to your router

After installing Asuswrt-Merlin, log in to the web UI and go to
**Administration → System**:

1. Set **Enable JFFS custom scripts and configs** to **Yes**.
2. Set **Enable SSH** to **LAN only** (resist "LAN + WAN" unless you really
   know what you're doing — WAN-exposed SSH on a router is asking for
   trouble).
3. Strongly consider pasting your workstation's **public key** into
   *Authorized Keys* and setting *Allow SSH password login* to **No**.
4. Hit **Apply**. (If JFFS scripts were off, a reboot may be needed.)

Then from your workstation:

```sh
ssh <router-username>@<router-ip>
```

using the same username/password as the web UI (or your key, if you added
one).

## Install

One command, run on the router over that SSH session:

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

The installer verifies JFFS scripts are enabled, fetches the two scripts into
`/jffs/scripts/`, wires the boot hook and the once-a-minute crash watchdog
into `services-start` + cron (idempotently — safe to re-run), and starts the
daemon. Uninstalling is just as clean:

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh | sh -s uninstall
```

If your SSIDs don't live on `wl0.1`/`wl1.1`/`wl2.1` (varies by model and
config — list bridge members with `ls /sys/class/net/br0/brif/`), edit
`BSSLIST` at the top of `/jffs/scripts/roam-detect.sh` after installing.

<details>
<summary>Manual install (no curl-pipe-sh)</summary>

```sh
scp scripts/roam-detect.sh scripts/roamctl router:/jffs/scripts/
ssh router
  chmod a+rx /jffs/scripts/roam-detect.sh /jffs/scripts/roamctl
  cat >> /jffs/scripts/services-start <<'EOF'
/jffs/scripts/roamctl boot
cru a roam-detect-wd "* * * * * /jffs/scripts/roamctl watchdog"
EOF
  chmod a+rx /jffs/scripts/services-start
  /jffs/scripts/roamctl start
  cru a roam-detect-wd "* * * * * /jffs/scripts/roamctl watchdog"
```
</details>

## Usage

```
roamctl status          # running? current policy?
roamctl log             # last 30 detection events (from syslog)
roamctl stop            # stop + disarm watchdog (until start or reboot)
roamctl start           # start + re-arm watchdog
roamctl restart         # bounce the daemon
roamctl policy off|on   # persistent master switch (survives reboots)
```

Supervision model (systemd-ish, with busybox means):

| systemd | here |
|---|---|
| start at boot | `services-start` → `roamctl boot` |
| `Restart=on-failure` | cron watchdog every 60 s (`cru`) |
| `systemctl stop` | `roamctl stop` (runtime flag disarms watchdog) |
| `systemctl disable` | `roamctl policy off` (persists on JFFS) |
| `journalctl` | `roamctl log` (RAM-backed syslog) |

## Manual fix, when it strikes

```sh
ssh router 'fcctl flush --mac <client-mac>'  # surgical — proven sufficient
ssh router 'fcctl flush --if <bss>'          # one radio
ssh router 'fcctl flush'                     # everything (the classic cure)
ssh router 'fcctl flush --hw'                # include HW accelerator entries
```

(`fc` is a symlink to `fcctl`; prefer `fcctl` — `fc` collides with a shell
builtin.)

## Capturing evidence (`extras/blackhole-probe-pack.sh`)

If you want to help confirm this bug on more models: run the probe pack from
the affected client **while the blackhole is live, before flushing**. It
captures the client's view (ARP/ping/traceroute), the router's flow tables
(`fcctl dump`, `archerctl flows`), bridge FDB + port map, and per-radio
station state — the exact stale-binding evidence. Set the CONFIG variables at
the top first. Then consider posting your capture in the
[RMerlin RT-BE92U feedback thread](https://www.snbforums.com/threads/looking-for-feedback-rt-be92u-stability-issues.96798/).

## Limitations (honest ones)

- `wl assoclist` — the polling detector's truth source — can go blind during
  rapid roam storms, missing events (observed). The planned `wlceventd`
  event-driven trigger fixes this properly.
- Flow-level staleness **without** an FDB-level mismatch exists (observed
  once): the per-MAC comparison can't see it. A roam-triggered flush (phase
  2) covers it; pure table-diffing cannot.
- A client transiently listed on two radios at once makes v1 flap
  ROAM/RECOVERED pairs — noisy but harmless.
- BSS interface names vary by model/config — set `BSSLIST` accordingly.

## Alternative workarounds

- **Split your SSIDs per band** (give 6 GHz its own SSID). On BE-series
  routers one SSID on multiple bands *is* Smart Connect — there is no toggle;
  splitting is the only off-switch. No roams → no bug. Deterministic, zero
  moving parts, at the cost of manual band choice per device.
- **Disable flow cache entirely**: `nvram set fc_disable_force=1; nvram
  commit` + `fcctl disable` (a bare `fc disable` gets silently re-enabled by
  the QoS startup code). Cures the class at a CPU/throughput cost.
- **Disable Roaming Assistant** — reduces router-forced roams; does nothing
  about client-initiated ones. Partial at best.

## Similar reports in the wild

The roam→blackhole family shows up across Asus Broadcom models and firmware
generations — usually without the flow-cache connection being made:

- [SNB: RT-BE92U New Merlin Firmware (p.3)](https://www.snbforums.com/threads/rt-be92u-new-merlin-firmware.94409/page-3)
  — relay that ASUS is aware of "the bug in the Broadcom chip in these
  routers," reported to them by the Merlin team; interim advice was disabling
  Roaming Assistant.
- [SNB: BE92U roaming issues between 5/6 GHz bands](https://www.snbforums.com/threads/be92u-roaming-issues-between-5-6ghz-bands.96990/)
  — same trigger (5↔6 GHz roam), client-level blackhole.
- [SNB: Host wired to node temporarily inaccessible when roaming (AiMesh, RT-AX92U)](https://www.snbforums.com/threads/host-wired-to-node-temporarily-inaccessible-when-roaming-on-aimesh.85967/)
  — the AX-era ancestor: roam → *one specific wired host* unreachable for
  minutes, everything else fine.
- [ZenTalk: BQ16 Pro — same Broadcom Wi-Fi driver bugs, `dhd_pktfwd_lut_lkup` pool/unit mismatch](https://zentalk.asus.com/t5/networking/bq16-pro-same-broadcom-wifi-driver-bugs-dhd-pktfwd-lut-lkup-get/td-p/508436)
  — kernel-level evidence of the stale station-table race on the same SoC
  family (stock firmware).
- [ZenTalk: BE92U Smart Connect combined 5/6 GHz — multiple issues](https://zentalk.asus.com/t5/networking/be92u-smart-connect-with-combined-5-6ghz-network-multiple-issues/td-p/506213)
  — stock-firmware users hitting instability with the same band-steering
  setup.
- [SNB: RMerlin on the Wi-Fi stack ("Wifi comes from Broadcom's SDK")](https://www.snbforums.com/threads/big-wifi-issue-with-latest-firmware.95749/)
  — why no firmware fork can fix this directly.
- [SNB: Disable flow cache](https://www.snbforums.com/threads/disable-flow-cache.73330/)
  — background on the `fc`/`fcctl` acceleration layer and disabling it.
- [SNB: Asuswrt-Merlin 3006.102.8 release thread (p.4)](https://www.snbforums.com/threads/asuswrt-merlin-3006-102-8-is-now-available.97535/page-4)
  — the *adjacent* Guest-Network-Pro/AP-Isolation LAN-blackhole bug, easily
  confused with this one (we ruled it out by experiment: disabling AP
  isolation did not stop the roam blackhole).

If your case matches, consider posting your `probe-pack` capture in the
[RMerlin RT-BE92U feedback thread](https://www.snbforums.com/threads/looking-for-feedback-rt-be92u-stability-issues.96798/)
— that's the channel that reaches ASUS.

## Credits & sources

- Mechanism analysis draws on the Broadcom driver sources visible in the
  [RMerl/asuswrt-merlin.ng](https://github.com/RMerl/asuswrt-merlin.ng) tree
  (`wl_pktfwd.c`, `wl_br_d3lut.c`, `wl_blog.c`, `bcm_br_fdb.c`) and the
  `fcctl`/`archerctl` prebuilts in the RT-BE92U build profile.
- Community context: SNB Forums threads on RT-BE92U stability and roaming
  issues; ZenTalk reports of `dhd_pktfwd_lut_lkup` pool/unit-mismatch races.
- Not affiliated with ASUS, Broadcom, or the Asuswrt-Merlin project. Merlin
  deliberately does not modify the Wi-Fi stack ("Wifi comes from Broadcom's
  SDK") — no blame there; this tool exists to bridge the gap until a fixed
  SDK ships.
