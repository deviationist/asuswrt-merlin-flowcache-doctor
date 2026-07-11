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

# stop daemon (busybox: no pkill)
for p in $(ps w | grep "[r]oam-detect.sh" | awk '{print $1}'); do kill "$p"; done

cru d "$CRU_ID" 2>/dev/null
[ -f "$SS" ] && sed -i '/roamctl boot/d; /roam-detect-wd/d' "$SS"
rm -f "$DEST/roam-detect.sh" "$DEST/roamctl" "$DEST/roam-detect.policy" "$DEST/roam-detect.flush" "$DEST/roam-detect.conf" /tmp/roam-detect.disabled
rm -rf /tmp/roam-detect

logger -t roam-detect "uninstalled" 2>/dev/null
echo "flowcache-doctor uninstalled. (services-start kept, minus our lines.)"
