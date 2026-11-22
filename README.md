# EavesDrop (SuperCombat Fork for WoW 1.12 / Turtle WoW)

A fork of [laytya/EavesDrop](https://github.com/laytya/EavesDrop) — a lightweight combat log that displays hits, spells, misses, heals, buffs/debuffs, power gains, and kills as fading icon+text lines split into incoming, outgoing, and misc columns.

## Client Mods Used

| Mod | Purpose in this addon | Required? |
|---|---|---|
| WeirdUtils (`dpslog`) | **Preferred backend:** WotLK-style `COMBAT_LOG_EVENT_UNFILTERED` (9-arg header) + `GetSpellInfo(spellId)` for spell icons and unit names | Optional |
| ClassicAPI | **Secondary backend / support:** Modern `COMBAT_LOG_EVENT_UNFILTERED` (11-arg header), `UnitGUID()`, and `GetSpellInfo(spellId)` | Optional |
| Nampower | **Fallback backend:** Structured GUID/spellID combat events (`SPELL_DAMAGE_EVENT_*`, `AUTO_ATTACK_*`, `SPELL_MISS_*`, `SPELL_HEAL_*`, `SPELL_ENERGIZE_*`, `UNIT_DIED`) and `GetUnitGUID()` | Optional |
| SuperWoW | **Fallback backend support:** `UnitName(guid)`, `UnitExists()` GUID return, and `SpellInfo(spellId)` | Optional |
| **CombatHub** | Optional shared combat event coordinator (`EavesDrop_CombatHub.lua`) that filters out non-self/non-pet `*_OTHER` events at the hub | Optional |

*(The addon works without any client mods by falling back to stock ParserLib chat-log parsing.)*

## Features

- **Scrolling Incoming / Outgoing / Misc Combat Feed:** Displays melee, spell, periodic, environmental damage, misses, heals, overhealing, power gains, buffs/debuffs/fades, and kills.
- **Hover Tooltips with `Source:` Line:** Displays the attacker, target, healer, or environmental hazard source on hover when "Display details in tooltip" is enabled.
- **History Frame:** Tracks highest normal and critical hits/heals per skill and flags new highs with `!`.
- **Configurable Layout & Colors:** Customizable line count, height, width, font size, fade time, school colors, and side-flipping.

## What Was Added / Improved

- **Fixed outgoing damage not displaying on ClassicAPI / WeirdUtils / Nampower:**
  - Distinguished `WeirdUtils` (`dpslog`) from `ClassicAPI`'s `CombatLogGetCurrentEventInfo()` (9-arg header vs 11-arg header) so `COMBAT_LOG_EVENT_UNFILTERED` no longer drops all combat events when ClassicAPI is loaded without DPSLog.
  - Fixed `SC:RefreshSelfGUIDs()` to resolve `playerGUID` and `petGUID` via `UnitGUID()` (ClassicAPI), `GetUnitGUID()` (Nampower), `UnitExists()` (SuperWoW), or `COMBATLOG_OBJECT_AFFILIATION_MINE` flags (standalone DPSLog).
  - Fixed Lua 5.0 incompatibilities in `EavesDropSuperCombat.lua` (`math.mod` instead of `%`, direct local indexing instead of 3-arg `unpack(t, i, j)`).
  - Fixed `SchoolConstFromMask()` for DPSLog/ClassicAPI bitmask spell schools (`1, 2, 4, 8, 16, 32, 64`) vs Nampower 0-based school indices (`0..6`).
  - Guarded `TrackStat` against `nil` skill keys so unknown spell IDs never abort event display.
- **Improved performance & reliability:**
  - Zero-table unpack in `OnCombatLogEvent()` to avoid per-event garbage collection in raids.
  - Added spell icons on spell misses, glancing/crushing indicators on `SWING_DAMAGE`, self-inflicted damage routing to incoming, and periodic pruning of `recentSelfDamage`.
  - Added `/edsc` (`status`, `trace`, `test`) diagnostic slash commands.
- **Fixed stock EavesDrop bugs:**
  - Fixed swapped `PETI` / `PETO` color getters/setters in `options.lua`.
  - Fixed inverted `FADEFRAME` toggle in `options.lua`.
  - Fixed `GetDefaultConfig()` key names (`GAIN`, `BUFF`, `DEBUFF` instead of `GAINS`, `BUFFS`, `DEBUFFS`).
  - Fixed accidental global `outtexture` in `EavesDrop.lua` (`UpdateEvents` and `ResetEvents`) and self-target recognition in `GetTargetUnit()`.

## Usage

- `/EavesDrop` — Open options menu (or right-click the EavesDrop tab; Shift+right-click for Waterfall panel).
- `/edsc` — Print active SuperCombat backend, detected mods, and `playerGUID`/`petGUID`.
- `/edsc trace` — Toggle live SuperCombat event debug tracing in chat.
- `/edsc test` — Display sample outgoing, incoming, and kill test lines.
- Mouse wheel over the frame to scroll history (Shift+wheel to jump to top/bottom); Shift+click a line to copy its tooltip to chat.

## Credits & License

- Original addon: [laytya/EavesDrop](https://github.com/laytya/EavesDrop) (original idea by Bant, Grayhoof).
- SuperCombat & 1.12/Turtle WoW fixes: Fork contributors.
- License: Same as original addon.
