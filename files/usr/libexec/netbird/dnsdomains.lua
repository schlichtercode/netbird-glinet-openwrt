-- Reads `netbird status --json` on stdin, prints one DNS domain per line:
-- the peer domain (derived from the router's own FQDN) plus every domain of
-- every enabled NetBird nameserver group. Used by nb_dns_sync().
local ok, cjson = pcall(require, "cjson")
if not ok then os.exit(1) end
local raw = io.read("*a")
if not raw or raw == "" then os.exit(1) end
local ok2, st = pcall(cjson.decode, raw)
if not ok2 or type(st) ~= "table" then os.exit(1) end

local seen, out = {}, {}
local function add(d)
    if type(d) ~= "string" then return end
    d = d:gsub("^%.+", ""):gsub("%.+$", ""):lower()
    if d ~= "" and not seen[d] and d:match("^[%w%-%.]+$") then
        seen[d] = true
        out[#out + 1] = d
    end
end

-- two formats: `netbird status --json` (fqdn, dnsServers at top level) and the
-- daemon JSON gateway (fullStatus.localPeerState.fqdn, fullStatus.dnsServers)
local fs = type(st.fullStatus) == "table" and st.fullStatus or nil
local fqdn = st.fqdn
if fs and type(fs.localPeerState) == "table" then fqdn = fs.localPeerState.fqdn end
local groups = st.dnsServers
if fs and type(fs.dnsServers) == "table" then groups = fs.dnsServers end
if type(fqdn) == "string" then
    local dom = fqdn:match("^[^.]+%.(.+)$")
    add(dom)
end
if type(groups) == "table" then
    for _, g in ipairs(groups) do
        if type(g) == "table" and g.enabled ~= false and type(g.domains) == "table" then
            for _, d in ipairs(g.domains) do add(d) end
        end
    end
end
for _, d in ipairs(out) do print(d) end
