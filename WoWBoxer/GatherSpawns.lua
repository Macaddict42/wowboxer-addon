--[[ WoWBoxer – Gather sharing: spawn points (02_Spec/Gather-sharing-plan.md §1.4). Places where a herb or vein CAN grow,
  read from QuestieDB when it is installed (an optional addon, GPL-3; nothing of it is copied here: its data is read in
  game through its public interface _G.LibQuestieDB – Object.spawns, Object.name, Support.Get("ZoneDB")). Their
  presence now is never claimed; the pins hide them near a live node or a known spot.

  QuestieDB publishes its zone table (areaIdToUiMapId) as the TEXT of a Lua table ("return { [1] = 1426, … }").
  WoWBoxer never runs outside text (CLAUDE.md hard rule 2: no loadstring): the text is read as data with a pattern
  ("[number] = number" pairs) and anything else in it is ignored.

  Built per map on demand, a few objects per frame, never in combat; the last 4 maps are kept. A point =
  { x, y (0..1), k = "H"|"O", ids = { objects }, key }. Two objects at the same place (copper and tin share points)
  make one point.

  Ported from PartyGatherRadar 0.6.0, Map/SpawnPoints.lua (comments translated; the zone table parsed as data instead
  of loadstring):

  MIT License – Copyright (c) 2026 Christophe Vandermeulen
  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
  documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
  persons to whom the Software is furnished to do so, subject to the following conditions:
  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
  Software.
  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
  WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
  OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. ]]
local _, ns = ...
local SP = {}
ns.GatherSpawns = SP

local G = _G
local type, pairs, ipairs, pcall, floor, tonumber = type, pairs, ipairs, pcall, math.floor, tonumber

SP.CONTRACT = 4
SP.PER_STEP = 8
SP.MAX_MAPS = 4
SP.MAX_NAMES = 3
SP.version = 0

-- Gather objects (game object IDs), from PartyGatherRadar's list (QuestieDB 1.0.13, Forever variants included).
-- Names alone are not enough: QuestieDB also has quest objects named like herbs.
SP.OBJECTS = {}
local HERB_IDS = {
  1618, 3724, 657382, 657456, 656160, 657454, 1617, 3725, 657380, 657457, 656161, 657455, 1619, 3726, 657383, 657458,
  1620, 3727, 657459, 1621, 3729, 657385, 657460, 2045, 657394, 1622, 3730, 657386, 657461, 1623, 657387,
  1628, 1624, 2041, 657390, 2042, 2046, 2043, 2044, 2866, 142140, 180165, 142141, 176642, 142142, 176636, 180164,
  142143, 183046, 142144, 142145, 176637, 176583, 176638, 180167, 176584, 176639, 180168,
  176586, 176640, 180166, 176587, 176641, 176588, 176589, 694732, 176753, 175566, 13891, 439762, 439810,
}
local ORE_IDS = {
  1731, 2055, 3763, 103713, 181248, 562111, 1732, 2054, 3764, 103711, 181249, 1733, 105569, 73940, 1735,
  1734, 150080, 181109, 73941, 2040, 150079, 176645, 123310, 2047, 150081, 181108, 123309, 165658,
  324, 150082, 176643, 123848, 175404, 177388, 1610, 1667, 2653, 656332, 656333, 439778, 439628,
}
local LIST = {}
for _, id in ipairs(HERB_IDS) do SP.OBJECTS[id] = "H"; LIST[#LIST + 1] = id end
for _, id in ipairs(ORE_IDS) do SP.OBJECTS[id] = "O"; LIST[#LIST + 1] = id end

local cache, cached, used = {}, 0, 0
local job, scheduled, lib, areaToMap, unavailable
local names = {}

--- A "return { [k] = v, … }" text (or a table) as data: {[areaId] = uiMapID}; a value 0 removes the area.
--- Only number = number pairs are read; nothing in the text is ever run.
function SP.parseAreaTable(value, into)
  into = into or {}
  if type(value) == "table" then
    for k, v in pairs(value) do
      if type(k) == "number" and type(v) == "number" then into[k] = v > 0 and v or nil end
    end
    return into, true
  end
  if type(value) ~= "string" then return into, false end
  local any = false
  for k, v in value:gmatch("%[%s*(%-?%d+)%s*%]%s*=%s*(%-?%d+)") do
    k, v = tonumber(k), tonumber(v)
    if k and v then into[k] = v > 0 and v or nil; any = true end
  end
  return into, any
end

local function library()
  local L = G.LibQuestieDB
  if type(L) ~= "table" or type(L.Object) ~= "table" or type(L.Object.spawns) ~= "function" then return nil, "absent" end
  if type(L.RequireContract) == "function" then
    local ok, yes = pcall(L.RequireContract, SP.CONTRACT)
    if not ok or not yes then return nil, "contract" end
  end
  return L
end
local function loadAreas(L)
  local S = L.Support
  if type(S) ~= "table" or type(S.Get) ~= "function" then return nil end
  local ok, zoneDB = pcall(S.Get, "ZoneDB")
  local priv = ok and type(zoneDB) == "table" and zoneDB.private
  if type(priv) ~= "table" then return nil end
  local t, any = SP.parseAreaTable(priv.areaIdToUiMapId)
  if not any then return nil end
  SP.parseAreaTable(priv.areaIdToUiMapIdOverride, t) -- aliases and removed zones (optional)
  return t
end
local function ready()
  if lib then return lib end
  if unavailable then return nil, unavailable end
  local L, why = library()
  if not L then return nil, why end -- absent: asked again later (another addon may load it on demand)
  areaToMap = loadAreas(L)
  if not areaToMap then
    unavailable = "zones"
    if ns.Core and ns.Core.log then ns.Core.log("warn", "gather: QuestieDB has no zone table – no spawn points") end
    return nil, unavailable
  end
  lib = L
  return L
end
function SP.available() return ready() ~= nil end
--- "ready" | "building" | "absent" | "contract" | "zones"
function SP.state()
  local L, why = ready()
  if not L then return why end
  return job and "building" or "ready"
end

local function isPercent(v) return type(v) == "number" and v == v and v >= 0 and v <= 100 end
local function addObject(L, id)
  local ok, spawns = pcall(L.Object.spawns, id)
  if not ok or type(spawns) ~= "table" then return end
  local kind = SP.OBJECTS[id]
  for area, list in pairs(spawns) do
    if areaToMap[area] == job.mapID and type(list) == "table" then
      for _, c in ipairs(list) do
        local x, y = type(c) == "table" and c[1], type(c) == "table" and c[2]
        if isPercent(x) and isPercent(y) then -- (-1, -1) = an instance object with no map position
          local place = kind .. floor(x * 100 + 0.5) .. ":" .. floor(y * 100 + 0.5)
          local p = job.byPlace[place]
          if p then if p.ids[#p.ids] ~= id then p.ids[#p.ids + 1] = id end
          else
            p = { x = x / 100, y = y / 100, k = kind, ids = { id }, key = "sp" .. job.mapID .. ":" .. (#job.points + 1) }
            job.points[#job.points + 1] = p
            job.byPlace[place] = p
          end
        end
      end
    end
  end
end
local function evict()
  while cached > SP.MAX_MAPS do
    local v, oldest
    for mapID, e in pairs(cache) do if not oldest or e.used < oldest then v, oldest = mapID, e.used end end
    cache[v] = nil
    cached = cached - 1
  end
end
local schedule
local function step()
  scheduled = false
  if not job then return end
  if G.InCombatLockdown and G.InCombatLockdown() then schedule(1); return end -- never in combat
  local L = ready()
  if not L then job = nil; return end
  local last = job.index + SP.PER_STEP - 1
  for i = job.index, last do local id = LIST[i]; if not id then break end addObject(L, id) end
  job.index = last + 1
  if job.index <= #LIST then schedule(0); return end
  used = used + 1
  if not cache[job.mapID] then cached = cached + 1 end
  cache[job.mapID] = { points = job.points, used = used }
  if ns.Core and ns.Core.log then ns.Core.log("info", "gather: map " .. job.mapID .. ": " .. #job.points .. " spawn point(s) (QuestieDB)") end
  job = nil
  evict()
  SP.version = SP.version + 1
end
schedule = function(delay)
  if scheduled then return end
  scheduled = true
  local After = G.C_Timer and G.C_Timer.After
  if After then After(delay, step) else step() end
end

--- The points of a map when built; otherwise starts building them (SP.version changes at the end) and returns nil.
function SP.onMap(mapID)
  local e = cache[mapID]
  if e then used = used + 1; e.used = used; return e.points end
  if not (ns.GatherGeo.isMapID(mapID) and ready()) then return nil end
  if not job or job.mapID ~= mapID then job = { mapID = mapID, index = 1, points = {}, byPlace = {} } end
  schedule(0)
  return nil
end
function SP.count(mapID)
  if mapID then local e = cache[mapID]; return e and #e.points or 0 end
  local n = 0
  for _, e in pairs(cache) do n = n + #e.points end
  return n
end
local function objectName(id)
  local c = names[id]
  if c == nil then
    c = false
    local L = ready()
    if L and type(L.Object.name) == "function" then
      local ok, v = pcall(L.Object.name, id)
      if ok and type(v) == "string" and v ~= "" then c = v:sub(1, 60) end
    end
    names[id] = c
  end
  return c or nil
end
--- The point's object names (the client's language when QuestieDB has it), no doubles; nil when none is readable.
function SP.nameOf(p)
  local list, seen = {}, {}
  for _, id in ipairs(p.ids) do
    local n = objectName(id)
    if n and not seen[n] then seen[n] = true; list[#list + 1] = n; if #list >= SP.MAX_NAMES then break end end
  end
  return #list > 0 and table.concat(list, " / ") or nil
end
function SP.reset()
  cache, names, cached, job, lib, areaToMap, unavailable = {}, {}, 0, nil, nil, nil, nil
  SP.version = SP.version + 1
end

return SP
