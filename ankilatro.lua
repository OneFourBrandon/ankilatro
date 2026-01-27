-- Create ankilatro state to add to the game's state machine
G.STATES.ANKILATRO = 31404


-- Define ankilatro UI
function G.UIDEF.ankilatro()
    local t = {n=G.UIT.ROOT, config = {align = 'cl', colour = G.C.CLEAR}, nodes={
            UIBox_dyn_container({
                {n=G.UIT.C, config={align = "cm", padding = 0.1, emboss = 0.05, r = 0.1, colour = G.C.DYN_UI.BOSS_MAIN, minw = 12, minh = 1}, nodes={
                    {n=G.UIT.T, config={text = 'Ankilatro', scale = 1.0, colour = G.C.WHITE, shadow = true}},
                }},
            }, false)
        }
    }
    return t
end

-- Update Ankilatro Logic
function Game:update_ankilatro(dt)
    if not G.STATE_COMPLETE then
        G.hand.states.visible = false

        -- Define the ankilatro UI in global scope to keep it displayed
        G.ankilatro_ui = G.ankilatro_ui or UIBox{
            definition = G.UIDEF.ankilatro(),
            config = {align='tmi', offset = {x=0,y=G.ROOM.T.y+11}, major = G.hand, bond = 'Weak'}
        }
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