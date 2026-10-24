#!/bin/sh
# Shared helpers for the NetBird integration on GL.iNet firmware.
# Sourced by: /etc/init.d/netbird, watchdog.sh, cleanup.sh, exitnode.sh,
#             action.sh, netbird-status. BusyBox ash only (no bashisms).

NB_BIN="/usr/bin/netbird"
# CLI calls from procd / the panel run without HOME; NetBird's profile
# manager warns about that on every invocation.
export HOME="${HOME:-/root}"
[ "$HOME" = / ] && export HOME=/root
NB_LOG_DIR="/var/log/netbird"
NB_LOG="$NB_LOG_DIR/client.log"
NB_SOCK="/var/run/netbird.sock"
NB_STATE="/etc/netbird"              # persistent (overlay); /var/lib/netbird -> here
NB_RUN="/var/run/netbird"            # tmpfs scratch for status cache / action results
NB_DNSMASQ_CONF="/tmp/dnsmasq.d/netbird.conf"
NB_RESOLV_BACKUP="/etc/resolv.conf.original.netbird"

# ── UCI ──────────────────────────────────────────────────────────────────────
# nb_uci <section> <option> [default]
nb_uci() {
    local v
    v=$(uci -q get "netbird.$1.$2" 2>/dev/null)
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${3:-}"
}

nb_load_config() {
    NB_ENABLED=$(nb_uci settings enabled 1)
    NB_LOG_LEVEL=$(nb_uci settings log_level info)
    NB_GOGC=$(nb_uci settings gogc 50)
    NB_GOMEMLIMIT=$(nb_uci settings gomemlimit "")
    NB_WG_USERSPACE=$(nb_uci settings wg_userspace 0)
    NB_SKIP_NFT=$(nb_uci settings skip_nftables_check 1)
    NB_DISABLE_EBPF=$(nb_uci settings disable_ebpf_proxy 1)
    NB_WATCHDOG_INTERVAL=$(nb_uci settings watchdog_interval 300)
    NB_DAEMON_ENV_EXTRA=$(nb_uci settings daemon_env "")
    NB_JSON_SOCKET=$(nb_uci settings json_socket 1)
    NB_MEM_MIN_KB=$(nb_uci settings mem_min_kb 9216)
    NB_MEM_COOLDOWN=$(nb_uci settings mem_cooldown 120)
    NB_HW_SWITCH=$(nb_uci settings hw_switch 1)
    NB_HW_SWITCH_MODE=$(nb_uci settings hw_switch_mode service)   # service | exitnode
    NB_EXIT_NODE=$(nb_uci connection exit_node "")                 # network ID of the preferred exit node

    NB_MGMT_URL=$(nb_uci connection management_url "https://api.netbird.io:443")
    NB_HOSTNAME=$(nb_uci connection hostname "")
    NB_DISABLE_CLIENT_ROUTES=$(nb_uci connection disable_client_routes 1)
    NB_DISABLE_SERVER_ROUTES=$(nb_uci connection disable_server_routes 0)
    NB_DISABLE_DNS=$(nb_uci connection disable_dns 0)
    NB_DNS_ADDR=$(nb_uci connection dns_resolver_address 127.0.0.153)
    NB_LAN_DNS_FORWARD=$(nb_uci connection lan_dns_forward 1)
    NB_BLOCK_LAN=$(nb_uci connection block_lan_access 0)
    NB_WG_PORT=$(nb_uci connection wireguard_port 51820)
    NB_EXTRA_UP_ARGS=$(nb_uci connection extra_up_args "")
    NB_FW_ZONE=$(nb_uci connection firewall_zone 1)
    NB_API_TOKEN=$(nb_uci connection api_token "")
    NB_PEER_ID=$(nb_uci connection peer_id "")
    NB_ROUTE_ID=$(nb_uci connection route_id "")
}

# Arguments for `netbird up`, derived from UCI. Word-split on purpose: none of
# the values may contain whitespace (enforced by the RPC layer / validator).
# The daemon persists every flag it was last given (profile config.json), so
# booleans are always passed explicitly as =true/=false — otherwise switching
# an option off in UCI would never reach the daemon.
nb_bool() { [ "$1" = 1 ] && echo true || echo false; }
nb_up_args() {
    printf -- '--management-url %s ' "$NB_MGMT_URL"
    printf -- '--disable-client-routes=%s ' "$(nb_bool "$NB_DISABLE_CLIENT_ROUTES")"
    printf -- '--disable-server-routes=%s ' "$(nb_bool "$NB_DISABLE_SERVER_ROUTES")"
    printf -- '--disable-dns=%s ' "$(nb_bool "$NB_DISABLE_DNS")"
    [ "$NB_DISABLE_DNS" = 1 ] || printf -- '--dns-resolver-address %s:53 ' "$NB_DNS_ADDR"
    printf -- '--block-lan-access=%s ' "$(nb_bool "$NB_BLOCK_LAN")"
    [ -n "$NB_HOSTNAME" ] && printf -- '--hostname %s ' "$NB_HOSTNAME"
    [ -n "$NB_WG_PORT" ] && [ "$NB_WG_PORT" != 51820 ] && printf -- '--wireguard-port %s ' "$NB_WG_PORT"
    [ -n "$NB_EXTRA_UP_ARGS" ] && printf -- '%s ' "$NB_EXTRA_UP_ARGS"
}

# Environment for the daemon (KEY=VALUE words, space separated).
nb_daemon_env() {
    [ -n "$NB_GOGC" ] && printf 'GOGC=%s ' "$NB_GOGC"
    [ -n "$NB_GOMEMLIMIT" ] && printf 'GOMEMLIMIT=%s ' "$NB_GOMEMLIMIT"
    [ "$NB_WG_USERSPACE" = 1 ] && printf 'NB_WG_KERNEL_DISABLED=true '
    [ "$NB_SKIP_NFT" = 1 ] && printf 'NB_SKIP_NFTABLES_CHECK=true '
    [ "$NB_DISABLE_EBPF" = 1 ] && printf 'NB_DISABLE_EBPF_WG_PROXY=true '
    printf 'NB_LOG_MAX_SIZE_MB=2 NB_DISABLE_SSH_CONFIG=1 '
    [ -n "$NB_DAEMON_ENV_EXTRA" ] && printf '%s ' "$NB_DAEMON_ENV_EXTRA"
}

# ── Process helpers ──────────────────────────────────────────────────────────
nb_log() { logger -t netbird "$*" 2>/dev/null; }

# `timeout` applet is present on GL firmware, but keep a fallback.
nb_timeout() {
    if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

# Memory guard: when MemAvailable drops below mem_min_kb the router is about
# to thrash (page cache of the 46 MB binary gets evicted, everything lands in
# D state, SSH dies). Kill the daemon now, let run-daemon.sh wait mem_cooldown
# seconds before procd's respawn brings it back. Returns 0 if it fired.
nb_mem_guard() {
    local avail
    avail=$(nb_mem_available_kb)
    [ -n "$avail" ] && [ "$avail" -lt "${NB_MEM_MIN_KB:-9216}" ] || return 1
    [ "$(nb_daemon_count)" -gt 0 ] || return 1
    nb_log "MEMORY GUARD: MemAvailable=${avail}kB < ${NB_MEM_MIN_KB}kB — stopping daemon (rss=$(nb_daemon_rss_kb)kB), cooldown ${NB_MEM_COOLDOWN}s"
    mkdir -p "$NB_RUN"
    echo $(( $(date +%s) + NB_MEM_COOLDOWN )) > "$NB_RUN/hold-until"
    nb_kill_daemon 10
    rm -f "$NB_SOCK"
    nb_invalidate_status
    nb_dns_sync clear
    nb_resolv_restore
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    return 0
}

# PIDs of the real daemon only (not `netbird status` CLI invocations, which
# `pgrep -x netbird` would also count).
nb_daemon_pids() {
    # after exec the wrapper's pid IS the daemon; run-daemon.sh itself (still
    # in cooldown) must not count
    ps w 2>/dev/null | grep '[n]etbird service run' | grep -v run-daemon | awk '{print $1}'
}

nb_daemon_count() { nb_daemon_pids | wc -l | tr -d ' '; }

# Kill every netbird process and wait up to $1 seconds for them to exit.
# NOTE: no `pkill` applet on GL BusyBox; killall + pgrep are present.
nb_kill_daemon() {
    local max="${1:-10}" i=0
    killall -q -TERM netbird 2>/dev/null
    while pgrep -x netbird >/dev/null 2>&1 && [ "$i" -lt "$max" ]; do
        sleep 1; i=$((i + 1))
    done
    pgrep -x netbird >/dev/null 2>&1 && { nb_log "daemon did not exit within ${max}s — SIGKILL"; killall -q -9 netbird 2>/dev/null; }
    return 0
}

nb_prepare_dirs() {
    mkdir -p "$NB_STATE" "$NB_LOG_DIR" "$NB_RUN" /var/lib
    # /var -> /tmp on OpenWrt: keep config + WireGuard keys on the overlay.
    if [ ! -L /var/lib/netbird ]; then
        rm -rf /var/lib/netbird 2>/dev/null
        ln -s "$NB_STATE" /var/lib/netbird
    fi
}

# Management state word from `netbird status` ("Connected", "Disconnected",
# "NeedsLogin", ... or empty when the daemon does not answer).
nb_mgmt_state() {
    local out m
    [ -S "$NB_SOCK" ] || { echo ""; return; }
    # JSON first (gateway: "status"; CLI: "daemonStatus" + management.connected)
    m=$(nb_status_field 's.status or s.daemonStatus' 10)
    if [ -n "$m" ]; then
        case "$m" in
            NeedsLogin|LoginFailed|Connected|Idle|Connecting|Disconnected) echo "$m"; return ;;
        esac
        # CLI format reports daemonStatus=Connected only when management is up
        if [ "$(nb_status_field 's.management and s.management.connected or (s.fullStatus and s.fullStatus.managementState and s.fullStatus.managementState.connected)' 10)" = true ]; then
            echo Connected; return
        fi
        echo "$m"; return
    fi
    # No JSON: with the gateway configured that means "daemon still starting";
    # never fork the CLI here (it runs from the watchdog and the panel).
    [ "$NB_JSON_SOCKET" = 1 ] && { echo ""; return; }
    out=$(nb_timeout 15 "$NB_BIN" status 2>&1)
    case "$out" in
        *NeedsLogin*) echo NeedsLogin; return ;;
        *LoginFailed*) echo LoginFailed; return ;;
    esac
    m=$(echo "$out" | sed -n 's/^Management: *\([A-Za-z]*\).*/\1/p' | head -1)
    [ -n "$m" ] && { echo "$m"; return; }
    # no "Management:" line: report the daemon state word (Idle, Connecting, …)
    echo "$out" | sed -n 's/^Daemon status: *\([A-Za-z]*\).*/\1/p' | head -1
}

# JSON status for the panel / watchdog.
# Preferred source: the daemon's HTTP/JSON gateway on loopback TCP (enabled by
# the init script; GL's curl 7.63 has no unix-socket support) — a cheap curl,
# no second Go process. Loopback only; the daemon treats TCP callers as
# unprivileged, which is fine for Status.
# Fallback: `netbird status --json`, which forks the 46 MB CLI binary; on a
# 128 MB router that must never run twice at once (dir lock) and must give up
# quickly. Result is cached for $1 seconds (default 5).
NB_HTTP_ADDR="127.0.0.1:18090"

nb_status_json() {
    local cache="$NB_RUN/status.json" lock="$NB_RUN/status.lock" maxage="${1:-5}" now mt age
    mkdir -p "$NB_RUN"
    if [ -f "$cache" ]; then
        now=$(date +%s); mt=$(date -r "$cache" +%s 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
        age=$((now - mt))
        [ "$age" -lt "$maxage" ] && { cat "$cache"; return 0; }
    fi
    [ -S "$NB_SOCK" ] || { rm -f "$cache"; return 1; }
    if ! mkdir "$lock" 2>/dev/null; then
        # another fetch in flight: serve stale data rather than piling up
        [ -f "$cache" ] && cat "$cache"
        return 0
    fi
    if [ "$NB_JSON_SOCKET" = 1 ]; then
        # gateway only: if it does not answer the daemon is still starting —
        # report "unknown" rather than forking the 46 MB CLI.
        curl -s --max-time 8 -X POST -H 'Content-Type: application/json' \
            -d '{"getFullPeerStatus":true}' "http://$NB_HTTP_ADDR/daemon.DaemonService/Status" > "$cache.tmp" 2>/dev/null
    else
        nb_timeout 10 "$NB_BIN" status --json > "$cache.tmp" 2>/dev/null
    fi
    if [ -s "$cache.tmp" ] && head -c 1 "$cache.tmp" | grep -q '{'; then
        mv "$cache.tmp" "$cache"
    else
        rm -f "$cache.tmp"
    fi
    rmdir "$lock" 2>/dev/null
    [ -f "$cache" ] && cat "$cache"
}

# Extract a value from the status JSON (either format) with Lua: $1 = lua
# expression over `s` (decoded table), e.g. 's.status or s.daemonStatus'.
nb_status_field() {
    # NOTE: Lua 5.1's standalone interpreter treats a positional argument
    # after -e as a script file, so the expression travels via environment.
    nb_status_json "${2:-5}" | NB_EXPR="$1" lua -e '
        local ok, cjson = pcall(require, "cjson"); if not ok then os.exit(1) end
        local raw = io.read("*a"); if not raw or raw == "" then os.exit(1) end
        local ok2, s = pcall(cjson.decode, raw); if not ok2 or type(s) ~= "table" then os.exit(1) end
        local f = assert(loadstring("local s = ...; return " .. os.getenv("NB_EXPR")))
        local v = f(s)
        if v == nil or v == cjson.null then os.exit(1) end
        io.write(tostring(v))' 2>/dev/null
}

nb_invalidate_status() { rm -f "$NB_RUN/status.json"; }

# RSS of the daemon in kB (empty if not running).
nb_daemon_rss_kb() {
    local pid
    pid=$(nb_daemon_pids | head -1)
    [ -n "$pid" ] && awk '/VmRSS/{print $2}' "/proc/$pid/status" 2>/dev/null
}

nb_mem_available_kb() { awk '/MemAvailable/{print $2}' /proc/meminfo; }

# "kernel" if wt0 is a real WireGuard netdev, "userspace" if it is a TUN
# (wireguard-go), "-" if the interface does not exist.
nb_wg_mode() {
    [ -d /sys/class/net/wt0 ] || { echo "-"; return; }
    [ -e /sys/class/net/wt0/tun_flags ] && echo userspace || echo kernel
}

# ── dnsmasq forwarding for NetBird domains (LAN clients) ─────────────────────
# Writes server=/<domain>/<resolver> lines for every domain NetBird serves
# (peer domain + DNS routes from the management server). Reloads dnsmasq only
# when the file content actually changed. Pass "clear" to remove the file.
nb_dns_sync() {
    local new="$NB_RUN/dnsmasq.new" domains=""
    mkdir -p "$NB_RUN" /tmp/dnsmasq.d
    if [ "$1" != clear ] && [ "$NB_DISABLE_DNS" != 1 ] && [ "$NB_LAN_DNS_FORWARD" = 1 ]; then
        domains=$(nb_status_json 30 | lua /usr/libexec/netbird/dnsdomains.lua 2>/dev/null)
    fi
    : > "$new"
    if [ -n "$domains" ]; then
        echo "# Managed by NetBird watchdog — do not edit (see /etc/config/netbird)" >> "$new"
        for d in $domains; do
            echo "server=/$d/$NB_DNS_ADDR" >> "$new"
            echo "rebind-domain-ok=/$d/" >> "$new"
        done
    fi
    if [ -s "$new" ]; then
        if ! cmp -s "$new" "$NB_DNSMASQ_CONF" 2>/dev/null; then
            mv "$new" "$NB_DNSMASQ_CONF"
            nb_log "dnsmasq: forwarding $(echo "$domains" | wc -w | tr -d ' ') NetBird domain(s) to $NB_DNS_ADDR"
            /etc/init.d/dnsmasq reload >/dev/null 2>&1
        fi
    elif [ -f "$NB_DNSMASQ_CONF" ]; then
        rm -f "$NB_DNSMASQ_CONF"
        nb_log "dnsmasq: NetBird forwarding removed"
        /etc/init.d/dnsmasq reload >/dev/null 2>&1
    fi
    rm -f "$new"
}

# Router's own resolver: NetBird rewrites /etc/resolv.conf (-> /tmp/resolv.conf
# on OpenWrt, tmpfs). dnsmasq restarts overwrite it with "nameserver 127.0.0.1"
# and NetBird does not notice. Re-point it at the NetBird proxy when NetBird is
# connected with DNS enabled; NetBird forwards everything else to its backup
# upstream (127.0.0.1 = dnsmasq), so nothing is lost.
nb_resolv_repair() {
    [ "$NB_DISABLE_DNS" = 1 ] && return 0
    [ "$(nb_mgmt_state)" = Connected ] || return 0
    grep -q "nameserver $NB_DNS_ADDR" /etc/resolv.conf 2>/dev/null && return 0
    [ -f "$NB_RESOLV_BACKUP" ] || cp /etc/resolv.conf "$NB_RESOLV_BACKUP" 2>/dev/null
    {
        echo "# Generated by NetBird (repaired by netbird watchdog)"
        grep -E '^(search|domain|options)' /etc/resolv.conf 2>/dev/null
        echo "nameserver $NB_DNS_ADDR"
    } > /tmp/netbird-resolv.tmp && cat /tmp/netbird-resolv.tmp > /etc/resolv.conf
    rm -f /tmp/netbird-resolv.tmp
    nb_log "resolv.conf: re-pointed router resolver at $NB_DNS_ADDR"
}

nb_resolv_restore() {
    if grep -q "NetBird" /etc/resolv.conf 2>/dev/null; then
        if [ -s "$NB_RESOLV_BACKUP" ]; then
            cat "$NB_RESOLV_BACKUP" > /etc/resolv.conf
        else
            printf 'search lan\nnameserver 127.0.0.1\n' > /etc/resolv.conf
        fi
    fi
}

# ── GL-native firewall zone for wt0 ──────────────────────────────────────────
# Lets LAN clients use NetBird routes / exit nodes and lets this router act as
# exit node for peers (masquerade on the zone, lan→netbird, netbird→wan).
# Idempotent: only writes UCI when something is missing; reloads fw3 then.
nb_firewall_zone_ensure() {
    [ "$NB_FW_ZONE" = 1 ] || return 0
    local changed=0
    if ! uci -q get firewall.netbird >/dev/null 2>&1; then
        uci set firewall.netbird=zone
        uci set firewall.netbird.name='netbird'
        uci set firewall.netbird.input='REJECT'
        uci set firewall.netbird.output='ACCEPT'
        uci set firewall.netbird.forward='ACCEPT'
        uci set firewall.netbird.masq='1'
        uci set firewall.netbird.mtu_fix='1'
        uci add_list firewall.netbird.device='wt0'
        changed=1
    fi
    if ! uci -q get firewall.netbird_lan_fwd >/dev/null 2>&1; then
        uci set firewall.netbird_lan_fwd=forwarding
        uci set firewall.netbird_lan_fwd.src='lan'
        uci set firewall.netbird_lan_fwd.dest='netbird'
        changed=1
    fi
    if ! uci -q get firewall.netbird_wan_fwd >/dev/null 2>&1; then
        uci set firewall.netbird_wan_fwd=forwarding
        uci set firewall.netbird_wan_fwd.src='netbird'
        uci set firewall.netbird_wan_fwd.dest='wan'
        changed=1
    fi
    if [ "$changed" = 1 ]; then
        uci commit firewall
        nb_log "firewall: added zone 'netbird' (wt0) + forwardings lan→netbird, netbird→wan"
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi
}

nb_firewall_zone_remove() {
    local changed=0
    for s in netbird_wan_fwd netbird_lan_fwd netbird; do
        uci -q get "firewall.$s" >/dev/null 2>&1 && { uci delete "firewall.$s"; changed=1; }
    done
    [ "$changed" = 1 ] && { uci commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1; }
    return 0
}

# NetBird's own NETBIRD-* iptables chains vanish when fw3 flushes the tables
# (firewall restart on WAN changes). While connected they must exist.
nb_chains_present() { iptables-save 2>/dev/null | grep -q '^:NETBIRD'; }

# ── Networks / exit nodes (client side) via the daemon gateway ───────────────
nb_gw_post() { # <method> <json-body>
    curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d "$2" \
        "http://$NB_HTTP_ADDR/daemon.DaemonService/$1" 2>/dev/null
}
nb_networks_json() { [ -S "$NB_SOCK" ] && nb_gw_post ListNetworks '{}'; }
# nb_network_set <network-id> on|off
nb_network_set() {
    local id esc
    esc=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
    case "$2" in
        on)  nb_gw_post SelectNetworks "{\"networkIDs\":[\"$esc\"],\"append\":true}" >/dev/null ;;
        off) nb_gw_post DeselectNetworks "{\"networkIDs\":[\"$esc\"]}" >/dev/null ;;
        *) return 2 ;;
    esac
    nb_invalidate_status
    nb_log "network '$1' -> $2"
}
