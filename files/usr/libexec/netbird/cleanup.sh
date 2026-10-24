#!/bin/sh
# Full NetBird teardown: processes, NETBIRD-* iptables chains in every table,
# NetBird ip rules, dnsmasq forwarding, router resolv.conf.
# Does NOT touch /etc/netbird (enrollment survives). Restart with:
#   /etc/init.d/netbird restart

. /usr/libexec/netbird/common.sh
nb_load_config

echo "Stopping NetBird processes..."
nb_timeout 15 "$NB_BIN" down >/dev/null 2>&1
nb_kill_daemon 10
rm -f "$NB_SOCK"
nb_invalidate_status

echo "Removing NETBIRD-* iptables chains..."
for tbl in filter nat mangle raw; do
    iptables-save -t "$tbl" 2>/dev/null | grep -E '^-A.+-j NETBIRD' | sed 's/^-A/-D/' | \
        while IFS= read -r rule; do
            # shellcheck disable=SC2086
            iptables -t "$tbl" $rule 2>/dev/null || true
        done
    iptables-save -t "$tbl" 2>/dev/null | grep '^:NETBIRD' | cut -d' ' -f1 | tr -d ':' | \
        while IFS= read -r chain; do
            iptables -t "$tbl" -F "$chain" 2>/dev/null || true
            iptables -t "$tbl" -X "$chain" 2>/dev/null || true
        done
done

echo "Removing NetBird ip rules..."
ip rule show 2>/dev/null | grep -iE 'fwmark 0x1bd|lookup 712[0-9]' | sed 's/^[0-9]*:[[:space:]]*//' | \
    while IFS= read -r rule; do
        # shellcheck disable=SC2086
        ip rule del $rule 2>/dev/null || true
    done

nb_dns_sync clear
nb_resolv_restore

echo "Remaining NETBIRD chains:"
iptables-save 2>/dev/null | grep NETBIRD || echo "  (none — clean)"
echo "Done. Restart with: /etc/init.d/netbird restart"
