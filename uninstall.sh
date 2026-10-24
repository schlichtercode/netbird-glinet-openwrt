#!/bin/sh
# Remove the NetBird integration from a GL.iNet router.
#   ./uninstall.sh [root@192.168.8.1] [--purge]
# --purge also deletes /etc/netbird (enrollment keys) and /etc/config/netbird.
set -eu
ROUTER=""; PURGE=0
for a in "$@"; do case "$a" in --purge) PURGE=1 ;; -*) echo "unknown option $a" >&2; exit 2 ;; *) ROUTER="$a" ;; esac; done
ROUTER="${ROUTER:-root@192.168.8.1}"; case "$ROUTER" in *@*) ;; *) ROUTER="root@$ROUTER" ;; esac
SSH_BASE="-o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o ConnectTimeout=10 ${SSH_OPTS:-}"
# shellcheck disable=SC2086
ssh $SSH_BASE "$ROUTER" "PURGE=$PURGE sh -s" <<'REMOTE'
set -u
echo ">> stopping service"
[ -x /etc/init.d/netbird ] && { /etc/init.d/netbird stop; /etc/init.d/netbird disable; } 2>/dev/null
killall -q netbird 2>/dev/null; sleep 1; killall -q -9 netbird 2>/dev/null
[ -f /usr/libexec/netbird/common.sh ] && { . /usr/libexec/netbird/common.sh; nb_load_config; nb_firewall_zone_remove; nb_dns_sync clear; nb_resolv_restore; }
echo ">> removing switch hook"
f=/etc/gl-switch.d/vpn.sh
if [ -f "$f" ] && grep -q "netbird/switch.sh" "$f"; then
    sed -i '/netbird-glinet-openwrt: let the switch/d; /netbird\/switch.sh/d' "$f"
    rm -f "$f.pre-netbird"
fi
echo ">> restoring GL vpn-client RPC object and dashboard bundle"
f=/usr/lib/oui-httpd/rpc/vpn-client
[ -f "$f.gl" ] && grep -q "NETBIRD-VPN-CLIENT-WRAPPER" "$f" 2>/dev/null && mv "$f.gl" "$f"
v=/www/views/gl-sdk4-ui-vpndashboard.common.js.gz
[ -f "$v.pre-netbird" ] && mv "$v.pre-netbird" "$v"
echo ">> removing files"
rm -f /etc/init.d/netbird /usr/lib/oui-httpd/rpc/netbird /usr/share/gl-validator.d/netbird.lua \
      /usr/share/oui/menu.d/netbird.json /www/views/gl-sdk4-ui-netbird.common.js.gz /www/views/gl-sdk4-ui-netbird.common.js \
      /www/i18n/gl-sdk4-ui-netbird.*.json /usr/sbin/netbird-status /usr/sbin/netbird-setup-swap \
      /etc/sysctl.d/90-netbird.conf /tmp/dnsmasq.d/netbird.conf /etc/resolv.conf.original.netbird
rm -rf /usr/libexec/netbird /var/run/netbird /var/log/netbird
[ -L /var/lib/netbird ] && rm -f /var/lib/netbird
rm -f /usr/bin/netbird
if [ "$PURGE" = 1 ]; then
    rm -rf /etc/netbird /etc/config/netbird
    echo ">> purged enrollment + config"
else
    echo ">> kept /etc/netbird (enrollment) and /etc/config/netbird — use --purge to delete"
fi
/etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
[ -x /etc/init.d/nginx ] && /etc/init.d/nginx restart >/dev/null 2>&1 || true
echo ">> done"
REMOTE
