# Gather sharing (WoWBoxer 1.3.0, workstream E)

Plan and limits: `02_Spec/Gather-sharing-plan.md` in the project folder. This page is the code-side summary.

## What is allowed, and what WoWBoxer does
Blizzard blocked remote minimap reads in Nov 2026 ("Minimap is off limits", Stanzilla/WoWUIBugs#894). WoWBoxer never
sweeps, probes or moves the minimap. Sources:

| Source | How | Accuracy | Code |
|---|---|---|---|
| near | soft interact target (`softinteract`, GameObject GUID + name), every 0.5 s and on `PLAYER_SOFT_INTERACT_CHANGED` | ±5 yd in reach, else ±15 | `Gather.checkNear` |
| gathered | `UNIT_SPELLCAST_SENT` + `SUCCEEDED` of Herb Gathering / Mining (`D.gather` per game, else the spell's name) | ±3 | `Gather.onCast*` |
| hover | `C_TooltipInfo.GetMinimapMouseover()` while the real cursor is on the minimap | ±15 | `Gather.checkHover` |
| spawn | QuestieDB `Object.spawns` + its zone table, read as data (no loadstring) | – | `GatherSpawns.lua` |
| known | every node seen/gathered/received, account-wide, offered on request | per report | `GatherSpots.lua` |

## Protocol (prefix `WBXG`, data only, squad members in the party only)
```
N|k|mapID|x|y|src|acc|age|name   node seen      (k H/O, x/y 0..10000, src n/g/h/k)
G|k|mapID|x|y|name               gathered: gone for everyone
Q|mapID|x|y                      ask for known spots near me (join / zone, at most once a minute)
S|mapID|k,x,y,acc,name;…         answer, several messages ≤ 255
```
Sent through `Compat.sendAddon` (outbox for `AddOnMessageLockdown`). Same-node dedupe within 8 yd (or the same GUID).

## Settings (Setup → Gathering…, `WoWBoxerDB.settings.gather`)
Share what I find (on) · Show on my minimap (on for the leader) · Show on the world map (off) · Spawn points (off,
needs Questie) · Known spots (on, + Clear) · **Nearby detection: Apply / Restore** – `SoftTargetInteract 3`,
`SoftTargetInteractArc 2`, `SoftTargetInteractOnlyInRange 0`, `SoftTargetInteractRange ≥ 15`; after a click, out of
combat, the old values in the CVar backup (Setup's Restore restores them too). They are on `R.CVARS` with `gather = …`,
never part of "Apply settings" and never imported from a share string.

## Pins
Unnamed children of `Minimap` (EllesmereUI), ROUND vs any other shape = square, `rotateMinimap` + `GetPlayerFacing`
(hidden when secret), zoom via `C_Minimap.GetViewRadius` (fallback table). Live (2 min), known spot, spawn point; herb
green, ore copper. Tooltip: name, who, age, source, accuracy. ~10 Hz only while something is shown.

## Diagnose
`diag.gather`: probe (soft target, map API, hover API, view radius, shape, QuestieDB), options, CVar plan, stats,
`near` = GameObjects this character saw via soft interact (H / O / other) with its `professions` – this answers the
open question "does soft interact see herbs without Herbalism?" per character. `/wbx gather` prints the status line.

## Open [AFKLAR]
- Soft interact on herbs for a character without Herbalism (paladin): read `diag.gather.near` after the test walk.
- Real soft-interact range on herbs vs veins (PGR logged 4–13 yd first sightings).
- Whether WBXG is paused in instances/encounters on Forever (the outbox logs lockdowns).
- Exact client names of the new Forever herbs (Serpentbloom, Star Lotus, Moonroot): unknown names are learned at the
  first gather cast.

## Credits
Ported from PartyGatherRadar 0.6.0 by Christophe Vandermeulen (MIT, © 2026): `Detection/Coordinates.lua`,
`Detection/ResourceNames.lua`, `Detection/Proximity.lua`, `Map/KnownSpots.lua`, `Map/SpawnPoints.lua`,
`Map/MinimapOverlay.lua`. The MIT notice is in each ported file's header.
