# EavesDrop (SuperCombat fork)

A fork of [laytya/EavesDrop](https://github.com/laytya/EavesDrop) — a 1.12
combat log that shows hits, spells, misses, heals, buffs/debuffs, power
gains, and kills as fading icon+text lines, split into incoming/outgoing/misc
columns.

This fork adds one optional file, `EavesDropSuperCombat.lua`, which — only if
you also run certain native client mods — replaces the addon's chat-log
parsing with a GUID/spellID-based data feed for more accurate output. Nothing
else about the addon changes, and if you don't have those mods installed,
this fork behaves identically to stock EavesDrop.

## DLLs this addon can use (all optional)

These are native client-side mods, not addons — they get loaded by your
client (typically via `dlls.txt` and a loader like Nampower's own loader or
`VanillaFixes`), not by putting them in `Interface/AddOns`. Get them from
their own projects; this repo doesn't bundle any of them.

| DLL | Project | What it's used for here |
|---|---|---|
| `nampower.dll` | [nampower](https://github.com/brues-code/nampower) | Fires structured combat events (real GUIDs + spell IDs) instead of chat text — this is the core of what SuperCombat consumes. |
| `SuperWoWhook.dll` | [SuperWoW](https://github.com/balakethelock/SuperWoW) | Lets `UnitName()`/etc. accept a raw GUID directly, and resolves spell IDs to name/icon via `SpellInfo()`. |
| `ClassicAPI.dll` | [ClassicAPI](https://github.com/brues-code/ClassicAPI) | Backports a modern-style `GetSpellInfo(spellId)`; preferred over SuperWoW's `SpellInfo()` when both are present. |
| `UnitXP_SP3.dll` | [UnitXP_SP3](https://codeberg.org/konaka/UnitXP_SP3) | Detected and reported only — mainly the launcher/host for the DLLs above; has no combat-log API of its own that this addon uses. |
| `VanillaHelpers.dll` | [VanillaHelpers](https://github.com/isfir/VanillaHelpers) | Detected and reported only — texture/minimap/model helpers, no combat or spell API, so nothing for a combat-log addon to hook. |

**Minimum for the upgrade to activate:** `nampower.dll` + either
`SuperWoWhook.dll` or `ClassicAPI.dll`. Without that combination,
`EavesDropSuperCombat.lua` prints one line at login saying it's inactive and
changes nothing else.

## What's different from stock EavesDrop

| | Stock | This fork (mods active) |
|---|---|---|
| Data source | Re-parses localized chat strings (`CHAT_MSG_SPELL_SELF_DAMAGE`, etc.) | Reads nampower's structured GUID/spellID events directly — no text parsing |
| Identifying who's involved | Guesses by matching the name in the string against your party/raid roster | Resolves the real GUID via SuperWoW — unambiguous, not limited to your group |
| Spell icon | Looks up the *localized spell name string* in Babble-Spell's table — misses if that exact string isn't in its data | Looks up the icon straight from the spell ID via `GetSpellInfo`/`SpellInfo` |
| Non-English clients | README itself warns of "errors or strange behavior" — a direct symptom of string-matching against localized text | Not exposed to that problem, since it never parses localized text |
| "You have slain X" | Read directly from the death chat line, which names both killer and victim | `UNIT_DIED` only gives a GUID, no killer — approximated by remembering who you (or your pet) last hit that GUID in the previous 5 seconds |
| Buffs, debuffs, XP, reputation, honor, skill-ups | Chat-log parsing | **Unchanged** — still chat-log parsing; nampower has no reliable always-on equivalent for these, so this fork doesn't touch them |

The addon's frame, options menu, colors, filters, profiles, and
history/"new high" tracking are all unchanged either way.

## Commands

| Command | Effect |
|---|---|
| `/EavesDrop` | Opens the options menu (same as right-clicking the tab) |
| Left-click the tab | Drag the frame |
| Right-click the tab | Open options |
| Shift-right-click the tab | Open the Waterfall options panel |
| Mouse wheel over the frame | Scroll up/down through recent events |
| Shift + mouse wheel | Jump to top/bottom of the scroll history |

There is no separate slash command for SuperCombat — it's fully automatic.
At login it prints one status line to your chat frame naming which of the
mods above it detected, e.g.:

```
EavesDrop: SuperCombat active - nampower + ClassicAPI + SuperWoW
```

or, without the required mods:

```
EavesDrop: SuperCombat inactive (needs nampower + SuperWoW or ClassicAPI). Using stock chat-log parsing.
```

## Install

1. Unzip so you end up with `Interface/AddOns/EavesDrop/...` (containing
   `EavesDrop.toc`).
2. If you want the upgraded pipeline, install nampower + SuperWoW (or
   ClassicAPI) per their own install instructions (native DLLs, not addon
   folders) — see the table above for links.
3. Launch WoW, log in. Right-click the EavesDrop tab for options.

## Known limitation

The kill-credit heuristic (`SC.recentSelfDamage` in
`EavesDropSuperCombat.lua`) tracks GUIDs you've recently damaged so it can
attribute a later `UNIT_DIED` event to you. An entry is only cleared when a
matching death fires, so damaging something that never dies while tracked
(it resets, you leave the area, etc.) leaves a small stale entry for the
rest of the session — not dangerous, but not swept up either.
