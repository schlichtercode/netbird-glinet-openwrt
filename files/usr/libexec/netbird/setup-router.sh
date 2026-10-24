#!/bin/sh
# netbird-glinet-openwrt — router-side setup. This script runs ON the router.
#
#   setup-router.sh sysctl
#       apply /etc/sysctl.d/90-netbird.conf now (vm.overcommit_memory=1 must be
#       active before a Go-1.26 NetBird binary is executed on 128 MB RAM)
#   setup-router.sh install [--no-fetch] [--netbird-version X.Y.Z] [--management-url URL]
#       everything that has to happen once the files are in place: UCI
#       defaults for small routers / old kernels, cleanup of the old upstream
#       layout, hardware-switch hook, GL VPN-client wrapper + dashboard label,
#       NetBird binary via netbird-fetch-binary (unless --no-fetch), service
#       enable + restart, nginx restart when the panel's RPC object changed
#   setup-router.sh uninstall [--purge] [--keep-files]
#       reverse of install. --keep-files leaves the packaged files to opkg
#       (used by the .ipk prerm); --purge also deletes /etc/netbird
#       (enrollment keys) and /etc/config/netbird
#
# Callers: install.sh / uninstall.sh (over SSH) and the opkg package's
# postinst / prerm. Idempotent — re-run after a GL firmware update, which
# brings GL's original vpn-client object and dashboard bundle back.
# BusyBox ash only; the same logic must not be duplicated in install.sh.
set -u

ok()   { echo "   + $*"; }
warn() { echo "   ! $*"; }

SYSCTL_FILE=/etc/sysctl.d/90-netbird.conf
RPC=/usr/lib/oui-httpd/rpc/netbird
RPC_MD5_STATE=/etc/netbird/panel-rpc.md5   # md5 of $RPC when nginx last restarted
VPNC=/usr/lib/oui-httpd/rpc/vpn-client
WRAPPER=/usr/libexec/netbird/vpn-client-wrapper.lua
DASH=/www/views/gl-sdk4-ui-vpndashboard.common.js.gz
SWITCH_HOOK=/etc/gl-switch.d/vpn.sh
BIN=/usr/bin/netbird

CMD="${1:-}"; [ $# -gt 0 ] && shift
NO_FETCH=0; NB_VER=""; MGMT_URL=""; PURGE=0; KEEP_FILES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-fetch) NO_FETCH=1 ;;
        --netbird-version) NB_VER="$2"; shift ;;
        --management-url) MGMT_URL="$2"; shift ;;
        --purge) PURGE=1 ;;
        --keep-files) KEEP_FILES=1 ;;
        *) echo "setup-router.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

# nginx restart, detached: when this runs from the GL panel (opkg install /
# remove triggered in the browser) the calling nginx worker must survive
# until opkg has reported back. Restart, not reload: old workers would linger
# behind the panel's websocket and eat 15 MB each on a 128 MB router.
nginx_restart_later() {
    [ -x /etc/init.d/nginx ] || return 0
    ( sleep 3; /etc/init.d/nginx restart ) >/dev/null 2>&1 </dev/null &
}

apply_sysctl() {
    if [ -f "$SYSCTL_FILE" ]; then
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
        ok "sysctl applied from $SYSCTL_FILE (keepalive, ip_forward, overcommit=1)"
    else
        warn "$SYSCTL_FILE missing — Go-1.26 binaries may segfault on 128 MB routers"
    fi
}

fix_perms() {
    mkdir -p /usr/libexec/netbird /usr/lib/oui-httpd/rpc /usr/share/gl-validator.d \
             /usr/share/oui/menu.d /www/views /www/i18n /etc/netbird /var/log/netbird
    chmod 755 /etc/init.d/netbird /usr/libexec/netbird/*.sh /usr/sbin/netbird-status \
              /usr/sbin/netbird-setup-swap /usr/sbin/netbird-fetch-binary 2>/dev/null
    chmod 644 "$RPC" /usr/share/gl-validator.d/netbird.lua /usr/share/oui/menu.d/netbird.json \
              /www/i18n/gl-sdk4-ui-netbird.*.json /www/views/gl-sdk4-ui-netbird.common.js.gz 2>/dev/null
    # the panel loads the gzipped view; drop a plain copy from older installs
    [ -f /www/views/gl-sdk4-ui-netbird.common.js.gz ] && rm -f /www/views/gl-sdk4-ui-netbird.common.js
    return 0
}

tune_uci() {
    if ! uci -q get netbird.settings >/dev/null 2>&1; then
        warn "/etc/config/netbird missing — copy the template from the repo (files/etc/config/netbird)"
        return 0
    fi
    if [ -n "$MGMT_URL" ]; then
        uci set netbird.connection.management_url="$MGMT_URL" && uci commit netbird
        ok "management URL set to $MGMT_URL"
    fi
    local mem_total kernel kmaj cur
    mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo); : "${mem_total:=0}"
    if [ "$mem_total" -lt 262144 ]; then
        cur=$(uci -q get netbird.settings.gomemlimit)
        case "$cur" in ""|48MiB) uci set netbird.settings.gomemlimit=32MiB; uci commit netbird ;; esac
        ok "low-memory router ($((mem_total/1024)) MB): GOMEMLIMIT=32MiB, GOGC=50"
    fi
    kernel=$(uname -r); kmaj=${kernel%%.*}
    if [ "${kmaj:-5}" -lt 5 ] 2>/dev/null; then
        uci set netbird.settings.disable_ebpf_proxy=1; uci commit netbird
        ok "kernel $kernel: eBPF proxy disabled"
    fi
}

# Leftovers of the old upstream layout (nginx CGI UI, cron watchdog, rc.local).
remove_old_layout() {
    local f
    for f in /etc/nginx/gl-conf.d/netbird.conf /www/cgi-bin/netbird-api /www/cgi-bin/netbird-ui \
             /usr/share/oui/menu.d/netbirdview.json /www/views/gl-sdk4-ui-netbirdview.common.js.gz \
             /usr/libexec/netbird-watchdog.sh /usr/libexec/netbird-cleanup.sh \
             /usr/libexec/netbird-toggle-exit.sh /usr/libexec/netbird-setup-api.sh; do
        [ -e "$f" ] && { rm -f "$f"; ok "removed old $f"; }
    done
    rm -f /www/i18n/gl-sdk4-ui-netbirdview.*.json
    [ -d /www/netbird ] && { rm -rf /www/netbird; ok "removed old /www/netbird"; }
    if [ -f /etc/crontabs/root ] && grep -q netbird-watchdog /etc/crontabs/root; then
        sed -i '/netbird-watchdog/d' /etc/crontabs/root; ok "removed old cron line"
    fi
    if grep -qi netbird /etc/rc.local 2>/dev/null; then
        cp /etc/rc.local /etc/rc.local.pre-netbird
        grep -vi netbird /etc/rc.local > /etc/rc.local.new && mv /etc/rc.local.new /etc/rc.local && chmod +x /etc/rc.local
        ok "removed NetBird lines from /etc/rc.local (backup: /etc/rc.local.pre-netbird)"
    fi
    return 0
}

# Hardware toggle switch: /etc/gl-switch.d/vpn.sh is GL.iNet's handler for the
# "VPN client" switch function; two appended lines hand the event to switch.sh.
hook_switch() {
    if [ -f "$SWITCH_HOOK" ] && ! grep -q "netbird/switch.sh" "$SWITCH_HOOK"; then
        cp "$SWITCH_HOOK" "$SWITCH_HOOK.pre-netbird"
        printf '\n# netbird-glinet-openwrt: let the switch also control NetBird (uninstall removes this)\n[ -x /usr/libexec/netbird/switch.sh ] && /usr/libexec/netbird/switch.sh "$1"\n' >> "$SWITCH_HOOK"
        ok "hooked $SWITCH_HOOK (backup: $SWITCH_HOOK.pre-netbird)"
    fi
    ok "hardware switch: NetBird follows the \"VPN client\" switch function"
}
unhook_switch() {
    if [ -f "$SWITCH_HOOK" ] && grep -q "netbird/switch.sh" "$SWITCH_HOOK"; then
        sed -i '/netbird-glinet-openwrt: let the switch/d; /netbird\/switch.sh/d' "$SWITCH_HOOK"
        rm -f "$SWITCH_HOOK.pre-netbird"
    fi
}

# GL panel: VPN indicator + VPN Dashboard card. Wrap GL's vpn-client RPC
# object (original kept as vpn-client.gl) and label the "netbird" tunnel type
# in the dashboard bundle (backup kept). Sets PANEL_CHANGED=1 when nginx must
# pick up a new object.
PANEL_CHANGED=0
patch_gl_panel() {
    if [ -f "$VPNC" ] && ! grep -q "NETBIRD-VPN-CLIENT-WRAPPER" "$VPNC"; then
        cp "$VPNC" "$VPNC.gl"; PANEL_CHANGED=1
    fi
    if [ -f "$VPNC.gl" ] && [ -f "$WRAPPER" ] && ! cmp -s "$WRAPPER" "$VPNC"; then
        cp "$WRAPPER" "$VPNC"; chmod 644 "$VPNC"; PANEL_CHANGED=1
    fi
    if [ -f "$DASH" ] && ! zcat "$DASH" | grep -q '"netbird"===o?"NetBird"'; then
        [ -f "$DASH.pre-netbird" ] || cp "$DASH" "$DASH.pre-netbird"
        zcat "$DASH.pre-netbird" | sed \
            -e 's/d={wireguard:"WireGuard",openvpn:"OpenVPN"}/d={wireguard:"WireGuard",openvpn:"OpenVPN",netbird:"NetBird"}/' \
            -e 's/b\.label=S?M?""+M\.replace(\/,\/g," \/ "):C:`${T} \/ ${C}`/b.label=S?M?""+M.replace(\/,\/g," \/ "):C:"netbird"===o?"NetBird":`${T} \/ ${C}`/' \
            | gzip -9 > "$DASH.tmp" && mv "$DASH.tmp" "$DASH"
        if zcat "$DASH" | grep -q 'netbird:"NetBird"'; then
            ok "labelled NetBird in the VPN dashboard bundle (backup: $DASH.pre-netbird)"
        else
            mv "$DASH.pre-netbird" "$DASH"; warn "dashboard bundle layout unknown — left untouched"
        fi
    fi
    ok "GL panel: VPN indicator + dashboard card show NetBird"
}
unpatch_gl_panel() {
    [ -f "$VPNC.gl" ] && grep -q "NETBIRD-VPN-CLIENT-WRAPPER" "$VPNC" 2>/dev/null && mv "$VPNC.gl" "$VPNC"
    [ -f "$DASH.pre-netbird" ] && mv "$DASH.pre-netbird" "$DASH"
    return 0
}

install_binary() {
    [ "$NO_FETCH" = 1 ] && return 0
    if [ ! -x /usr/sbin/netbird-fetch-binary ]; then
        warn "/usr/sbin/netbird-fetch-binary missing — binary not installed"; return 0
    fi
    set -- --no-restart
    [ -n "$NB_VER" ] && set -- "$@" --version "$NB_VER"
    if ! /usr/sbin/netbird-fetch-binary "$@"; then
        warn "NetBird binary not installed — fix the cause (internet? flash?) and run: netbird-fetch-binary"
    fi
    return 0
}

start_service() {
    /etc/init.d/netbird enable 2>/dev/null
    if [ -x "$BIN" ]; then
        /etc/init.d/netbird restart >/dev/null 2>&1 || warn "service restart returned an error — check: logread -e netbird"
        ok "service enabled and started"
    else
        warn "$BIN missing — service enabled but not started (run: netbird-fetch-binary)"
    fi
}

# nginx workers cache the Lua RPC object; a changed object needs a restart.
# Compare against the md5 recorded at the last restart so re-runs with an
# unchanged object (install.sh --skip-binary, opkg reinstall) leave nginx alone.
restart_nginx_if_needed() {
    local new old
    new=$(md5sum "$RPC" 2>/dev/null | cut -d' ' -f1)
    old=$(cat "$RPC_MD5_STATE" 2>/dev/null || true)
    if [ "$PANEL_CHANGED" = 1 ] || [ "$new" != "$old" ]; then
        mkdir -p "$(dirname "$RPC_MD5_STATE")"; echo "$new" > "$RPC_MD5_STATE"
        nginx_restart_later
        ok "nginx restarts in a few seconds (panel RPC object changed) — reload the panel page"
    else
        ok "panel RPC object unchanged — nginx left alone"
    fi
}

report_state() {
    [ -x "$BIN" ] || return 0
    sleep 3
    local state
    state=$(. /usr/libexec/netbird/common.sh; nb_load_config; echo "daemon=$(nb_daemon_count) mgmt=$(nb_mgmt_state) wg=$(nb_wg_mode) rss=$(nb_daemon_rss_kb)kB avail=$(nb_mem_available_kb)kB" 2>/dev/null) || true
    ok "service state: $state"
}

do_install() {
    apply_sysctl
    fix_perms
    tune_uci
    remove_old_layout
    hook_switch
    patch_gl_panel
    install_binary
    start_service
    restart_nginx_if_needed
    report_state
}

do_uninstall() {
    # Installed through opkg (or the GL panel)? Then opkg owns the files.
    if [ "$KEEP_FILES" = 0 ] && opkg status netbird-glinet 2>/dev/null | grep -q '^Status:.*installed'; then
        echo ">> netbird-glinet is an opkg package here — removing it with opkg"
        opkg remove netbird-glinet || warn "opkg remove failed"
        if [ "$PURGE" = 1 ]; then rm -rf /etc/netbird /etc/config/netbird; echo ">> purged enrollment + config"; fi
        return 0
    fi
    echo ">> stopping service"
    [ -x /etc/init.d/netbird ] && { /etc/init.d/netbird stop; /etc/init.d/netbird disable; } 2>/dev/null
    killall -q netbird 2>/dev/null; sleep 1; killall -q -9 netbird 2>/dev/null
    if [ -f /usr/libexec/netbird/common.sh ]; then
        ( . /usr/libexec/netbird/common.sh; nb_load_config; nb_firewall_zone_remove; nb_dns_sync clear; nb_resolv_restore ) 2>/dev/null
    fi
    echo ">> removing switch hook, restoring GL vpn-client object and dashboard bundle"
    unhook_switch
    unpatch_gl_panel
    echo ">> removing files"
    if [ "$KEEP_FILES" = 0 ]; then
        rm -f /etc/init.d/netbird "$RPC" /usr/share/gl-validator.d/netbird.lua \
              /usr/share/oui/menu.d/netbird.json /www/views/gl-sdk4-ui-netbird.common.js.gz \
              /www/views/gl-sdk4-ui-netbird.common.js /www/i18n/gl-sdk4-ui-netbird.*.json \
              /usr/sbin/netbird-status /usr/sbin/netbird-setup-swap /usr/sbin/netbird-fetch-binary \
              "$SYSCTL_FILE"
        rm -rf /usr/libexec/netbird /usr/share/netbird-glinet
    fi
    # generated at runtime / by this script — never owned by opkg
    rm -f /tmp/dnsmasq.d/netbird.conf /etc/resolv.conf.original.netbird "$RPC_MD5_STATE" \
          /etc/config/netbird.pre-opkg "$BIN"
    rm -rf /var/run/netbird /var/log/netbird /usr/bin/.netbird-fetch
    [ -L /var/lib/netbird ] && rm -f /var/lib/netbird
    if [ "$PURGE" = 1 ]; then
        rm -rf /etc/netbird /etc/config/netbird
        echo ">> purged enrollment + config"
    else
        echo ">> kept /etc/netbird (enrollment) and /etc/config/netbird — use --purge to delete"
    fi
    /etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
    nginx_restart_later
    echo ">> done (nginx restarts in a few seconds)"
}

case "$CMD" in
    sysctl)    apply_sysctl ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) sed -n '2,20p' "$0" >&2; exit 2 ;;
esac
exit 0
