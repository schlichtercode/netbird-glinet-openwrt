#!/bin/sh
# NetBird watchdog — runs as a procd instance (`watchdog.sh loop`) because
# GL.iNet's crond uses /tmp/gl_crontabs (tmpfs) and ignores /etc/crontabs.
# `watchdog.sh once` runs a single pass (used by the panel / for debugging).
#
# Each pass: duplicate-daemon self-heal, reconnect when management is not
# Connected, router resolv.conf repair, dnsmasq forwarding sync for NetBird
# domains, exit-node ipset rules, memory logging.

. /usr/libexec/netbird/common.sh

LOCK="$NB_RUN/watchdog.lock"
LOGIN_WARNED=0

pass() {
    nb_load_config
    [ "$NB_ENABLED" = 1 ] || return 0

    # ── Duplicate daemon → full cleanup + procd restart ───────────────────
    if [ "$(nb_daemon_count)" -gt 1 ]; then
        nb_log "duplicate daemon detected — restarting service"
        /etc/init.d/netbird restart >/dev/null 2>&1
        return 0
    fi

    # ── Daemon missing → procd respawns it; nothing else to do this pass ──
    [ -S "$NB_SOCK" ] || { nb_log "daemon socket missing (procd will respawn)"; return 0; }

    # ── Reconnect ─────────────────────────────────────────────────────────
    local state
    state=$(nb_mgmt_state)
    case "$state" in
        Connected) LOGIN_WARNED=0 ;;
        NeedsLogin|LoginFailed)
            [ "$LOGIN_WARNED" = 1 ] || nb_log "not enrolled ($state): open Applications → NetBird and enter a setup key"
            LOGIN_WARNED=1
            return 0 ;;
        "")
            # daemon did not answer (still starting?) — never run `netbird up`
            # blindly: without an enrollment it would start a device-login flow.
            nb_log "daemon not answering yet — skipping this pass"
            return 0 ;;
        Connecting)
            # the daemon is working on it (auto-connect after start) — do not
            # fork the CLI on top of that
            return 0 ;;
        *)
            nb_log "management is '$state' — running netbird up"
            # shellcheck disable=SC2046
            nb_timeout 90 "$NB_BIN" up $(nb_up_args) >/dev/null 2>&1
            nb_invalidate_status
            sleep 5
            state=$(nb_mgmt_state) ;;
    esac

    # ── Firewall: fw3 reload wiped NetBird's chains? → reconnect ──────────
    if [ "$state" = Connected ] && ! nb_chains_present; then
        nb_log "NETBIRD-* iptables chains missing (firewall reload?) — re-applying via netbird down/up"
        nb_timeout 30 "$NB_BIN" down >/dev/null 2>&1
        # shellcheck disable=SC2046
        nb_timeout 90 "$NB_BIN" up $(nb_up_args) >/dev/null 2>&1
        nb_invalidate_status
    fi
    nb_firewall_zone_ensure

    # ── DNS: router resolver + LAN forwarding ─────────────────────────────
    nb_resolv_repair
    nb_dns_sync

    # ── Exit node: ACCEPT for every non-empty nb* ipset ───────────────────
    if iptables -n -L NETBIRD-RT-FWD-IN >/dev/null 2>&1; then
        for set in $(ipset list -n 2>/dev/null | grep '^nb'); do
            [ "$(ipset list "$set" 2>/dev/null | grep -c '^[0-9]')" -gt 0 ] || continue
            iptables -C NETBIRD-RT-FWD-IN -m set --match-set "$set" src -j ACCEPT 2>/dev/null || \
                iptables -I NETBIRD-RT-FWD-IN 1 -m set --match-set "$set" src -j ACCEPT 2>/dev/null
        done
    fi

    # ── Memory telemetry (logread) ────────────────────────────────────────
    nb_log "mgmt=$state wg=$(nb_wg_mode) rss=$(nb_daemon_rss_kb)kB mem_avail=$(nb_mem_available_kb)kB"
}

case "${1:-once}" in
    loop)
        mkdir -p "$NB_RUN"
        nb_load_config
        # Full pass every $NB_WATCHDOG_INTERVAL s; memory guard every 10 s.
        next_pass=$(( $(date +%s) + 15 ))
        while :; do
            nb_mem_guard && { sleep 30; continue; }
            if [ "$(date +%s)" -ge "$next_pass" ]; then
                if mkdir "$LOCK" 2>/dev/null; then
                    pass
                    rmdir "$LOCK" 2>/dev/null
                fi
                nb_load_config
                next_pass=$(( $(date +%s) + ${NB_WATCHDOG_INTERVAL:-300} ))
            fi
            sleep 10
        done
        ;;
    once)
        mkdir -p "$NB_RUN"
        if mkdir "$LOCK" 2>/dev/null; then
            pass
            rmdir "$LOCK" 2>/dev/null
        else
            echo "watchdog pass already running" >&2
            exit 1
        fi
        ;;
    *) echo "usage: $0 loop|once" >&2; exit 2 ;;
esac
