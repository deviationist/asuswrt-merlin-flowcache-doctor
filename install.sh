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
  rm -f "$DEST/roam-detect.sh" "$DEST/roamctl" "$DEST/roam-detect.policy" /tmp/roam-detect.disabled
  rm -rf /tmp/roam-detect
  echo "flowcache-doctor uninstalled."
  exit 0
fi

# Fetch scripts (prefer local copies when run from a checkout)
mkdir -p "$DEST"
for f in roam-detect.sh roamctl; do
  if [ -f "./scripts/$f" ]; then
    cp "./scripts/$f" "$DEST/$f"
  else
    curl -fsSL "$REPO_RAW/scripts/$f" -o "$DEST/$f" || fail "download of $f failed"
  fi
  chmod 755 "$DEST/$f"
done

# Boot hook + watchdog (idempotent)
if [ ! -f "$SS" ]; then printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; fi
grep -q "roamctl boot" "$SS" || echo "$DEST/roamctl boot" >> "$SS"
grep -q "$CRU_ID" "$SS" || echo "cru a $CRU_ID \"* * * * * $DEST/roamctl watchdog\"" >> "$SS"

# Arm now
cru a "$CRU_ID" "* * * * * $DEST/roamctl watchdog"
"$DEST/roamctl" start
sleep 2
"$DEST/roamctl" status

cat <<'EOF'

Installed. The detector runs now, restarts on crash (60s watchdog), and
survives reboots. If your SSIDs don't live on wl0.1/wl1.1/wl2.1, edit
BSSLIST at the top of /jffs/scripts/roam-detect.sh (list bridge members
with: ls /sys/class/net/br0/brif/).

Useful commands:
  /jffs/scripts/roamctl log         # what it has detected
  /jffs/scripts/roamctl status      # running? policy?
  /jffs/scripts/roamctl policy off  # disable persistently
  sh install.sh uninstall           # remove everything
EOF
