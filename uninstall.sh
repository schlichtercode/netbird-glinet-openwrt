#!/bin/sh
# Remove the NetBird integration from a GL.iNet router.
#   ./uninstall.sh [root@192.168.8.1] [--purge]
# --purge also deletes /etc/netbird (enrollment keys) and /etc/config/netbird.
#
# The router-side logic lives in files/usr/libexec/netbird/setup-router.sh
# (shared with the opkg package's prerm). This copies the repo's version to
# the router's tmpfs and runs it, so it also works on routers installed with
# an older install.sh. If NetBird was installed as the opkg package
# netbird-glinet, setup-router.sh hands over to `opkg remove`.
set -eu
ROUTER=""; PURGE=0
for a in "$@"; do case "$a" in --purge) PURGE=1 ;; -*) echo "unknown option $a" >&2; exit 2 ;; *) ROUTER="$a" ;; esac; done
ROUTER="${ROUTER:-root@192.168.8.1}"; case "$ROUTER" in *@*) ;; *) ROUTER="root@$ROUTER" ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP="$HERE/files/usr/libexec/netbird/setup-router.sh"
[ -f "$SETUP" ] || { echo "setup-router.sh not found next to uninstall.sh" >&2; exit 1; }
SSH_BASE="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=10 ${SSH_OPTS:-}"
PURGE_FLAG=""; [ "$PURGE" = 1 ] && PURGE_FLAG="--purge"
# shellcheck disable=SC2086
ssh $SSH_BASE "$ROUTER" 'cat > /var/run/netbird-setup-router.sh' < "$SETUP"
# shellcheck disable=SC2086
ssh $SSH_BASE "$ROUTER" "sh /var/run/netbird-setup-router.sh uninstall $PURGE_FLAG; rm -f /var/run/netbird-setup-router.sh"
