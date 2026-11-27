local mod = SMODS.current_mod
local mod_path = mod.path
if not (mod_path:match("^[/\\]") or mod_path:match("^%a:[/\\]")) then
    mod_path = NFS.getWorkingDirectory() .. "/" .. mod_path
end
package.path = mod_path .. "?.lua;" .. package.path
local connect = require("lib.anki_connect")
local akl_math = require("lib.akl_math")
local explainer = require("lib.explainer_panel")

-- Style the game's existing font. The UI element still measures and positions the text.
G.FUNCS.ankilatro_style_text = function(element)
    local config = element.config
    if config.text_drawable and config.text_drawable == config.akl_styled_drawable then return end
    local font = config.font.FONT
    local drawable = love.graphics.newText(font)
    local shear = config.akl_italic and -0.16 or 0
    local offset = -shear * font:getBaseline()
    drawable:add(config.text, offset, 0, 0, 1, 1, 0, 0, shear, 0)
    if config.akl_bold then
        drawable:add(config.text, offset + font:getHeight() * 0.035, 0, 0, 1, 1, 0, 0, shear, 0)
    end
    if config.akl_strike then
        drawable:add("_", 0, -font:getHeight() * 0.28, 0, font:getWidth(config.text) / font:getWidth("_"), 1)
    end
    config.text_drawable = drawable
    config.akl_styled_drawable = drawable
end

local LOCAL_DEBUGGING = true


-- Define ANKILATRO Variable Space
G.ANKILATRO = {}
-- Create ankilatro state to add to the game's state machine
G.STATES.ANKILATRO = 31404
local max_cards = 50
local function cards_per_blind()
    return math.max(0, math.min(max_cards, math.floor(tonumber(mod.config.cards_per_blind) or 3)))
end

local card_orders = {"random", "oldest", "scheduler"}
local default_card_order = 3 -- Anki scheduler

mod.config_tab = function()
    local choices = {}
    for n = 0, max_cards do choices[#choices + 1] = tostring(n) end
    local selected_order = default_card_order
    for index, order in ipairs(card_orders) do
        if order == mod.config.card_order then selected_order = index end
    end
    return {n = G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR}, nodes = {
        {n = G.UIT.R, config = {align = "cm"}, nodes = {create_option_cycle{
            label = "Cards between rounds", options = choices, current_option = cards_per_blind() + 1, w = 4,
            opt_callback = "ankilatro_set_cards", no_pips = true, info = {"0 skips the review at cash out."},
        }}},
        {n = G.UIT.R, config = {align = "cm"}, nodes = {create_option_cycle{
            label = "Card order", options = {"Random", "Oldest first", "Anki scheduler"},
            current_option = selected_order, w = 4,
            opt_callback = "ankilatro_set_card_order", no_pips = true,
            info = {"Anki scheduler uses the deck selected in Anki."},
        }}},
    }}
end

G.FUNCS.ankilatro_set_cards = function(args)
    mod.config.cards_per_blind = tonumber(args.to_val)
    SMODS.save_mod_config(mod)
end

G.FUNCS.ankilatro_set_card_order = function(args)
    mod.config.card_order = card_orders[args.to_key] or card_orders[default_card_order]
    SMODS.save_mod_config(mod)
end
-- Ankilatro Globals
G.ANKILATRO.CARD = {}
G.ANKILATRO.CARD.FRONT = nil
G.ANKILATRO.CARD.FRONT_ALT = nil
G.ANKILATRO.CARD.BACK = nil
G.ANKILATRO.CARD.REVEALED = false
G.ANKILATRO.CARD.CID = -1
G.ANKILATRO.CARD.REMAINING = 0

local review_notice
local explainer_available = false -- set when the review screen opens or retries

-- Explain is optional: it needs the bridge and Anki Explainer loaded in Anki.
local function check_explainer()
    local available, available_err = connect.request("ankilatroExplainerAvailable")
    if available == nil and tostring(available_err):find("unsupported action", 1, true) then
        -- A bridge older than this check can't say, so keep the button whenever
        -- that bridge is installed, as before; opening reports a missing add-on.
        local _, bridge_err = connect.request("ankilatroNextScheduledCard")
        explainer_available = bridge_err == nil
    else
        explainer_available = available == true
    end
end

local function report_review_issue(message, can_retry)
    review_notice = {message = message, can_retry = can_retry}
    print("[Ankilatro] " .. message)
end

-- Revert: undo the last rating. Greyed out when there is none, or when Anki has
-- changed since and refused.
local function revert_button(args)
    local last = G.ANKILATRO.LAST_RATING
    local usable = last ~= nil and not last.failed
    args = args or {}
    args.button = 'ankilatro_revert'
    args.label = {last and last.failed and "Can't revert" or 'Revert'}
    args.minw, args.scale, args.shadow = args.minw or 1.8, args.scale or 0.4, usable
    args.colour = usable and G.C.GREY or G.C.UI.BACKGROUND_INACTIVE
    local button = UIBox_button(args)
    if not usable then
        -- UIBox_button always sets a click action (default: close menu), so drop it
        button.nodes[1].config.button, button.nodes[1].config.hover = nil, nil
    end
    return button
end

local function review_notice_view()
    local buttons = {}
    local last = G.ANKILATRO.LAST_RATING
    if last and not last.failed then
        -- e.g. a misclick took the last card in the queue
        buttons[1] = revert_button{col = true, minw = 3, scale = 0.5}
    end
    if review_notice.can_retry then
        buttons[#buttons + 1] = UIBox_button{label = {"Retry"}, button = "ankilatro_retry", col = true, colour = G.C.BLUE}
    end
    buttons[#buttons + 1] = UIBox_button{label = {"Continue to shop"}, button = "ankilatro_shop", col = true}
    return {n = G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR}, nodes = {
        UIBox_dyn_container({
            {n = G.UIT.R, config = {align = "cm", padding = 0.1}, nodes = {
                {n = G.UIT.T, config = {text = "Ankilatro", scale = 0.5, colour = G.C.WHITE}}
            }},
            {n = G.UIT.R, config = {align = "cm", minw = 12, minh = 2}, nodes = {
                akl_create_wrapped_text_node(review_notice.message, 60, 0.35)
            }},
            {n = G.UIT.R, config = {align = "cm", padding = 0.1}, nodes = buttons},
        }, false)
    }}
end

-- Define ankilatro UI
function G.UIDEF.ankilatro()
    if review_notice then return review_notice_view() end
    -- What front card to display (FRONT, FRONT_ALT)
    local displayed_front = nil
    local displayed_back = nil
    local card = G.ANKILATRO.CARD
    -- Header: cards left, then counts in Anki's colours (due green, learning red, new blue)
    local function title_text(text, colour)
        return {n=G.UIT.T, config={text = text, scale = 0.5, colour = colour, shadow = false}}
    end
    local function title_gap(w)
        return {n=G.UIT.B, config={w = w, h = 0.1}}
    end
    local title_nodes = {
        title_text(("Left this blind: %d"):format(card.REMAINING + 1), G.C.WHITE),
        title_gap(0.6),
        title_text(("P: %d"):format(card.PENDING), G.C.GREEN),
        title_gap(0.45),
        title_text(("L: %d"):format(card.LEARNING), G.C.RED),
        title_gap(0.45),
        title_text(("N: %d"):format(card.NEW), G.C.BLUE),
    }

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
        displayed_front = card.FRONT_ALT or card.FRONT

        displayed_back =G.ANKILATRO.CARD.BACK

        -- Create the rating buttons - FUTURE: Add schedule times to buttons & move to helper function to clean up main functions
        button_row_nodes = {
            {n=G.UIT.R, config={align = "cm", padding = 0.1}, nodes={
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

    local panel = UIBox_dyn_container({
                -- Top Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12}, nodes=title_nodes},

                -- Front Card Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 3}, nodes={
                    akl_create_wrapped_text_node(displayed_front, 70, 0.35, true)
                }},

                -- Back Card Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 3}, nodes={
                    akl_create_wrapped_text_node(displayed_back, 70, 0.35, true)
                }},

                -- Buttons Row (Reveal + Difficulty)
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 1}, nodes=button_row_nodes},
            }, false)
    return {n = G.UIT.ROOT, config = {align = 'tm', colour = G.C.CLEAR}, nodes = {
        panel
    }}
end


-- Update Ankilatro Logic
function Game:update_ankilatro(dt)
    if not G.STATE_COMPLETE then
        stop_use()
        explainer.close()
        G.ANKILATRO.CARD.REMAINING = cards_per_blind()
        G.ANKILATRO.LAST_RATING = nil -- Revert only covers ratings on this screen
        check_explainer()

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
    explainer.update(function()
        local card = G.ANKILATRO.CARD
        if not card.REVEALED then
            card.REVEALED = true
            refresh_ankilatro_ui(false)
        end
    end)
    if self.buttons then self.buttons:remove(); self.buttons = nil end
end


--                      BUTTON FUNCTIONS                      --

-- Sets card to revealed, then refreshes the ankilatro_ui  FUTURE: Add blue outline animation around entire ankilatro box like cashout screen
G.FUNCS.ankilatro_reveal_card = function(e)
    if explainer.active() or review_notice then return end
    G.ANKILATRO.CARD.REVEALED = true
    refresh_ankilatro_ui(false)
end

G.FUNCS.ankilatro_explain = function()
    if explainer_available and not review_notice then explainer.open(mod_path, G.ANKILATRO.CARD) end
end

G.FUNCS.ankilatro_close_explanation = explainer.close

-- Flip between Cloze Rephraser's wording and the note as written
G.FUNCS.ankilatro_toggle_original = function()
    local card = G.ANKILATRO.CARD
    if review_notice or explainer.active() or not card.REPHRASED then return end
    card.SHOWING_ORIGINAL = not card.SHOWING_ORIGINAL
    local sides = card.SHOWING_ORIGINAL and card.ORIGINAL or card.REPHRASED
    card.FRONT, card.FRONT_ALT, card.BACK = sides.front, sides.front_alt, sides.back
    refresh_ankilatro_ui(false)
end

local function load_review(card_id)
    review_notice = nil
    G.ANKILATRO.CARD.CONFIRM_SUSPEND = nil
    if G.ANKILATRO.CARD.REMAINING <= 0 then return akl_exit() end
    local ok, message = fetch_anki_card(card_id)
    if not ok then report_review_issue(message, true) end
    return true -- display either the card or the reason it could not be loaded
end

G.FUNCS.ankilatro_retry = function()
    if not (review_notice and review_notice.can_retry) then return end
    -- Anki may have been started, or add-ons installed, since the screen opened.
    check_explainer()
    if load_review() then refresh_ankilatro_ui(false) end
end

G.FUNCS.ankilatro_shop = function() akl_exit() end

local function rate_card(ease)
    local card = G.ANKILATRO.CARD
    if review_notice or explainer.active() or not card.REVEALED then return end
    -- The bridge rates the card and says which undo step that was, for Revert
    local result, err = connect.request("ankilatroAnswer", {cardId = card.CID, ease = ease})
    local ok, undo_step = type(result) == "table", type(result) == "table" and result.undoStep
    if result == nil and tostring(err):find("unsupported action", 1, true) then
        -- No bridge, or one from before Revert: rate without a way back
        result, err = connect.request("answerCards", {answers = {{cardId = card.CID, ease = ease}}})
        ok = type(result) == "table" and result[1] == true
    end
    if not ok then
        report_review_issue("Anki could not confirm your rating. " .. (err or "The card is no longer available."), false)
        return refresh_ankilatro_ui(false)
    end
    G.ANKILATRO.LAST_RATING = undo_step and {cid = card.CID, step = undo_step, remaining = card.REMAINING} or nil
    -- Let Cloze Rephraser record the wording as seen, so the next showing differs
    if G.ANKILATRO.CARD.REPHRASER then
        connect.request("ankilatroRephraseAnswered", {cardId = G.ANKILATRO.CARD.CID})
    end
    if load_review() then refresh_ankilatro_ui(false) end
end

-- Suspend the card in Anki (undo with Unsuspend in Anki's browser) and show the
-- next one. It doesn't count as a review, so the blind still needs as many ratings.
G.FUNCS.ankilatro_suspend = function()
    local card = G.ANKILATRO.CARD
    if review_notice or explainer.active() then return end
    if not card.CONFIRM_SUSPEND then
        card.CONFIRM_SUSPEND = true
        return refresh_ankilatro_ui(false)
    end
    local _, err = connect.request("suspend", {cards = {card.CID}})
    if err then
        report_review_issue("Anki could not suspend the card. " .. tostring(err), true)
        return refresh_ankilatro_ui(false)
    end
    -- Suspending is Anki's latest undo step now, so the rating can't be reverted
    G.ANKILATRO.LAST_RATING = nil
    -- fetching the replacement uses up a card; this one wasn't reviewed
    card.REMAINING = card.REMAINING + 1
    if load_review() then refresh_ankilatro_ui(false) end
end

-- Undo the last rating in Anki and show that card again, answer revealed, so it
-- can be rated again. Only while nothing else has changed in Anki since.
G.FUNCS.ankilatro_revert = function()
    local card, last = G.ANKILATRO.CARD, G.ANKILATRO.LAST_RATING
    if not last or last.failed or explainer.active() then return end
    local _, err = connect.request("ankilatroUndoAnswer", {undoStep = last.step})
    if err then
        last.failed = true
        print("[Ankilatro] Could not revert the last rating: " .. tostring(err))
        return refresh_ankilatro_ui(false)
    end
    G.ANKILATRO.LAST_RATING = nil
    -- The card counts towards the blind again, as before it was rated
    card.REMAINING = last.remaining + 1
    if load_review(last.cid) then
        if not review_notice then card.REVEALED = true end
        refresh_ankilatro_ui(false)
    end
end

G.FUNCS.ankilatro_again = function() rate_card(1) end
G.FUNCS.ankilatro_hard = function() rate_card(2) end
G.FUNCS.ankilatro_good = function() rate_card(3) end
G.FUNCS.ankilatro_easy = function() rate_card(4) end
--                  END OF BUTTON FUNCTIONS                  --


-- Define the ankilatro UI in global scope to keep it displayed and update the values
function refresh_ankilatro_ui(first_load)
    if first_load and not load_review() then return false end
    if G.ankilatro_ui then G.ankilatro_ui:remove() end
    G.ankilatro_ui = UIBox{
        definition = G.UIDEF.ankilatro(),
        config = {align = 'tmi', offset = {x = 0, y = first_load and G.ROOM.T.y + 11 or -5.3}, major = G.hand, bond = 'Weak'}
    }
    if review_notice then return true end

    -- Buttons in a column to the right of the review panel, top to bottom
    local slot = 0
    local function side_button(key, button)
        G.ankilatro_ui.children[key] = UIBox{
            definition = {n = G.UIT.ROOT, config = {align = 'cm', colour = G.C.CLEAR}, nodes = {button}},
            config = {align = 'tr', offset = {x = 0.55, y = 1.02 + 1.1 * slot}, major = G.ankilatro_ui, lr_clamp = true}
        }
        slot = slot + 1
    end

    if explainer_available then
        side_button('explain', UIBox_button{button = 'ankilatro_explain', label = {'Explain'}, minw = 1.8, scale = 0.4,
            colour = G.C.PURPLE, shadow = true})
    end
    local card = G.ANKILATRO.CARD
    -- Suspend asks for a second click before it takes the card out of Anki's reviews
    side_button('suspend', UIBox_button{button = 'ankilatro_suspend',
        label = {card.CONFIRM_SUSPEND and 'Confirm' or 'Suspend'}, minw = 1.8, scale = 0.4, shadow = true,
        colour = card.CONFIRM_SUSPEND and G.C.RED or HEX("9C3F4A")})
    if card.REPHRASE_CLOZE then
        -- Cloze Rephraser cards: switch wording. When this showing already uses
        -- the original wording it is greyed out.
        local reworded = card.REPHRASED ~= nil
        local toggle = UIBox_button{button = 'ankilatro_toggle_original',
            label = {not reworded and 'Original' or card.SHOWING_ORIGINAL and 'Show reworded' or 'Show original'},
            minw = 1.8, scale = 0.4, shadow = reworded,
            colour = reworded and G.C.BLUE or G.C.UI.BACKGROUND_INACTIVE}
        if not reworded then
            -- UIBox_button always sets a click action (default: close menu), so drop it
            toggle.nodes[1].config.button, toggle.nodes[1].config.hover = nil, nil
        end
        side_button('original', toggle)
    end
    side_button('revert', revert_button())

    return true
end


-- Preserve Anki's active-cloze spans and remove template source metadata before
-- the HTML cleaner strips the tags. Track nested elements of the same type.
local function clean_rendered_card(html, separate_extra)
    html = html or ""
    local parts, extras = {}, {}
    local stacks = {span = {}, div = {}, p = {}, small = {}, aside = {}, section = {}}
    local pos, hidden, extra_depth = 1, 0, 0
    local function append(text)
        if hidden ~= 0 then return end
        local target = extra_depth > 0 and extras or parts
        target[#target + 1] = text
    end
    for first, closing, tag, attrs, last in html:gmatch("()<(/?)(%a+)(%f[%s>][^<>]*)>()") do
        local stack = stacks[tag:lower()]
        if stack then
            append(html:sub(pos, first - 1))
            if closing == "" then
                local _, classes = attrs:match([[%sclass%s*=%s*(["'])(.-)%1]])
                classes = " " .. (classes or attrs:match([[%sclass%s*=%s*([^%s'"/>]+)]]) or "") .. " "
                local source = classes:find("%ssource%s") ~= nil
                local cloze = tag:lower() == "span" and classes:find("%scloze%s") ~= nil
                local extra = separate_extra and (classes:find("%sextra%s") or classes:find("%sback[-_]extra%s"))
                stack[#stack + 1] = {source = source, cloze = cloze, extra = extra}
                if extra then extra_depth = extra_depth + 1 end
                if source then
                    hidden = hidden + 1
                else
                    if extra and extra_depth == 1 then append("\n") end
                    append(cloze and akl_math.cloze_start or html:sub(first, last - 1))
                end
            else
                local opener = table.remove(stack)
                if opener and opener.source then
                    hidden = hidden - 1
                else
                    append(opener and opener.cloze and akl_math.cloze_end or html:sub(first, last - 1))
                end
                if opener and opener.extra then extra_depth = extra_depth - 1 end
            end
            pos = last
        end
    end
    append(html:sub(pos))
    return akl_clean_html(table.concat(parts)), akl_clean_html(table.concat(extras)):match("^%s*(.-)%s*$")
end

local function select_review_card(card)
    if mod.config.card_order == "scheduler" then
        local queue, err = connect.request("ankilatroNextScheduledCard")
        if not queue then
            if err == "unsupported action" then
                return nil, "Anki scheduler requires the updated Ankilatro bridge. Install it and restart Anki, then retry."
            end
            return nil, "Could not read Anki's scheduled queue. " .. (err or "Anki returned no queue.")
        end
        if not queue.cardId then
            return nil, "Anki's review queue is empty for the selected deck. Check the deck and its daily limits in Anki."
        end
        card.PENDING, card.LEARNING, card.NEW = queue.pending, queue.learning, queue.new
        return queue.cardId
    end

    -- A card can be both learning and review in Anki. Keep these buckets disjoint
    -- and draw from exactly the IDs counted in the header.
    local scope = '-is:suspended -is:buried '
    local actions = {}
    for _, filter in ipairs({"is:due is:review -is:learn", "is:due is:learn", "is:new"}) do
        actions[#actions + 1] = {action = "findCards", version = 6, params = {query = scope .. filter}}
    end
    local groups, err = connect.request("multi", {actions = actions})
    if type(groups) ~= "table" or #groups ~= 3 then
        return nil, "Could not read the Anki review queue. " .. (err or "AnkiConnect returned an incomplete response.")
    end
    local pending_cards = {}
    for _, group in ipairs(groups) do
        if type(group.result) ~= "table" then
            return nil, "Anki card search failed. " .. (group.error or "AnkiConnect returned no card list.")
        end
        for _, id in ipairs(group.result) do pending_cards[#pending_cards + 1] = id end
    end
    if #pending_cards == 0 then
        return nil, "No new cards or due reviews in the open Anki profile. Buried and suspended cards are excluded."
    end
    card.PENDING, card.LEARNING, card.NEW = #groups[1].result, #groups[2].result, #groups[3].result

    -- Avoid immediately repeating the displayed card when another is available.
    local card_id = pending_cards[1]
    if #pending_cards > 1 then
        if mod.config.card_order == "oldest" then
            card_id = math.huge
            for _, id in ipairs(pending_cards) do
                if id ~= card.CID then card_id = math.min(card_id, id) end
            end
        else
            repeat
                card_id = pending_cards[math.random(1, #pending_cards)]
            until card_id ~= card.CID
        end
    end

    return card_id
end

local function replace_all(str, old, new)
    local parts, pos = {}, 1
    while true do
        local s, e = str:find(old, pos, true)
        if not s then break end
        parts[#parts + 1] = str:sub(pos, s - 1) .. new
        pos = e + 1
    end
    parts[#parts + 1] = str:sub(pos)
    return table.concat(parts)
end

-- Anki renders a cloze inside MathJax as plain text, [...] on the question and
-- the answer on the back, with no cloze span to colour it. Rebuild each such
-- MathJax region from the note's cloze fields and swap in a marked copy.
local function mark_math_clozes(card_data, question, answer)
    local ord = tonumber(card_data.ord)
    if not ord or type(card_data.fields) ~= "table" then return question, answer end
    local cloze_order = ord + 1
    question, answer = question or "", answer or ""
    for _, field in pairs(card_data.fields) do
        local value = type(field) == "table" and type(field.value) == "string" and field.value or ""
        for _, r in ipairs(akl_math.segment_positions(value)) do
            local region = value:sub(r[1], r[2])
            if region:find("{{c" .. cloze_order .. "::", 1, true) then
                -- Every copy, for templates that show the field more than once
                local plain = akl_parse_cloze_front(region, cloze_order, nil, true)
                local marked = akl_parse_cloze_front(region, cloze_order, akl_math.cloze_placeholder)
                question = replace_all(question, plain[1], marked[1])
                answer = replace_all(answer, plain[2], marked[2])
            end
        end
    end
    return question, answer
end

-- Turn AnkiConnect card data into what the review panel shows:
-- {front = question side, front_alt = front with the cloze revealed (or nil), back = answer/extra}
local function card_sides(card_data)
    local model_name = card_data.modelName
    local fields = card_data.fields

    -- Preserve the two-panel layout and math-aware masking for the stock templates.
    if (model_name == "Basic" or model_name == "AnkiGPT Basic") and fields.Front and fields.Back then
        return {front = akl_clean_html(fields.Front.value), front_alt = nil, back = akl_clean_html(fields.Back.value)}

    elseif (model_name == "Cloze" or model_name == "AnkiGPT Cloze") and fields.Text and tonumber(card_data.ord) then
        local cloze_order = tonumber(card_data.ord) + 1
        local extra = fields["Back Extra"] or fields.Extra
        local front_arr = akl_parse_cloze_front(akl_clean_html(fields.Text.value), cloze_order, akl_math.cloze_placeholder)
        return {front = front_arr[1], front_alt = front_arr[2], back = akl_clean_html(extra and extra.value)}
    end

    -- Anki has already applied this card's template and active cloze ordinal.
    -- Use its rendered sides for renamed notes, custom fields and reversed cards.
    -- An "extra" / "back-extra" section goes to the lower panel. Don't require a
    -- visible cloze span for this: a cloze inside MathJax renders as plain [...].
    local question, answer_html = mark_math_clozes(card_data, card_data.question, card_data.answer)
    local front = clean_rendered_card(question)
    local answer, extra = clean_rendered_card(answer_html, true)
    return {front = front, front_alt = answer, back = extra}
end

-- Fetch the chosen card, or card_id when given (Revert). On failure return the
-- reason for the review screen.
function fetch_anki_card(card_id)
    if not connect.available() then
        return false, "Cannot reach AnkiConnect. Open your Anki profile and check that AnkiConnect is listening at " .. connect.url
    end
    local card = G.ANKILATRO.CARD
    -- Also refreshes the header counts
    local selected, err = select_review_card(card)
    card_id = card_id or selected
    if not card_id then return false, err end
    if LOCAL_DEBUGGING then print("Selected cID: " .. card_id) end

    -- Get Card Info
    local cards, info_error = connect.request("cardsInfo", {cards = {card_id}})
    local card_data = cards and cards[1]
    if not card_data or not card_data.fields then
        return false, "Could not load Anki card " .. card_id .. ". " .. (info_error or "The card may have been deleted. Retry to refresh the queue.")
    end
    local model_name = card_data.modelName
    local original = card_sides(card_data)
    card.FRONT, card.FRONT_ALT, card.BACK = original.front, original.front_alt, original.back

    -- Optional Cloze Rephraser add-on (through the bridge): show this card in new
    -- wording. Returns nothing when the add-on or the updated bridge is missing.
    card.ORIGINAL, card.REPHRASED, card.SHOWING_ORIGINAL = nil, nil, false
    local rephrase = connect.request("ankilatroRephrase", {cardId = card_id})
    card.REPHRASER = type(rephrase) == "table"
    -- a cloze card the add-on handles, whether or not this showing is reworded
    card.REPHRASE_CLOZE = card.REPHRASER and (rephrase.cloze == true or rephrase.rephrased == true)
    if card.REPHRASER and rephrase.rephrased and type(rephrase.fields) == "table" then
        local copy = {modelName = card_data.modelName, ord = card_data.ord, fields = {},
            question = rephrase.question, answer = rephrase.answer}
        for name, field in pairs(card_data.fields) do
            copy.fields[name] = {value = rephrase.fields[name] or field.value, order = field.order}
        end
        local sides = card_sides(copy)
        if sides.front:find("%S") and (sides.front_alt or sides.back):find("%S") then
            card.ORIGINAL, card.REPHRASED = original, sides
            card.FRONT, card.FRONT_ALT, card.BACK = sides.front, sides.front_alt, sides.back
        end
    end

    if not card.FRONT:find("%S") or not (card.FRONT_ALT or card.BACK):find("%S") then
        card.CID = card_id -- let Retry pick a different card when possible
        return false, ("Card %s (%s) has no displayable text on one side. Review it in Anki, or retry to refresh the queue."):format(card_id, model_name)
    end
    
    -- Shared Globals
    G.ANKILATRO.CARD.CID = card_id
    G.ANKILATRO.CARD.REVEALED = false
    G.ANKILATRO.CARD.REMAINING = G.ANKILATRO.CARD.REMAINING - 1

    return true
end


-- Returns an array with 2 strings, Front and Front_alt
-- RETURNS:
-- Front: Contains [...] in place of current cloze, with all other clozes visible
-- Front_alt: Front of card with all clozes visible
-- raw_math: leave a hidden cloze inside MathJax as plain [...], as Anki renders it
function akl_parse_cloze_front(str, cloze_order, placeholder, raw_math)
    local target_ord = tostring(cloze_order)

    -- Helper to split "Answer::Hint" into ("Answer", "Hint")
    -- Only a "::" outside of braces counts, so nested clozes keep their own "::"
    local function get_content_and_hint(inner_text)
        local depth = 0
        local i = 1
        while i < #inner_text do
            local c = inner_text:sub(i, i)
            if c == "{" then
                depth = depth + 1
            elseif c == "}" then
                if depth > 0 then depth = depth - 1 end
            elseif c == ":" and depth == 0 and inner_text:sub(i+1, i+1) == ":" then
                return inner_text:sub(1, i-1), inner_text:sub(i+2)
            end
            i = i + 1
        end
        return inner_text, nil
    end

    -- Finds the "}}" that closes a cloze whose content starts at content_start.
    -- Braces are balanced so MathJax like {{c1::\frac{a}{b}}} closes at the right place.
    local function find_cloze_end(content_start)
        local depth = 0
        local i = content_start
        while i <= #str do
            local c = str:sub(i, i)
            if c == "\\" then
                i = i + 1 -- skip escaped character (e.g. \{ )
            elseif c == "{" then
                depth = depth + 1
            elseif c == "}" then
                if depth == 0 and str:sub(i+1, i+1) == "}" then return i end
                if depth > 0 then depth = depth - 1 end
            end
            i = i + 1
        end
        -- Unbalanced braces, fall back to the first "}}" like Anki does
        return str:find("}}", content_start, true)
    end

    -- Math regions, so a hidden cloze inside MathJax can be rendered as \text{[...]}
    local math_regions = akl_math.segment_positions(str)
    local function in_math(pos)
        for _, r in ipairs(math_regions) do
            if pos > r[1] and pos < r[2] then return true end
        end
        return false
    end

    local front_parts, alt_parts = {}, {}
    local pos = 1
    while true do
        local s, e, id = str:find("{{c(%d+)::", pos)
        if not s then break end
        local close = find_cloze_end(e + 1)
        if not close then break end

        local text, hint = get_content_and_hint(str:sub(e + 1, close - 1))
        table.insert(front_parts, str:sub(pos, s - 1))
        table.insert(alt_parts, str:sub(pos, s - 1))

        if id == target_ord then
            -- Active Cloze: Hide it. If a hint exists, show [Hint], otherwise [...]
            local hidden = hint and ("[" .. hint .. "]") or placeholder or "[...]"
            if in_math(s) and not raw_math then hidden = "\\text{" .. hidden .. "}" end
            table.insert(front_parts, hidden)
            if placeholder then text = akl_math.cloze_start .. text .. akl_math.cloze_end end
        else
            -- Inactive Cloze: Show the text
            table.insert(front_parts, text)
        end
        table.insert(alt_parts, text)
        pos = close + 2
    end
    table.insert(front_parts, str:sub(pos))
    table.insert(alt_parts, str:sub(pos))

    local front = table.concat(front_parts)
    local front_alt = table.concat(alt_parts)

    -- Nested clozes: resolve any that are left over
    if front:find("{{c%d+::") and front ~= str then front = akl_parse_cloze_front(front, cloze_order, placeholder, raw_math)[1] end
    if front_alt:find("{{c%d+::") and front_alt ~= str then front_alt = akl_parse_cloze_front(front_alt, cloze_order, placeholder, raw_math)[2] end

    return {front, front_alt}
end


-- TEXT + MATHJAX RENDERING - see lib/akl_math.lua
-- Wraps text to roughly max_width characters per line and renders any MathJax
-- (\( \) inline, \[ \] display) with Balatro UI nodes.
function akl_create_wrapped_text_node(text_content, max_width, text_scale, markdown)
    local node = akl_math.create_text_node(text_content or "", max_width, text_scale, {markdown = markdown})
    return node
end


-- Anki shows a field's own * _ ~ ` \ as typed: only its HTML formatting
-- becomes Markdown (below). Escape them so "my_rank*local_n*h" isn't italic.
-- MathJax, tags and code are left as they are. Not "[": "\[" opens MathJax.
local function escape_literal_markdown(str)
    local out, code = {}, 0
    local function plain(text)
        out[#out + 1] = code > 0 and text or (text:gsub("[\\%*_~`]", "\\%0"))
    end
    local function text(chunk)
        local pos = 1
        for first, closing, tag, last in chunk:gmatch("()<(/?)(%a*)[^<>]*>()") do
            plain(chunk:sub(pos, first - 1))
            out[#out + 1] = chunk:sub(first, last - 1)
            tag = tag:lower()
            if tag == "pre" or tag == "code" then code = math.max(0, code + (closing == "" and 1 or -1)) end
            pos = last
        end
        plain(chunk:sub(pos))
    end
    local pos = 1
    for _, r in ipairs(akl_math.segment_positions(str)) do
        text(str:sub(pos, r[1] - 1))
        out[#out + 1] = str:sub(r[1], r[2])
        pos = r[2] + 1
    end
    text(str:sub(pos))
    return table.concat(out)
end

-- cleans up the output from anki cards
function akl_clean_html(str)
    if not str then return "" end

    -- Anki includes the note stylesheet in its rendered question and answer.
    str = str:gsub("<[sS][tT][yY][lL][eE]%f[%s>][^>]*>.-</[sS][tT][yY][lL][eE]%s*>", "")
    str = str:gsub("<[sS][cC][rR][iI][pP][tT]%f[%s>][^>]*>.-</[sS][cC][rR][iI][pP][tT]%s*>", "")
    str = str:gsub("<!%-%-.-%-%->", "")
    str = escape_literal_markdown(str)

    str = str:gsub("<pre[^>]*>(.-)</pre%s*>", function(code)
        return "\n```\n" .. code:gsub("</?code[^>]*>", "") .. "\n```\n"
    end)
    local markers = {strong = "**", b = "**", em = "*", i = "*", del = "~~", s = "~~", code = "`"}
    str = str:gsub("<(/?)(%a+)%f[%s>][^>]*>", function(closing, tag)
        tag = tag:lower()
        if markers[tag] then return markers[tag] end
        if tag == "li" and closing == "" then return "\n- " end
        if tag == "p" or tag == "ul" or tag == "ol" then return "\n" end
    end)
    str = str:gsub("<h([1-6])%f[%s>][^>]*>(.-)</h%1%s*>", function(level, title)
        return "\n" .. string.rep("#", tonumber(level)) .. " " .. title .. "\n"
    end)
    
    -- Replace &nbsp; with a normal space
    str = str:gsub("&nbsp;", " ")
    
    -- Replace <br> and <div> with newlines (to preserve formatting)
    str = str:gsub("<br%s*/?>", "\n")
    str = str:gsub("<div%f[%s>][^>]*>", "\n")
    str = str:gsub("<hr%f[%s/>][^>]*>", "\n")
    str = str:gsub("</div>", "")
    
    -- Strip all other HTML tags (anything between < and >) - this may break some things we'll see
    str = str:gsub("<.->", "")

    -- Decode HTML entities (Anki stores < > & in MathJax as &lt; &gt; &amp;)
    str = akl_decode_entities(str)

    return str
end


local HTML_ENTITIES = {
    lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", amp = "&",
    times = "×", divide = "÷", plusmn = "±", deg = "°", middot = "·", hellip = "…",
    ndash = "–", mdash = "—", lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”",
    le = "≤", ge = "≥", ne = "≠", minus = "−", rarr = "→", larr = "←", harr = "↔",
}

local function akl_utf8_char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp/0x40), 0x80 + cp%0x40)
    elseif cp < 0x10000 then return string.char(0xE0 + math.floor(cp/0x1000), 0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40)
    elseif cp < 0x110000 then return string.char(0xF0 + math.floor(cp/0x40000), 0x80 + math.floor(cp/0x1000)%0x40, 0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40)
    end
    return ""
end

-- Decodes &name; &#123; and &#x1F; entities in a single pass (so "&amp;lt;" stays "&lt;")
function akl_decode_entities(str)
    return (str:gsub("&(#?[xX]?)(%w+);", function(prefix, body)
        if prefix == "#" then
            local cp = tonumber(body)
            if cp then return akl_utf8_char(cp) end
        elseif prefix == "#x" or prefix == "#X" then
            local cp = tonumber(body, 16)
            if cp then return akl_utf8_char(cp) end
        elseif prefix == "" and HTML_ENTITIES[body] then
            return HTML_ENTITIES[body]
        end
        return nil -- leave unknown entities untouched
    end))
end


-- Exits ankilatro, returns false as exitcode
function akl_exit()
    review_notice = nil
    explainer.close()
    stop_use()
    if G.ankilatro_ui then 
        G.ankilatro_ui:remove() 
        G.ankilatro_ui = nil
    end
    G.STATE = G.STATES.SHOP
    G.STATE_COMPLETE = false

    return false
end
