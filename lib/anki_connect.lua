local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")
local json = require("lib.json")

local M = { url = "http://127.0.0.1:8765/" }

function M.available()
    local client = socket.tcp()
    if not client then return false end
    client:settimeout(0.05)
    local host, port = M.url:match("://([^:]+):(%d+)")
    local ok = client:connect(host, tonumber(port))
    client:close()
    return ok ~= nil
end

function M.request(action, params)
    local body = json.encode({ action = action, version = 6, params = params })
    local chunks = {}
    local _, status = http.request{
        url = M.url, method = "POST",
        headers = { ["Content-Type"] = "application/json", ["Content-Length"] = #body },
        source = ltn12.source.string(body), sink = ltn12.sink.table(chunks),
    }
    if type(status) == "number" and status ~= 200 then
        return nil, "AnkiConnect returned HTTP " .. status .. "."
    elseif status ~= 200 then
        return nil, "Cannot reach AnkiConnect (" .. tostring(status) .. ")."
    end
    local ok, reply = pcall(json.decode, table.concat(chunks))
    if not ok or type(reply) ~= "table" then return nil, "Invalid AnkiConnect response." end
    return reply.result, reply.error
end

return M
