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

## Design invariants (do not weaken)

- **Flushes are per-client only** (`fcctl flush --mac`). The daemon must
  never run a global `fcctl flush`; that stays a human command.
- **Auto-heal is opt-in** (`roamctl flush on` → flag file). Fresh installs
  are log-only. Don't change the default.
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
  `tar cf - -C scripts roam-detect.sh roamctl | ssh <router> 'tar xf - -C /jffs/scripts && chmod 755 /jffs/scripts/roam* && /jffs/scripts/roamctl restart'`
- After deploying: `roamctl status` (expect `running (pid N)` + policy +
  autoflush), then `roamctl log` for the `starting (pid N, ...)` banner.
- The installer flows are tested by full cycles: `install.sh` →
  verify artifacts → `uninstall` path → verify **zero residue** (files,
  processes, cron entry, `services-start` lines, `/tmp/roam-detect`).

## Architecture in one paragraph

`scripts/roam-detect.sh` is a 2 s busybox loop: gather per-radio assoclists
(truth) and the bridge FDB (belief), run a per-client state machine
(ROAM/DUAL/STALE1→STALE2/OK), and heal via rate-limited per-MAC flush.
`scripts/roamctl` is the lifecycle wrapper (start/stop/restart/status/log/
policy/flush/boot/watchdog/uninstall) — boot via Merlin's `services-start`,
crash recovery via a `cru` cron watchdog every 60 s, both honoring the
persistent policy file and the runtime stop flag. `install.sh`/`uninstall.sh`
run on the router (curl-pipe-sh or from a checkout — local files preferred);
`setup.sh` is the interactive workstation-side guide (SSH multiplexed, reads
prompts from `/dev/tty` so curl-pipe works). `.claude/skills/flowcache-doctor`
is a user-facing diagnosis skill, not contributor docs.

## Known open problems (good first issues for agents)

- `wlceventd` event-driven detection: `wlceventd_msglevel=1` + syslogd `-l 7`
  produced no events on 3006.102.8 despite the binary containing Assoc/Deauth
  format strings. Cracking this closes the polling detector's storm blind spot.
- `wl assoclist` goes blind during rapid roam storms — missed roams get no
  proactive flush (the stale-FDB backstop catches the FDB-visible subset).
- Churn that never surfaces in the assoclist at all (no DUAL, no roam, no FDB
  symptom) has no trigger — theorized, never observed. The dual-settle trigger
  (added 2026-07-12 after a live miss) already closed the observable variant:
  there-and-back bounces inside a DUAL window.
