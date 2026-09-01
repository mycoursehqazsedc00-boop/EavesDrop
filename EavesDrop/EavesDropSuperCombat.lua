--[[
****************************************************************
  EavesDropSuperCombat

  Optional companion module for EavesDrop.

  Stock EavesDrop reads the *localized chat-log strings*
  (CHAT_MSG_COMBAT_SELF_HITS, CHAT_MSG_SPELL_SELF_DAMAGE, ...)
  and re-parses them with ParserLib pattern matching. That is
  the only way to get combat data in plain 1.12 - the client
  never exposes real unit GUIDs or spell IDs to Lua, so the
  addon has to guess "who is this" by matching names against
  your party/raid roster (EavesDrop:GetTargetUnit), and "which
  spell is this" by matching the *localized spell name string*
  against Babble-Spell's translation tables.

  If you're running with the mods listed below, better data is
  available and this file switches EavesDrop to use it instead:

    * nampower   - fires structured, GUID + spellId combat events
                   (SPELL_DAMAGE_EVENT_SELF/OTHER, SPELL_MISS_*,
                   SPELL_HEAL_*, SPELL_ENERGIZE_*, AUTO_ATTACK_*,
                   UNIT_DIED, ...). This is what replaces the
                   fragile chat-string parsing.
    * SuperWoW   - lets every UnitXXX() Lua call accept a raw
                   GUID in place of a unit token, and adds
                   SpellInfo(spellId) to resolve a spell ID to
                   its name/icon. This is what turns nampower's
                   GUIDs and spell IDs back into unit names and
                   spell icons.
    * ClassicAPI - backports GetSpellInfo(spellId)/UnitGUID as a
                   convenience; used the same way as SuperWoW's
                   SpellInfo() and preferred when present since it
                   returns the full modern GetSpellInfo() tuple.
    * UnitXP_SP3 - primarily the launcher that hosts the DLLs
                   above; also exposes a few misc helpers
                   (UnitXP("distanceBetween", ...) etc.) which
                   this file uses only as an optional, best-effort
                   range/LOS tag - EavesDrop's core combat feed
                   does not depend on it.
    * VanillaHelpers - a client-tweaks DLL (minimap blips, high-
                   res textures, unit display remapping). It has
                   no combat-log or spell-info API, so there is
                   nothing for a combat log addon to hook here;
                   it's detected/reported for completeness only.

  If nampower + SuperWoW (or ClassicAPI) aren't detected, this
  file does nothing and EavesDrop behaves exactly as stock -
  it is a pure enhancement, never a requirement.

  NOTE: written and reviewed against the public docs/READMEs of
  each project, but not run against a live 1.12 client - please
  sanity check event names/field order against your installed
  DLL versions (EVENTS.md in the nampower repo, in particular)
  before relying on it raid-side.
****************************************************************]]

local SC = {}
EavesDrop.SuperCombat = SC

-- Mirrors the private locals in EavesDrop.lua - these are plain
-- constants, not shared state, so redefining them here is safe.
local OUTGOING   = 1
local INCOMING   = -1
local MISC       = 3
local critchar   = "*"
local deathchar  = "\226\128\160" -- †  (kept ASCII-safe in source)
local crushchar  = "^"
local glancechar = "~"

-- ---------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------

function SC:DetectMods()
	self.hasSuperWoW   = (SUPERWOW_VERSION ~= nil)
	self.hasClassicAPI = (CLASSIC_API_VERSION ~= nil)
	self.hasUnitXP      = (type(UnitXP) == "function")
	-- nampower has no version global; its presence is inferred from
	-- one of its CVars, which only exist once the DLL registers them.
	local npCvar = GetCVar and GetCVar("NP_SpellQueueWindowMs")
	self.hasNampower = (npCvar ~= nil and npCvar ~= "")
	-- VanillaHelpers has no Lua-visible marker at all (it's pure
	-- C++ side texture/minimap/file functions); WriteFile/ReadFile
	-- are the only globals it adds, so use those as a weak signal.
	self.hasVanillaHelpers = (type(ReadFile) == "function" and type(WriteFile) == "function")

	-- Spell ID -> name/icon resolver: prefer ClassicAPI's modern
	-- GetSpellInfo (returns the full retail-style tuple), fall back
	-- to SuperWoW's SpellInfo(id) (name, rank, icon, minRange, maxRange).
	--
	-- Both of these are third-party native calls, and in practice
	-- some spellIds nampower reports (0, or ids for effects that
	-- aren't "real" cast spells) make at least one known ClassicAPI
	-- build (v1.12.7) throw a hard Lua error ("Invalid spell slot in
	-- GetSpellName") instead of returning nil. So every call is
	-- pcall-wrapped and results are cached, both to stop a bad id
	-- from ever crashing an event handler and so a bad id is only
	-- ever probed once instead of erroring on every repeat event.
	local spellCache = {}
	local function tryResolve(fn, spellId)
		if type(fn) ~= "function" then return nil, nil end
		local ok, name, _, icon = pcall(fn, spellId)
		if ok and name then return name, icon end
		return nil, nil
	end
	self.SpellNameIcon = function(_, spellId)
		spellId = tonumber(spellId)
		if not spellId or spellId <= 0 then return nil, nil end
		local cached = spellCache[spellId]
		if cached ~= nil then
			if cached == false then return nil, nil end
			return cached.name, cached.icon
		end
		local name, icon
		if self.hasClassicAPI then name, icon = tryResolve(GetSpellInfo, spellId) end
		if not name and self.hasSuperWoW then name, icon = tryResolve(SpellInfo, spellId) end
		if name then
			spellCache[spellId] = { name = name, icon = icon }
		else
			spellCache[spellId] = false
		end
		return name, icon
	end

	self.active = self.hasNampower and (self.hasSuperWoW or self.hasClassicAPI)
	return self.active
end

-- ---------------------------------------------------------------
-- GUID <-> name resolution
-- ---------------------------------------------------------------

function SC:RefreshSelfGUIDs()
	local _, pGuid = UnitExists("player")
	self.playerGUID = pGuid
	local petExists, petGuid = UnitExists("pet")
	self.petGUID = petExists and petGuid or nil
end

-- Returns either ParserLib_SELF (so EavesDrop's existing color/side
-- logic treats it exactly like a stock event), the resolved unit
-- name (SuperWoW accepts a GUID directly as a unit token), or the
-- raw GUID string as a last-resort label.
function SC:NameFromGUID(guid)
	if not guid or guid == "0x0000000000000000" then return nil end
	if guid == self.playerGUID then return ParserLib_SELF end
	if self.hasSuperWoW then
		local ok, name = pcall(UnitName, guid)
		if ok and name then return name end
	end
	return guid
end

function SC:IsPet(guid)
	return guid ~= nil and guid == self.petGUID
end

local SCHOOL_CAP_NAME = {
	[0] = "SPELL_SCHOOL0_CAP", [1] = "SPELL_SCHOOL1_CAP", [2] = "SPELL_SCHOOL2_CAP",
	[3] = "SPELL_SCHOOL3_CAP", [4] = "SPELL_SCHOOL4_CAP", [5] = "SPELL_SCHOOL5_CAP",
	[6] = "SPELL_SCHOOL6_CAP",
}
function SC:SchoolConst(schoolIndex)
	local key = SCHOOL_CAP_NAME[schoolIndex]
	return key and getglobal(key)
end

-- Small dependency-free bitwise AND for 16/32-bit flag fields, used
-- so crit/crushing/glancing/miss detection doesn't silently go dark
-- if no `bit` library happens to be loaded by another addon.
local function band(a, b)
	if bit and bit.band then return bit.band(a, b) end
	local result, bitval = 0, 1
	while a > 0 and b > 0 do
		local abit, bbit = a % 2, b % 2
		if abit == 1 and bbit == 1 then result = result + bitval end
		a, b, bitval = (a - abit) / 2, (b - bbit) / 2, bitval * 2
	end
	return result
end

local function splitMitigation(str)
	-- "absorb,block,resist"
	local a, b, r = 0, 0, 0
	if str and str ~= "" then
		local _, _, sa, sb, sr = string.find(str, "(%d*),(%d*),(%d*)")
		a, b, r = tonumber(sa) or 0, tonumber(sb) or 0, tonumber(sr) or 0
	end
	return a, b, r
end

-- ---------------------------------------------------------------
-- Shared display helper - builds the same kind of `info` table
-- ParserLib produces and hands it to EavesDrop:TrackStat, then
-- renders the line via EavesDrop:DisplayEvent (so history/new-high
-- tracking, colors, filters and options all keep working unchanged).
-- ---------------------------------------------------------------

function SC:Show(direction, text, texture, color, statInfo)
	if statInfo then
		if EavesDrop:TrackStat(direction, statInfo) then
			text = "|cffffff00!|r" .. text .. "|cffffff00!|r"
		end
	end
	EavesDrop:DisplayEvent(direction, text, texture, color)
end

-- ---------------------------------------------------------------
-- Damage (SPELL_DAMAGE_EVENT_SELF / _OTHER)
-- ---------------------------------------------------------------

function SC:OnSpellDamage(isSelfEvent, targetGuid, casterGuid, spellId, amount, mitigationStr, hitInfo, spellSchool)
	spellId, amount, hitInfo, spellSchool = tonumber(spellId), tonumber(amount), tonumber(hitInfo), tonumber(spellSchool)
	local isCrit = (hitInfo == 2)
	local absorb, block, resist = splitMitigation(mitigationStr)
	local name, icon = self:SpellNameIcon(spellId)
	local db = EavesDrop.db.profile

	local outgoing = isSelfEvent -- SELF event = damage the player dealt
	local incoming = (not isSelfEvent) and (targetGuid == self.playerGUID)
	local petOut    = (not isSelfEvent) and (casterGuid == self.petGUID) and db["PET"]
	local petIn     = (not isSelfEvent) and (targetGuid == self.petGUID) and db["PET"]

	if not (outgoing or incoming or petOut or petIn) then return end

	local text = tostring(amount)
	if isCrit then text = critchar .. text .. critchar end
	if resist > 0 then text = text .. " (" .. resist .. ")" end
	if block > 0 then text = text .. " (" .. block .. ")" end
	if absorb > 0 then text = text .. " (" .. absorb .. ")" end

	local statInfo = { type = "hit", skill = name, amount = amount, isCrit = isCrit, element = self:SchoolConst(spellSchool) }

	if outgoing then
		self:Show(OUTGOING, text, icon, EavesDrop:SpellColor(db["TSPELL"], self:SchoolConst(spellSchool)), statInfo)
	elseif incoming then
		self:Show(INCOMING, "-" .. text, icon, EavesDrop:SpellColor(db["PSPELL"], self:SchoolConst(spellSchool)), statInfo)
	elseif petOut then
		self:Show(OUTGOING, text, icon or "pet", db["PETO"])
	elseif petIn then
		self:Show(INCOMING, "-" .. text, icon or "pet", db["PETI"])
	end
end

-- ---------------------------------------------------------------
-- Melee / auto attack (AUTO_ATTACK_SELF / _OTHER)
-- gated behind NP_EnableAutoAttackEvents, enabled in SC:Init
-- ---------------------------------------------------------------

local HITINFO_CRITICALHIT = 128
local HITINFO_GLANCING    = 16384
local HITINFO_CRUSHING    = 32768
local HITINFO_MISS        = 16
local VICTIMSTATE_NAMES = {
	[2] = "DODGE", [3] = "PARRY", [4] = "INTERRUPT", [5] = "BLOCK", [6] = "EVADE", [7] = "IMMUNE", [8] = "DEFLECT",
}

function SC:OnAutoAttack(attackerGuid, targetGuid, totalDamage, hitInfo, victimState, subDamageCount, blockedAmount, totalAbsorb, totalResist)
	totalDamage, hitInfo, victimState = tonumber(totalDamage), tonumber(hitInfo), tonumber(victimState)
	local db = EavesDrop.db.profile

	local outgoing = (attackerGuid == self.playerGUID)
	local incoming = (targetGuid == self.playerGUID)
	local petOut    = (attackerGuid == self.petGUID) and db["PET"]
	local petIn     = (targetGuid == self.petGUID) and db["PET"]
	if not (outgoing or incoming or petOut or petIn) then return end

	-- a miss/dodge/parry/etc reports through victimState / HITINFO_MISS
	if band(hitInfo, HITINFO_MISS) ~= 0 or VICTIMSTATE_NAMES[victimState] then
		local missWord = VICTIMSTATE_NAMES[victimState] and getglobal(VICTIMSTATE_NAMES[victimState]) or MISS
		if outgoing then
			self:Show(OUTGOING, missWord, nil, db["TMELEE"])
		elseif incoming then
			self:Show(INCOMING, missWord, nil, db["PMISS"])
		elseif petOut then
			self:Show(OUTGOING, missWord, "pet", db["PETO"])
		elseif petIn then
			self:Show(INCOMING, missWord, "pet", db["PETI"])
		end
		return
	end

	local isCrit = band(hitInfo, HITINFO_CRITICALHIT) ~= 0
	local isGlancing = band(hitInfo, HITINFO_GLANCING) ~= 0
	local isCrushing = band(hitInfo, HITINFO_CRUSHING) ~= 0

	local text = tostring(totalDamage)
	if isCrit then text = critchar .. text .. critchar end
	if isCrushing then text = crushchar .. text .. crushchar end
	if isGlancing then text = glancechar .. text .. glancechar end
	local nResist, nBlocked, nAbsorb = tonumber(totalResist) or 0, tonumber(blockedAmount) or 0, tonumber(totalAbsorb) or 0
	if nResist > 0 then text = text .. " (" .. nResist .. ")" end
	if nBlocked > 0 then text = text .. " (" .. nBlocked .. ")" end
	if nAbsorb > 0 then text = text .. " (" .. nAbsorb .. ")" end

	local statInfo = { type = "hit", skill = ParserLib_MELEE, amount = totalDamage, isCrit = isCrit }

	if outgoing then
		self:Show(OUTGOING, text, nil, db["TMELEE"], statInfo)
	elseif incoming then
		self:Show(INCOMING, "-" .. text, nil, db["PHIT"], statInfo)
	elseif petOut then
		self:Show(OUTGOING, text, "pet", db["PETO"])
	elseif petIn then
		self:Show(INCOMING, "-" .. text, "pet", db["PETI"])
	end
end

-- ---------------------------------------------------------------
-- Spell misses (SPELL_MISS_SELF / _OTHER)
-- ---------------------------------------------------------------

local MISS_NAME = {
	[1] = "MISS", [2] = "RESIST", [3] = "DODGE", [4] = "PARRY", [5] = "BLOCK",
	[6] = "EVADE", [7] = "IMMUNE", [8] = "IMMUNE", [9] = "DEFLECT", [10] = "ABSORB", [11] = "REFLECT",
}

function SC:OnSpellMiss(isSelfEvent, casterGuid, targetGuid, spellId, missInfo)
	missInfo = tonumber(missInfo)
	local word = MISS_NAME[missInfo]
	if not word then return end
	local miss = getglobal(word) or word
	local db = EavesDrop.db.profile

	local outgoing = isSelfEvent
	local incoming = (not isSelfEvent) and (targetGuid == self.playerGUID)
	local petIn     = (not isSelfEvent) and (targetGuid == self.petGUID) and db["PET"]

	if outgoing then
		self:Show(OUTGOING, miss, nil, db["TSPELL"])
	elseif incoming then
		self:Show(INCOMING, miss, nil, db["PMISS"])
	elseif petIn then
		self:Show(INCOMING, miss, "pet", db["PETI"])
	end
end

-- ---------------------------------------------------------------
-- Heals (SPELL_HEAL_BY_SELF / SPELL_HEAL_ON_SELF)
-- gated behind NP_EnableSpellHealEvents, enabled in SC:Init
-- ---------------------------------------------------------------

function SC:OnHealBySelf(targetGuid, casterGuid, spellId, amount, critical, periodic)
	amount = tonumber(amount)
	local db = EavesDrop.db.profile
	if amount < db["HFILTER"] then return end
	local isCrit = (tonumber(critical) == 1)
	local name, icon = self:SpellNameIcon(tonumber(spellId))

	if targetGuid == self.playerGUID then return end -- handled by OnHealOnSelf to avoid double count
	local text = tostring(amount)
	if db["OVERHEAL"] == true then
		text = EavesDrop:GetOverheal(self:NameFromGUID(targetGuid) or targetGuid, amount)
	end
	if isCrit then text = critchar .. text .. critchar end
	text = "+" .. text
	if db["HEALERID"] == true then text = (self:NameFromGUID(targetGuid) or "?") .. ": " .. text end

	local statInfo = { type = "heal", skill = name, amount = amount, isCrit = isCrit }
	self:Show(OUTGOING, text, icon, db["THEAL"], statInfo)
end

function SC:OnHealOnSelf(targetGuid, casterGuid, spellId, amount, critical, periodic)
	if targetGuid ~= self.playerGUID then return end
	amount = tonumber(amount)
	local db = EavesDrop.db.profile
	if amount < db["HFILTER"] then return end
	local isCrit = (tonumber(critical) == 1)
	local name, icon = self:SpellNameIcon(tonumber(spellId))
	local text = tostring(amount)
	if isCrit then text = critchar .. text .. critchar end
	if db["HEALERID"] == true and casterGuid ~= self.playerGUID then
		text = text .. " (" .. (self:NameFromGUID(casterGuid) or "?") .. ")"
	end
	local statInfo = { type = "heal", skill = name, amount = amount, isCrit = isCrit }
	self:Show(INCOMING, "+" .. text, icon, db["PHEAL"], statInfo)
end

-- ---------------------------------------------------------------
-- Power gains (SPELL_ENERGIZE_ON_SELF)
-- gated behind NP_EnableSpellEnergizeEvents, enabled in SC:Init
-- ---------------------------------------------------------------

local POWER_NAME = { [0] = MANA, [1] = RAGE, [2] = FOCUS, [3] = ENERGY, [4] = HAPPINESS }

function SC:OnEnergizeOnSelf(targetGuid, casterGuid, spellId, powerType, amount, periodic)
	if targetGuid ~= self.playerGUID then return end
	amount = tonumber(amount)
	local db = EavesDrop.db.profile
	if db["GAIN"] ~= true then return end
	if amount < (db["MFILTER"] or 0) then return end
	local powerName = POWER_NAME[tonumber(powerType)] or ""
	local name, icon = self:SpellNameIcon(tonumber(spellId))
	self:Show(INCOMING, amount .. " " .. powerName, icon, db["PGAIN"])
end

-- ---------------------------------------------------------------
-- Deaths (UNIT_DIED)
-- UNIT_DIED only gives a GUID, not a killer - so this keeps a short
-- rolling window of "who last hit this GUID" from the damage/attack
-- handlers above and only announces a death that followed shortly
-- after damage from the player, to reproduce EavesDrop's original
-- "you have slain X" behaviour instead of announcing every death
-- in the zone.
-- ---------------------------------------------------------------

SC.recentSelfDamage = {} -- [guid] = GetTime() of last hit dealt by the player

function SC:NoteSelfDamage(guid)
	self.recentSelfDamage[guid] = GetTime()
end

function SC:OnUnitDied(guid)
	local t = self.recentSelfDamage[guid]
	if not t or (GetTime() - t) > 5 then return end
	self.recentSelfDamage[guid] = nil
	local name = self:NameFromGUID(guid) or UNKNOWN
	local db = EavesDrop.db.profile
	self:Show(MISC, "\226\128\160" .. name .. "\226\128\160", nil, db["DEATH"])
end

-- ---------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------

-- Chat-message events made redundant once the GUID feed is live.
-- Anything NOT in this list (buffs/debuffs, XP, reputation, honor,
-- skill-ups) still comes from the stock ParserLib/CHAT_MSG_* path,
-- because nampower has no equivalent event for those, or the
-- equivalent is opt-in and less battle-tested (aura cast events).
local REPLACED_EVENTS = {
	"CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
	"CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS", "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES",
	"CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
	"CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE", "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE", "CHAT_MSG_SPELL_SELF_DAMAGE",
	"CHAT_MSG_COMBAT_HOSTILE_DEATH",
	"CHAT_MSG_COMBAT_PET_HITS", "CHAT_MSG_COMBAT_PET_MISSES", "CHAT_MSG_SPELL_PET_DAMAGE",
}

function SC:Init()
	if not self:DetectMods() then
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: SuperCombat inactive (needs nampower + SuperWoW or ClassicAPI). Using stock chat-log parsing.")
		return
	end

	self:RefreshSelfGUIDs()

	-- Turn on the nampower events this module needs; they default off.
	if type(SetCVar) == "function" then
		for _, cvar in ipairs({ "NP_EnableAutoAttackEvents", "NP_EnableSpellHealEvents", "NP_EnableSpellEnergizeEvents" }) do
			if GetCVar(cvar) == "0" then SetCVar(cvar, "1") end
		end
	end

	-- Stop double-processing events the GUID feed now owns.
	local parser = ParserLib and ParserLib:GetInstance("1.1")
	if parser then
		for _, ev in ipairs(REPLACED_EVENTS) do
			parser:UnregisterEvent("EavesDrop", ev)
		end
	end

	local f = CreateFrame("Frame")
	f:RegisterEvent("UNIT_PET_GUID")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")
	f:RegisterEvent("SPELL_DAMAGE_EVENT_SELF")
	f:RegisterEvent("SPELL_DAMAGE_EVENT_OTHER")
	f:RegisterEvent("SPELL_MISS_SELF")
	f:RegisterEvent("SPELL_MISS_OTHER")
	f:RegisterEvent("AUTO_ATTACK_SELF")
	f:RegisterEvent("AUTO_ATTACK_OTHER")
	f:RegisterEvent("SPELL_HEAL_BY_SELF")
	f:RegisterEvent("SPELL_HEAL_ON_SELF")
	f:RegisterEvent("SPELL_ENERGIZE_ON_SELF")
	f:RegisterEvent("UNIT_DIED")

	f:SetScript("OnEvent", function()
		if event == "UNIT_PET_GUID" or event == "PLAYER_ENTERING_WORLD" then
			SC:RefreshSelfGUIDs()
		elseif event == "SPELL_DAMAGE_EVENT_SELF" then
			SC:OnSpellDamage(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
			if arg2 == SC.playerGUID then SC:NoteSelfDamage(arg1) end
		elseif event == "SPELL_DAMAGE_EVENT_OTHER" then
			SC:OnSpellDamage(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
			if arg2 == SC.playerGUID or arg2 == SC.petGUID then SC:NoteSelfDamage(arg1) end
		elseif event == "SPELL_MISS_SELF" then
			SC:OnSpellMiss(true, arg1, arg2, arg3, arg4)
		elseif event == "SPELL_MISS_OTHER" then
			SC:OnSpellMiss(false, arg1, arg2, arg3, arg4)
		elseif event == "AUTO_ATTACK_SELF" or event == "AUTO_ATTACK_OTHER" then
			SC:OnAutoAttack(arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
			if arg1 == SC.playerGUID or arg1 == SC.petGUID then SC:NoteSelfDamage(arg2) end
		elseif event == "SPELL_HEAL_BY_SELF" then
			SC:OnHealBySelf(arg1, arg2, arg3, arg4, arg5, arg6)
		elseif event == "SPELL_HEAL_ON_SELF" then
			SC:OnHealOnSelf(arg1, arg2, arg3, arg4, arg5, arg6)
		elseif event == "SPELL_ENERGIZE_ON_SELF" then
			SC:OnEnergizeOnSelf(arg1, arg2, arg3, arg4, arg5, arg6)
		elseif event == "UNIT_DIED" then
			SC:OnUnitDied(arg1)
		end
	end)

	self.frame = f

	local msg = "|cff7fff7fEavesDrop|r: SuperCombat active - nampower"
	if self.hasClassicAPI then msg = msg .. " + ClassicAPI" end
	if self.hasSuperWoW then msg = msg .. " + SuperWoW" end
	if self.hasUnitXP then msg = msg .. " + UnitXP_SP3" end
	DEFAULT_CHAT_FRAME:AddMessage(msg)
	if self.hasVanillaHelpers then
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: VanillaHelpers detected, but it has no combat/spell API for a combat log addon to use.")
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	-- Runs after EavesDrop:OnEnable (Ace2 addons enable on ADDON_LOADED,
	-- well before PLAYER_LOGIN), so EavesDrop.db and the event list
	-- registered by EavesDrop:OnEnable already exist to unregister.
	SC:Init()
end)
