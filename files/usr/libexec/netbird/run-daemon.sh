#!/bin/sh
# procd runs the NetBird daemon through this wrapper:
#   1. honours a cooldown set by the watchdog's memory guard (the daemon was
#      killed to save the router from thrashing — do not come straight back)
#   2. makes the daemon the kernel OOM killer's preferred victim, so a real
#      out-of-memory situation kills NetBird and not nginx/dropbear/dnsmasq
#   3. execs netbird (same pid, procd keeps supervising it)
. /usr/libexec/netbird/common.sh
nb_load_config
mkdir -p "$NB_RUN"

hold="$NB_RUN/hold-until"
if [ -f "$hold" ]; then
    until_ts=$(cat "$hold" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ "$until_ts" -gt "$now" ] 2>/dev/null; then
        nb_log "memory guard cooldown: waiting $((until_ts - now))s before starting the daemon"
        sleep $((until_ts - now))
    fi
    rm -f "$hold"
fi

# The daemon persists its flags in the profile file and auto-connects with
# them on start; `netbird up` on a live connection only says "Already
# connected". So UCI is synced into the profile here, before every start —
# no CLI fork needed for a settings change. Simple line-based edits only.
nb_sync_profile() {
    local f="$NB_STATE/default.json"
    [ -f "$f" ] || return 0
    set_bool() { # key uci-value
        local v; v=$([ "$2" = 1 ] && echo true || echo false)
        grep -q "\"$1\": *\(true\|false\)" "$f" && sed -i "s/\"$1\": *\(true\|false\)/\"$1\": $v/" "$f"
    }
    set_bool DisableClientRoutes "$NB_DISABLE_CLIENT_ROUTES"
    set_bool DisableServerRoutes "$NB_DISABLE_SERVER_ROUTES"
    set_bool DisableDNS "$NB_DISABLE_DNS"
    set_bool BlockLANAccess "$NB_BLOCK_LAN"
    [ "$NB_DISABLE_DNS" = 1 ] || sed -i "s/\"CustomDNSAddress\": *\"[^\"]*\"/\"CustomDNSAddress\": \"$NB_DNS_ADDR:53\"/" "$f"
    [ -n "$NB_WG_PORT" ] && sed -i "s/\"WgPort\": *[0-9]*/\"WgPort\": $NB_WG_PORT/" "$f"
    return 0
}
nb_sync_profile

echo 1000 > /proc/self/oom_score_adj 2>/dev/null
nb_invalidate_status
rm -f "$NB_SOCK"
exec "$NB_BIN" service run --log-file "$NB_LOG" --log-level "$NB_LOG_LEVEL" "$@"
