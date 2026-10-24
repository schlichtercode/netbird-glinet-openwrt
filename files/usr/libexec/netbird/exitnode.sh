#!/bin/sh
# Exit-node helper via the NetBird management API (needs api_token in UCI).
#   exitnode.sh discover   find this peer's id + the enabled 0.0.0.0/0 route id
#   exitnode.sh toggle     flip the exit route's "enabled" flag
#   exitnode.sh state      print "true"/"false" (route enabled?) or "unknown"

. /usr/libexec/netbird/common.sh
nb_load_config

[ -n "$NB_API_TOKEN" ] || { echo "api_token not set" >&2; exit 1; }
API="$NB_MGMT_URL/api"
curl_api() { curl -sk --connect-timeout 10 --max-time 20 -H "Authorization: Token $NB_API_TOKEN" "$@"; }

discover() {
    local my_ip peers peer_id routes route_id
    my_ip=$(nb_status_field 's.netbirdIp or (s.fullStatus and s.fullStatus.localPeerState and s.fullStatus.localPeerState.IP)' 10 | sed 's|/.*||')
    [ -n "$my_ip" ] || { echo "daemon not connected (no NetBird IP)" >&2; return 1; }
    peers=$(curl_api "$API/peers") || return 1
    peer_id=$(echo "$peers" | tr '\n' ' ' | tr '{' '\n' | grep "\"$my_ip\"" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$peer_id" ] || { echo "peer with IP $my_ip not found via API (token needs read:peers)" >&2; return 1; }
    uci set "netbird.connection.peer_id=$peer_id"
    routes=$(curl_api "$API/routes") || return 1
    route_id=$(echo "$routes" | tr '\n' ' ' | tr '{' '\n' | grep '0\.0\.0\.0/0' | grep "$peer_id" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$route_id" ] && route_id=$(echo "$routes" | tr '\n' ' ' | tr '{' '\n' | grep '0\.0\.0\.0/0' | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$route_id" ] || { uci commit netbird; echo "no 0.0.0.0/0 route found — create an exit-node route in the dashboard first" >&2; return 1; }
    uci set "netbird.connection.route_id=$route_id"
    uci commit netbird
    echo "peer_id=$peer_id route_id=$route_id"
}

state() {
    [ -n "$NB_ROUTE_ID" ] || { echo unknown; return 0; }
    curl_api "$API/routes/$NB_ROUTE_ID" | tr '\n' ' ' | tr ',' '\n' | grep '"enabled"' | grep -o 'true\|false' | head -1 || echo unknown
}

toggle() {
    [ -n "$NB_ROUTE_ID" ] || discover >/dev/null || return 1
    nb_load_config
    local route flat enabled new body
    route=$(curl_api "$API/routes/$NB_ROUTE_ID") || return 1
    [ -n "$route" ] || { echo "empty API response" >&2; return 1; }
    flat=$(echo "$route" | tr '\n' ' ')
    enabled=$(echo "$flat" | tr ',' '\n' | grep '"enabled"' | grep -o 'true\|false' | head -1)
    [ -n "$enabled" ] || { echo "could not parse route" >&2; return 1; }
    [ "$enabled" = true ] && new=false || new=true
    body=$(echo "$flat" | sed "s/\"enabled\":$enabled/\"enabled\":$new/")
    curl_api -X PUT -H "Content-Type: application/json" -d "$body" "$API/routes/$NB_ROUTE_ID" >/dev/null || return 1
    echo "exit node route $NB_ROUTE_ID enabled=$new"
}

case "${1:-}" in
    discover) discover ;;
    toggle) toggle ;;
    state) state ;;
    *) echo "usage: $0 discover|toggle|state" >&2; exit 2 ;;
esac
