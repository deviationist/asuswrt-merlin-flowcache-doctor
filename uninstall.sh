#!/bin/sh
# uninstall.sh — remove flowcache-doctor completely from an Asuswrt-Merlin router.
#
# Run ON the router:
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/uninstall.sh | sh
#
# Removes: the daemon (and stops it), the control wrapper, the cron watchdog,
# the services-start boot hooks, the persistent policy file, and runtime state.
# Leaves everything else on your router untouched.

DEST=/jffs/scripts
SS=$DEST/services-start
CRU_ID=roam-detect-wd

# stop daemon (busybox: no pkill; pidfile first, then the daemon's distinctive
# "{roam-detect.sh}" ps form — never a broad grep, which could match and kill
# the calling SSH session, see AGENTS.md)
if [ -f /tmp/roam-detect.pid ]; then
  p=$(cat /tmp/roam-detect.pid)
  grep -q "roam-detect.sh" "/proc/$p/cmdline" 2>/dev/null && kill "$p"
fi
for p in $(ps w | grep "{[r]oam-detect.sh}" | awk '{print $1}'); do kill "$p"; done
if [ -f /tmp/roam-events.pid ]; then
  p=$(cat /tmp/roam-events.pid)
  grep -q "roam-events.sh" "/proc/$p/cmdline" 2>/dev/null && kill "$p"
fi
for p in $(ps w | grep "{[r]oam-events.sh}" | awk '{print $1}'); do kill "$p"; done
rm -f /tmp/roam-events.pid

cru d "$CRU_ID" 2>/dev/null
[ -f "$SS" ] && sed -i '/roamctl boot/d; /roam-detect-wd/d' "$SS"
rm -f "$DEST/roam-detect.sh" "$DEST/roam-events.sh" "$DEST/roam-lib.sh" "$DEST/roamctl" "$DEST/roam-detect.policy" "$DEST/roam-detect.flush" "$DEST/roam-detect.conf" /tmp/roam-detect.disabled /tmp/roam-detect.update.sh
rm -rf /tmp/roam-detect

logger -t roam-detect "uninstalled" 2>/dev/null
echo "flowcache-doctor uninstalled. (services-start kept, minus our lines.)"
