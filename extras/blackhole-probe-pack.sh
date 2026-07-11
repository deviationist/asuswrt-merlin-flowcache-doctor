#!/bin/sh
# blackhole-probe-pack.sh — workstation-side incident capture for the
# flow-cache roam blackhole. Run this from the AFFECTED Wi-Fi client while
# the blackhole is live, BEFORE flushing anything — the capture is the
# evidence that distinguishes this bug from everything else.
#
# Requires: SSH access to the router (and optionally to a second LAN host
# as a control vantage point).
#
# CONFIG — set these for your network:
ROUTER="${ROUTER:-router}"            # ssh alias or user@ip of the router
VICTIM_MAC="${VICTIM_MAC:-aa:bb:cc:dd:ee:ff}"  # this client's Wi-Fi MAC
TARGET_IP="${TARGET_IP:-192.168.1.10}"         # the unreachable LAN host
CONTROL_IP="${CONTROL_IP:-192.168.1.11}"       # a host that still works (optional)

OUT="$HOME/blackhole-capture-$(date +%Y%m%d-%H%M%S).txt"
R() { ssh -o ConnectTimeout=5 "$ROUTER" "$@"; }
log() { printf '\n===== %s =====\n' "$1" >> "$OUT"; shift; "$@" >> "$OUT" 2>&1; }

echo "capture started $(date '+%F %T')" > "$OUT"

# --- client side ---
log "arp table" arp -an
log "ping target (expect fail)" ping -c 3 "$TARGET_IP"
log "ping control" ping -c 3 "$CONTROL_IP"
log "traceroute target (often WORKS - slow path)" traceroute -w 2 -m 4 "$TARGET_IP"

# --- router side: flow tables (fcctl, not the fc symlink; plus Archer layer) ---
log "fcctl status" R 'fcctl status'
log "fcctl dump (full flow table)" R 'fcctl dump'
log "archer flows" R 'archerctl flows --all'
log "fcache slow_path stats" R 'cat /proc/fcache/stats/slow_path'
log "fcache evict stats" R 'cat /proc/fcache/stats/evict'

# --- router side: station + bridge state ---
log "bridge fdb" R 'brctl showmacs br0'
log "bridge port map" R 'for f in /sys/class/net/br0/brif/*/port_no; do echo "$f: $(cat $f)"; done'
log "assoclists" R 'for i in /sys/class/net/br0/brif/wl*; do b=$(basename $i); echo "-- $b"; wl -i $b assoclist 2>&1; done'
log "victim sta_info sweep" R "for i in /sys/class/net/br0/brif/wl*; do b=\$(basename \$i); echo \"-- \$b\"; wl -i \$b sta_info $VICTIM_MAC 2>&1 | head -6; done"

echo "" >> "$OUT"; echo "capture finished $(date '+%F %T')" >> "$OUT"
echo "Saved: $OUT"
echo ""
echo "Escalating fix (run in order, re-test the target after each — proves scope):"
echo "  1. ssh $ROUTER 'fcctl flush --mac $VICTIM_MAC'   # surgical: this client only"
echo "  2. ssh $ROUTER 'fcctl flush --if <bss>'          # one radio"
echo "  3. ssh $ROUTER 'fcctl flush'                     # everything"
echo "  4. ssh $ROUTER 'fcctl flush --hw'                # include HW accelerator entries"
