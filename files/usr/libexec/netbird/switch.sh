#!/bin/sh
# Hardware toggle switch → NetBird on/off.
# Called from GL.iNet's /etc/gl-switch.d/vpn.sh (hook appended by install.sh)
# whenever the switch is assigned the "VPN client" function in the GL panel.
#   switch.sh on | off
# Honours netbird.settings.hw_switch (1 = follow the switch, 0 = ignore it).
. /usr/libexec/netbird/common.sh
nb_load_config
[ "$NB_HW_SWITCH" = 1 ] || exit 0
case "$1" in on|off) ;; *) echo "usage: $0 on|off" >&2; exit 2 ;; esac

if [ "$NB_HW_SWITCH_MODE" = exitnode ]; then
    # Switch = exit node on/off; NetBird itself keeps running.
    [ -n "$NB_EXIT_NODE" ] || { nb_log "hardware switch: no exit node configured (netbird.connection.exit_node)"; exit 0; }
    if [ "$1" = on ]; then
        [ -S "$NB_SOCK" ] || { uci set netbird.settings.enabled=1; uci commit netbird; /etc/init.d/netbird start >/dev/null 2>&1
            i=0; until [ "$(nb_mgmt_state)" = Connected ] || [ $i -ge 30 ]; do sleep 2; i=$((i+1)); done; }
        nb_log "hardware switch: ON — selecting exit node '$NB_EXIT_NODE'"
        nb_network_set "$NB_EXIT_NODE" on
    else
        nb_log "hardware switch: OFF — deselecting exit node '$NB_EXIT_NODE'"
        nb_network_set "$NB_EXIT_NODE" off
    fi
    exit 0
fi

# Switch = NetBird service on/off.
if [ "$1" = on ]; then
    nb_log "hardware switch: ON — enabling NetBird"
    uci set netbird.settings.enabled=1; uci commit netbird
    /etc/init.d/netbird start >/dev/null 2>&1
else
    nb_log "hardware switch: OFF — disabling NetBird"
    uci set netbird.settings.enabled=0; uci commit netbird
    /etc/init.d/netbird stop >/dev/null 2>&1
fi

sleep 2; nb_panel_push force
