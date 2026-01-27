-- Create ankilatro state to add to the game's state machine
G.STATES.ANKILATRO = 31404
-- Ankilatro Globals
G.ANKILATRO = {}
G.ANKILATRO.CARD = {}
G.ANKILATRO.CARD.FRONT = "Sample Front of ankilatro card"
G.ANKILATRO.CARD.BACK = "The back has been revealed!"
G.ANKILATRO.CARD.REVEALED = false
G.ANKILATRO.CARD.ISCLOZE = false


-- Define ankilatro UI
function G.UIDEF.ankilatro()
    -- Init button_row_nodes and start in "Show Answer" state
    local button_row_nodes = nil
    if not G.ANKILATRO.CARD.REVEALED then
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
    else
        -- FUTURE: Add schedule times to buttons
        print("created alt buttons")
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
                    {n=G.UIT.T, config={text = 'Ankilatro', scale = 0.5, colour = G.C.WHITE, shadow = true}}
                }},

                -- Front Card Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 3}, nodes={
                    {n=G.UIT.T, config={text = G.ANKILATRO.CARD.FRONT, scale = 0.35, colour = G.C.WHITE, shadow = false}}
                }},

                -- Back Card Row
                {n=G.UIT.R, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 3}, nodes={
                    {n=G.UIT.T, config={text = G.ANKILATRO.CARD.REVEALED and G.ANKILATRO.CARD.BACK or "???", scale = 0.35, colour = G.C.WHITE, shadow = false}}
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
        -- Initialize ankilatro_ui
        refresh_ankilatro_ui(true)

        -- Move the window on-screen
        G.E_MANAGER:add_event(Event({
                func = function()
                    G.ankilatro_ui.alignment.offset.y = -5.3
                    G.ankilatro_ui.alignment.offset.x = 0
                end
        }))

        G.STATE_COMPLETE = true
    end
    if self.buttons then self.buttons:remove(); self.buttons = nil end       
end


-- Sets card to revealed, then refreshes the ankilatro_ui  FUTURE: Add blue outline animation around entire ankilatro box like cashout screen
G.FUNCS.ankilatro_reveal_card = function(e)
    G.ANKILATRO.CARD.REVEALED = true
    print("removed ui")
    if G.ankilatro_ui then 
        G.ankilatro_ui:remove() 
        G.ankilatro_ui = nil
    end

    refresh_ankilatro_ui(false)
end


-- Define the ankilatro UI in global scope to keep it displayed and update the values
function refresh_ankilatro_ui(first_load)
    if first_load then
        print("added ui")
        G.ankilatro_ui = G.ankilatro_ui or UIBox{
                definition = G.UIDEF.ankilatro(),
                config = {align='tmi', offset = {x=0,y=G.ROOM.T.y+11}, major = G.hand, bond = 'Weak'}
        }
    else
        print("added ui")
        G.ankilatro_ui = G.ankilatro_ui or UIBox{
            definition = G.UIDEF.ankilatro(),
            config = {align='tmi', offset = {x=0,y=-5.3}, major = G.hand, bond = 'Weak'}
    }
    end
end