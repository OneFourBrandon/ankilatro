-- Future SMODS has http so switch to that
local http = require("socket.http")
local socket = require("socket")
local ltn12 = require("ltn12")
local mod_path = SMODS.current_mod.path
package.path = package.path .. ";" .. mod_path .. "?.lua"
local json = require("lib.json")

local LOCAL_DEBUGGING = true


-- Define ANKILATRO Variable Space
G.ANKILATRO = {}
-- Create ankilatro state to add to the game's state machine
G.STATES.ANKILATRO = 31404
-- Ankilatro Config Globals - FUTURE: Set ingame and save to file
G.ANKILATRO.CONFIG = {}
G.ANKILATRO.CONFIG.MAXCARDS_BLIND = 3
G.ANKILATRO.CONFIG.SEARCH_QUERY = "(is:new OR is:learn OR is:due) AND (note:basic OR note:cloze)"
-- Ankilatro Globals
G.ANKILATRO.CARD = {}
G.ANKILATRO.CARD.FRONT = nil
G.ANKILATRO.CARD.FRONT_ALT = nil
G.ANKILATRO.CARD.BACK = nil
G.ANKILATRO.CARD.REVEALED = false
G.ANKILATRO.CARD.ISCLOZE = false
G.ANKILATRO.CARD.CID = -1
G.ANKILATRO.CARD.REMAINING = 0

-- AnkiConnect Related Globals
local ac_url = "http://127.0.0.1:8765/"


-- Define ankilatro UI
function G.UIDEF.ankilatro()
    -- What front card to display (FRONT, FRONT_ALT)
    local displayed_front = nil
    local displayed_back = nil
    local displayed_title = string.format("Ankilatro - Cards Remaining This Blind: %d - P:? L:? N:?", G.ANKILATRO.CARD.REMAINING+1)

    -- Init button_row_nodes and start in "Show Answer" state
    local button_row_nodes = nil

    --   Answer is hidden   --
    if not G.ANKILATRO.CARD.REVEALED then
        displayed_front = G.ANKILATRO.CARD.FRONT

        -- If there is content on the back show ???
        if G.ANKILATRO.CARD.BACK ~= "" then
            displayed_back = "???"
        else
            displayed_back = ""
        end

        button_row_nodes = {
            -- Show Answer Button
            {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
                UIBox_button{ 
                    button = 'ankilatro_reveal_card', 
                    label = {'Show Answer'}, 
                    minw = 4, 
                    minh = 1, 
                    colour = G.C.BLUE,
                    shadow = true
                }
            }}
        }

    --   Answer is revealed   --
    else
        -- Set front to alt front if it is cloze type (or any future ones)
        if G.ANKILATRO.CARD.ISCLOZE then
            displayed_front = G.ANKILATRO.CARD.FRONT_ALT
        else
            displayed_front = G.ANKILATRO.CARD.FRONT
        end

        displayed_back =G.ANKILATRO.CARD.BACK

        -- Create the rating buttons - FUTURE: Add schedule times to buttons & move to helper function to clean up main functions
        button_row_nodes = {
            {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
                -- Again button (blue)
                UIBox_button{ 
                    button = 'ankilatro_again', 
                    label = {'Again'}, 
                    col = true,
                    minh = 1, 
                    colour = G.C.BLUE,
                    shadow = true
                },
                -- Hard button (red)
                UIBox_button{ 
                    button = 'ankilatro_hard', 
                    label = {'Hard'}, 
                    col = true,
                    minh = 1, 
                    colour = G.C.RED,
                    shadow = true
                },
                -- Good button (yellow)
                UIBox_button{ 
                    button = 'ankilatro_good', 
                    label = {'Good'}, 
                    col = true,
                    minh = 1, 
                    colour = G.C.ORANGE,
                    shadow = true
                },
                -- Easy button (green)
                UIBox_button{ 
                    button = 'ankilatro_easy', 
                    label = {'Easy'}, 
                    col = true, 
                    minh = 1, 
                    colour = G.C.GREEN,
                    shadow = true
                }
            }},
        }
    end

    local t = {n=G.UIT.ROOT, config = {align = 'cl', colour = G.C.CLEAR}, nodes={
            UIBox_dyn_container({
                -- Top Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12}, nodes={
                    -- Title - Future: Add cards left, pending cards, new cards
                    {n=G.UIT.T, config={text = displayed_title, scale = 0.5, colour = G.C.WHITE, shadow = false}}
                }},

                -- Front Card Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 3}, nodes={
                    akl_create_wrapped_text_node(displayed_front, 70, 0.35)
                }},

                -- Back Card Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 3}, nodes={
                    akl_create_wrapped_text_node(displayed_back, 70, 0.35)
                }},

                -- Buttons Row (Reveal + Difficulty)
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 1}, nodes=button_row_nodes},
            }, false)
        }
    }
    return t
end


-- Update Ankilatro Logic
function Game:update_ankilatro(dt)
    if not G.STATE_COMPLETE then
        stop_use()
        G.ANKILATRO.CARD.REMAINING = G.ANKILATRO.CONFIG.MAXCARDS_BLIND

        -- Initialize ankilatro_ui
        local refresh_ok = refresh_ankilatro_ui(true)

        -- Exit without recreating UI if we could not refresh (due to exit or error)
        if not refresh_ok then return end

        -- Move the window on-screen
        G.E_MANAGER:add_event(Event({
            func = function()
                if G.ankilatro_ui then  -- check since refresh sometimes causes a race condition - may be fixed
                    G.ankilatro_ui.alignment.offset.y = -5.3
                    G.ankilatro_ui.alignment.offset.x = 0
                end
                return true -- Events must return true to finish
            end
        }))

        G.STATE_COMPLETE = true
    end
    if self.buttons then self.buttons:remove(); self.buttons = nil end

    return refresh_ok
end


--                      BUTTON FUNCTIONS                      --

-- Sets card to revealed, then refreshes the ankilatro_ui  FUTURE: Add blue outline animation around entire ankilatro box like cashout screen
G.FUNCS.ankilatro_reveal_card = function(e)
    G.ANKILATRO.CARD.REVEALED = true
    refresh_ankilatro_ui(false)
end

-- Rate Ease Functions 1 = Again, 2 = Hard, 3 = Good, 4 = Easy

G.FUNCS.ankilatro_again = function (e)
    akl_post_request("answerCards", {
        answers = {
            {cardId=G.ANKILATRO.CARD.CID, ease=1}
        }
    })
    local exitcode = fetch_anki_card()
    if exitcode == true then
        refresh_ankilatro_ui(false)
    end
end

G.FUNCS.ankilatro_hard = function (e)
    akl_post_request("answerCards", {
        answers = {
            {cardId=G.ANKILATRO.CARD.CID, ease=2}
        }
    })
    local exitcode = fetch_anki_card()
    if exitcode == true then
        refresh_ankilatro_ui(false)
    end
end

G.FUNCS.ankilatro_good = function (e)
    akl_post_request("answerCards", {
        answers = {
            {cardId=G.ANKILATRO.CARD.CID, ease=3}
        }
    })
    local exitcode = fetch_anki_card()
    if exitcode == true then
        refresh_ankilatro_ui(false)
    end
end

G.FUNCS.ankilatro_easy = function (e)
    akl_post_request("answerCards", {
        answers = {
            {cardId=G.ANKILATRO.CARD.CID, ease=4}
        }
    })
    local exitcode = fetch_anki_card()
    if exitcode == true then
        refresh_ankilatro_ui(false)
    end
end
--                  END OF BUTTON FUNCTIONS                  --


-- Define the ankilatro UI in global scope to keep it displayed and update the values
function refresh_ankilatro_ui(first_load)
    if first_load then
        -- Try and fetch anki card to populate UI
        local fetch_ok = fetch_anki_card()
        if not fetch_ok then return false end

        -- Generate UI for first time offscreen - will move with next update_ankilatro
        G.ankilatro_ui = G.ankilatro_ui or UIBox{
                definition = G.UIDEF.ankilatro(),
                config = {align='tmi', offset = {x=0,y=G.ROOM.T.y+11}, major = G.hand, bond = 'Weak'}
        }
    else
        -- If not first load, nuke the old UI
        if G.ankilatro_ui then 
            G.ankilatro_ui:remove() 
            G.ankilatro_ui = nil
        end

        -- Create new UI in same position but updated values
        G.ankilatro_ui = G.ankilatro_ui or UIBox{
            definition = G.UIDEF.ankilatro(),
            config = {align='tmi', offset = {x=0,y=-5.3}, major = G.hand, bond = 'Weak'}
        }
    end

    return true
end


-- Fetches a random pending Anki Card from AnkiConnect and fills in the globals BACK, FRONT, ISCLOZE, REVEALED
function fetch_anki_card()
    -- CHECK CONNECTION
    if not akl_check_connection() then
        if LOCAL_DEBUGGING then print("Anki is not running. Exiting state.") end
        return akl_exit() -- Exit back to shop immediately
    end


    -- Check if we have any remaining cards to fetch
    if G.ANKILATRO.CARD.REMAINING == 0 then
        return akl_exit()
    end

    -- Find Cards
    local find_resp = akl_post_request("findCards", {query = G.ANKILATRO.CONFIG.SEARCH_QUERY})

    if find_resp == nil then
        if LOCAL_DEBUGGING then
            print("fetching from AnkiConnect Failed - nil response")
        end
        return akl_exit()
    end
    
    local pending_cards = find_resp.result
    if not pending_cards or #pending_cards == 0 then
        if LOCAL_DEBUGGING then
            print("No cards found")
        end
        return akl_exit()
    end

    -- Pick Random Card - make sure it was not last card seen (unless it is the last card)
    local card_id = nil
    repeat
        local random_index = math.random(1, #pending_cards)
        card_id = pending_cards[random_index]
    until card_id ~= G.ANKILATRO.CARD.CID or #pending_cards == 1

    if LOCAL_DEBUGGING then
        print("Selected cID: " .. card_id)
    end

    -- Get Card Info
    local info_resp = akl_post_request("cardsInfo", {cards = {card_id}})

    if info_resp == nil then
        if LOCAL_DEBUGGING then
            print("fetching from AnkiConnect Failed - nil response")
        end

        return false
    end
    
    -- Process json response
    local card_data = info_resp.result[1]
    local model_name = card_data.modelName
    local card_front = ""
    local card_back = ""

    -- Current support card models: Basic, Cloze
    if model_name == "Basic" then
        G.ANKILATRO.CARD.ISCLOZE = false
        card_front = akl_clean_html(card_data.fields.Front.value)
        card_back = akl_clean_html(card_data.fields.Back.value)

        G.ANKILATRO.CARD.FRONT = card_front
        G.ANKILATRO.CARD.BACK = card_back

    elseif model_name == "Cloze" then
        G.ANKILATRO.CARD.ISCLOZE = true
        cloze_order = tonumber(card_data.ord)+1
        card_front = akl_clean_html(card_data.fields.Text.value)
        card_back = akl_clean_html(card_data.fields["Back Extra"].value)

        front_arr = akl_parse_cloze_front(card_front, cloze_order)

        G.ANKILATRO.CARD.FRONT = front_arr[1]
        G.ANKILATRO.CARD.FRONT_ALT = front_arr[2]
        G.ANKILATRO.CARD.BACK = card_back

    end
    
    -- Shared Globals
    G.ANKILATRO.CARD.CID = card_id
    G.ANKILATRO.CARD.REVEALED = false
    G.ANKILATRO.CARD.REMAINING = G.ANKILATRO.CARD.REMAINING - 1

    return true
end


-- Internal helper to handle the POST requests cleanly
function akl_post_request(action, params)
    local payload = {
        action = action,
        version = 6,
        params = params or {}
    }
    
    local req_body = json.encode(payload)
    local resp_chunks = {}
    
    local res, code, headers = http.request{
        url = ac_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = #req_body
        },
        source = ltn12.source.string(req_body),
        sink = ltn12.sink.table(resp_chunks)
    }
    
    if LOCAL_DEBUGGING then
        print(code)
    end

    if code ~= 200 then return nil end
    return json.decode(table.concat(resp_chunks))
end

-- Returns an array with 2 strings, Front and Front_alt
-- RETURNS:
-- Front: Contains ... in place of current cloze, with all other clozes visible 
-- Front_alt: Front of card with all clozes visible
function akl_parse_cloze_front(str, cloze_order)
local target_ord = tostring(cloze_order)

    local pattern = "{{c(%d+)::(.-)}}"

    -- Helper to split "Answer::Hint" into ("Answer", "Hint")
    local function get_content_and_hint(inner_text)
        local s, e = inner_text:find("::")
        if s then
            return inner_text:sub(1, s-1), inner_text:sub(e+1)
        else
            return inner_text, nil
        end
    end

    -- 1. Generate Front (Hide active cloze)
    local front = str:gsub(pattern, function(id, content)
        local text, hint = get_content_and_hint(content)

        if id == target_ord then
            -- Active Cloze: Hide it
            -- If a hint exists, show [Hint], otherwise [...]
            if hint then
                return "[" .. hint .. "]"
            else
                return "[...]"
            end
        else
            -- Inactive Cloze: Show the text
            return text
        end
    end)

    -- 2. Generate Front_alt (Reveal everything)
    local front_alt = str:gsub(pattern, function(id, content)
        local text, _ = get_content_and_hint(content)
        return text
    end)

    return {front, front_alt}
end


-- LINE WRAP FUNCTIONS - FUTURE: Make custom font with LOVE Word Wrapping


function akl_wrap_text(str, max_chars)
    local lines = {}
    local current_line = ""
    for word in str:gmatch("%S+") do
        if #current_line + #word + 1 > max_chars then
            table.insert(lines, current_line)
            current_line = word
        else
            current_line = (#current_line > 0) and (current_line .. " " .. word) or word
        end
    end
    if #current_line > 0 then table.insert(lines, current_line) end
    return lines
end


function akl_create_wrapped_text_node(text_content, max_width, text_scale)
    local wrapped_lines = akl_wrap_text(text_content, max_width)
    local rows = {}

    for _, line in ipairs(wrapped_lines) do
        table.insert(rows, {
            n = G.UIT.R, -- Force a NEW ROW for every line
            config = { align = "cm", padding = 0.05 },
            nodes = {
                {
                    n = G.UIT.T,
                    config = {
                        text = line,
                        scale = text_scale or 0.35,
                        colour = G.C.WHITE,
                        shadow = false
                    }
                }
            }
        })
    end

    -- Return a Column containing all the Rows
    return {
        n = G.UIT.C, 
        config = { align = "cm", padding = 0.05 },
        nodes = rows
    }
end


-- cleans up the output from anki cards
function akl_clean_html(str)
    if not str then return "" end
    
    -- Replace &nbsp; with a normal space
    str = str:gsub("&nbsp;", " ")
    
    -- Replace <br> and <div> with newlines (to preserve formatting)
    str = str:gsub("<br%s*/?>", "\n")
    str = str:gsub("<div>", "\n")
    str = str:gsub("</div>", "")
    
    -- Strip all other HTML tags (anything between < and >) - this may break some things we'll see
    str = str:gsub("<.->", "")
    
    return str
end


-- Checks to make sure ankilatro is running
function akl_check_connection()
    local client = socket.tcp()
    client:settimeout(0.005) -- Set timeout to 50 milliseconds
    local host, port = ac_url:match("://(.-):(%d+)")

    -- Try to connect to localhost:8765
    local connection, err = client:connect(host, port)
    
    if connection then
        client:close()
        return true
    else
        if LOCAL_DEBUGGING then print("Anki Connection Failed: " .. tostring(err)) end
        return false
    end
end

-- Exits ankilatro, returns false as exitcode
function akl_exit()
    stop_use()
    if LOCAL_DEBUGGING then
        print("exiting ankilatro ui")
    end
    if G.ankilatro_ui then 
        G.ankilatro_ui:remove() 
        G.ankilatro_ui = nil
    end
    G.STATE = G.STATES.SHOP
    G.STATE_COMPLETE = false

    return false
end