--[[
****************************************************************
  EavesDropSuperCombat

  Optional companion module for EavesDrop.

  Stock EavesDrop reads localized chat-log strings via ParserLib.
  When supported client DLL mods are present, this module upgrades
  EavesDrop to structured GUID/spellID combat events:

    * WeirdUtils (dpslog) - WotLK-style COMBAT_LOG_EVENT_UNFILTERED
                            (9-arg header) + GetSpellInfo(spellId).
    * ClassicAPI          - Modern COMBAT_LOG_EVENT_UNFILTERED
                            (11-arg header), UnitGUID(), GetSpellInfo().
    * Nampower + SuperWoW - Nampower structured combat events +
                            SuperWoW GUID UnitName() and SpellInfo().

  Strictly Lua 5.0 compatible so it loads cleanly with or without
  ClassicAPI. If none of the supported backends are detected, this
  module stays inactive and stock ParserLib behavior is preserved.
****************************************************************]]

local SC = {}
EavesDrop.SuperCombat = SC
local L = AceLibrary("AceLocale-2.2"):new("EavesDrop")

-- Mirrors the private locals in EavesDrop.lua
local OUTGOING   = 1
local INCOMING   = -1
local MISC       = 3
local critchar   = "*"
local deathchar  = "\226\128\160" -- dagger (ASCII-safe)
local crushchar  = "^"
local glancechar = "~"

-- COMBATLOG_OBJECT_* bitmasks
local FLAG_MINE   = 1     -- 0x0001
local FLAG_PLAYER = 1024  -- 0x0400
local FLAG_PET    = 4096  -- 0x1000
local MASK_MINE_PLAYER = FLAG_MINE + FLAG_PLAYER
local MASK_MINE_PET    = FLAG_MINE + FLAG_PET

SC.debugTrace = false
SC.guidNameCache = {}
SC.guidCacheCount = 0

local function traceMsg(msg)
	if SC.debugTrace and DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop SC|r: " .. tostring(msg))
	end
end

-- Lua 5.0 safe bitwise AND
local function band(a, b)
	if not a or not b then return 0 end
	if bit and bit.band then return bit.band(a, b) end
	local result, bitval = 0, 1
	while a > 0 and b > 0 do
		local abit = math.mod(a, 2)
		local bbit = math.mod(b, 2)
		if abit == 1 and bbit == 1 then
			result = result + bitval
		end
		a = (a - abit) / 2
		b = (b - bbit) / 2
		bitval = bitval * 2
	end
	return result
end

-- ---------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------

function SC:DetectMods()
	self.hasSuperWoW   = (SUPERWOW_VERSION ~= nil)
	self.hasClassicAPI = (CLASSIC_API_VERSION ~= nil)
	self.hasUnitXP     = pcall(UnitXP, "nop", "nop")

	if type(GetNampowerVersion) == "function" then
		self.hasNampower = true
	else
		local npCvar = GetCVar and GetCVar("NP_SpellQueueWindowMs")
		self.hasNampower = (npCvar ~= nil and npCvar ~= "")
	end

	-- Distinguish WeirdUtils DPSLog from ClassicAPI's CombatLogGetCurrentEventInfo
	self.hasDPSLog = (type(GetWeirdUtilsVersion) == "function" and GetWeirdUtilsVersion("dpslog") ~= nil)
	self.hasClassicAPICombatLog = (not self.hasDPSLog) and self.hasClassicAPI and (type(CombatLogGetCurrentEventInfo) == "function")

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
		if not name and self.hasSuperWoW then
			name, icon = tryResolve(SpellInfo, spellId)
		end
		if name then
			spellCache[spellId] = { name = name, icon = icon }
		else
			spellCache[spellId] = false
		end
		return name, icon
	end

	if self.hasDPSLog then
		self.backend = "DPSLog"
	elseif self.hasClassicAPICombatLog then
		self.backend = "ClassicAPI"
	elseif self.hasNampower and (self.hasSuperWoW or self.hasClassicAPI) then
		self.backend = "Nampower"
	else
		self.backend = nil
	end

	self.active = (self.backend ~= nil)
	return self.active
end

-- ---------------------------------------------------------------
-- GUID <-> name resolution
-- ---------------------------------------------------------------

function SC:GetUnitGUIDSafe(unit)
	if type(UnitGUID) == "function" then
		local ok, g = pcall(UnitGUID, unit)
		if ok and g then return g end
	end
	if type(GetUnitGUID) == "function" then
		local ok, g = pcall(GetUnitGUID, unit)
		if ok and g then return g end
	end
	if self.hasSuperWoW then
		local exists, g = UnitExists(unit)
		if exists and g then return g end
	end
	return nil
end

function SC:RefreshSelfGUIDs()
	local pGuid = self:GetUnitGUIDSafe("player")
	if pGuid then self.playerGUID = pGuid end
	local petGuid = self:GetUnitGUIDSafe("pet")
	self.petGUID = petGuid
end

function SC:CacheGUIDName(guid, name)
	if not guid or not name or guid == "0x0000000000000000" then return end
	if not self.guidNameCache[guid] then
		if self.guidCacheCount >= 500 then
			self.guidNameCache = {}
			self.guidCacheCount = 0
		end
		self.guidCacheCount = self.guidCacheCount + 1
	end
	self.guidNameCache[guid] = name
end

function SC:NameFromGUID(guid)
	if not guid or guid == "0x0000000000000000" then return nil end
	if guid == self.playerGUID then return ParserLib_SELF end
	if self.hasSuperWoW or self.hasNampower then
		local ok, name = pcall(UnitName, guid)
		if ok and name and name ~= "" and name ~= UNKNOWNOBJECT and name ~= "Unknown" then
			self:CacheGUIDName(guid, name)
			return name
		end
	end
	if self.guidNameCache[guid] then
		return self.guidNameCache[guid]
	end
	if UnitExists("target") and self:GetUnitGUIDSafe("target") == guid then
		local name = UnitName("target")
		if name and name ~= "" and name ~= UNKNOWNOBJECT and name ~= "Unknown" then
			self:CacheGUIDName(guid, name)
			return name
		end
	end
	if UnitExists("mouseover") and self:GetUnitGUIDSafe("mouseover") == guid then
		local name = UnitName("mouseover")
		if name and name ~= "" and name ~= UNKNOWNOBJECT and name ~= "Unknown" then
			self:CacheGUIDName(guid, name)
			return name
		end
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

-- DPSLog and ClassicAPI report school as a bitmask (1, 2, 4, 8, 16, 32, 64)
local MASK_TO_SCHOOL = {
	[1]  = 0, -- Physical
	[2]  = 1, -- Holy
	[4]  = 2, -- Fire
	[8]  = 3, -- Nature
	[16] = 4, -- Frost
	[32] = 5, -- Shadow
	[64] = 6, -- Arcane
}

function SC:SchoolConstFromMask(schoolMask)
	schoolMask = tonumber(schoolMask)
	if not schoolMask then return nil end
	local idx = MASK_TO_SCHOOL[schoolMask]
	if idx then return self:SchoolConst(idx) end
	-- Multi-school bitmask fallback: pick first matching school bit
	if band(schoolMask, 64) ~= 0 then return self:SchoolConst(6) end
	if band(schoolMask, 32) ~= 0 then return self:SchoolConst(5) end
	if band(schoolMask, 16) ~= 0 then return self:SchoolConst(4) end
	if band(schoolMask, 8)  ~= 0 then return self:SchoolConst(3) end
	if band(schoolMask, 4)  ~= 0 then return self:SchoolConst(2) end
	if band(schoolMask, 2)  ~= 0 then return self:SchoolConst(1) end
	if band(schoolMask, 1)  ~= 0 then return self:SchoolConst(0) end
	return nil
end

local function splitMitigation(str)
	local a, b, r = 0, 0, 0
	if str and str ~= "" then
		local _, _, sa, sb, sr = string.find(str, "(%d*),(%d*),(%d*)")
		a, b, r = tonumber(sa) or 0, tonumber(sb) or 0, tonumber(sr) or 0
	end
	return a, b, r
end

-- ---------------------------------------------------------------
-- Shared display helper
-- ---------------------------------------------------------------

function SC:Show(direction, text, texture, color, statInfo, source)
	-- Clear leftover native event arg1 before TrackStat/DisplayEvent so
	-- raw GUIDs/timestamps aren't saved in History tooltips or event tooltips.
	arg1 = nil
	if statInfo then
		if EavesDrop:TrackStat(direction, statInfo) then
			text = "|cffffff00!|r" .. text .. "|cffffff00!|r"
		end
	end
	EavesDrop:DisplayEvent(direction, text, texture, color, source)
end

-- ---------------------------------------------------------------
-- Nampower Damage (SPELL_DAMAGE_EVENT_SELF / _OTHER)
-- ---------------------------------------------------------------

function SC:OnSpellDamage(isSelfEvent, targetGuid, casterGuid, spellId, amount, mitigationStr, hitInfo, spellSchool)
	spellId, amount, hitInfo, spellSchool = tonumber(spellId), tonumber(amount), tonumber(hitInfo), tonumber(spellSchool)
	if not amount then return end
	local isCrit = (hitInfo and band(hitInfo, 2) ~= 0) or false
	local absorb, block, resist = splitMitigation(mitigationStr)
	local name, icon = self:SpellNameIcon(spellId)
	local db = EavesDrop.db.profile

	local isTargetPlayer = (self.playerGUID ~= nil and targetGuid == self.playerGUID)
	local outgoing = isSelfEvent and (not isTargetPlayer)
	local incoming = isTargetPlayer
	local petOut   = (not isSelfEvent) and (self.petGUID ~= nil and casterGuid == self.petGUID) and db["PET"]
	local petIn    = (not isSelfEvent) and (self.petGUID ~= nil and targetGuid == self.petGUID) and db["PET"]

	if not (outgoing or incoming or petOut or petIn) then return end

	local text = tostring(amount)
	if isCrit then text = critchar .. text .. critchar end
	if resist > 0 then text = text .. " (" .. resist .. ")" end
	if block > 0 then text = text .. " (" .. block .. ")" end
	if absorb > 0 then text = text .. " (" .. absorb .. ")" end

	local element = self:SchoolConst(spellSchool)
	local skillName = name or ("Spell #" .. tostring(spellId or 0))
	local statInfo = { type = "hit", skill = skillName, amount = amount, isCrit = isCrit, element = element, icon = icon }

	if outgoing then
		self:Show(OUTGOING, text, icon, EavesDrop:SpellColor(db["TSPELL"], element), statInfo, self:NameFromGUID(targetGuid))
	elseif incoming then
		self:Show(INCOMING, "-" .. text, icon, EavesDrop:SpellColor(db["PSPELL"], element), statInfo, self:NameFromGUID(casterGuid))
	elseif petOut then
		self:Show(OUTGOING, text, icon or "pet", db["PETO"], nil, self:NameFromGUID(targetGuid))
	elseif petIn then
		self:Show(INCOMING, "-" .. text, icon or "pet", db["PETI"], nil, self:NameFromGUID(casterGuid))
	end
end

-- ---------------------------------------------------------------
-- Nampower Melee / auto attack (AUTO_ATTACK_SELF / _OTHER)
-- ---------------------------------------------------------------

local HITINFO_CRITICALHIT = 128
local HITINFO_GLANCING    = 16384
local HITINFO_CRUSHING    = 32768
local HITINFO_MISS        = 16
local VICTIMSTATE_NAMES = {
	[2] = "DODGE", [3] = "PARRY", [4] = "INTERRUPT", [5] = "BLOCK", [6] = "EVADE", [7] = "IMMUNE", [8] = "DEFLECT",
}

function SC:OnAutoAttack(isSelfEvent, attackerGuid, targetGuid, totalDamage, hitInfo, victimState, subDamageCount, blockedAmount, totalAbsorb, totalResist)
	totalDamage, hitInfo, victimState = tonumber(totalDamage) or 0, tonumber(hitInfo) or 0, tonumber(victimState) or 0
	local db = EavesDrop.db.profile

	local outgoing = isSelfEvent or (self.playerGUID ~= nil and attackerGuid == self.playerGUID)
	local incoming = (self.playerGUID ~= nil and targetGuid == self.playerGUID)
	local petOut   = (not outgoing) and (self.petGUID ~= nil and attackerGuid == self.petGUID) and db["PET"]
	local petIn    = (not incoming) and (self.petGUID ~= nil and targetGuid == self.petGUID) and db["PET"]
	if not (outgoing or incoming or petOut or petIn) then return end

	local isMiss = (band(hitInfo, HITINFO_MISS) ~= 0)
	local isFullVictimState = (VICTIMSTATE_NAMES[victimState] ~= nil) and (victimState ~= 5 or totalDamage == 0)
	if isMiss or isFullVictimState then
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
-- Nampower Spell misses (SPELL_MISS_SELF / _OTHER)
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
	local _, icon = self:SpellNameIcon(spellId)
	local db = EavesDrop.db.profile

	local outgoing = isSelfEvent
	local incoming = (not isSelfEvent) and (self.playerGUID ~= nil and targetGuid == self.playerGUID)
	local petOut   = (not isSelfEvent) and (self.petGUID ~= nil and casterGuid == self.petGUID) and db["PET"]
	local petIn    = (not isSelfEvent) and (self.petGUID ~= nil and targetGuid == self.petGUID) and db["PET"]

	if outgoing then
		self:Show(OUTGOING, miss, icon, db["TSPELL"], nil, self:NameFromGUID(targetGuid))
	elseif incoming then
		self:Show(INCOMING, miss, icon, db["PMISS"], nil, self:NameFromGUID(casterGuid))
	elseif petOut then
		self:Show(OUTGOING, miss, icon or "pet", db["PETO"], nil, self:NameFromGUID(targetGuid))
	elseif petIn then
		self:Show(INCOMING, miss, icon or "pet", db["PETI"], nil, self:NameFromGUID(casterGuid))
	end
end

-- ---------------------------------------------------------------
-- Nampower Heals (SPELL_HEAL_BY_SELF / SPELL_HEAL_ON_SELF)
-- ---------------------------------------------------------------

function SC:OnHealBySelf(targetGuid, casterGuid, spellId, amount, critical, periodic)
	amount = tonumber(amount)
	if not amount then return end
	local db = EavesDrop.db.profile
	if amount < db["HFILTER"] then return end
	local isCrit = (tonumber(critical) == 1)
	local name, icon = self:SpellNameIcon(tonumber(spellId))

	if self.playerGUID and targetGuid == self.playerGUID then return end
	local text = tostring(amount)
	if db["OVERHEAL"] == true then
		text = EavesDrop:GetOverheal(self:NameFromGUID(targetGuid) or targetGuid, amount)
	end
	if isCrit then text = critchar .. text .. critchar end
	text = "+" .. text
	if db["HEALERID"] == true then text = (self:NameFromGUID(targetGuid) or "?") .. ": " .. text end

	local statInfo = { type = "heal", skill = name or ("Spell #" .. tostring(spellId or 0)), amount = amount, isCrit = isCrit, icon = icon }
	self:Show(OUTGOING, text, icon, db["THEAL"], statInfo, self:NameFromGUID(targetGuid))
end

function SC:OnHealOnSelf(targetGuid, casterGuid, spellId, amount, critical, periodic)
	if self.playerGUID and targetGuid ~= self.playerGUID then return end
	amount = tonumber(amount)
	if not amount then return end
	local db = EavesDrop.db.profile
	if amount < db["HFILTER"] then return end
	local isCrit = (tonumber(critical) == 1)
	local name, icon = self:SpellNameIcon(tonumber(spellId))
	local text = tostring(amount)
	if isCrit then text = critchar .. text .. critchar end
	local isOther = (self.playerGUID == nil) or (casterGuid ~= self.playerGUID)
	if db["HEALERID"] == true and isOther then
		text = text .. " (" .. (self:NameFromGUID(casterGuid) or "?") .. ")"
	end
	local statInfo = { type = "heal", skill = name or ("Spell #" .. tostring(spellId or 0)), amount = amount, isCrit = isCrit, icon = icon }
	self:Show(INCOMING, "+" .. text, icon, db["PHEAL"], statInfo, isOther and self:NameFromGUID(casterGuid) or nil)
end

-- ---------------------------------------------------------------
-- Nampower Power gains (SPELL_ENERGIZE_ON_SELF)
-- ---------------------------------------------------------------

local POWER_NAME = { [0] = MANA, [1] = RAGE, [2] = FOCUS, [3] = ENERGY, [4] = HAPPINESS }

function SC:OnEnergizeOnSelf(targetGuid, casterGuid, spellId, powerType, amount, periodic)
	if self.playerGUID and targetGuid ~= self.playerGUID then return end
	amount = tonumber(amount)
	if not amount then return end
	local db = EavesDrop.db.profile
	if db["GAIN"] ~= true then return end
	if amount < (db["MFILTER"] or 0) then return end
	local powerName = POWER_NAME[tonumber(powerType)] or ""
	local _, icon = self:SpellNameIcon(tonumber(spellId))
	local isOther = (self.playerGUID == nil) or (casterGuid ~= self.playerGUID)
	self:Show(INCOMING, amount .. " " .. powerName, icon, db["PGAIN"], nil, isOther and self:NameFromGUID(casterGuid) or nil)
end

-- ---------------------------------------------------------------
-- Nampower Deaths (UNIT_DIED)
-- ---------------------------------------------------------------

SC.recentSelfDamage = {}
SC.lastDamagePrune = 0

function SC:NoteSelfDamage(guid)
	if not guid then return end
	local now = GetTime()
	self.recentSelfDamage[guid] = now
	if now - self.lastDamagePrune > 30 then
		self.lastDamagePrune = now
		for k, ts in pairs(self.recentSelfDamage) do
			if (now - ts) > 10 then
				self.recentSelfDamage[k] = nil
			end
		end
	end
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
-- Unified COMBAT_LOG_EVENT_UNFILTERED backend
-- Supports both WeirdUtils DPSLog (9-arg header) and
-- ClassicAPI (11-arg header)
-- ---------------------------------------------------------------

local DL_POWER_NAME = { [-2] = HEALTH, [0] = MANA, [1] = RAGE, [2] = FOCUS, [3] = ENERGY, [4] = "Combo Points" }

function SC:DL_Name(guid, name)
	if self.playerGUID and guid == self.playerGUID then return ParserLib_SELF end
	return name or self:NameFromGUID(guid) or guid
end

function SC:DL_Damage(srcGUID, srcName, dstGUID, dstName, spellId, spellName, school, amount, resisted, blocked, absorbed, isCrit, isGlancing, isCrushing, isMelee)
	amount = tonumber(amount) or 0
	resisted, blocked, absorbed = tonumber(resisted) or 0, tonumber(blocked) or 0, tonumber(absorbed) or 0
	local db = EavesDrop.db.profile

	local isSrcPlayer = (self.playerGUID ~= nil and srcGUID == self.playerGUID)
	local isDstPlayer = (self.playerGUID ~= nil and dstGUID == self.playerGUID)
	local outgoing = isSrcPlayer and (not isDstPlayer)
	local incoming = isDstPlayer
	local petOut   = (not isSrcPlayer) and (self.petGUID ~= nil and srcGUID == self.petGUID) and db["PET"]
	local petIn    = (not isDstPlayer) and (self.petGUID ~= nil and dstGUID == self.petGUID) and db["PET"]
	if not (outgoing or incoming or petOut or petIn) then return end

	local text = tostring(amount)
	if isCrit then text = critchar .. text .. critchar end
	if isCrushing then text = crushchar .. text .. crushchar end
	if isGlancing then text = glancechar .. text .. glancechar end
	if resisted > 0 then text = text .. " (" .. resisted .. ")" end
	if blocked > 0 then text = text .. " (" .. blocked .. ")" end
	if absorbed > 0 then text = text .. " (" .. absorbed .. ")" end

	local element = (not isMelee) and self:SchoolConstFromMask(school)
	local resolvedName, icon = self:SpellNameIcon(spellId)
	local skillName = isMelee and ParserLib_MELEE or (spellName or resolvedName or ("Spell #" .. tostring(spellId or 0)))
	local statInfo = { type = "hit", skill = skillName, amount = amount, isCrit = isCrit, element = element, icon = icon }

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

function SC:DL_Miss(srcGUID, srcName, dstGUID, dstName, spellId, missType, isMelee)
	local db = EavesDrop.db.profile
	local miss = (missType and getglobal(missType)) or missType or MISS

	local isSrcPlayer = (self.playerGUID ~= nil and srcGUID == self.playerGUID)
	local isDstPlayer = (self.playerGUID ~= nil and dstGUID == self.playerGUID)
	local outgoing = isSrcPlayer and (not isDstPlayer)
	local incoming = isDstPlayer
	local petOut   = (not isSrcPlayer) and (self.petGUID ~= nil and srcGUID == self.petGUID) and db["PET"]
	local petIn    = (not isDstPlayer) and (self.petGUID ~= nil and dstGUID == self.petGUID) and db["PET"]
	if not (outgoing or incoming or petOut or petIn) then return end

	local icon
	if not isMelee and spellId then
		local _, resolvedIcon = self:SpellNameIcon(spellId)
		icon = resolvedIcon
	end

	if outgoing then
		self:Show(OUTGOING, miss, icon, isMelee and db["TMELEE"] or db["TSPELL"], nil, self:DL_Name(dstGUID, dstName))
	elseif incoming then
		self:Show(INCOMING, miss, icon, db["PMISS"], nil, self:DL_Name(srcGUID, srcName))
	elseif petOut then
		self:Show(OUTGOING, miss, icon or "pet", db["PETO"], nil, self:DL_Name(dstGUID, dstName))
	elseif petIn then
		self:Show(INCOMING, miss, icon or "pet", db["PETI"], nil, self:DL_Name(srcGUID, srcName))
	end
end

function SC:DL_Heal(srcGUID, srcName, dstGUID, dstName, spellId, spellName, amount, overhealing, isCrit)
	amount = tonumber(amount) or 0
	overhealing = tonumber(overhealing) or 0
	local db = EavesDrop.db.profile
	if amount < db["HFILTER"] then return end
	local resolvedName, icon = self:SpellNameIcon(spellId)
	local statInfo = { type = "heal", skill = spellName or resolvedName or ("Spell #" .. tostring(spellId or 0)), amount = amount, isCrit = isCrit, icon = icon }

	if self.playerGUID and dstGUID == self.playerGUID then
		local text = tostring(amount)
		if isCrit then text = critchar .. text .. critchar end
		if db["HEALERID"] == true and srcGUID ~= self.playerGUID then
			text = text .. " (" .. self:DL_Name(srcGUID, srcName) .. ")"
		end
		self:Show(INCOMING, "+" .. text, icon, db["PHEAL"], statInfo, srcGUID ~= self.playerGUID and self:DL_Name(srcGUID, srcName) or nil)
	elseif self.playerGUID and srcGUID == self.playerGUID then
		local text = tostring(amount)
		if db["OVERHEAL"] == true then
			if overhealing > 0 then
				text = tostring(amount - overhealing) .. " {" .. tostring(overhealing) .. "}"
			else
				text = EavesDrop:GetOverheal(self:DL_Name(dstGUID, dstName), amount)
			end
		end
		if isCrit then text = critchar .. text .. critchar end
		text = "+" .. text
		if db["HEALERID"] == true then text = self:DL_Name(dstGUID, dstName) .. ": " .. text end
		self:Show(OUTGOING, text, icon, db["THEAL"], statInfo, self:DL_Name(dstGUID, dstName))
	end
end

function SC:DL_Energize(dstGUID, spellId, amount, powerType)
	if not self.playerGUID or dstGUID ~= self.playerGUID then return end
	amount = tonumber(amount) or 0
	local db = EavesDrop.db.profile
	if db["GAIN"] ~= true then return end
	if amount < (db["MFILTER"] or 0) then return end
	local powerName = DL_POWER_NAME[tonumber(powerType)] or ""
	local _, icon = self:SpellNameIcon(spellId)
	self:Show(INCOMING, amount .. " " .. powerName, icon, db["PGAIN"])
end

function SC:DL_DrainLeech(srcGUID, srcName, dstGUID, dstName, spellId, spellName, school, amount, powerType, extraAmount, isLeech)
	amount = tonumber(amount) or 0
	extraAmount = tonumber(extraAmount) or 0
	powerType = tonumber(powerType)
	local db = EavesDrop.db.profile
	local resolvedName, icon = self:SpellNameIcon(spellId)
	local element = self:SchoolConstFromMask(school)

	if powerType == -2 then
		if self.playerGUID and srcGUID == self.playerGUID and dstGUID ~= self.playerGUID then
			self:Show(OUTGOING, tostring(amount), icon, EavesDrop:SpellColor(db["TSPELL"], element), nil, self:DL_Name(dstGUID, dstName))
		elseif self.playerGUID and dstGUID == self.playerGUID then
			self:Show(INCOMING, "-" .. tostring(amount), icon, EavesDrop:SpellColor(db["PSPELL"], element), nil, self:DL_Name(srcGUID, srcName))
		end
	end

	if isLeech and self.playerGUID and srcGUID == self.playerGUID and extraAmount > 0 then
		if powerType == -2 then
			if extraAmount >= (db["HFILTER"] or 0) then
				local skillName = spellName or resolvedName or ("Spell #" .. tostring(spellId or 0))
				local statInfo = { type = "heal", skill = skillName, amount = extraAmount, isCrit = false, icon = icon }
				self:Show(INCOMING, "+" .. tostring(extraAmount), icon, db["PHEAL"], statInfo)
			end
		elseif db["GAIN"] == true and extraAmount >= (db["MFILTER"] or 0) then
			local powerName = DL_POWER_NAME[powerType] or ""
			self:Show(INCOMING, tostring(extraAmount) .. " " .. powerName, icon, db["PGAIN"])
		end
	end
end

function SC:DL_Aura(dstGUID, spellId, spellName, auraType, applied)
	if not self.playerGUID or dstGUID ~= self.playerGUID then return end
	local resolvedName, icon = self:SpellNameIcon(spellId)
	local name = spellName or resolvedName
	if not name then return end
	local db = EavesDrop.db.profile
	if applied then
		if auraType == "BUFF" then
			if db["BUFF"] ~= true then return end
			self:Show(INCOMING, name, icon, db["PBUFF"])
		else
			if db["DEBUFF"] ~= true then return end
			self:Show(INCOMING, name, icon, db["PDEBUFF"])
		end
	else
		if db["FADE"] ~= true then return end
		self:Show(INCOMING, L["Fades"] .. ": " .. name, icon, db["PBUFF"])
	end
end

function SC:DL_Died(srcGUID, dstGUID, dstName)
	if not self.playerGUID or srcGUID ~= self.playerGUID then return end
	local name = dstName or self:NameFromGUID(dstGUID) or UNKNOWN
	local db = EavesDrop.db.profile
	self:Show(MISC, "\226\128\160" .. name .. "\226\128\160", nil, db["DEATH"])
end

function SC:OnCombatLogEvent()
	-- Zero-table unpack directly into locals
	local a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, a19, a20, a21 = CombatLogGetCurrentEventInfo()

	local sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags
	local p1, p2, p3, p4, p5, p6, p7, p8, p9, p10

	if type(a1) == "number" then
		-- ClassicAPI 11-arg header: timestamp, subevent, hideCaster, srcGUID, srcName, srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags
		sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags = a2, a4, a5, a6, a8, a9, a10
		p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 = a12, a13, a14, a15, a16, a17, a18, a19, a20, a21
	else
		-- WeirdUtils DPSLog 9-arg header: subevent, srcGUID, srcName, srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags
		sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags = a1, a2, a3, a4, a6, a7, a8
		p1, p2, p3, p4, p5, p6, p7, p8, p9, p10 = a10, a11, a12, a13, a14, a15, a16, a17, a18, a19
	end

	if not sub then return end

	-- Fallback GUID learning when standalone DPSLog is used without SuperWoW/ClassicAPI/Nampower
	if not self.playerGUID then
		if srcFlags and band(srcFlags, MASK_MINE_PLAYER) == MASK_MINE_PLAYER then
			self.playerGUID = srcGUID
			traceMsg("Learned playerGUID from srcFlags: " .. tostring(srcGUID))
		elseif dstFlags and band(dstFlags, MASK_MINE_PLAYER) == MASK_MINE_PLAYER then
			self.playerGUID = dstGUID
			traceMsg("Learned playerGUID from dstFlags: " .. tostring(dstGUID))
		end
	end
	if not self.petGUID then
		if srcFlags and band(srcFlags, MASK_MINE_PET) == MASK_MINE_PET then
			self.petGUID = srcGUID
		elseif dstFlags and band(dstFlags, MASK_MINE_PET) == MASK_MINE_PET then
			self.petGUID = dstGUID
		end
	end

	if self.debugTrace then
		if srcGUID == self.playerGUID or dstGUID == self.playerGUID then
			traceMsg(tostring(sub) .. " src=" .. tostring(srcName) .. " dst=" .. tostring(dstName) .. " p1=" .. tostring(p1) .. " p4=" .. tostring(p4))
		end
	end

	if sub == "SWING_DAMAGE" then
		-- p1=amount, p2=overkill, p3=school, p4=resisted, p5=blocked, p6=absorbed, p7=critical, p8=glancing, p9=crushing
		self:DL_Damage(srcGUID, srcName, dstGUID, dstName, nil, nil, p3, p1, p4, p5, p6, (p7 and true or false), (p8 and true or false), (p9 and true or false), true)
	elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" or sub == "DAMAGE_SHIELD" or sub == "DAMAGE_SPLIT" then
		-- p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=overkill, p6=school, p7=resisted, p8=blocked, p9=absorbed, p10=critical
		self:DL_Damage(srcGUID, srcName, dstGUID, dstName, p1, p2, p6 or p3, p4, p7, p8, p9, (p10 and true or false), false, false, false)
	elseif sub == "SWING_MISSED" then
		self:DL_Miss(srcGUID, srcName, dstGUID, dstName, nil, p1, true)
	elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED" or sub == "SPELL_PERIODIC_MISSED" or sub == "DAMAGE_SHIELD_MISSED" then
		self:DL_Miss(srcGUID, srcName, dstGUID, dstName, p1, p4, false)
	elseif sub == "SPELL_HEAL" or sub == "SPELL_PERIODIC_HEAL" then
		-- p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=overhealing, p6=absorbed, p7=critical
		self:DL_Heal(srcGUID, srcName, dstGUID, dstName, p1, p2, p4, p5, (p7 and true or false))
	elseif sub == "SPELL_ENERGIZE" or sub == "SPELL_PERIODIC_ENERGIZE" then
		-- p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=powerType
		self:DL_Energize(dstGUID, p1, p4, p5)
	elseif sub == "SPELL_DRAIN" or sub == "SPELL_PERIODIC_DRAIN" then
		-- p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=powerType, p6=extraAmount
		self:DL_DrainLeech(srcGUID, srcName, dstGUID, dstName, p1, p2, p3, p4, p5, p6, false)
	elseif sub == "SPELL_LEECH" or sub == "SPELL_PERIODIC_LEECH" then
		-- p1=spellId, p2=spellName, p3=spellSchool, p4=amount, p5=powerType, p6=extraAmount
		self:DL_DrainLeech(srcGUID, srcName, dstGUID, dstName, p1, p2, p3, p4, p5, p6, true)
	elseif sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_APPLIED_DOSE" then
		self:DL_Aura(dstGUID, p1, p2, p4, true)
	elseif sub == "SPELL_AURA_REMOVED" then
		self:DL_Aura(dstGUID, p1, p2, p4, false)
	elseif sub == "ENVIRONMENTAL_DAMAGE" then
		-- p1=envType, p2=amount, p3=overkill, p4=school, p5=resisted, p6=blocked, p7=absorbed
		if self.playerGUID and dstGUID == self.playerGUID then
			local amount = tonumber(p2) or 0
			local resisted = tonumber(p5) or 0
			local absorbed = tonumber(p7) or 0
			local text = tostring(amount)
			if resisted > 0 then text = text .. " (" .. resisted .. ")" end
			if absorbed > 0 then text = text .. " (" .. absorbed .. ")" end
			self:Show(INCOMING, "-" .. text, nil, EavesDrop.db.profile["PSPELL"], nil, p1)
		end
	elseif sub == "PARTY_KILL" then
		self:DL_Died(srcGUID, dstGUID, dstName)
	end
end

-- ---------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------

local REPLACED_EVENTS_BASE = {
	"CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS", "CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES",
	"CHAT_MSG_COMBAT_HOSTILEPLAYER_HITS", "CHAT_MSG_COMBAT_HOSTILEPLAYER_MISSES",
	"CHAT_MSG_COMBAT_SELF_HITS", "CHAT_MSG_COMBAT_SELF_MISSES",
	"CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE", "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_DAMAGESHIELDS_ON_OTHERS", "CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF",
	"CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE",
	"CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE", "CHAT_MSG_SPELL_SELF_DAMAGE",
	"CHAT_MSG_COMBAT_HOSTILE_DEATH",
	"CHAT_MSG_COMBAT_PET_HITS", "CHAT_MSG_COMBAT_PET_MISSES", "CHAT_MSG_SPELL_PET_DAMAGE",
}
local REPLACED_EVENTS_HEAL_GAIN = {
	"CHAT_MSG_SPELL_SELF_BUFF", "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF", "CHAT_MSG_SPELL_PARTY_BUFF",
	"CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS", "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS",
	"CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
}
local REPLACED_EVENTS_AURA = {
	"CHAT_MSG_SPELL_CREATURE_VS_SELF_BUFF", "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
	"CHAT_MSG_SPELL_AURA_GONE_SELF", "CHAT_MSG_SPELL_AURA_GONE_OTHER", "CHAT_MSG_SPELL_BREAK_AURA",
}

SC.ownedParserEvents = {}

function SC:OwnsParserEvent(ev)
	return self.backend ~= nil and self.ownedParserEvents[ev] == true
end

local function UnregisterChatEvents(list)
	local parser = ParserLib and ParserLib:GetInstance("1.1")
	for _, ev in ipairs(list) do
		SC.ownedParserEvents[ev] = true
		if parser then
			parser:UnregisterEvent("EavesDrop", ev)
		end
	end
end

function SC:RegisterFrameEvents()
	local f = self.frame
	if not f then return end
	f:UnregisterAllEvents()
	if self.backend == "DPSLog" or self.backend == "ClassicAPI" then
		f:RegisterEvent("UNIT_PET")
		if self.hasNampower then
			f:RegisterEvent("UNIT_PET_GUID")
		end
		f:RegisterEvent("PLAYER_ENTERING_WORLD")
		f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
	elseif self.backend == "Nampower" then
		f:RegisterEvent("UNIT_PET")
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
	end
end

function SC:Disable()
	self.disabled = true
	if self.frame then
		self.frame:UnregisterAllEvents()
	end
	if CombatHub and type(CombatHub.Unsubscribe) == "function" then
		CombatHub:Unsubscribe("EavesDrop_CLEU")
		CombatHub:Unsubscribe("EavesDrop_Self")
		CombatHub:Unsubscribe("EavesDrop_Other")
	end
end

function SC:Enable()
	if not self.backend then return end
	self.disabled = false
	UnregisterChatEvents(REPLACED_EVENTS_BASE)
	UnregisterChatEvents(REPLACED_EVENTS_HEAL_GAIN)
	if self.backend == "DPSLog" or self.backend == "ClassicAPI" then
		UnregisterChatEvents(REPLACED_EVENTS_AURA)
	end
	if self.frame then
		if self.AttachCombatHub then
			self:AttachCombatHub()
		else
			self:RegisterFrameEvents()
		end
	end
end

function SC:InitCombatLogBackend(label)
	UnregisterChatEvents(REPLACED_EVENTS_BASE)
	UnregisterChatEvents(REPLACED_EVENTS_HEAL_GAIN)
	UnregisterChatEvents(REPLACED_EVENTS_AURA)

	local f = CreateFrame("Frame")
	self.frame = f
	self:RegisterFrameEvents()
	f:SetScript("OnEvent", function()
		if event == "UNIT_PET" then
			if arg1 == "player" then SC:RefreshSelfGUIDs() end
		elseif event == "UNIT_PET_GUID" or event == "PLAYER_ENTERING_WORLD" then
			SC:RefreshSelfGUIDs()
		elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
			SC:OnCombatLogEvent()
		end
	end)

	DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: SuperCombat active - " .. label)
end

function SC:InitNampower()
	UnregisterChatEvents(REPLACED_EVENTS_BASE)
	UnregisterChatEvents(REPLACED_EVENTS_HEAL_GAIN)

	if type(SetCVar) == "function" then
		for _, cvar in ipairs({ "NP_EnableAutoAttackEvents", "NP_EnableSpellHealEvents", "NP_EnableSpellEnergizeEvents" }) do
			if GetCVar(cvar) == "0" then SetCVar(cvar, "1") end
		end
	end

	local f = CreateFrame("Frame")
	self.frame = f
	self:RegisterFrameEvents()

	f:SetScript("OnEvent", function()
		if event == "UNIT_PET" then
			if arg1 == "player" then SC:RefreshSelfGUIDs() end
		elseif event == "UNIT_PET_GUID" or event == "PLAYER_ENTERING_WORLD" then
			SC:RefreshSelfGUIDs()
		elseif event == "SPELL_DAMAGE_EVENT_SELF" then
			traceMsg("SPELL_DAMAGE_EVENT_SELF target=" .. tostring(arg1) .. " spell=" .. tostring(arg3) .. " amt=" .. tostring(arg4))
			SC:OnSpellDamage(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
			SC:NoteSelfDamage(arg1)
		elseif event == "SPELL_DAMAGE_EVENT_OTHER" then
			SC:OnSpellDamage(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7)
			if SC.petGUID and arg2 == SC.petGUID then SC:NoteSelfDamage(arg1) end
		elseif event == "SPELL_MISS_SELF" then
			SC:OnSpellMiss(true, arg1, arg2, arg3, arg4)
		elseif event == "SPELL_MISS_OTHER" then
			SC:OnSpellMiss(false, arg1, arg2, arg3, arg4)
		elseif event == "AUTO_ATTACK_SELF" then
			traceMsg("AUTO_ATTACK_SELF target=" .. tostring(arg2) .. " dmg=" .. tostring(arg3))
			SC:OnAutoAttack(true, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
			SC:NoteSelfDamage(arg2)
		elseif event == "AUTO_ATTACK_OTHER" then
			SC:OnAutoAttack(false, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
			if SC.petGUID and arg1 == SC.petGUID then SC:NoteSelfDamage(arg2) end
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

	local msg = "|cff7fff7fEavesDrop|r: SuperCombat active - Nampower"
	if self.hasClassicAPI then msg = msg .. " + ClassicAPI" end
	if self.hasSuperWoW then msg = msg .. " + SuperWoW" end
	DEFAULT_CHAT_FRAME:AddMessage(msg)
end

function SC:PrintStatus()
	DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop SuperCombat Status|r:")
	DEFAULT_CHAT_FRAME:AddMessage("  Backend: " .. tostring(self.backend or "Stock ParserLib"))
	DEFAULT_CHAT_FRAME:AddMessage("  Mods: DPSLog=" .. tostring(self.hasDPSLog) .. ", ClassicAPI=" .. tostring(self.hasClassicAPI) .. ", Nampower=" .. tostring(self.hasNampower) .. ", SuperWoW=" .. tostring(self.hasSuperWoW))
	DEFAULT_CHAT_FRAME:AddMessage("  playerGUID=" .. tostring(self.playerGUID) .. ", petGUID=" .. tostring(self.petGUID))
	DEFAULT_CHAT_FRAME:AddMessage("  debugTrace=" .. tostring(self.debugTrace))
end

function SC:Init()
	if not self:DetectMods() then
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: SuperCombat inactive (using stock chat-log parsing).")
		return
	end

	self:RefreshSelfGUIDs()

	if self.backend == "DPSLog" then
		self:InitCombatLogBackend("DPSLog")
	elseif self.backend == "ClassicAPI" then
		self:InitCombatLogBackend("ClassicAPI CombatLog")
	else
		self:InitNampower()
	end
end

SLASH_EAVESDROPSC1 = "/edsc"
SlashCmdList["EAVESDROPSC"] = function(msg)
	local cmd = string.lower(msg or "")
	if cmd == "trace" then
		SC.debugTrace = not SC.debugTrace
		DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7fEavesDrop|r: SuperCombat trace " .. (SC.debugTrace and "ON" or "OFF"))
	elseif cmd == "test" then
		local db = EavesDrop.db.profile
		SC:Show(OUTGOING, "*1234*", "Interface\\Icons\\Spell_Fire_FireBall02", db["TSPELL"], nil, "Test Target")
		SC:Show(INCOMING, "-567", nil, db["PHIT"], nil, "Test Attacker")
		SC:Show(MISC, "\226\128\160Test Kill\226\128\160", nil, db["DEATH"])
	else
		SC:PrintStatus()
	end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
	SC:Init()
end)
