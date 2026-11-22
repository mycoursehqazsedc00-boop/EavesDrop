--[[
    EavesDrop - CombatHub Adapter
    Routes EavesDropSuperCombat events through CombatHub and filters out
    irrelevant raid-wide *_OTHER events at the hub.
    Strict Lua 5.0.
]]

if not CombatHub or type(CombatHub.OnPostLogin) ~= "function" then
    return
end

CombatHub:OnPostLogin(function()
    local SC = getglobal("EavesDropSuperCombat")
    if not SC or not SC.frame or not SC.backend then return end

    local f = SC.frame
    local origOnEvent = f:GetScript("OnEvent")
    if type(origOnEvent) ~= "function" then return end

    local function dispatch(ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
        CombatHub:InvokeFrameOnEvent(f, origOnEvent, ev, a1, a2, a3, a4, a5, a6, a7, a8, a9)
    end

    f:UnregisterAllEvents()

    if SC.backend == "DPSLog" or SC.backend == "ClassicAPI" then
        local cleuEvents = {
            "COMBAT_LOG_EVENT_UNFILTERED",
            "UNIT_PET",
            "PLAYER_ENTERING_WORLD",
        }
        if SC.hasNampower then
            table.insert(cleuEvents, "UNIT_PET_GUID")
        end
        CombatHub:Subscribe("EavesDrop_CLEU", "EavesDrop (CLEU)", cleuEvents, dispatch, nil)
    else
        local selfEvents = {
            "SPELL_DAMAGE_EVENT_SELF",
            "SPELL_MISS_SELF",
            "AUTO_ATTACK_SELF",
            "SPELL_HEAL_BY_SELF",
            "SPELL_HEAL_ON_SELF",
            "SPELL_ENERGIZE_ON_SELF",
            "UNIT_DIED",
            "UNIT_PET",
            "UNIT_PET_GUID",
            "PLAYER_ENTERING_WORLD",
        }
        local otherEvents = {
            "SPELL_DAMAGE_EVENT_OTHER",
            "SPELL_MISS_OTHER",
            "AUTO_ATTACK_OTHER",
        }
        CombatHub:Subscribe("EavesDrop_Self", "EavesDrop (Self)", selfEvents, dispatch, nil)
        CombatHub:Subscribe("EavesDrop_Other", "EavesDrop (Filtered Other)", otherEvents, dispatch, "self_or_pet")
    end
end)
