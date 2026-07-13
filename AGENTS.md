# AGENTS.md — guidance for AI coding agents working on this repo

This repo ships shell scripts that run on **Asuswrt-Merlin routers under
busybox `sh`** and on users' workstations. The constraints are unusual and
violating them produces silent, hard-to-debug failures — read this before
editing anything.

## Hard constraints (learned the hard way)

- **busybox `sh` only** for everything under `scripts/` and the two
  installers. No bash, no arrays, no `[[`, no `local` outside functions'
  simple use, no process substitution. Check with `sh -n <file>` before
  committing — it's the repo's only lint.
- **No `pgrep`/`pkill` on the router** — busybox there doesn't ship them.
  Process discovery uses the pidfile (`/tmp/roam-detect.pid`) with the
  daemon's distinctive `{roam-detect.sh}` ps form as orphan fallback.
- **Never find the daemon via broad `ps | grep <string>`**: an SSH session
  whose command line mentions the daemon's path will match itself, and a
  kill loop will then **terminate the caller's SSH session mid-deploy**.
  This was a real bug (fixed in `roamctl` `pids()`); don't reintroduce it.
- **macOS BSD tools differ from GNU**: `sed -i` needs `''`, `sed` has no
  `\b` word boundaries (use `perl -pi -e` for word-boundary edits). The
  repo is developed from macOS; scripts under `extras/` run on macOS/Linux
  workstations — keep them POSIX.
- **JFFS flash wear**: never log high-frequency data to `/jffs`. Runtime
  state goes to `/tmp` (RAM); syslog via `logger -t roam-detect` (RAM-backed).
- **`fc` is a shell-builtin collision** — always invoke the flow-cache tool
  as `fcctl`.
- **Never kill/restart `wlceventd` from a shell.** It writes its start line
  and then receives no driver events — the event feed (and the default-on
  listener with it) silently dies. Only `service restart_wireless` (or a
  reboot) restores it. This cost us a day of "wlceventd doesn't log"
  confusion; the events were in `/jffs/wifi_wlc.log` all along.
- **`heal()` is duplicated** in `roam-detect.sh` and `roam-events.sh`
  (deliberate: zero risk to the validated poller). If you change one, change
  both — they must agree on state files, gates, and semantics.
- **No development-setup specifics in shipped code** — no real IPs, client
  MACs, hostnames, or SSIDs from anyone's network, not even in comments
  (use `AA:BB:CC:DD:EE:FF` / `192.168.1.x` style placeholders).
  *Model*-specific defaults (interface names, firmware paths like the
  wlceventd log) are acceptable ONLY as documented defaults that the conf
  file can override — define them before the `. "$CONF"` line.

## Design invariants (do not weaken)

- **Flushes are per-client only** (`fcctl flush --mac`). The daemon must
  never run a global `fcctl flush`; that stays a human command.
- **Auto-heal is ON for fresh installs** (installer creates the flush flag;
  owner decision 2026-07-12: an installed doctor must create value out of
  the box). Audit-only mode is `roamctl flush off`; **reinstalls/updates
  must respect the user's existing on/off choice** (the installer only
  touches the flag on FRESH installs — keep it that way). The event
  listener is likewise default-on but must auto-stand-down when
  `/jffs/wifi_wlc.log` doesn't exist (other firmware builds).
- **Rate limiting**: band-aware cooldown (`COOLDOWN` same-radio, bypass on
  radio change, `MIN_GAP` hard floor). A settle-roam onto a new radio must
  always be allowed to heal; flapping must never cause a flush storm.
- **DUAL guard**: clients listed in two radios' assoclists simultaneously
  are parked, not acted on. Acting on ambiguous membership caused log spam
  and would cause flush churn.
- **Every artifact is inventoried** (see README's manual-install table) and
  **all three uninstall paths** (`roamctl uninstall`, `uninstall.sh`,
  `install.sh uninstall`) must remove every artifact, including any new one
  you add. New persistent files belong in `/jffs/scripts/roam-detect.*`.
- **User tunables live in `/jffs/scripts/roam-detect.conf`** (sourced over
  defaults). The installer must never write or overwrite it.

## Testing

- Syntax: `for f in setup.sh install.sh uninstall.sh scripts/*; do sh -n "$f"; done`
- There is no CI and no router emulator: real validation happens on an
  actual Asuswrt-Merlin router over SSH. Deploy pattern that avoids both
  connection bursts and the self-kill trap:
  `tar cf - -C scripts roam-detect.sh roam-events.sh roamctl | ssh <router> 'tar xf - -C /jffs/scripts && chmod 755 /jffs/scripts/roam* && /jffs/scripts/roamctl restart'`
- After deploying: `roamctl status` (expect `running (pid N)` + policy +
  autoflush), then `roamctl log` for the `starting (pid N, ...)` banner.
- The installer flows are tested by full cycles: `install.sh` →
  verify artifacts → `uninstall` path → verify **zero residue** (files,
  processes, cron entry, `services-start` lines, `/tmp/roam-detect`).

## Architecture in one paragraph

`scripts/roam-detect.sh` is a 2 s busybox loop: gather per-radio assoclists
(truth) and the bridge FDB (belief), run a per-client state machine
(ROAM/DUAL/STALE1→STALE2/OK), and heal via rate-limited per-MAC flush; it
also retries `*.pending` deferred heals (cross-radio flushes suppressed by
MIN_GAP). `scripts/roam-events.sh` is the default-on second source (auto-stands-down without the event log; EVENT_HEAL=0 disables)
— tails `/jffs/wifi_wlc.log` (wlceventd's
default event log) and heals within ~1 s of a successful (Re)Assoc, sharing
the same `/tmp/roam-detect/` cooldown state so the sources never
double-flush. `scripts/roamctl` is the lifecycle wrapper (start/stop/
restart/status/log/policy/flush/boot/watchdog/uninstall) managing both
daemons — boot via Merlin's `services-start`, crash recovery via a `cru`
cron watchdog every 60 s, both honoring the persistent policy file and the
runtime stop flag. `install.sh`/`uninstall.sh`
run on the router (curl-pipe-sh or from a checkout — local files preferred);
`setup.sh` is the interactive workstation-side guide (SSH multiplexed, reads
prompts from `/dev/tty` so curl-pipe works). `.claude/skills/flowcache-doctor`
is a user-facing diagnosis skill, not contributor docs.

## Known open problems (good first issues for agents)

- Churn that produces no observable signal at all (no assoc event, no
  assoclist change, no FDB symptom) has no trigger — theorized, never
  observed. Everything observable is covered: net roams + dual-settle
  (poller), assoc events (event listener), FDB mismatch (backstop),
  MIN_GAP-suppressed cross-radio flushes (deferred pending retry).
- The event listener's file source (`/jffs/wifi_wlc.log`) grows on flash and
  its rotation behavior is unknown (ASUS's file, not ours) — worth
  characterizing before recommending EVENT_HEAL widely.
- SOLVED 2026-07-12 (context): the "wlceventd doesn't log" mystery — it logs
  to `/jffs/wifi_wlc.log` by default, not syslog; our own shell-restarts had
  killed its driver-event subscription. See Hard constraints.
