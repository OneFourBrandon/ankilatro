local math_text = require("lib.akl_math")
local json = require("lib.json")
local utf8 = require("utf8")

local M = {}
local session
local viewport_id = "ankilatro_explainer"
local side_id = "ankilatro_explainer_follow_up"
local colours = {
    navigation = HEX("455971"),
    primary = HEX("1269B5"),
    learning = HEX("6950A1"),
    utility = HEX("326A63"),
    retry = HEX("8B562B"),
    stop = HEX("9C3F4A"),
    input = HEX("253344"),
    focused = HEX("314B69"),
    track = HEX("273546"),
    thumb = HEX("738DAA"),
}
local action_colour = {
    submit = "primary", explain = "primary", confirm_send = "primary", continue = "primary",
    selection_mode = "learning", reasoning = "learning", stronger_hint = "learning", chip = "learning",
    show_answer_explain = "learning",
    copy = "utility", edit_card = "utility", open_browser = "utility", error_link = "utility",
    retry = "retry", regenerate = "retry", stop = "stop", confirm_cancel = "navigation",
}

local function mix(a, b, amount)
    return {a[1] + (b[1] - a[1]) * amount, a[2] + (b[2] - a[2]) * amount, a[3] + (b[3] - a[3]) * amount, 1}
end

-- How each kind of transcript entry looks: what you sent, the model's reply,
-- and messages from Ankilatro / Anki Explainer itself. Built on first use
-- because G.C isn't complete when this file loads.
local message_styles
local function message_style(kind)
    if not message_styles then
        local base = G.C.BLACK
        message_styles = {
            user = {card = mix(base, G.C.BLUE, 0.3), text = mix(G.C.WHITE, G.C.BLUE, 0.12),
                label = mix(G.C.WHITE, G.C.BLUE, 0.45), title = "You"},
            ai = {card = mix(base, G.C.WHITE, 0.07), text = G.C.WHITE,
                label = mix(G.C.WHITE, colours.learning, 0.55), title = "Anki Explainer"},
            system = {text = mix(G.C.WHITE, base, 0.4)},
        }
        message_styles.ai.meta = mix(G.C.WHITE, base, 0.45)
    end
    return message_styles[kind]
end

local function row(nodes, config)
    return {n = G.UIT.R, config = config or {align = "cm", padding = 0.04}, nodes = nodes}
end

local function label(text, scale, colour)
    return {n = G.UIT.T, config = {text = text, scale = scale or 0.36, colour = colour or G.C.WHITE}}
end

local function button(title, action, value, width)
    local composer = action == "submit" or action == "selection_mode" or action == "stop"
    return UIBox_button{
        label = {title}, button = "ankilatro_explainer_action", ref_table = {action = action, value = value},
        col = true, colour = colours[action_colour[action] or "navigation"],
        scale = composer and 0.35 or 0.3, minw = width or 1.8, minh = composer and 0.66 or 0.48,
        padding = composer and 0.06 or nil, shadow = composer,
    }
end

local row_padding = 0.04     -- padding of the transcript row
local composer_gap = 0.08    -- space between the input box and its buttons
local scrollbar_width = 0.1
local chip_width = 2.6       -- follow-up buttons in the side panel
-- The side panel sits outside the popup's frame, to its right. Its space is
-- always reserved so the popup doesn't move when the buttons come and go.
local side_gap = 0.15        -- between the popup's frame and the side panel
local side_outline = 0.07    -- same frame as the popup (create_UIBox_generic_options)
local side_padding = 0.15
-- chip buttons have no inner padding; each button's row pads 0.04 on each side
local side_width = chip_width + 0.08 + 2 * (side_outline + side_padding)

local function width()
    -- leaves ~0.6 between the popup + panel and each screen edge
    return math.min(16, G.ROOM.T.w - 2.4 - side_gap - side_width)
end

-- Follow-up actions ("Go deeper", "Example", ...) shown in a panel beside the
-- popup instead of as rows of buttons inside it. They stay in place while a
-- reply is generating (greyed out) so the layout does not jump.
local function follow_up_chips()
    local state = session and session.state
    if not state or session.error or session.models then return {} end
    if state.view ~= "idle" and state.view ~= "thread" and state.view ~= "confirm" then return {} end
    local thread = state.thread or {}
    if thread.readOnly or not thread.hasAnswer then return {} end
    return thread.chips or {}
end

local function transcript_width()
    return width()
end

local function viewport_height()
    return G.ROOM.T.h - 3.55
end

local function build_transcript()
    local items = {}
    local state = session.state or {}
    local thread = state.thread or {}
    local scale = 0.34 * math.max(0.8, math.min(1.25, (state.settings and state.settings.fontSize or 15) / 15))
    local content_width = transcript_width() - 0.45

    -- Items are single lines so the transcript scrolls line by line. Each one
    -- belongs to a message (group); view() draws a message's lines as one card.
    local group, kind = 0, "system"
    local function message(new_kind)
        group, kind = group + 1, new_kind
    end

    local function item(node, height)
        items[#items + 1] = {node = node, height = height, group = group, kind = kind}
    end

    local function paragraphs(text, markdown, colour)
        if not text or text == "" then return end
        local body = math_text.create_text_node(text, nil, scale, {
            width = content_width, left = true, markdown = markdown, links = markdown,
            colour = colour or message_style(kind).text,
        })
        -- akl_height includes the spacing create_text_node's own column puts
        -- between lines. The lines are moved into message cards, which space them
        -- instead (card_padding), so leave it out.
        local spacing = 0.08 * scale / 0.35
        for _, line in ipairs(body.nodes) do
            local natural = line.config.akl_height - spacing
            local height = math.min(natural, viewport_height() - 0.35)
            if height < natural then
                line.config.maxh, line.config.maxw = height, nil
            end
            item(line, height)
        end
    end

    -- Text from Ankilatro or Anki Explainer rather than from you or the model
    local function system(text)
        if not text or text == "" then return end
        message("system")
        paragraphs(text, false)
    end

    local function title()
        local style = message_style(kind)
        paragraphs("**" .. style.title .. "**", true, style.label)
    end

    local function actions(list)
        for start = 1, #list, 5 do
            local buttons = {}
            for i = start, math.min(start + 4, #list) do buttons[#buttons + 1] = list[i] end
            item(row(buttons, {align = "cl", padding = 0.06, maxw = content_width}), 0.61)
        end
    end

    system(session.error or state.notice)
    if session.error then return items end
    if not session.state then
        system("Opening Anki Explainer...")
    elseif session.models then
        system("Choose a model")
        for _, model in ipairs(state.models or {}) do
            actions({button(model.label, "model", model.id, 5)})
        end
    elseif state.view == "onboarding" then
        system("Connect your OpenRouter account in Anki Explainer settings, then select Explain.")
        actions({button("Account settings", "account", nil, 3)})
    elseif state.view == "history" then
        if #(state.history or {}) == 0 then system("No saved conversations.") end
        for _, entry in ipairs(state.history or {}) do
            message("system")
            paragraphs(entry.title, false, G.C.WHITE)
            local detail = (entry.deck and entry.deck ~= "" and entry.deck .. "  |  " or "") .. (entry.model or "")
            paragraphs(detail, false)
            actions({button("Open", "history_open", entry.id)})
        end
    else
        if state.card then
            if state.card.sent ~= "text" then system(state.card.sent) end
            for _, note in ipairs(state.card.notes or {}) do system(note) end
        end
        local latest
        for _, turn in ipairs(thread.turns or {}) do
            latest = turn
            if turn.role == "user" then
                message("user")
                title()
                paragraphs(turn.text, false)
            else
                message("ai")
                title()
                local style = message_style("ai")
                local meta = turn.meta or {}
                if turn.reasoning and turn.reasoning ~= "" then
                    actions({button(session.reasoning[turn.id] and "Hide reasoning" or "Show reasoning",
                        "reasoning", turn.id, 2.7)})
                    if session.reasoning[turn.id] then paragraphs(turn.reasoning, true, style.meta) end
                end
                paragraphs(turn.text, true)
                if state.settings.showCost and meta.cost then
                    paragraphs(("Cost $%.5f%s"):format(meta.cost, meta.tokens and ("  |  " .. meta.tokens .. " tokens") or ""),
                        false, style.meta)
                end
                if meta.edit_card then actions({button("Edit card", "edit_card")}) end
                if meta.error then
                    paragraphs(meta.error.message, false, mix(G.C.WHITE, G.C.RED, 0.45))
                    if meta.error.url then actions({button(meta.error.actionLabel or "Open OpenRouter", "error_link", nil, 3)})
                    elseif meta.error.action == "settings" then actions({button("Account settings", "account", nil, 3)}) end
                end
            end
        end
        -- Buttons for the latest reply (Copy, Regenerate, ...) go at the bottom of its card
        if not latest or latest.role == "user" then message("system") end

        if state.view == "confirm" then
            system(state.confirm.message)
            actions({button("Send anyway", "confirm_send", nil, 2.5), button("Cancel", "confirm_cancel")})
        elseif thread.busy then
            local phases = {reading = "Reading card...", asking = "Waiting for model...", thinking = "Thinking...", retrying = "Retrying..."}
            system(phases[state.phase] or "Generating...")
        elseif thread.readOnly then
            actions({button("Continue chat", "continue", nil, 2.6), button("Open in Anki", "open_browser", nil, 2.6),
                button("Copy", "copy"), button("Recent", "history_back")})
        else
            local controls = {}
            if latest then
                controls[#controls + 1] = button("Copy", "copy")
                local failed = latest.status == "error" or latest.status == "incomplete" or latest.status == "stopped"
                controls[#controls + 1] = failed and button("Retry", "retry") or button("Regenerate", "regenerate", nil, 2.4)
            else
                controls[#controls + 1] = button("Explain", "explain")
            end
            if thread.hintActions and thread.hasAnswer then
                controls[#controls + 1] = button("Stronger hint", "stronger_hint", nil, 2.6)
            end
            if thread.showAnswerAction or (state.side == "question" and state.questionDisabled) then
                controls[#controls + 1] = button("Reveal + explain", "show_answer_explain", nil, 3)
            end
            actions(controls)
            -- follow-up chips live in the side panel (see side_view())
        end
    end
    return items
end

local card_padding = 0.06     -- inside a message card, around and between its lines
local transcript_padding = 0.08

-- Height item i adds to the transcript, counting its card's padding once per
-- card (the item that starts the card, given the item shown above it).
local function item_height(index, above)
    local entry = session.items[index]
    local height = entry.height + card_padding
    if not above or session.items[above].group ~= entry.group then
        height = height + card_padding + transcript_padding
    end
    return height
end

local function scroll_limit()
    local height = transcript_padding
    for index = #session.items, 1, -1 do
        -- treat index as the top line: its card starts here
        local top = item_height(index, nil)
        if height + top > viewport_height() then return math.min(#session.items, index + 1) end
        height = height + item_height(index, index - 1 >= 1 and index - 1 or nil)
    end
    return 1
end

local function set_input_focus(focused)
    if session.focused == focused then return end
    session.focused = focused
    session.select_all = false
    love.keyboard.setTextInput(focused)
end

local function input_display()
    local draft = session.draft
    if not session.focused and draft == "" then
        return session.selection and "Paste or type the excerpt to explain" or "Click to type a follow-up"
    end
    local length = 64
    local first = utf8.offset(draft:sub(1, session.caret), -math.floor(length * 0.68)) or 1
    local last = utf8.offset(draft, length + 1, first) or (#draft + 1)
    local text = draft:sub(first, last - 1)
    if session.focused then
        local index = session.caret - first + 1
        text = text:sub(1, index) .. "|" .. text:sub(index + 1)
    end
    return (first > 1 and "... " or "") .. text .. (last <= #draft and " ..." or "")
end

local function can_type()
    local state = session.state
    if not state or session.error or session.models or session.sending then return false end
    if state.view ~= "idle" and state.view ~= "thread" then return false end
    if state.thread and state.thread.busy then return false end
    return state.side ~= "question" or not state.questionDisabled
end

local function view()
    local state = session.state or {}
    local thread = state.thread or {}
    local is_history = state.view == "history" or state.view == "history_thread"
    local header = row({
        label("Anki Explainer", 0.46),
        button("Current card", "history_close", nil, 2.5),
        button(is_history and "Recent" or "History", "history", nil),
        button(state.model and state.model.name or "Model", "models", nil, 2.8),
        button("Settings", "settings"),
    })
    -- Each message's visible lines go in one card, styled by who it's from
    local rows, h, card = {}, transcript_padding, nil
    for i = session.first, #session.items do
        local entry = session.items[i]
        local height = item_height(i, i > session.first and i - 1 or nil)
        if #rows > 0 and h + height > viewport_height() then break end
        if not card or card.group ~= entry.group then
            local style = message_style(entry.kind) or {}
            card = {group = entry.group, node = {n = G.UIT.C, config = {align = "tl", r = 0.1,
                padding = card_padding, minw = transcript_width() - 2 * transcript_padding,
                colour = style.card or G.C.CLEAR}, nodes = {}}}
            rows[#rows + 1] = {n = G.UIT.R, config = {align = "cl"}, nodes = {card.node}}
        end
        card.node.nodes[#card.node.nodes + 1] = entry.node
        h = h + height
    end
    -- The composer spans exactly the transcript box (plus the scrollbar when shown)
    -- so its left and right edges line up with the box above it.
    local scrolling = session.limit > 1
    local span = transcript_width() + (scrolling and (row_padding + scrollbar_width) or 0)
    local submit_width, mode_width = 1.8, 2.5
    -- UIBox_button adds its padding (0.06) on both sides of minw
    local input_width = span - (submit_width + 0.12) - (mode_width + 0.12) - 2 * composer_gap
    local composer = {}
    if can_type() then
        composer[#composer + 1] = {n = G.UIT.C, config = {
            align = "cl", minw = input_width, maxw = input_width, minh = 0.58,
            padding = 0.08, r = 0.1, hover = true, shadow = true,
            colour = session.focused and colours.focused or colours.input, button = "ankilatro_explainer_focus",
        }, nodes = {row({label(input_display(), 0.32)}, {align = "cl", maxw = input_width - 0.25})}}
        composer[#composer + 1] = button(session.selection and "Explain" or (thread.awaitingQuiz and "Answer" or "Send"), "submit", nil, submit_width)
        composer[#composer + 1] = button(session.selection and "Ask instead" or "Explain text", "selection_mode", nil, mode_width)
    elseif thread.busy then
        composer[#composer + 1] = button("Stop", "stop")
    end

    -- Scrolling moves whole lines, so part of a line's height can be left over.
    -- At the end of a long conversation, keep that space above, not below the last line.
    local at_end = session.limit > 1 and session.first >= session.limit
    local transcript = {n = G.UIT.C, config = {align = at_end and "bl" or "tl", minw = transcript_width(), maxw = transcript_width(),
        minh = viewport_height(), padding = transcript_padding, r = 0.1, colour = G.C.BLACK}, nodes = rows}
    local contents = {transcript}
    if session.limit > 1 then
        local track_height = viewport_height()
        local thumb_height = math.max(0.4, track_height * (#session.items - session.limit + 1) / #session.items)
        local top = (track_height - thumb_height) * (session.first - 1) / (session.limit - 1)
        contents[2] = {n = G.UIT.C, config = {align = "tm", minh = track_height, r = 0.05, colour = colours.track}, nodes = {
            row({{n = G.UIT.B, config = {w = scrollbar_width, h = top}}}, {align = "cm"}),
            row({{n = G.UIT.B, config = {w = scrollbar_width, h = thumb_height, r = 0.05, colour = colours.thumb}}}, {align = "cm"}),
        }}
    end
    return {n = G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR}, nodes = {
        header,
        row(contents, {align = "cm", padding = row_padding}),
        row(composer, {align = "cm", padding = composer_gap, minh = 0.82}),
    }}
end

-- The follow-up buttons, in their own framed panel to the right of the popup.
-- Without buttons it is an empty box of the same width, so the popup keeps its place.
local function side_view()
    local chips = follow_up_chips()
    if #chips == 0 then
        return {n = G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR}, nodes = {
            {n = G.UIT.B, config = {w = side_width, h = 0.1}},
        }}
    end
    local state = session.state or {}
    local busy = (state.thread or {}).busy or state.view == "confirm"
    local column = {row({label("Follow up", 0.32, G.C.UI.TEXT_LIGHT)}, {align = "cm", padding = 0.04})}
    for _, chip in ipairs(chips) do
        local b = button(chip.label, "chip", chip.id, chip_width)
        if busy then
            -- greyed out and not clickable while a reply is in progress
            b.nodes[1].config.button = nil
            b.nodes[1].config.hover = nil
            b.nodes[1].config.colour = G.C.UI.BACKGROUND_INACTIVE
        end
        column[#column + 1] = row({b}, {align = "cm", padding = 0.04})
    end
    return {n = G.UIT.ROOT, config = {align = "cm", colour = G.C.CLEAR}, nodes = {
        {n = G.UIT.R, config = {align = "cm", r = 0.3, padding = side_outline, colour = G.C.JOKER_GREY, emboss = 0.1}, nodes = {
            {n = G.UIT.C, config = {align = "tm", r = 0.2, padding = side_padding, colour = G.C.L_BLACK}, nodes = column},
        }},
    }}
end

local function replace_object(id, definition)
    local area = session.overlay:get_UIE_by_ID(id)
    area.config.object:remove()
    area.config.object = UIBox{definition = definition, config = {parent = area, align = "cm"}}
end

local function redraw()
    if not session.overlay then return end
    replace_object(viewport_id, view())
    replace_object(side_id, side_view())
    session.overlay:recalculate()
end

local function update_transcript(follow)
    session.items = build_transcript()
    session.limit = scroll_limit()
    session.first = follow and session.limit or math.min(session.first, session.limit)
    redraw()
end

local function scroll(delta)
    local first = math.max(1, math.min(session.limit, session.first + delta))
    session.follow_end = delta > 0 and first >= session.limit
    if first ~= session.first then
        session.first = first
        redraw()
    end
end

local function send(action, value)
    if not session.error then session.input:push(json.encode({action = action, value = value})) end
end

local function submit()
    if not can_type() or not session.draft:find("%S") then return end
    send(session.selection and "selection" or "ask", session.draft)
    session.sending = true
    session.follow_end = not session.selection and session.state.thread ~= nil
    session.draft, session.caret, session.selection = "", 0, false
    set_input_focus(false)
    redraw()
end

G.FUNCS.ankilatro_explainer_focus = function()
    if not session or not can_type() then return end
    session.caret = #session.draft
    set_input_focus(true)
    redraw()
end

G.FUNCS.ankilatro_explainer_link = function(element)
    local url = element.config.akl_link
    if session and session.overlay == G.OVERLAY_MENU and url and url:match("^https?://[^%s%c]+$") then
        love.system.openURL(url)
    end
end

G.FUNCS.ankilatro_explainer_action = function(element)
    if not session then return end
    local args = element.config.ref_table
    local action, value = args.action, args.value
    if action == "submit" then
        submit()
    elseif action == "selection_mode" then
        session.selection = not session.selection
        set_input_focus(true)
        redraw()
    elseif action == "reasoning" then
        session.reasoning[value] = not session.reasoning[value]
        update_transcript(false)
    elseif action == "models" then
        session.models = not session.models
        session.first = 1
        set_input_focus(false)
        update_transcript(false)
    else
        session.models = false
        if action == "chip" or action == "stronger_hint" then session.follow_end = true end
        if action == "history" or action == "history_open" or action == "show_answer_explain" then
            session.follow_end = false
        end
        set_input_focus(false)
        send(action, value)
    end
end

function M.close()
    if not session then return end
    local overlay = session.overlay
    if love.handlers.wheelmoved == session.wheel_handler then
        love.handlers.wheelmoved = session.previous_wheel_handler
    end
    set_input_focus(false)
    session.cancel:push(true)
    session = nil
    if overlay and G.OVERLAY_MENU == overlay then G.FUNCS.exit_overlay_menu() end
end

function M.active()
    return session ~= nil
end

function M.update(reveal)
    if not session then return end
    if G.OVERLAY_MENU ~= session.overlay then M.close(); return end
    local snapshot
    repeat
        local message = session.output:pop()
        if message then snapshot = json.decode(message) end
    until not message
    if not snapshot then return end
    session.sending = false
    local previous = session.state
    local follow = session.follow_end
    if snapshot.error then
        session.error = snapshot.error
    else
        session.state = snapshot.state
        if snapshot.state.revealed then reveal() end
        local before = previous and previous.thread
        local after = snapshot.state.thread
        if not before or not after or before.id ~= after.id then
            session.first = 1
            session.follow_end, follow = false, false
        end
    end
    if not can_type() then set_input_focus(false) end
    update_transcript(follow)
end

function M.open(path, card)
    if session or G.OVERLAY_MENU then return end
    local worker = love.thread.newThread(love.filesystem.newFileData(
        assert(NFS.read(path .. "lib/explain_worker.lua")), "ankilatro_explain.lua"))
    session = {
        input = love.thread.newChannel(), output = love.thread.newChannel(), cancel = love.thread.newChannel(),
        draft = "", caret = 0, focused = false, first = 1, reasoning = {}, worker = worker,
    }
    update_transcript(false)
    worker:start(path, card.CID, card.REVEALED and "answer" or "question", session.input, session.output, session.cancel)
    G.SETTINGS.paused = true
    local definition = create_UIBox_generic_options{
        back_label = "Back to card", back_func = "ankilatro_close_explanation",
        contents = {{n = G.UIT.O, config = {id = viewport_id,
            object = UIBox{definition = view(), config = {align = "cm"}}}}}
    }
    -- Put the follow-up panel beside the popup's frame, outside it, top-aligned.
    -- The overlay centres the pair, so the frame sits slightly left of centre.
    -- The frame is a row, and a row always starts a new line, so it goes in a
    -- column for the panel to sit beside it.
    definition.nodes[1] = {n = G.UIT.R, config = {align = "tm", padding = 0}, nodes = {
        {n = G.UIT.C, config = {align = "tm"}, nodes = {definition.nodes[1]}},
        {n = G.UIT.B, config = {w = side_gap, h = 0.1}},
        {n = G.UIT.C, config = {align = "tm"}, nodes = {
            {n = G.UIT.O, config = {id = side_id, object = UIBox{definition = side_view(), config = {align = "cm"}}}},
        }},
    }}
    G.FUNCS.overlay_menu{definition = definition}
    session.overlay = G.OVERLAY_MENU
    -- Balatro dispatches through love.handlers. Intercept there while the popup
    -- owns the wheel so callbacks installed by other mods cannot consume it.
    local current = session
    local fallback = love.handlers.wheelmoved
    current.previous_wheel_handler = rawget(love.handlers, "wheelmoved")
    current.wheel_handler = function(x, y, ...)
        if session == current and G.OVERLAY_MENU == current.overlay and y ~= 0 then
            local delta = math.max(1, math.floor(math.abs(y) * 3 + 0.5))
            scroll(y > 0 and -delta or delta)
        elseif fallback then
            fallback(x, y, ...)
        end
    end
    love.handlers.wheelmoved = current.wheel_handler
end

local function insert(text)
    text = text:gsub("[%c]", " ")
    if not utf8.len(text) then return end
    if session.select_all then session.draft, session.caret, session.select_all = "", 0, false end
    local remaining = 8000 - #session.draft
    if #text > remaining then text = text:sub(1, (utf8.offset(text, 0, remaining + 1) or 1) - 1) end
    local pos = session.caret
    session.draft = session.draft:sub(1, pos) .. text .. session.draft:sub(pos + 1)
    session.caret = pos + #text
    redraw()
end

local old_textinput, old_keypressed = love.textinput, love.keypressed
local function popup_open()
    return session and session.overlay == G.OVERLAY_MENU
end

local function shortcut_matches(binding, key)
    if not binding or binding == "" then return false end
    local ctrl = love.keyboard.isDown("lctrl", "rctrl")
    local shift = love.keyboard.isDown("lshift", "rshift")
    local alt = love.keyboard.isDown("lalt", "ralt")
    local prefix = (ctrl and "Ctrl+" or "") .. (alt and "Alt+" or "") .. (shift and "Shift+" or "")
    return binding:lower() == (prefix .. key):lower()
end

local function conversation_shortcut(key)
    local state = session.state or {}
    local bindings = state.shortcuts or {}
    local thread = state.thread or {}
    if thread.busy and shortcut_matches(bindings.stop, key) then
        send("stop")
        return true
    end
    if not thread.hasAnswer or thread.busy or thread.readOnly or state.view ~= "thread" then return false end
    for index, binding in ipairs(bindings.chips or {}) do
        if shortcut_matches(binding, key) then
            local chip = (thread.chips or {})[index]
            if chip then
                send("chip", chip.id)
            elseif index == 1 and thread.hintActions then
                send("stronger_hint")
            elseif thread.showAnswerAction and (index == 1 or index == 2) then
                send("show_answer_explain")
            end
            return true
        end
    end
    return false
end

function love.textinput(text)
    if popup_open() and session.focused then insert(text)
    elseif old_textinput then old_textinput(text) end
end

function love.keypressed(key, ...)
    if popup_open() then
        if conversation_shortcut(key) then return
        elseif key == "escape" then
            if session.focused then set_input_focus(false); redraw() else M.close() end
            return
        elseif key == "pageup" or key == "pagedown" then
            scroll(key == "pageup" and -12 or 12)
            return
        elseif session.focused then
            local draft, pos = session.draft, session.caret
            local ctrl = love.keyboard.isDown("lctrl", "rctrl", "lgui", "rgui")
            if key == "return" or key == "kpenter" then submit(); return
            elseif ctrl and key == "v" then insert(love.system.getClipboardText() or ""); return
            elseif ctrl and key == "a" then session.select_all = true; return
            elseif ctrl and (key == "c" or key == "x") and session.select_all then
                love.system.setClipboardText(draft)
                if key == "x" then session.draft, session.caret, session.select_all = "", 0, false end
            elseif key == "backspace" or key == "delete" then
                local first = utf8.offset(draft, -1, pos + 1) or (pos + 1)
                local last = utf8.offset(draft, 2, pos + 1) or (#draft + 1)
                if session.select_all then session.draft, session.caret = "", 0
                elseif key == "backspace" then session.draft, session.caret = draft:sub(1, first - 1) .. draft:sub(pos + 1), first - 1
                else session.draft = draft:sub(1, pos) .. draft:sub(last) end
                session.select_all = false
            elseif key == "home" or key == "end" or key == "left" or key == "right" then
                if key == "home" then session.caret = 0
                elseif key == "end" then session.caret = #draft
                elseif key == "left" then session.caret = (utf8.offset(draft, -1, pos + 1) or 1) - 1
                else session.caret = (utf8.offset(draft, 2, pos + 1) or (#draft + 1)) - 1 end
                session.select_all = false
            else return end
            redraw()
            return
        end
    end
    if old_keypressed then old_keypressed(key, ...) end
end

return M
