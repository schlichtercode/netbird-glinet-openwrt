#!/bin/sh
# Background actions triggered from the GL panel (RPC object "netbird").
# Runs detached; progress/result is written to $NB_RUN/action.json so the
# panel can show it. Only one action at a time (directory lock).
#
#   action.sh enroll <setup-key>   netbird up --setup-key ...
#   action.sh connect              netbird up (existing enrollment)
#   action.sh disconnect           netbird down
#   action.sh restart              /etc/init.d/netbird restart (+ netbird up)
#   action.sh start | stop         enable/disable + service start/stop
#   action.sh exit_toggle          toggle exit-node route via management API
#   action.sh exit_discover        store peer_id/route_id via management API

. /usr/libexec/netbird/common.sh
nb_load_config
mkdir -p "$NB_RUN"
LOCK="$NB_RUN/action.lock"
RESULT="$NB_RUN/action.json"
ACTION="${1:-}"
ARG="${2:-}"

json_escape() { printf '%s' "$1" | tr -d '\r' | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-400; }

write_result() { # <state> <ok> <message>
    printf '{"action":"%s","state":"%s","ok":%s,"message":"%s","ts":%s}\n' \
        "$ACTION" "$1" "$2" "$(json_escape "$3")" "$(date +%s)" > "$RESULT.tmp"
    mv "$RESULT.tmp" "$RESULT"
}

if ! mkdir "$LOCK" 2>/dev/null; then
    pid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        echo "busy" >&2; exit 3
    fi
    rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || exit 3
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT INT TERM

write_result running true "started"
nb_invalidate_status
out=""; rc=0

case "$ACTION" in
    enroll)
        [ -n "$ARG" ] || { write_result done false "setup key missing"; exit 1; }
        nb_prepare_dirs
        [ -S "$NB_SOCK" ] || /etc/init.d/netbird start >/dev/null 2>&1
        i=0; while [ ! -S "$NB_SOCK" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
        nb_timeout 20 "$NB_BIN" down >/dev/null 2>&1
        # shellcheck disable=SC2046
        out=$(nb_timeout 120 "$NB_BIN" up $(nb_up_args) --setup-key "$ARG" 2>&1); rc=$?
        ;;
    connect)
        [ -S "$NB_SOCK" ] || /etc/init.d/netbird start >/dev/null 2>&1
        i=0; while [ ! -S "$NB_SOCK" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
        # shellcheck disable=SC2046
        out=$(nb_timeout 120 "$NB_BIN" up $(nb_up_args) 2>&1); rc=$?
        ;;
    disconnect)
        out=$(nb_timeout 30 "$NB_BIN" down 2>&1); rc=$?
        nb_dns_sync clear; nb_resolv_restore
        ;;
    restart)
        # The daemon reconnects on its own when an enrollment exists; no
        # `netbird up` (= CLI fork) needed here. The watchdog covers the rest.
        out=$(/etc/init.d/netbird restart 2>&1); rc=$?
        i=0; while [ ! -S "$NB_SOCK" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
        ;;
    start)
        uci set netbird.settings.enabled=1; uci commit netbird
        out=$(/etc/init.d/netbird enable 2>&1; /etc/init.d/netbird start 2>&1); rc=$?
        ;;
    stop)
        uci set netbird.settings.enabled=0; uci commit netbird
        out=$(/etc/init.d/netbird stop 2>&1); rc=$?
        ;;
    exit_toggle)
        out=$(sh /usr/libexec/netbird/exitnode.sh toggle 2>&1); rc=$?
        ;;
    exit_discover)
        out=$(sh /usr/libexec/netbird/exitnode.sh discover 2>&1); rc=$?
        ;;
    *)
        write_result done false "unknown action"; exit 2 ;;
esac

nb_invalidate_status
# keep only the last meaningful line (the CLI prefixes WARN lines)
out=$(printf '%s\n' "$out" | grep -vE '^[0-9T:.-]+Z (WARN|INFO|DEBG)' | grep -v '^$' | tail -1)
if [ "$rc" -eq 0 ]; then
    write_result done true "${out:-ok}"
else
    nb_log "action $ACTION failed (rc=$rc): $(echo "$out" | tail -1)"
    write_result done false "${out:-failed (rc=$rc)}"
fi
# Refresh DNS forwarding right away after a (re)connect; update the panel's VPN indicator.
case "$ACTION" in enroll|connect|restart) sleep 3; nb_dns_sync ;; esac
nb_panel_push force
exit "$rc"
