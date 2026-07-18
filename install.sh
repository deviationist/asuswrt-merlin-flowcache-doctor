#!/bin/sh
# install.sh — flowcache-doctor installer for Asuswrt-Merlin.
#
# Run ON the router (after enabling SSH + JFFS scripts, see README):
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
#
# Or from a clone of this repo copied to the router:
#   sh install.sh
#
# Uninstall (removes daemon, watchdog, boot hooks, state):
#   sh install.sh uninstall

REPO_RAW="https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main"
DEST=/jffs/scripts
SS=$DEST/services-start
CRU_ID=roam-detect-wd

fail() { echo "ERROR: $1" >&2; exit 1; }

[ -d /jffs ] || fail "no /jffs mount — is this an Asuswrt-Merlin router?"
[ "$(nvram get jffs2_scripts)" = "1" ] || fail "JFFS custom scripts are disabled.
Enable: Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
hit Apply, then re-run this installer."

if [ "$1" = "uninstall" ]; then
  [ -x "$DEST/roamctl" ] && "$DEST/roamctl" stop 2>/dev/null
  cru d "$CRU_ID" 2>/dev/null
  [ -f "$SS" ] && sed -i '/roamctl boot/d; /roam-detect-wd/d' "$SS"
  rm -f "$DEST/roam-detect.sh" "$DEST/roam-events.sh" "$DEST/roamctl" "$DEST/roam-detect.policy" "$DEST/roam-detect.flush" "$DEST/roam-detect.conf" /tmp/roam-detect.disabled /tmp/roam-detect.update.sh
  rm -rf /tmp/roam-detect
  echo "flowcache-doctor uninstalled."
  exit 0
fi

# Fresh install (no prior roamctl) => healing on out of the box. On
# reinstall/update we respect the user's existing flush on/off choice.
FRESH=0
[ -f "$DEST/roamctl" ] || FRESH=1

# Fetch scripts (prefer local copies when run from a checkout)
mkdir -p "$DEST"
for f in roam-detect.sh roam-events.sh roamctl; do
  if [ -f "./scripts/$f" ]; then
    cp "./scripts/$f" "$DEST/$f"
  else
    # ?cb= busts the raw CDN cache — see roamctl update
    curl -fsSL "$REPO_RAW/scripts/$f?cb=$(date +%s)" -o "$DEST/$f" || fail "download of $f failed"
  fi
  chmod 755 "$DEST/$f"
done

# Boot hook + watchdog (idempotent)
if [ ! -f "$SS" ]; then printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; fi
grep -q "roamctl boot" "$SS" || echo "$DEST/roamctl boot" >> "$SS"
grep -q "$CRU_ID" "$SS" || echo "cru a $CRU_ID \"* * * * * $DEST/roamctl watchdog\"" >> "$SS"

# Fresh installs heal out of the box (audit-only available: roamctl flush off)
[ "$FRESH" = "1" ] && touch "$DEST/roam-detect.flush"

# Arm now. restart, not start: on update the daemons are already running
# the OLD code — start would no-op and leave stale processes; restart makes
# the just-installed scripts take effect. (On fresh installs restart is
# equivalent to start.)
cru a "$CRU_ID" "* * * * * $DEST/roamctl watchdog"
"$DEST/roamctl" restart
sleep 2
"$DEST/roamctl" health

cat <<'EOF'

Installed and HEALING (per-client flushes on roam events, rate-limited —
never a global flush). Restarts on crash (60s watchdog), survives reboots.
The event listener runs automatically when your firmware provides
/jffs/wifi_wlc.log; otherwise the 2s poller covers everything.
If your SSIDs don't live on wl0.1/wl1.1/wl2.1, set BSSLIST in
/jffs/scripts/roam-detect.conf (list bridge members with:
ls /sys/class/net/br0/brif/).

Useful commands:
  /jffs/scripts/roamctl log         # what it has detected and healed
  /jffs/scripts/roamctl status      # running? healing? listener? version?
  /jffs/scripts/roamctl health      # full install + runtime health check
  /jffs/scripts/roamctl flush off   # audit-only mode (log, don't heal)
  /jffs/scripts/roamctl policy off  # disable persistently
  /jffs/scripts/roamctl update      # self-update to the latest version
  sh install.sh uninstall           # remove everything
EOF
