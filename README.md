# EavesDrop (SuperCombat fork)

A fork of [laytya/EavesDrop](https://github.com/laytya/EavesDrop) — a 1.12
combat log that shows hits, spells, misses, heals, buffs/debuffs, power
gains, and kills as fading icon+text lines, split into incoming/outgoing/misc
columns.

This fork adds one optional file, `EavesDropSuperCombat.lua`, which — only if
you also run certain native client mods — replaces the addon's chat-log
parsing with a GUID/spellID-based data feed for more accurate output, and
always adds a "who did this come from" line to the hover tooltip on every
line. If you don't have any of the mods below installed, the data-feed
upgrade doesn't activate but the hover-tooltip source line still works, since
that part reads the same data the stock chat-log parser already extracts.

## DLLs this addon can use (all optional)

These are native client-side mods, not addons — they get loaded by your
client (typically via `dlls.txt` and a loader like Nampower's own loader or
`VanillaFixes`), not by putting them in `Interface/AddOns`. Get them from
their own projects; this repo doesn't bundle any of them.

| DLL | Project | What it's used for here |
|---|---|---|
| `dpslog.dll` | [WeirdUtils / DPSLog](https://codeberg.org/MarcelineVQ/WeirdUtils/wiki) | **Preferred backend when present.** Backports WotLK's `COMBAT_LOG_EVENT_UNFILTERED` + `CombatLogGetCurrentEventInfo()` — hands over unit *names* directly (no GUID resolution needed), has its own spell-info lookup for icons, and fires buff/debuff/aura events too. Makes the four DLLs below unnecessary, though they still work as a fallback if this one isn't installed. |
| `nampower.dll` | [nampower](https://github.com/brues-code/nampower) | Fallback backend. Fires structured combat events (real GUIDs + spell IDs) instead of chat text. Used only if DPSLog isn't detected. |
| `SuperWoWhook.dll` | [SuperWoW](https://github.com/balakethelock/SuperWoW) | Fallback backend support. Lets `UnitName()`/etc. accept a raw GUID directly, and resolves spell IDs to name/icon via `SpellInfo()`. Used only if DPSLog isn't detected. |
| `ClassicAPI.dll` | [ClassicAPI](https://github.com/brues-code/ClassicAPI) | Fallback backend support. Backports a modern-style `GetSpellInfo(spellId)`; preferred over SuperWoW's `SpellInfo()` when both are present. Used only if DPSLog isn't detected. |
| `UnitXP_SP3.dll` | [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3) | Detected and reported only — mainly the launcher/host for the DLLs above; has no combat-log API of its own that this addon uses. |
| `VanillaHelpers.dll` | [VanillaHelpers](https://github.com/isfir/VanillaHelpers) | Detected and reported only — texture/minimap/model helpers, no combat or spell API, so nothing for a combat-log addon to hook. |

**To get the upgraded data feed, install *either*:**
- `dpslog.dll` on its own (simplest — it's fully self-contained), **or**
- `nampower.dll` + either `SuperWoWhook.dll` or `ClassicAPI.dll`

Without one of those two combinations, `EavesDropSuperCombat.lua` prints one
line at login saying the data-feed upgrade is inactive; the hover-tooltip
source line still works regardless, off the stock chat-log data.

## What's different from stock EavesDrop

| | Stock | This fork, DPSLog active | This fork, nampower path active (no DPSLog) |
|---|---|---|---|
| Data source | Re-parses localized chat strings | Reads DPSLog's structured GUID/name events directly | Reads nampower's structured GUID/spellID events directly |
| Identifying who's involved | Guesses by matching the name in the string against your party/raid roster | Given directly by DPSLog (`srcName`/`dstName`) — not limited to your group | Resolves the real GUID via SuperWoW — not limited to your group |
| Spell icon | Looks up the *localized spell name string* in Babble-Spell's table | Looks up the icon straight from the spell ID (DPSLog's own resolver) | Looks up the icon straight from the spell ID via ClassicAPI/SuperWoW |
| Non-English clients | Warns of "errors or strange behavior" — string-matching against localized text | Not exposed to that problem | Not exposed to that problem |
| "You have slain X" | Read from the death chat line | `PARTY_KILL` gives a real killer GUID — exact, no guessing | `UNIT_DIED` has no killer field — approximated by remembering who you (or your pet) last hit in the previous 5 seconds |
| Buffs, debuffs, fades | Chat-log parsing | **Also upgraded** — DPSLog's aura events replace this too | Unchanged — nampower has no equivalent, so this stays on stock chat-log parsing |
| XP, reputation, honor, skill-ups | Chat-log parsing | Unchanged (neither backend covers these) | Unchanged |
| Hover tooltip | Whatever the raw chat-log sentence happened to say (only if the "display details in tooltip" option is on) | Adds a dedicated `Source: <name>` line to every hit/miss/heal/environmental-damage line, regardless of backend | Same |

The addon's frame, options menu, colors, filters, profiles, and
history/"new high" tracking are all unchanged in every case above.

### Hovering a line now shows who it came from

Every hit, miss, heal, and environmental-damage line now adds a `Source:`
line to its hover tooltip — the attacker on incoming lines, the target on
outgoing lines, the healer/patient on heals, the hazard type ("Fire",
"Drowning", ...) on environmental damage. This works with the stock
chat-log pipeline too, not just with the mods above, since the underlying
data (`info.source`/`info.victim`) was already being parsed out — it just
wasn't being surfaced before.

**This requires the "Display details in tooltip" option to be turned on**
(right-click the tab → Misc.) — that's the addon's existing master switch
for whether hovering shows anything at all; this fork doesn't override it.

## Commands

| Command | Effect |
|---|---|
| `/EavesDrop` | Opens the options menu (same as right-clicking the tab) |
| Left-click the tab | Drag the frame |
| Right-click the tab | Open options |
| Shift-right-click the tab | Open the Waterfall options panel |
| Mouse wheel over the frame | Scroll up/down through recent events |
| Shift + mouse wheel | Jump to top/bottom of the scroll history |
| Shift + left/right-click a line | Copy that line's tooltip text to chat |

There is no separate slash command for SuperCombat — it's fully automatic.
At login it prints one status line to your chat frame naming which backend
and mods it detected, e.g.:

```
EavesDrop: SuperCombat active - DPSLog + UnitXP_SP3
```
```
EavesDrop: SuperCombat active - nampower + ClassicAPI + SuperWoW
EavesDrop: buffs/debuffs/fades still use stock chat-log parsing (no DPSLog detected).
```

or, with none of the mods:

```
EavesDrop: SuperCombat inactive (needs DPSLog, or nampower + SuperWoW/ClassicAPI). Using stock chat-log parsing.
```

## Install

1. Unzip so you end up with `Interface/AddOns/EavesDrop/...` (containing
   `EavesDrop.toc`).
2. If you want the upgraded data feed, install `dpslog.dll` **or**
   `nampower.dll` + (`SuperWoWhook.dll` or `ClassicAPI.dll`) per their own
   install instructions (native DLLs, not addon folders) — see the table
   above for links. Not required for the hover-tooltip source line, which
   works either way.
3. Launch WoW, log in. Right-click the EavesDrop tab for options.

## Known limitations

- **nampower path only:** the kill-credit heuristic
  (`SC.recentSelfDamage` in `EavesDropSuperCombat.lua`) tracks GUIDs you've
  recently damaged so it can attribute a later `UNIT_DIED` event to you. An
  entry is only cleared when a matching death fires, so damaging something
  that never dies while tracked (it resets, you leave the area, etc.) leaves
  a small stale entry for the rest of the session — not dangerous, but not
  swept up either. The DPSLog path doesn't have this issue, since
  `PARTY_KILL` already names the killer.
- **DPSLog and nampower are not run together.** If both are installed,
  DPSLog is used exclusively and nampower's events are simply never
  registered — running both pipelines at once would double-process every
  event.
- Neither backend threads a source name through buff/debuff/gain lines the
  way it does for hits/misses/heals (no clean "who cast this" field is
  available for those event types), so their tooltip still falls back to
  whatever the stock chat-log line said, same as before this fork.
