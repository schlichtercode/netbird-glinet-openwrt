-- Push a live status update into GL.iNet's panel websocket, exactly like
-- gl-ngx-session does: a line with the payload size, then the JSON payload,
-- to /var/run/ngx-ws-proxy.sock. Used after NetBird state changes so the VPN
-- indicator updates without a page reload.
--   lua wspush.lua            → pushes "vpnclient.status" from the wrapper
local SOCK = "/var/run/ngx-ws-proxy.sock"
local ok_s, unix = pcall(require, "socket.unix")
local ok_c, cjson = pcall(require, "cjson")
if not ok_s or not ok_c then os.exit(0) end

ngx = ngx or { log = function() end, ctx = {}, var = {} }
local ok, M = pcall(dofile, "/usr/lib/oui-httpd/rpc/vpn-client")
if not ok or type(M) ~= "table" or type(M.get_status) ~= "function" then os.exit(0) end
local ok2, st = pcall(M.get_status, {})
if not ok2 or type(st) ~= "table" then os.exit(0) end

local payload = cjson.encode({ name = "vpnclient.status", data = st })
local c = unix()
if not c then os.exit(0) end
c:settimeout(2)
if not c:connect(SOCK) then os.exit(0) end
c:send(tostring(#payload) .. "\n" .. payload)
c:close()
