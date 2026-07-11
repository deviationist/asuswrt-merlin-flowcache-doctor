#!/bin/sh
# roam-detect.sh — flowcache-doctor daemon (phase 2: detect + optional auto-heal)
#
# Detects the Broadcom flow-cache roam blackhole on Asuswrt-Merlin routers and,
# when auto-flush is enabled (roamctl flush on), surgically flushes ONLY the
# affected client's flow entries: fcctl flush --mac <client>. Never a global
# flush. Per-client cooldown limits flushes to one per COOLDOWN seconds.
#
# Truth  = wl -i <bss> assoclist  (which radio the client is really on)
# Belief = brctl showmacs br0     (which bridge port the forwarding layer uses)
#
# CONFIG — adjust for your model. BSSLIST must name the bridge-member BSS
# interfaces your SSIDs actually use (check: ls /sys/class/net/br0/brif/).
BSSLIST="wl0.1 wl1.1 wl2.1"
INTERVAL=2
COOLDOWN=60                                  # min seconds between flushes per client
TAG=roam-detect
STATE=/tmp/roam-detect
FLUSHFLAG=/jffs/scripts/roam-detect.flush    # exists => auto-flush on (roamctl flush on|off)

mkdir -p "$STATE"
echo $$ > /tmp/roam-detect.pid
logger -t "$TAG" "starting (pid $$, interval ${INTERVAL}s, bss: $BSSLIST, autoflush: $([ -f "$FLUSHFLAG" ] && echo on || echo off))"

port_of() { printf '%d' "$(cat /sys/class/net/br0/brif/$1/port_no 2>/dev/null)" 2>/dev/null; }

# Rate-limited per-MAC flush (or announcement, when auto-flush is off).
heal() { # $1 = mac, $2 = reason
  now=$(date +%s)
  lf="$STATE/$(echo "$1" | tr -d :).lastflush"
  last=0; [ -f "$lf" ] && last=$(cat "$lf")
  [ $((now - last)) -lt "$COOLDOWN" ] && return 0
  echo "$now" > "$lf"
  if [ -f "$FLUSHFLAG" ]; then
    fcctl flush --mac "$1" >/dev/null 2>&1
    logger -t "$TAG" "FLUSHED $1 ($2)"
  else
    logger -t "$TAG" "WOULD FLUSH $1 ($2) — enable with: roamctl flush on"
  fi
}

while true; do
  FDB=$(brctl showmacs br0 2>/dev/null)

  # Pass 1: gather mac -> bss membership across all radios
  MAP="$STATE/.map"; : > "$MAP"
  for bss in $BSSLIST; do
    for mac in $(wl -i "$bss" assoclist 2>/dev/null | awk '{print tolower($2)}'); do
      echo "$mac $bss" >> "$MAP"
    done
  done

  # Pass 2: per-client state machine
  for mac in $(awk '{print $1}' "$MAP" | sort -u); do
    f="$STATE/$(echo "$mac" | tr -d :)"
    prev_bss=""; prev_status=""
    [ -f "$f" ] && read prev_bss prev_status < "$f"

    # Client listed on multiple radios at once (driver artifact during
    # steering churn): note it once, act only when it settles.
    if [ "$(grep -c "^$mac " "$MAP")" -gt 1 ]; then
      [ "$prev_status" != "DUAL" ] && logger -t "$TAG" "DUAL $mac on multiple radios ($(grep "^$mac " "$MAP" | awk '{print $2}' | tr '\n' ' ')) — waiting for it to settle"
      echo "$prev_bss DUAL" > "$f"
      continue
    fi

    bss=$(grep "^$mac " "$MAP" | awk '{print $2}')
    bport=$(port_of "$bss")

    if [ -n "$prev_bss" ] && [ "$prev_bss" != "$bss" ]; then
      logger -t "$TAG" "ROAM $mac $prev_bss -> $bss"
      heal "$mac" "roam $prev_bss->$bss"
    fi

    fport=$(echo "$FDB" | awk -v m="$mac" 'tolower($2)==m && $3=="no" {print $1; exit}')
    if [ -n "$fport" ] && [ -n "$bport" ] && [ "$fport" != "$bport" ]; then
      case "$prev_status" in
        STALE1:$fport|STALE2:$fport)
          # persisted for 2+ passes -> real stale binding, not a transient
          [ "$prev_status" = "STALE1:$fport" ] && logger -t "$TAG" "STALE-FDB $mac assoc=$bss(port $bport) fdb=port $fport (persistent)"
          status="STALE2:$fport"
          heal "$mac" "stale-fdb port $fport" ;;   # cooldown gates retries
        *) status="STALE1:$fport" ;;               # first sighting: wait one pass
      esac
    else
      status="OK"
      case "$prev_status" in STALE*) logger -t "$TAG" "RECOVERED $mac fdb now matches $bss" ;; esac
    fi
    echo "$bss $status" > "$f"
  done
  sleep $INTERVAL
done
