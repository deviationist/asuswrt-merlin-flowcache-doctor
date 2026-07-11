#!/bin/sh
# roam-detect.sh — flowcache-doctor detection daemon (phase 1: log-only)
#
# Detects the Broadcom flow-cache roam blackhole on Asuswrt-Merlin routers:
# a client roams between radios, but the Broadcom packet-forwarding layer
# (pktfwd d3lut / flow cache) keeps forwarding its flows toward the OLD radio.
# Result: traffic between that Wi-Fi client and specific hosts silently
# blackholes until the stale flow entries are flushed (fcctl flush).
#
# Truth  = wl -i <bss> assoclist  (which radio the client is really on)
# Belief = brctl showmacs br0     (which bridge port the forwarding layer uses)
# Sustained mismatch = the bug, live. This phase logs; it does not flush.
#
# CONFIG — adjust for your model. BSSLIST must name the bridge-member BSS
# interfaces your SSIDs actually use (check: ls /sys/class/net/br0/brif/).
# On an RT-BE92U with the main SSID on all three bands this is:
BSSLIST="wl0.1 wl1.1 wl2.1"
INTERVAL=2
TAG=roam-detect
STATE=/tmp/roam-detect

mkdir -p "$STATE"
logger -t "$TAG" "starting (pid $$, interval ${INTERVAL}s, bss: $BSSLIST)"

port_of() { printf '%d' "$(cat /sys/class/net/br0/brif/$1/port_no 2>/dev/null)" 2>/dev/null; }

while true; do
  FDB=$(brctl showmacs br0 2>/dev/null)
  for bss in $BSSLIST; do
    bport=$(port_of "$bss")
    [ -z "$bport" ] && continue
    for mac in $(wl -i "$bss" assoclist 2>/dev/null | awk '{print tolower($2)}'); do
      f="$STATE/$(echo "$mac" | tr -d :)"
      prev_bss=""; prev_status=""
      [ -f "$f" ] && read prev_bss prev_status < "$f"
      if [ -n "$prev_bss" ] && [ "$prev_bss" != "$bss" ]; then
        logger -t "$TAG" "ROAM $mac $prev_bss -> $bss"
      fi
      fport=$(echo "$FDB" | awk -v m="$mac" 'tolower($2)==m && $3=="no" {print $1; exit}')
      if [ -n "$fport" ] && [ "$fport" != "$bport" ]; then
        status="STALE:$fport"
        if [ "$prev_status" != "$status" ]; then
          logger -t "$TAG" "STALE-FDB $mac assoc=$bss(port $bport) fdb=port $fport <- WOULD FLUSH: fcctl flush --mac $mac"
        fi
      else
        status="OK"
        case "$prev_status" in STALE:*) logger -t "$TAG" "RECOVERED $mac fdb now matches $bss" ;; esac
      fi
      echo "$bss $status" > "$f"
    done
  done
  sleep $INTERVAL
done
