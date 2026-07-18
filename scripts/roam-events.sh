#!/bin/sh
# roam-events.sh — flowcache-doctor OPT-IN event listener (wlceventd source).
#
# Tails the Broadcom driver's own association log (/jffs/wifi_wlc.log, written
# by wlceventd by default on this firmware) and heals a client the moment it
# (re)associates — sub-second reaction, immune to the polling detector's storm
# blind spots. The 2 s polling daemon (roam-detect.sh) remains the primary and
# default; enable this listener with EVENT_HEAL=1 in /jffs/scripts/roam-detect.conf
# (roamctl start/stop/watchdog manage it automatically when enabled).
#
# CAUTION (learned the hard way): wlceventd only logs events when started by
# init. If it is ever killed and restarted from a shell, it writes a start
# line and then goes silent — only `service restart_wireless` (or a reboot)
# restores the event feed.

EVLOG=/jffs/wifi_wlc.log
BSSLIST="wl0.1 wl1.1 wl2.1"
COOLDOWN=60
MIN_GAP=8
TAG=roam-events
STATE=/tmp/roam-detect
FLUSHFLAG=/jffs/scripts/roam-detect.flush
CONF=/jffs/scripts/roam-detect.conf
[ -f "$CONF" ] && . "$CONF"

if [ ! -f "$EVLOG" ]; then
  logger -t "$TAG" "event source $EVLOG not present on this firmware — standing down (the polling daemon covers healing)"
  exit 0
fi

mkdir -p "$STATE"
echo $$ > /tmp/roam-events.pid
logger -t "$TAG" "starting (pid $$, source: $EVLOG)"

# Same state files as roam-detect.sh — both sources share per-client cooldowns,
# so a client healed by one source won't be immediately re-flushed by the other.
# (Duplicated from roam-detect.sh heal(); keep the two in sync — see AGENTS.md.)
heal() { # $1 = mac, $2 = reason, $3 = current bss, $4 = "force" bypasses same-radio cooldown
  now=$(date +%s)
  key=$(echo "$1" | tr -d :)
  lf="$STATE/$key.lastflush"; lb="$STATE/$key.lastflushbss"
  last=0; [ -f "$lf" ] && last=$(cat "$lf")
  lastbss=""; [ -f "$lb" ] && lastbss=$(cat "$lb")
  [ $((now - last)) -lt "$MIN_GAP" ] && { { [ "$4" = "force" ] || [ "$3" != "$lastbss" ]; } && [ ! -f "$STATE/$key.pending" ] && echo "$2|$3" > "$STATE/$key.pending"; return 0; }
  if [ "$4" != "force" ] && [ $((now - last)) -lt "$COOLDOWN" ] && [ "$3" = "$lastbss" ]; then
    # Same-radio flush within cooldown: DON'T silently drop a genuine roam's
    # heal (a roam is one-shot; it won't re-fire on its own). Leave a pending
    # marker — the poller (roam-detect.sh) drains it past the MIN_GAP floor.
    # Symmetric with the MIN_GAP deferral above; MIN_GAP still caps the rate.
    [ ! -f "$STATE/$key.pending" ] && echo "$2|$3" > "$STATE/$key.pending"
    return 0
  fi
  echo "$now" > "$lf"; echo "$3" > "$lb"
  rm -f "$STATE/$key.pending"
  if [ -f "$FLUSHFLAG" ]; then
    fcctl flush --mac "$1" >/dev/null 2>&1
    logger -t "$TAG" "FLUSHED $1 ($2)"
  else
    logger -t "$TAG" "WOULD FLUSH $1 ($2) — enable with: roamctl flush on"
  fi
}

# Event lines look like:
#   Sun Jul 12 16:44:43 2026  [notice] wlceventd_proc_event(744): wl2.1: Assoc AA:BB:CC:DD:EE:FF, status: Successful (0), rssi:-77
tail -n 0 -F "$EVLOG" 2>/dev/null | while read -r line; do
  case "$line" in
    *": Assoc "*Successful*|*": ReAssoc "*Successful*)
      bss=$(echo "$line" | awk -F': ' '{print $2}')
      mac=$(echo "$line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr 'A-F' 'a-f')
      [ -n "$mac" ] && [ -n "$bss" ] && heal "$mac" "event assoc on $bss" "$bss"
      ;;
    *": Deauth_ind "*|*": Disassoc "*)
      # A deauth/disassoc from a radio the client is NO LONGER on is the
      # old radio's delayed station teardown — the exact moment the
      # eviction race can poison the client's NEW forwarding state
      # (research mechanism #2, observed live 2026-07-13 12:01). Heal the
      # client on its CURRENT radio, bypassing the same-radio cooldown
      # (the preceding assoc-flush is otherwise still fresh).
      evbss=$(echo "$line" | awk -F': ' '{print $2}')
      mac=$(echo "$line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr 'A-F' 'a-f')
      if [ -n "$mac" ] && [ -n "$evbss" ]; then
        # Live assoclist lookup (NOT the poller's state file — during churn
        # that lags by up to a minute, which would mask exactly this race).
        curbss=""
        for b in $BSSLIST; do
          [ "$b" = "$evbss" ] && continue
          wl -i "$b" assoclist 2>/dev/null | grep -qi "$mac" && { curbss="$b"; break; }
        done
        if [ -n "$curbss" ]; then
          heal "$mac" "stale-radio deauth on $evbss (client on $curbss)" "$curbss" force
        fi
      fi
      ;;
  esac
done
