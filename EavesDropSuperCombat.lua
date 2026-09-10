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

    * DPSLog     - WeirdUtils' backport of WotLK's structured
                   COMBAT_LOG_EVENT_UNFILTERED / CombatLogGetCurrentEventInfo()
                   API. Hands over unit NAMES directly (no GUID
                   resolution needed), has its own GetSpellInfo for
                   icons, and covers buffs/debuffs/fades too - so
                   when this is present it's used on its own instead
                   of the nampower/SuperWoW/ClassicAPI combination
                   below, which it makes largely redundant.
    * nampower   - fires structured, GUID + spellId combat events
                   (SPELL_DAMAGE_EVENT_SELF/OTHER, SPELL_MISS_*,
                   SPELL_HEAL_*, SPELL_ENERGIZE_*, AUTO_ATTACK_*,
                   UNIT_DIED, ...). This is what replaces the
                   fragile chat-string parsing when DPSLog isn't
                   present.
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

  If none of DPSLog or (nampower + SuperWoW/ClassicAPI) are
  detected, this file does nothing and EavesDrop behaves exactly
  as stock - it is a pure enhancement, never a requirement.

  NOTE: written and reviewed against the public docs/READMEs of
  each project, but not run against a live 1.12 client - please
  sanity check event names/field order against your installed
  DLL versions (EVENTS.md in the nampower repo, WeirdUtils'
  DPSLog wiki, in particular) before relying on it raid-side.
****************************************************************]]

local SC = {}
EavesDrop.SuperCombat = SC
local L = AceLibrary("AceLocale-2.2"):new("EavesDrop")

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
	-- WeirdUtils' DPSLog has no version global either; its presence is
	-- unambiguous from CombatLogGetCurrentEventInfo existing, since
	-- nothing else in 1.12 ever defines that function.
	self.hasDPSLog = (type(CombatLogGetCurrentEventInfo) == "function")
	-- VanillaHelpers has no Lua-visible marker at all (it's pure
	-- C++ side texture/minimap/file functions); WriteFile/ReadFile
	-- are the only globals it adds, so use those as a weak signal.
	self.hasVanillaHelpers = (type(ReadFile) == "function" and type(WriteFile) == "function")

	-- Spell ID -> name/icon resolver. Several of these mods each ship
	-- their own GetSpellInfo(spellId) global (ClassicAPI, DPSLog) and
	-- SuperWoW ships the equivalent under a different name (SpellInfo).
	-- Whichever DLL happens to own the `GetSpellInfo` global name is
	-- irrelevant here - just try it, then fall back to SuperWoW's name.
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
		local name, icon = tryResolve(GetSpellInfo, spellId)
		if not name and self.hasSuperWoW then name, icon = tryResolve(SpellInfo, spellId) end
		if name then
			spellCache[spellId] = { name = name, icon = icon }
		else
			spellCache[spellId] = false
		end
		return name, icon
	end

	self.active = self.hasDPSLog or (self.hasNampower and (self.hasSuperWoW or self.hasClassicAPI))
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

function SC:Show(direction, text, texture, color, statInfo, source)
	if statInfo then
		if EavesDrop:TrackStat(direction, statInfo) then
			text = "|cffffff00!|r" .. text .. "|cffffff00!|r"
		end
	end
	-- arg1 is a plain global set by the WoW frame event dispatcher (the
	-- same one ParserLib's chat-message path reuses for its "raw chat
	-- text" tooltip line). By the time we get here it's a leftover
	-- native event arg (a GUID, a number, ...), not chat text - clear
	-- it so DisplayEvent doesn't fold that noise into the tooltip
	-- alongside our own clean "Source: X" line.
	arg1 = nil
	EavesDrop:DisplayEvent(direction, text, texture, color, source)
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
		self:Show(OUTGOING, text, icon, EavesDrop:SpellColor(db["TSPELL"], self:SchoolConst(spellSchool)), statInfo, self:NameFromGUID(targetGuid))
	elseif incoming then
		self:Show(INCOMING, "-" .. text, icon, EavesDrop:SpellColor(db["PSPELL"], self:SchoolConst(spellSchool)), statInfo, self:NameFromGUID(casterGuid))
	elseif petOut then
		self:Show(OUTGOING, text, icon or "pet", db["PETO"], nil, self:NameFromGUID(targetGuid))
	elseif petIn then
		self:Show(INCOMING, "-" .. text, icon or "pet", db["PETI"], nil, self:NameFromGUID(casterGuid))
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
			self:Show(OUTGOING, missWord, nil, db["TMELEE"], nil, self:NameFromGUID(targetGuid))
		elseif incoming then
			self:Show(INCOMING, missWord, nil, db["PMISS"], nil, self:NameFromGUID(attackerGuid))
		elseif petOut then
			self:Show(OUTGOING, missWord, "pet", db["PETO"], nil, self:NameFromGUID(targetGuid))
		elseif petIn then
			self:Show(INCOMING, missWord, "pet", db["PETI"], nil, self:NameFromGUID(attackerGuid))
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
		self:Show(OUTGOING, text, nil, db["TMELEE"], statInfo, self:NameFromGUID(targetGuid))
	elseif incoming then
		self:Show(INCOMING, "-" .. text, nil, db["PHIT"], statInfo, self:NameFromGUID(attackerGuid))
	elseif petOut then
		self:Show(OUTGOING, text, "pet", db["PETO"], nil, self:NameFromGUID(targetGuid))
	elseif petIn then
		self:Show(INCOMING, "-" .. text, "pet", db["PETI"], nil, self:NameFromGUID(attackerGuid))
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
		self:Show(OUTGOING, miss, nil, db["TSPELL"], nil, self:NameFromGUID(targetGuid))
	elseif incoming then
		self:Show(INCOMING, miss, nil, db["PMISS"], nil, self:NameFromGUID(casterGuid))
	elseif petIn then
		self:Show(INCOMING, miss, "pet", db["PETI"], nil, self:NameFromGUID(casterGuid))
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
	self:Show(OUTGOING, text, icon, db["THEAL"], statInfo, self:NameFromGUID(targetGuid))
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
	self:Show(INCOMING, "+" .. text, icon, db["PHEAL"], statInfo, casterGuid ~= self.playerGUID and self:NameFromGUID(casterGuid) or nil)
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
	self:Show(INCOMING, amount .. " " .. powerName, icon, db["PGAIN"], nil, casterGuid ~= self.playerGUID and self:NameFromGUID(casterGuid) or nil)
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
-- DPSLog backend (WeirdUtils' dpslog.dll)
--
-- This is preferred over the nampower/SuperWoW/ClassicAPI path above
-- whenever it's present, for three reasons:
--
--  1. DPSLog hands over srcName/dstName directly in every event - no
--     GUID-to-name resolution step needed at all (no dependency on
--     SuperWoW or ClassicAPI for that half of the problem).
--  2. It has its own GetSpellInfo(spellId), so icon lookup works even
--     completely standalone, with neither of the other two present.
--  3. It fires SPELL_AURA_APPLIED/REMOVED, which the nampower path
--     has no equivalent for - so buffs/debuffs/fades, previously left
--     on the old chat-string pipeline, now go through the same
--     accurate GUID-based feed as everything else.
--
-- It also fires PARTY_KILL with a real killer GUID for player kills,
-- which is a cleaner signal than nampower's bare UNIT_DIED - so the
-- "who last hit this" heuristic above isn't needed on this path.
-- ---------------------------------------------------------------

local DL_POWER_NAME = { [-2] = "Health", [0] = MANA, [1] = RAGE, [2] = FOCUS, [3] = ENERGY, [4] = "Combo Points" }
-- Note: this is WotLK-style numbering (DPSLog's own doc), which is NOT
-- the same table as nampower's POWER_NAME above - nampower's power
-- type 4 is vanilla-native "Happiness", DPSLog's is "Combo Points".
-- Mixing these two tables up would silently mislabel pet happiness
-- gains or combo points depending on which backend is active.

function SC:DL_Name(guid, name)
	if guid == self.playerGUID then return ParserLib_SELF end
	return name or self:NameFromGUID(guid) or guid
end

function SC:DL_Damage(srcGUID, srcName, dstGUID, dstName, spellId, spellName, school, amount, resisted, blocked, absorbed, isCrit, isMelee)
	amount = tonumber(amount) or 0
	resisted, blocked, absorbed = tonumber(resisted) or 0, tonumber(blocked) or 0, tonumber(absorbed) or 0
	local db = EavesDrop.db.profile

	local outgoing = (srcGUID == self.playerGUID)
	local incoming = (dstGUID == self.playerGUID)
	local petOut    = (srcGUID == self.petGUID) and db["PET"]
	local petIn     = (dstGUID == self.petGUID) and db["PET"]
	if not (outgoing or incoming or petOut or petIn) then return end

	local text = tostring(amount)
	if isCrit then text = critchar .. text .. critchar end
	if resisted > 0 then text = text .. " (" .. resisted .. ")" end
	if blocked > 0 then text = text .. " (" .. blocked .. ")" end
	if absorbed > 0 then text = text .. " (" .. absorbed .. ")" end

	local element = (not isMelee) and self:SchoolConst(school)
	local _, icon = self:SpellNameIcon(spellId)
	local statInfo = { type = "hit", skill = isMelee and ParserLib_MELEE or spellName, amount = amount, isCrit = isCrit, element = element }

	if outgoing then
		self:Show(OUTGOING, text, icon, isMelee and db["TMELEE"] or EavesDrop:SpellColor(db["TSPELL"], element), statInfo, self:DL_Name(dstGUID, dstName))
	elseif incoming then
		self:Show(INCOMING, "-" .. text, icon, isMelee and db["PHIT"] or EavesDrop:SpellColor(db["PSPELL"], element), statInfo, self:DL_Name(srcGUID, srcName))
	elseif petOut then
		self:Show(OUTGOING, text, icon or "pet", db["PETO"], nil, self:DL_Name(dstGUID, dstName))
	elseif petIn then
		self:Show(INCOMING, "-" .. text, icon or "pet", db["PETI"], nil, self:DL_Name(srcGUID, srcName))
	end
end

function SC:DL_Miss(srcGUID, srcName, dstGUID, dstName, missType, isMelee)
	local db = EavesDrop.db.profile
	local miss = getglobal(missType) or missType

	local outgoing = (srcGUID == self.playerGUID)
	local incoming = (dstGUID == self.playerGUID)
	local petOut    = (srcGUID == self.petGUID) and db["PET"]
	local petIn     = (dstGUID == self.petGUID) and db["PET"]
	if not (outgoing or incoming or petOut or petIn) then return end

	if outgoing then
		self:Show(OUTGOING, miss, nil, isMelee and db["TMELEE"] or db["TSPELL"], nil, self:DL_Name(dstGUID, dstName))
	elseif incoming then
		self:Show(INCOMING, miss, nil, db["PMISS"], nil, self:DL_Name(srcGUID, srcName))
	elseif petOut then
		self:Show(OUTGOING, miss, "pet", db["PETO"], nil, self:DL_Name(dstGUID, dstName))
	elseif petIn then
		self:Show(INCOMING, miss, "pet", db["PETI"], nil, self:DL_Name(srcGUID, srcName))
	end
end

function SC:DL_Heal(srcGUID, srcName, dstGUID, dstName, spellId, spellName, amount, isCrit)
	amount = tonumber(amount) or 0
	local db = EavesDrop.db.profile
	if amount < db["HFILTER"] then return end
	local _, icon = self:SpellNameIcon(spellId)
	local statInfo = { type = "heal", skill = spellName, amount = amount, isCrit = isCrit }

	if dstGUID == self.playerGUID then
		local text = tostring(amount)
		if isCrit then text = critchar .. text .. critchar end
		if db["HEALERID"] == true and srcGUID ~= self.playerGUID then
			text = text .. " (" .. self:DL_Name(srcGUID, srcName) .. ")"
		end
		self:Show(INCOMING, "+" .. text, icon, db["PHEAL"], statInfo, srcGUID ~= self.playerGUID and self:DL_Name(srcGUID, srcName) or nil)
	elseif srcGUID == self.playerGUID then
		local text = tostring(amount)
		if db["OVERHEAL"] == true then
			text = EavesDrop:GetOverheal(self:DL_Name(dstGUID, dstName), amount)
		end
		if isCrit then text = critchar .. text .. critchar end
		text = "+" .. text
		if db["HEALERID"] == true then text = self:DL_Name(dstGUID, dstName) .. ": " .. text end
		self:Show(OUTGOING, text, icon, db["THEAL"], statInfo, self:DL_Name(dstGUID, dstName))
	end
end

function SC:DL_Energize(dstGUID, amount, powerType)
	if dstGUID ~= self.playerGUID then return end
	amount = tonumber(amount) or 0
	local db = EavesDrop.db.profile
	if db["GAIN"] ~= true then return end
	if amount < (db["MFILTER"] or 0) then return end
	local powerName = DL_POWER_NAME[tonumber(powerType)] or ""
	self:Show(INCOMING, amount .. " " .. powerName, nil, db["PGAIN"])
end

-- Buffs/debuffs/fades - previously only available via the stock
-- chat-string pipeline (nampower has no equivalent), self-only to
-- match what stock EavesDrop covers.
function SC:DL_Aura(dstGUID, spellId, spellName, auraType, applied)
	if dstGUID ~= self.playerGUID then return end
	local db = EavesDrop.db.profile
	local _, icon = self:SpellNameIcon(spellId)
	if applied then
		if auraType == "BUFF" then
			if db["BUFF"] ~= true then return end
			self:Show(INCOMING, spellName, icon, db["PBUFF"])
		else
			if db["DEBUFF"] ~= true then return end
			self:Show(INCOMING, spellName, icon, db["PDEBUFF"])
		end
	else
		if db["FADE"] ~= true then return end
		self:Show(INCOMING, L["Fades"]..": "..spellName, icon, db["PBUFF"])
	end
end

-- PARTY_KILL carries a real killer GUID (unlike UNIT_DIED, which
-- DPSLog - like nampower - reports with no reliable source), so no
-- "who last hit this" heuristic is needed on this backend.
function SC:DL_Died(srcGUID, dstGUID, dstName)
	if srcGUID ~= self.playerGUID then return end
	local name = dstName or UNKNOWN
	local db = EavesDrop.db.profile
	self:Show(MISC, "\226\128\160" .. name .. "\226\128\160", nil, db["DEATH"])
end

function SC:OnCombatLogEvent()
	local args = { CombatLogGetCurrentEventInfo() }
	local sub, srcGUID, srcName, srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags = unpack(args, 1, 9)

	if sub == "SWING_DAMAGE" then
		local amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing = unpack(args, 10, 18)
		self:DL_Damage(srcGUID, srcName, dstGUID, dstName, nil, nil, school, amount, resisted, blocked, absorbed, critical ~= nil, true)
	elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT" then
		local spellId, spellName, spellSchool, amount, overkill, school, resisted, blocked, absorbed, critical = unpack(args, 10, 19)
		self:DL_Damage(srcGUID, srcName, dstGUID, dstName, spellId, spellName, school, amount, resisted, blocked, absorbed, critical ~= nil, false)
	elseif sub == "SWING_MISSED" then
		local missType = unpack(args, 10, 10)
		self:DL_Miss(srcGUID, srcName, dstGUID, dstName, missType, true)
	elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED" or sub == "SPELL_PERIODIC_MISSED" or sub == "DAMAGE_SHIELD_MISSED" then
		local spellId, spellName, spellSchool, missType = unpack(args, 10, 13)
		self:DL_Miss(srcGUID, srcName, dstGUID, dstName, missType, false)
	elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
		local spellId, spellName, spellSchool, amount, overhealing, absorbed, critical = unpack(args, 10, 16)
		self:DL_Heal(srcGUID, srcName, dstGUID, dstName, spellId, spellName, amount, critical ~= nil)
	elseif sub == "SPELL_ENERGIZE" or sub == "SPELL_PERIODIC_ENERGIZE" then
		local spellId, spellName, spellSchool, amount, powerType = unpack(args, 10, 14)
		self:DL_Energize(dstGUID, amount, powerType)
	elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_APPLIED_DOSE" then
		local spellId, spellName, spellSchool, auraType = unpack(args, 10, 13)
		self:DL_Aura(dstGUID, spellId, spellName, auraType, true)
	elseif sub == "SPELL_AURA_REMOVED" or sub == "SPELL_AURA_REMOVED_DOSE" then
		local spellId, spellName, spellSchool, auraType = unpack(args, 10, 13)
		self:DL_Aura(dstGUID, spellId, spellName, auraType, false)
	elseif sub == "ENVIRONMENTAL_DAMAGE" then
		local envType, amount, overkill, school, resisted, blocked, absorbed, critical = unpack(args, 10, 17)
		if dstGUID == self.playerGUID then
			amount, resisted, absorbed = tonumber(amount) or 0, tonumber(resisted) or 0, tonumber(absorbed) or 0
			local text = tostring(amount)
			if resisted > 0 then text = text .. " (" .. resisted .. ")" end
			if absorbed > 0 then text = text .. " (" .. absorbed .. ")" end
			self:Show(INCOMING, "-" .. text, nil, EavesDrop.db.profile["PSPELL"], nil, envType)
		end
	elseif sub == "PARTY_KILL" then
		self:DL_Died(srcGUID, dstGUID, dstName)
	elseif sub == "UNIT_PET_GUID" then
		self:RefreshSelfGUIDs()
	end
end

-- ---------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------

-- Chat-message events made redundant once a GUID feed is live.
-- The base set is replaced by either backend; the extra set (buffs/
-- debuffs/fades) is only replaced when DPSLog is driving, since the
-- nampower path has no equivalent for those.
local REPLACED_EVENTS_BASE = {
	"CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
	"CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS", "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES",
	"CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
	"CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE", "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE", "CHAT_MSG_SPELL_SELF_DAMAGE",
	"CHAT_MSG_COMBAT_HOSTILE_DEATH",
	"CHAT_MSG_COMBAT_PET_HITS", "CHAT_MSG_COMBAT_PET_MISSES", "CHAT_MSG_SPELL_PET_DAMAGE",
}
local REPLACED_EVENTS_AURA = {
	"CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF", "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
	"CHAT_MSG_SPELL_AURA_GONE_SELF", "CHAT_MSG_SPELL_AURA_GONE_OTHER", "CHAT_MSG_SPELL_BREAK_AURA",
}

local function UnregisterChatEvents(list)
	local parser = ParserLib and ParserLib:GetInstance("1.1")
	if not parser then return end
	for _, ev in ipairs(list) do
		parser:UnregisterEvent("EavesDrop", ev)
	end
end

function SC:InitDPSLog()
	UnregisterChatEvents(REPLACED_EVENTS_BASE)
	UnregisterChatEvents(REPLACED_EVENTS_AURA)

	local f = CreateFrame("Frame")
	f:RegisterEvent("UNIT_PET_GUID")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")
	f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	f:SetScript("OnEvent", function()
		if event == "UNIT_PET_GUID" or event == "PLAYER_ENTERING_WORLD" then
			SC:RefreshSelfGUIDs()
		elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
			SC:OnCombatLogEvent()
		end
	end)
	self.frame = f

	local msg = "|cff7fff7fEavesDrop|r: SuperCombat active - DPSLog"
	if self.hasUnitXP then msg = msg .. " + UnitXP_SP3" end
	DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function SC:InitNampower()
	UnregisterChatEvents(REPLACED_EVENTS_BASE)

	-- Turn on the nampower events this module needs; they default off.
	if type(SetCVar) == "function" then
		for _, cvar in ipairs({ "NP_EnableAutoAttackEvents", "NP_EnableSpellHealEvents", "NP_EnableSpellEnergizeEvents" }) do
			if GetCVar(cvar) == "0" then SetCVar(cvar, "1") end
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
	DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: buffs/debuffs/fades still use stock chat-log parsing (no DPSLog detected).")
end

function SC:Init()
	if not self:DetectMods() then
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: SuperCombat inactive (needs DPSLog, or nampower + SuperWoW/ClassicAPI). Using stock chat-log parsing.")
		return
	end

	self:RefreshSelfGUIDs()

	if self.hasDPSLog then
		self:InitDPSLog()
	else
		self:InitNampower()
	end

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
