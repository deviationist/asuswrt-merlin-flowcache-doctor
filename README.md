# asuswrt-merlin-flowcache-doctor

> **Not a technical person?** No problem — skip ahead to
> [what this bug feels like in daily life](#in-plain-words--what-this-bug-feels-like),
> written for humans, not network engineers.

Broadcom-based ASUS routers accelerate LAN traffic through a per-flow cache
instead of running every packet through the kernel. When a Wi-Fi client roams
between bands (5 GHz ↔ 6 GHz under Smart Connect), a race in Broadcom's
closed-source driver can leave that client's cached forwarding entries pinned
to the radio it just left — and an inverted aging check keeps the stale
entries alive indefinitely. The result: traffic between that client and
*specific* LAN hosts silently blackholes — brand-new connections included —
until the router's flow cache is flushed. The bug lives in Broadcom's driver
blobs, so **stock ASUSWRT and [Asuswrt-Merlin](https://www.asuswrt-merlin.net/)
are equally affected**, and no firmware fix exists as of Merlin 3006.102.8.

**This repo is the doctor.** A tiny supervised daemon for Asuswrt-Merlin
(Merlin is required — only it can run user scripts; see *Requirements*) that
watches every Wi-Fi client for roams and the resulting stale forwarding
state and heals automatically, out of the box: a surgical
`fcctl flush --mac` of just the affected client, the exact invalidation the
driver misses. Never a global flush, rate-limited per client, and an
audit-only mode (`roamctl flush off`) for those who want to watch before
trusting. Plus the
diagnostics to confirm you're hitting this bug at all, and a bundled
[Claude Code skill](#claude-code-skill) for AI-assisted diagnosis.
Developed and validated live on an **RT-BE92U** (BCM6765, Merlin
3006.102.8); the Wi-Fi 7 BE-series shares the same SDK and AX-era ancestors
of the bug are on record, so if you match
[the symptoms](#symptoms--how-to-recognize-this-bug-technical) on another
model, please open an issue with your model + firmware.

## Start here

| If you want… | Go to |
|---|---|
| *"Is this my problem?"* — how the bug feels in daily life | [In plain words](#in-plain-words--what-this-bug-feels-like) |
| The technical symptom fingerprint | [Symptoms](#symptoms--how-to-recognize-this-bug-technical) |
| Proof in one command (doubles as the temporary fix) | [Quick self-test](#quick-self-test--confirm-you-have-this-bug-in-one-command) |
| Background: what a flow cache is and why it exists | [What is a flow cache, anyway?](#what-is-a-flow-cache-anyway) |
| The root-cause deep dive | [What's actually broken](#whats-actually-broken) |
| The permanent fix: install the doctor | [Setup](#setup-ssh-access-to-your-router) → [Install](#install) |
| Similar cases across models | [Similar reports](#similar-reports-in-the-wild) |

## In plain words — what this bug feels like

You're on Wi-Fi, full bars, internet works fine. But suddenly **one** device
on your network is gone: your NAS won't open, Plex won't load, your smart-home
dashboard times out, you can't reach the printer. Everything *else* still
works — which makes it maddening. You reboot your laptop: nothing. You forget
and rejoin Wi-Fi: nothing. You start blaming the NAS, reboot *it*, reinstall
apps, check cables — nothing, because the NAS was never the problem. Then at
some point you reboot the router and everything magically works again… until
a few days later, when it happens again. Usually right after you carried your
laptop or phone to another room.

That's this bug. Your router's Wi-Fi chip has a bookkeeping error: when your
device hops between Wi-Fi bands (which it does silently as you move around),
the chip sometimes keeps delivering that device's traffic to where you *used*
to be. The affected connection is then a black hole — and the chip actively
refuses to notice. Nothing you do on your laptop or your NAS can fix it,
because the broken state lives inside the router.

The good news: it can be fixed in one second, without a reboot, by telling
the router to forget its bad bookkeeping (`fcctl flush`). This project makes
the router detect the situation and do exactly that, automatically.

## Symptoms — how to recognize this bug (technical)

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

## Quick self-test — confirm you have this bug in one command

While the problem is happening (the host is unreachable *right now*), SSH to
your router (see *Setup* below) and run:

```sh
fcctl flush
```

or from your workstation in one line:

```sh
ssh <router-username>@<router-ip> 'fcctl flush'
```

This flushes the router's flow cache — the "temporary fix." It's harmless:
no reboot, no dropped Wi-Fi, connections just re-learn their path through the
router's normal slow path within a second or two.

**If the dead host becomes instantly reachable again, you have this bug** —
nothing else produces that signature (a reboot also "fixes" it, but a reboot
fixes everything and proves nothing; the flush is surgical evidence). Repeat
offenders should then install the doctor so this happens automatically.

On older firmware the binary may be exposed as `fc` (`fc flush`) — same
tool; `fc` is a symlink to `fcctl`.

## What is a flow cache, anyway?

Consumer routers advertise multi-gigabit Wi-Fi and WAN speeds, but their ARM
SoCs are far too slow to push that through the full Linux network stack —
bridging, FDB/ARP lookups, netfilter/NAT, routing cost thousands of CPU
cycles *per packet*. At Wi-Fi 7 / 2.5 GbE rates that's simply impossible in
software.

So chip vendors bolt on a **fast path**. The first packet of any new flow
(a connection, roughly: src/dst MAC + IP + port) traverses the full kernel
stack the slow, correct way. The flow engine watches the result and records
it as a flow entry — essentially *"packets matching this signature: apply
these header rewrites, send out this interface"* — where the egress can be a
specific ethernet port or a specific Wi-Fi radio. Every subsequent packet of
that flow matches the entry and gets forwarded directly, skipping the kernel
entirely. On the RT-BE92U's BCM6765 this stack is `fcache` (software flow
table) → Archer (software accelerator) → Crossbow (full hardware offload);
other Broadcom SoCs use a sibling called Runner. That skip is what buys the
advertised throughput — and it's why disabling the flow cache entirely (a
legitimate workaround, see below) costs peak speed.

The property that matters for this bug: **once an entry exists, the fast
path never re-consults the kernel's bridge or ARP tables.** Not consulting
them is the entire point — every consultation avoided is the saving. The
kernel can know the truth perfectly (it does — we verified it live) while
the fast path keeps executing a decision cached from a world that no longer
exists. A cache without a working invalidation story is a time bomb; the
next section is about the invalidation story breaking.

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
reportedly aware — per a
[community relay on SNB Forums (July 2025)](https://www.snbforums.com/threads/rt-be92u-new-merlin-firmware.94409/page-3):
*"Asus is aware of the bug in the Broadcom chip in these routers, and the
Merlin team has reported it directly to Asus"* (a member's account, not an
official ASUS or RMerlin statement — hence "reportedly"). The Wi-Fi stack
is closed Broadcom SDK code, so a real fix can only arrive inside a future
GPL blob merge. Until then: this project.

## Requirements — Asuswrt-Merlin

**[Asuswrt-Merlin](https://www.asuswrt-merlin.net/) is required.** The fix
depends on Merlin's user-script hooks (`/jffs/scripts/`, `services-start`),
which stock ASUSWRT does not offer — stock firmware gives you no sanctioned
way to run anything at boot.

The bug itself affects stock ASUSWRT just the same (same Broadcom blobs). If
you're on stock, your options are rebooting the router whenever it happens —
or switching to Merlin, which we'd encourage anyway: same ASUS UI and feature
set, plus user scripts, better VPN support, proper cron (`cru`), Entware
support, and an actively maintained changelog. This tool is one more reason.

Also required: SSH access to the router (Administration → System → Enable
SSH) and **JFFS custom scripts** enabled (Administration → System → Enable
JFFS custom scripts and configs = Yes).

## What it does

A small daemon (`roam-detect.sh`) iterates every 2 s and compares, for every
associated Wi-Fi client:

- **truth**: which radio the client is actually associated to
  (`wl -i <bss> assoclist`), against
- **belief**: which bridge port the forwarding layer maps its MAC to
  (`brctl showmacs br0`).

It logs to the router's syslog (tag `roam-detect`):

```
roam-detect: ROAM aa:bb:cc:dd:ee:ff wl1.1 -> wl2.1
roam-detect: STALE-FDB aa:bb:cc:dd:ee:ff assoc=wl1.1(port 6) fdb=port 8 (persistent)
roam-detect: FLUSHED aa:bb:cc:dd:ee:ff (roam wl1.1->wl2.1)
roam-detect: RECOVERED aa:bb:cc:dd:ee:ff fdb now matches wl1.1
```

**Auto-heal (on by default for fresh installs):** on every detected roam —
and on any stale binding that persists across two passes — the daemon runs
`fcctl flush --mac <that client>`: strictly per-client (never a global
flush) and harmless by construction (that client's flows re-learn through
the correct slow path within a second). Flushes are rate-limited with a
**band-aware cooldown**: one flush per client per 60 s on the same radio,
but a roam onto a *different* radio bypasses the cooldown (the settle-roam
after a steering storm must always heal), with a hard 8 s floor so rapid
flapping can't turn the bypass into a flush storm. Skeptics can switch to
audit-only mode with `roamctl flush off` — detection keeps running and logs
`WOULD FLUSH` lines showing exactly what it *would* have done (re-arming is
`roamctl flush on`; reinstalls and updates respect your choice). Clients
transiently listed on two radios at once (a driver artifact during steering
churn) are parked in a `DUAL` state and left alone until they settle — and
**healed on settle even when the churn nets out to the same radio** (a
there-and-back bounce is invisible to net-roam detection and leaves no FDB
symptom, but the eviction race runs during it all the same; observed in the
wild 2026-07-12).

**Event listener (on by default when available):** a second heal source,
`roam-events.sh`, tails the driver's own association log
(`/jffs/wifi_wlc.log`, written by `wlceventd` by default on this firmware)
and heals a client **within ~1 second** of a successful (re)association —
faster than the poller's 2 s floor and immune to its storm blind spots.
Both sources share per-client cooldown state, so they cooperate rather than
double-flush; if the event feed dies, the poller still covers everything it
always did. The listener enables itself only when the firmware actually
provides the event log — on builds without `/jffs/wifi_wlc.log` it stands
down with a log line and the poller carries everything (disable explicitly
with `EVENT_HEAL=0` in the conf). One caution baked into the design:
`wlceventd` only emits events when started by init — if it's ever killed and
restarted from a shell it goes silent, and only `service restart_wireless`
(or a reboot) restores the feed. Cross-radio flushes suppressed by the
anti-storm floor leave a *pending marker* that the poller retries seconds
later (covers rapid multi-hop reconnects like off → 2.4 GHz → 6 GHz).

## Claude Code skill

The repo ships a [Claude Code](https://claude.com/claude-code) skill at
`.claude/skills/flowcache-doctor/`. Clone the repo, open Claude Code in it,
and ask something like *"my NAS is unreachable from my laptop but works from
everything else — is this the flow-cache bug?"* — Claude walks the full
triage: symptom checks, the ARP/ping/traceroute anatomy, router-side proof,
the decisive per-MAC flush test, and (if confirmed) installing this fix.

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

### Guided setup (easiest — run on your computer, not the router)

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/setup.sh | sh
```

It asks for your router's address and SSH username (ssh itself prompts for
the password if you haven't set up keys), verifies the router is ready
(JFFS scripts enabled), detects whether flowcache-doctor is already
installed, and offers the right action: install, reinstall/repair,
uninstall, or just showing recent detections. Safe to run any number of
times.

### Direct install (run on the router)

One command, over an SSH session on the router itself:

```sh
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

The installer verifies JFFS scripts are enabled, fetches the two scripts into
`/jffs/scripts/`, wires the boot hook and the once-a-minute crash watchdog
into `services-start` + cron (idempotently — safe to re-run), and starts the
daemon.

## Uninstall

Just as clean, three equivalent ways:

```sh
# offline, right on the router (no internet needed):
/jffs/scripts/roamctl uninstall

# or the dedicated script:
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/uninstall.sh | sh

# or via the installer:
curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh | sh -s uninstall
```

All of them stop the daemon, remove both scripts, the cron watchdog, the
`services-start` hooks, the policy file, and runtime state — and nothing
else.

## Will this become unnecessary? Hopefully!

Yes, ideally. The real fix has to come from Broadcom, shipped inside an ASUS
GPL update, merged into a firmware release. ASUS is reportedly aware (see the
sourced quote in *What's actually broken*). When that happens, this tool
becomes redundant — by design, it's a stopgap, not a permanent fixture.

How you'll know: after a firmware upgrade, watch `roamctl log` — if weeks of
roaming produce no `STALE-FDB` lines (where they used to appear), the driver
is likely fixed. The detector doubles as your regression test. Wi-Fi fixes
are rarely mentioned in changelogs (they arrive silently inside GPL blob
merges), so the log is more trustworthy than the release notes.

Until confirmed fixed, the tool is cheap insurance: one idle shell loop, logs
only on real events, and uninstalls in one command.

If your SSIDs don't live on `wl0.1`/`wl1.1`/`wl2.1` (varies by model and
config — list bridge members with `ls /sys/class/net/br0/brif/`), edit
`BSSLIST` at the top of `/jffs/scripts/roam-detect.sh` after installing.

### Manual install (for the tech-savvy — no scripts, full control)

Everything the installer does, by hand, so you know exactly what lands on
your router:

```sh
# 1. Copy the two scripts (from a clone of this repo)
scp scripts/roam-detect.sh scripts/roamctl <user>@<router>:/jffs/scripts/

ssh <user>@<router>

# 2. Permissions (they run as root via cron/boot — keep them non-world-writable)
chmod 755 /jffs/scripts/roam-detect.sh /jffs/scripts/roamctl

# 3. Adapt to your radios if needed: BSSLIST at the top of roam-detect.sh
#    must name the bridge-member BSS interfaces your SSIDs use.
ls /sys/class/net/br0/brif/    # candidates
vi /jffs/scripts/roam-detect.sh

# 4. Boot persistence: Merlin runs /jffs/scripts/services-start at every boot.
#    Two lines: start the daemon (honoring the on/off policy), and register
#    the once-a-minute crash watchdog with Merlin's cron helper (cru).
cat >> /jffs/scripts/services-start <<'EOF'
/jffs/scripts/roamctl boot
cru a roam-detect-wd "* * * * * /jffs/scripts/roamctl watchdog"
EOF
chmod 755 /jffs/scripts/services-start

# 5. Arm it now (same two things, without waiting for a reboot)
cru a roam-detect-wd "* * * * * /jffs/scripts/roamctl watchdog"
/jffs/scripts/roamctl start

# 6. Verify
/jffs/scripts/roamctl status     # daemon pid + policy
cru l | grep roam-detect         # watchdog registered
/jffs/scripts/roamctl log        # "starting (pid ...)" line
```

Complete inventory of what exists after install — and all of it is removed
by any of the uninstall paths:

| Path | What it is |
|---|---|
| `/jffs/scripts/roam-detect.sh` | the detection daemon (one busybox `sh` loop) |
| `/jffs/scripts/roamctl` | lifecycle wrapper (start/stop/status/log/policy/uninstall) |
| `/jffs/scripts/roam-detect.policy` | persistent on/off switch (only if you used `policy`) |
| two lines in `/jffs/scripts/services-start` | boot start + watchdog registration |
| cron entry `roam-detect-wd` | watchdog, every 60 s (RAM, re-added at boot) |
| `/jffs/scripts/roam-events.sh` | wlceventd event listener (default-on when available; `EVENT_HEAL=0` disables) |
| `/tmp/roam-detect/` | per-client state (RAM), shared by both heal sources |
| `/tmp/roam-events.pid` | event listener pidfile (RAM) |
| syslog tag `roam-detect` | all output (RAM-backed log) |

## Usage

```
roamctl status          # running? policy? auto-flush?
roamctl log             # last 30 detection events (from syslog)
roamctl flush on|off    # enable/disable auto-heal (persistent; default off)
roamctl stop            # stop + disarm watchdog (until start or reboot)
roamctl start           # start + re-arm watchdog
roamctl restart         # bounce the daemon
roamctl policy off|on   # persistent master switch (survives reboots)
roamctl uninstall       # remove everything, offline
```

Note: the repo also works checked out **on the router itself** — routers
have no git, so fetch a tarball (`curl -L <repo>/archive/refs/heads/main.tar.gz`),
extract, and run `sh install.sh` from the directory; it prefers local files
over downloading.

### Tuning (optional config file)

Create `/jffs/scripts/roam-detect.conf` to override the defaults — it's
plain shell sourced by the daemon, it survives updates and reinstalls (the
installer never touches it), and all uninstall paths remove it:

```sh
# /jffs/scripts/roam-detect.conf — all optional
BSSLIST="wl0.1 wl1.1 wl2.1"  # your SSID-carrying BSS interfaces (varies by model!)
INTERVAL=2                   # seconds between detection passes
COOLDOWN=60                  # min seconds between flushes per client (same radio)
MIN_GAP=8                    # hard floor between flushes per client (any radio)
HEAL_TRIGGERS="roam stale-fdb dual-settle"   # which triggers may flush
LOG_EVENTS=1                 # 0 = quiet mode: log only actions (FLUSHED) + lifecycle
EVENT_HEAL=1                 # 0 = disable the wlceventd event listener (poller only)
```

`LOG_EVENTS=0` silences the observation lines (`ROAM`/`DUAL`/`SETTLED`/
`STALE-FDB`/`RECOVERED`) for noise-sensitive setups; actions (`FLUSHED`,
`WOULD FLUSH`) and lifecycle messages are always logged — they're the audit
trail that tells you the tool is working (and, after a firmware update,
whether the bug is gone). Log growth is a non-issue either way: the router's
syslog is size-capped and rotated by the firmware; on a stormy day the
doctor contributes a few dozen lines (~2% of syslog in our measurements).

`HEAL_TRIGGERS` selects which detections are allowed to heal (detection
itself always runs and logs everything): `roam` = preventive flush on every
net radio change; `stale-fdb` = corrective flush when the forwarding table
provably contradicts the association (retried until recovered);
`dual-settle` = flush when a client exits multi-radio churn even without a
net radio change. Default: all three. A conservative setup that only ever
flushes on *proven* corruption would be `HEAL_TRIGGERS="stale-fdb"` — at the
cost of eating the blackhole classes the preventive triggers exist for.

Restart after editing: `/jffs/scripts/roamctl restart`. `BSSLIST` is the one
most people need (per-model interface names); the timing knobs are for the
curious — the defaults are deliberately conservative.

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
ssh <user>@<router-ip> 'fcctl flush --mac <client-mac>'  # surgical — proven sufficient
ssh <user>@<router-ip> 'fcctl flush --if <bss>'          # one radio
ssh <user>@<router-ip> 'fcctl flush'                     # everything (the classic cure)
ssh <user>@<router-ip> 'fcctl flush --hw'                # include HW accelerator entries
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
  rapid roam storms, missing events (observed).   listener (`EVENT_HEAL=1`) closes this: the driver's own event log keeps
  flowing when the query interfaces don't.
- Flow-level staleness **without** an FDB-level mismatch exists (observed):
  table comparison can't see it, so healing relies on roam/settle/event
  triggers firing. Churn that produces *no* observable signal at all (no
  assoc event, no assoclist change, no FDB symptom) remains theoretically
  uncovered — never observed.
- The healing residual: a roam still costs a few seconds of turbulence
  (association handover + flow re-learn). The doctor makes the bug
  survivable; it cannot make roaming free.
- Active traffic to a blackholed host keeps the stale entry alive (the
  aging inversion) — so without a heal trigger, retry loops *sustain* the
  outage while ~2 minutes of quiet lets it starve. Monitoring pings count
  as traffic (we proved this on ourselves — twice).
- BSS interface names vary by model/config — set `BSSLIST` accordingly.
- The event listener depends on ASUS's `wlceventd` logger staying healthy;
  killed-and-shell-restarted wlceventd goes silent (see caution above). The
  poller is deliberately kept as the always-on primary for exactly this
  reason.

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

## Discussion

Two SNB Forums threads, split by topic:

- **The bug** (diagnosis, hardware discussion):
  [RT-BE92U: Wi-Fi client can't reach specific LAN hosts after 5/6 GHz roam](https://www.snbforums.com/threads/rt-be92u-wi-fi-client-cant-reach-specific-lan-hosts-after-5-6-ghz-roam-cause-found-open-source-fix.97555/)
- **The addon** (support, install help, model/firmware reports):
  [flowcache-doctor on the Asuswrt-Merlin AddOns forum](https://www.snbforums.com/threads/flowcache-doctor-v0-2-0-auto-heal-for-the-broadcom-flow-cache-roam-blackhole-wi-fi-client-loses-specific-lan-hosts-after-a-band-roam.97561/)

Reports from other router models are especially welcome (there or as GitHub
issues here).

## Similar reports in the wild

The roam→blackhole family shows up across ASUS Broadcom models and firmware
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
- [SNB: Persistent Broadcom kernel instability on RT-BE92U (AiMesh)](https://www.snbforums.com/threads/attempting-to-track-down-a-persistent-broadcom-kernel-instability-on-asus-rt-be92u-in-an-aimesh-setup.96138/)
  — a *different* member of the same family: station-**departure** events leak
  the driver's per-station control block (`WLC_SCB_DEAUTHORIZE error (-30)`),
  degrading the whole router until reboot. Not the flow-cache blackhole (their
  symptom is global and loud; ours is per-host and silent) — but further
  evidence that per-station state lifecycle handling in this Broadcom stack is
  broken in more than one way.
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
