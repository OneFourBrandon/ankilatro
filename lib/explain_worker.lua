-- Keep HTTP and polling off the game thread for the lifetime of the popup.
local path, card_id, side, input, output, cancel = ...
package.path = path .. "?.lua;" .. package.path
local timer = require("love.timer")
require("socket.http").TIMEOUT = 5
local connect = require("lib.anki_connect")
local json = require("lib.json")

local token
local function run()
    if cancel:pop() then return end
    local reply, err = connect.request("ankilatroPanelOpen", {cardId = card_id, side = side})
    if not reply then
        if err == "unsupported action" then err = "Update the Ankilatro bridge and restart Anki." end
        return err
    end
    token = reply.token
    local revision, poll_at = 0, 0
    while not cancel:pop() do
        if reply.state then
            revision = reply.revision
            output:push(json.encode({state = reply.state}))
        end
        local command = input:pop()
        if command then
            local request = json.decode(command)
            request.token = token
            reply, err = connect.request("ankilatroPanelAction", request)
            poll_at = timer.getTime() + 0.35
        elseif timer.getTime() >= poll_at then
            reply, err = connect.request("ankilatroPanelPoll", {token = token, revision = revision})
            poll_at = timer.getTime() + 0.35
        else
            reply = {}
            timer.sleep(0.04)
        end
        if not reply then return err or "Anki Explainer did not respond." end
    end
end

local ok, message = pcall(run)
if token then connect.request("ankilatroPanelClose", {token = token}) end
if not ok then message = "Could not run the Anki Explainer bridge client." end
if message then output:push(json.encode({error = message})) end
