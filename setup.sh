#!/bin/sh
# setup.sh — guided install/uninstall for flowcache-doctor, run from YOUR
# COMPUTER (macOS/Linux), not on the router.
#
#   curl -fsSL https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main/setup.sh | sh
#
# It asks for your router's address and SSH username, connects (your SSH
# password is prompted by ssh itself if you haven't set up keys), checks
# whether flowcache-doctor is installed, and walks you through installing,
# reinstalling, or uninstalling.

RAW="https://raw.githubusercontent.com/deviationist/asuswrt-merlin-flowcache-doctor/main"
TTY=/dev/tty

say()  { printf '%s\n' "$*"; }
ask()  { printf '%s' "$1" > "$TTY"; read -r REPLY < "$TTY"; }
die()  { say "ERROR: $*" >&2; exit 1; }

[ -e "$TTY" ] || die "no interactive terminal available — run this in a terminal."

say "=== flowcache-doctor guided setup ==="
say ""
say "This connects to your Asuswrt-Merlin router over SSH."
say "Prerequisites (router web UI, Administration -> System):"
say "  - 'Enable JFFS custom scripts and configs' = Yes"
say "  - 'Enable SSH' = LAN only"
say ""

ask "Router address [192.168.1.1]: "
HOST=${REPLY:-192.168.1.1}
ask "SSH username [admin]: "
USER=${REPLY:-admin}
TARGET="$USER@$HOST"

# One TCP connection for everything: multiplex if the platform allows it,
# so a password is asked at most once.
CP="$HOME/.ssh/fcd-setup-$$"
SSHOPTS="-o ConnectTimeout=8 -o ControlPath=$CP"
cleanup() { ssh -o ControlPath="$CP" -O exit "$TARGET" 2>/dev/null; rm -f "$CP"; }
trap cleanup EXIT INT TERM

say ""
say "Connecting to $TARGET (enter your router password if prompted)..."
ssh $SSHOPTS -o ControlMaster=auto -o ControlPersist=120 "$TARGET" true < "$TTY" \
  || die "cannot SSH to $TARGET — check address, username, and that SSH is enabled."

R() { ssh $SSHOPTS "$TARGET" "$@"; }

# --- inspect the router ---
STATE=$(R '
  [ -d /jffs ] || { echo NOJFFS; exit 0; }
  [ "$(nvram get jffs2_scripts)" = "1" ] || { echo NOSCRIPTS; exit 0; }
  if [ -f /jffs/scripts/roam-detect.sh ]; then
    if ps w | grep -q "[r]oam-detect.sh"; then echo INSTALLED_RUNNING; else echo INSTALLED_STOPPED; fi
  else
    echo NOT_INSTALLED
  fi')

case "$STATE" in
  NOJFFS)     die "no /jffs on this device — is it an Asuswrt-Merlin router?" ;;
  NOSCRIPTS)  die "JFFS custom scripts are disabled. Enable them in the web UI
       (Administration -> System -> 'Enable JFFS custom scripts and configs' = Yes,
       Apply, reboot if asked), then re-run this setup." ;;
esac

say ""
case "$STATE" in
  INSTALLED_RUNNING) say "Status: flowcache-doctor is INSTALLED and RUNNING." ;;
  INSTALLED_STOPPED) say "Status: flowcache-doctor is installed but NOT running." ;;
  NOT_INSTALLED)     say "Status: flowcache-doctor is NOT installed." ;;
esac
say ""

if [ "$STATE" = "NOT_INSTALLED" ]; then
  ask "Install it now? [Y/n]: "
  case "$REPLY" in n|N) say "Nothing done. Bye!"; exit 0 ;; esac
  ACTION=install
else
  say "  [u] uninstall"
  say "  [r] reinstall / repair (safe, idempotent)"
  say "  [s] show recent detections and exit"
  say "  [q] quit"
  ask "Choice [q]: "
  case "$REPLY" in
    u|U) ACTION=uninstall ;;
    r|R) ACTION=install ;;
    s|S) R '/jffs/scripts/roamctl log' || true; exit 0 ;;
    *)   say "Nothing done. Bye!"; exit 0 ;;
  esac
fi

say ""
if [ "$ACTION" = "install" ]; then
  R "curl -fsSL $RAW/install.sh | sh" || die "install failed."
  say ""
  say "Done! The detector is running, restarts itself on crash, and survives"
  say "reboots. Check what it finds anytime with:"
  say "  ssh $TARGET '/jffs/scripts/roamctl log'"
else
  R "curl -fsSL $RAW/uninstall.sh | sh" || die "uninstall failed."
  say ""
  say "Done! flowcache-doctor has been fully removed."
fi
