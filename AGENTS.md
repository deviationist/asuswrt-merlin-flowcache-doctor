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
- **No `command` builtin on the router's busybox sh** — `command -v foo`
  fails with "command: not found" (a false negative that looks like foo is
  missing; bit us in `roamctl health` on 2026-07-18). Probe binaries with
  `which foo` (returns 1 on missing) or the `type` builtin instead.
- **No `mkfifo` applet either** (also 2026-07-18) — use
  `mkfifo || mknod <path> p` as a fallback chain; `mknod` is present. The
  applet set on this firmware is trimmed: before relying on ANY busybox
  applet, verify with `which` on the router.
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
- **No `tail | while read` in daemons** — the read-loop runs in a pipeline
  SUBSHELL that survives a kill of its parent. The orphaned loop keeps
  running pre-update code, and because it shows up in the `{script.sh}` ps
  fallback it convinces the lifecycle code a daemon is already running, so
  restarts silently no-op (bit us live 2026-07-18: the event listener
  skipped four consecutive updates). Read through a FIFO instead, with a
  `trap` that kills the background tail — the worker loop must live in the
  process whose pid is in the pidfile.
- **A running script must never have its file overwritten** — busybox `sh`
  reads scripts incrementally, so rewriting an executing file is undefined
  behavior. This is why `roamctl update` downloads the installer to `/tmp`
  and `exec`s it (replacing the roamctl process before `/jffs/scripts/roamctl`
  is replaced on disk). Any future self-modifying path must follow the same
  download-then-exec pattern.
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
- **Never-drop deferral** (v0.2.2/v0.2.3): a heal suppressed by either gate
  is *deferred* via a `*.pending` marker (drained by the poller past the
  `MIN_GAP` floor), never silently dropped — one-shot triggers (roam,
  stale-radio deauth, dual-settle) won't re-fire on their own, so a dropped
  flush is lost forever. `force` bypasses the same-radio `COOLDOWN` but
  never `MIN_GAP`; a forced heal landing inside the floor defers like any
  other. Don't reintroduce a bare `return 0` in either gate.
- **DUAL guard**: clients listed in two radios' assoclists simultaneously
  are parked, not acted on. Acting on ambiguous membership caused log spam
  and would cause flush churn.
- **Every artifact is inventoried** (see README's manual-install table) and
  **all three uninstall paths** (`roamctl uninstall`, `uninstall.sh`,
  `install.sh uninstall`) must remove every artifact, including any new one
  you add. New persistent files belong in `/jffs/scripts/roam-detect.*`.
- **User tunables live in `/jffs/scripts/roam-detect.conf`** (sourced over
  defaults). The installer must never write or overwrite it.
- **Release checklist**: bump `VERSION` in `scripts/roamctl` (shown by
  `roamctl status` and used by `roamctl update`'s banner) in the release
  commit, then tag `vX.Y.Z` + GitHub Release. Docs-only/comment-only
  changes get no release — users install from `main` via curl.
- **raw.githubusercontent.com lags pushes by up to ~5 minutes** even with
  the `?cb=` cache-bust (cb defeats the CDN edge, not raw's internal
  layer; verified 2026-07-18 against the API, which was already fresh).
  Consequence: don't field-test `roamctl update` within ~5 min of a push
  and conclude the push is broken — grep the fetched
  `/tmp/roam-detect.update.sh` to see what was actually served.

## Testing

- Syntax: `for f in setup.sh install.sh uninstall.sh scripts/*; do sh -n "$f"; done`
- There is no CI and no router emulator: real validation happens on an
  actual Asuswrt-Merlin router over SSH. Deploy pattern that avoids both
  connection bursts and the self-kill trap:
  `tar cf - -C scripts roam-detect.sh roam-events.sh roamctl | ssh <router> 'tar xf - -C /jffs/scripts && chmod 755 /jffs/scripts/roam* && /jffs/scripts/roamctl restart'`
- After deploying: `roamctl health` (full artifact + runtime check, exits
  non-zero on any FAIL — the installer and `roamctl update` run it
  automatically at the end), then `roamctl log` for the
  `starting (pid N, ...)` banner. Keep `health` in sync with the artifact
  inventory: a new artifact means a new health check line.
- The installer flows are tested by full cycles: `install.sh` →
  verify artifacts → `uninstall` path → verify **zero residue** (files,
  processes, cron entry, `services-start` lines, `/tmp/roam-detect`).

## Architecture in one paragraph

`scripts/roam-detect.sh` is a 2 s busybox loop: gather per-radio assoclists
(truth) and the bridge FDB (belief), run a per-client state machine
(ROAM/DUAL/STALE1→STALE2/OK), and heal via rate-limited per-MAC flush; it
also retries `*.pending` deferred heals (any flush suppressed by a
rate-limit gate — see *Never-drop deferral* above). `scripts/roam-events.sh` is the default-on second source (auto-stands-down without the event log; EVENT_HEAL=0 disables)
— tails `/jffs/wifi_wlc.log` (wlceventd's
default event log) and heals within ~1 s of a successful (Re)Assoc, sharing
the same `/tmp/roam-detect/` cooldown state so the sources never
double-flush. `scripts/roamctl` is the lifecycle wrapper (start/stop/
restart/status/health/log/policy/flush/boot/watchdog/update/uninstall) managing both
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
  gate-suppressed flushes (deferred pending retry).
- **AiMesh departure gap** (surfaced by a 3×BE92U field report, 2026-07-18):
  a roam *away* from this unit (client vanishes to an AiMesh node, never
  reappearing on a local radio) leaves the departed unit's stale flow
  entries unhealed — no trigger fires. Candidate fix: heal on
  deauth/disassoc even when the client doesn't reappear in any local
  assoclist (flushing a departed client is harmless; rate limits still
  apply). Publicly promised as "in the works" in the addon forum thread.
  Related: clients associated to a node are entirely outside detection
  (README → Limitations). Field data 2026-07-18 (3×RT-BE92U, all-Merlin):
  the doctor installs and runs on Merlin AiMesh nodes, but node bridge
  members are named differently (`wl0.1.0 wl0.2 wl0.5 wl1.1.0 wl1.2
  wl2.1.0 wl2.2` vs the router's `wl0.0 wl0.1 wl0.4 wl1.0 wl1.1 wl2.0
  wl2.1`) — default BSSLIST matches nothing on a node. Candidate v0.3.0
  work: BSSLIST auto-detection (enumerate br0 `wl*` members, exclude the
  `wlX.0` primaries that carry AiMesh backhaul), which would make node
  installs work out of the box.
- **MLO (Wi-Fi 7 Multi-Link Operation) is uncharacterized**: the doctor's
  model assumes a client is associated to exactly one BSS at a time; an
  STA MLD is legitimately on multiple radios under one association, band
  switches happen without roam events, and we have zero data on how
  Broadcom exposes MLD clients in `wl assoclist` / `br0` membership (could
  look like a permanent `DUAL` state). Need a capture from an MLO-enabled
  setup before trusting the doctor there.
- The event listener's file source (`/jffs/wifi_wlc.log`) grows on flash and
  its rotation behavior is unknown (ASUS's file, not ours) — worth
  characterizing before recommending EVENT_HEAL widely.
- SOLVED 2026-07-12 (context): the "wlceventd doesn't log" mystery — it logs
  to `/jffs/wifi_wlc.log` by default, not syslog; our own shell-restarts had
  killed its driver-event subscription. See Hard constraints.
