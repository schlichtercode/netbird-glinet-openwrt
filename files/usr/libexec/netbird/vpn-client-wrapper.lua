-- netbird-glinet-openwrt: wrapper around GL.iNet's "vpn-client" RPC object.
-- install.sh moves the original to /usr/lib/oui-httpd/rpc/vpn-client.gl and
-- puts this file in its place. Everything is passed through unchanged except:
--   get_status  → status_list gets a "NetBird" entry (status 1/2/0) so the
--                 VPN indicator on the Internet page lights up
--   get_tunnel  → tunnels get a "NetBird" card for the VPN dashboard
--   set_tunnel / remove_tunnel / set_default_tunnel for that card → NetBird
-- Marker for install.sh: NETBIRD-VPN-CLIENT-WRAPPER
local ORIG = "/usr/lib/oui-httpd/rpc/vpn-client.gl"
local NB_TUNNEL_ID = 900
local COMMON = "/usr/libexec/netbird/common.sh"

local ok, orig = pcall(dofile, ORIG)
if not ok or type(orig) ~= "table" then orig = {} end

local M = {}
for k, v in pairs(orig) do M[k] = v end

local function q(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

local function sh(cmd)
    local f = io.popen(cmd .. " 2>/dev/null")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end

local function uci_get(key, default)
    local v = sh("uci -q get " .. key):gsub("%s+$", "")
    if v == "" then return default end
    return v
end

-- One shell round trip: "<state>|<netbird ip>|<management url>|<wg port>"
local STATUS_EXPR = [[(s.status or s.daemonStatus or "").."|"..]] ..
    [[((s.fullStatus and s.fullStatus.localPeerState and s.fullStatus.localPeerState.IP) or s.netbirdIp or "").."|"..]] ..
    [[((s.fullStatus and s.fullStatus.managementState and s.fullStatus.managementState.URL) or (s.management and s.management.url) or "").."|"..]] ..
    [[tostring((s.fullStatus and s.fullStatus.localPeerState and s.fullStatus.localPeerState.wgPort) or "")]]

-- returns status code (0 disconnected, 1 connected, 2 connecting — GL's codes),
-- enabled flag, and details {ip, domain, port}
local function nb_status()
    local enabled = uci_get("netbird.settings.enabled", "1") == "1"
    local details = { ip = "", domain = "", port = "" }
    local running = os.execute("[ -S /var/run/netbird.sock ]") == 0
    if not running then return 0, enabled, details end
    local raw = sh(". " .. COMMON .. "; nb_load_config; nb_status_field " .. q(STATUS_EXPR) .. " 5"):gsub("%s+$", "")
    local st, ip, url, port = raw:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
    st = st or ""
    details.ip = (ip or ""):gsub("/.*$", "")
    details.domain = (url or ""):gsub("^https?://", ""):gsub(":%d+$", "")
    details.port = port or ""
    if st == "Connected" then return 1, enabled, details end
    if st == "Connecting" or st == "" then return 2, enabled, details end
    return 0, enabled, details
end

local function wt0_counters()
    local rx, tx = 0, 0
    local f = io.open("/proc/net/dev", "r")
    if f then
        for line in f:lines() do
            local r, t = line:match("^%s*wt0:%s*(%d+)%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+%d+%s+(%d+)")
            if r then rx, tx = tonumber(r), tonumber(t) end
        end
        f:close()
    end
    return rx, tx
end

local function nb_status_entry()
    local status, enabled, d = nb_status()
    local rx, tx = wt0_counters()
    return { tunnel_id = NB_TUNNEL_ID, name = "NetBird", enabled = enabled, status = status, type = "netbird",
             rx_bytes = rx, tx_bytes = tx, domain = d.domain, port = tonumber(d.port) or d.port, ipv4 = d.ip,
             via = { type = "netbird", group_id = "netbird", peer_id = "netbird" } }
end

local function nb_tunnel_entry()
    local _, enabled, _ = nb_status()
    return {
        tunnel_id = NB_TUNNEL_ID, id = "netbird", name = "NetBird", enabled = enabled, killswitch = false,
        -- the dashboard reads via.type for the badge and needs group/peer ids
        -- to consider the tunnel "configured"
        via = { via = "netbird", type = "netbird", group_id = "netbird", peer_id = "netbird" },
        from = { type = "default" },
        to = { manual = true, type = "default", domain_list = "", domain_list_len = 0 },
        options = { options_in_used = false, masq = true, local_access = true, service_policy = false },
    }
end

local function is_nb(params)
    if type(params) ~= "table" then return false end
    local id = params.tunnel_id
    return tonumber(id) == NB_TUNNEL_ID or id == "netbird" or params.id == "netbird"
end

M.get_status = function(params)
    local r = (orig.get_status and orig.get_status(params)) or {}
    if type(r) ~= "table" then r = {} end
    if type(r.status_list) ~= "table" then r.status_list = {} end
    r.status_list[#r.status_list + 1] = nb_status_entry()
    return r
end

-- In GL's "global mode" the dashboard shows only tunnels[1]. Put NetBird first
-- while GL's own first tunnel has no VPN config (via == ""); once the user
-- configures a GL WireGuard/OpenVPN client, that one stays in front and
-- NetBird is listed behind it (visible in policy mode).
M.get_tunnel = function(params)
    local r = (orig.get_tunnel and orig.get_tunnel(params)) or {}
    if type(r) ~= "table" then r = {} end
    if type(r.tunnels) ~= "table" then r.tunnels = {} end
    local first = r.tunnels[1]
    local gl_unconfigured = (first == nil) or (type(first.via) ~= "table") or (first.via.via == nil) or (first.via.via == "")
    if gl_unconfigured then
        table.insert(r.tunnels, 1, nb_tunnel_entry())
    else
        r.tunnels[#r.tunnels + 1] = nb_tunnel_entry()
    end
    return r
end

M.set_tunnel = function(params)
    if not is_nb(params) then
        if orig.set_tunnel then return orig.set_tunnel(params) end
        return {}
    end
    local on = params.enabled == true or params.enabled == 1 or params.enabled == "1" or params.enabled == "true"
    os.execute("( sh /usr/libexec/netbird/action.sh " .. (on and "start" or "stop") .. " >/dev/null 2>&1 </dev/null & )")
    return {}
end

for _, name in ipairs({ "remove_tunnel", "set_default_tunnel", "order_tunnel", "set_options" }) do
    local f = orig[name]
    M[name] = function(params)
        if is_nb(params) then return {} end
        if f then return f(params) end
        return {}
    end
end

return M
