--[[ WoWBoxer – Gather sharing: known spots (02_Spec/Gather-sharing-plan.md §1.5). Every herb or vein seen (near, hover),
  gathered or received from the squad is remembered per map, across sessions, account-wide (WoWBoxerDB.gather.spots).
  Herbs and veins grow back in the same places, so the minimap shows these as quiet "known spot" pins; their presence
  now is never claimed (only a live sighting is). One spot per physical node: same kind within MERGE_YARDS, or within
  the two accuracies added up (at most MAX_MERGE_YARDS); the more accurate position is kept. At most 300 per map and
  3000 in all; the least recently seen goes first, received ones before this character's own. A gathered spot is not
  shown for GATHERED_HIDE seconds (the node just went). No frames: tested headless.

  Stored (short keys, small SavedVariables):
    [mapID] = { { x, y, k = "H"|"O", n = name, a = accuracy (yd), t = last seen (time()), c = times seen,
                  m = seen by this character, g = gathered at (time()), cleared by a new sighting } }

  Ported from PartyGatherRadar 0.6.0, Map/KnownSpots.lua (comments translated, kinds shortened to H/O):

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
local GS = {}
ns.GatherSpots = GS

local G = _G
local type, pairs, ipairs, floor, min, max = type, pairs, ipairs, math.floor, math.min, math.max

GS.MERGE_YARDS = 15
GS.MAX_MERGE_YARDS = 30
GS.GATHERED_HIDE = 300
GS.MAX_PER_MAP = 300
GS.MAX_TOTAL = 3000
GS.DEFAULT_ACCURACY = 15
GS.MAX_COUNT = 9999
GS.version = 0 -- bumped on every visible change (the pins redraw)

local KINDS = { H = true, O = true }
local store, total = nil, 0
local persist -- called once on the first write: the table goes into SavedVariables only then (a login never writes)
local function wrote() if persist then local p = persist; persist = nil; p(store) end end

local function geo() return ns.GatherGeo end
local function clock() return (G.time and G.time()) or 0 end
local function touch() GS.version = GS.version + 1 end
local function isCoord(v) return type(v) == "number" and v == v and v >= 0 and v <= 1 end
local function positive(v) return type(v) == "number" and v == v and v > 0 and v < math.huge end
local function cleanName(n)
  if type(n) ~= "string" or n == "" or (ns.Compat and ns.Compat.isSecret and ns.Compat.isSecret(n)) then return nil end
  return (n:gsub("[|%c]", "")):sub(1, 60)
end

-- ------------------------------------------------------------------ limits
local function oldestIndex(list, ownToo)
  local index, oldest
  for i, s in ipairs(list) do
    if (ownToo or not s.m) and (not oldest or s.t < oldest) then index, oldest = i, s.t end
  end
  return index, oldest
end
local function victim(list) return oldestIndex(list, false) or oldestIndex(list, true) end
--- Drop the least recently seen spot of all maps; received ones first, so a busy squad member never pushes out what
--- this character saw itself.
local function evictOldest()
  local vMap, vIndex, vTime
  for _, ownToo in ipairs({ false, true }) do
    for mapID, list in pairs(store) do
      local i, t = oldestIndex(list, ownToo)
      if i and (not vTime or t < vTime) then vMap, vIndex, vTime = mapID, i, t end
    end
    if vMap then break end
  end
  if not vMap then return end
  table.remove(store[vMap], vIndex)
  total = total - 1
  if #store[vMap] == 0 then store[vMap] = nil end
end

-- ------------------------------------------------------------------ loading
local function valid(s) return type(s) == "table" and isCoord(s.x) and isCoord(s.y) and KINDS[s.k] == true and positive(s.t) end
--- Attach the saved table: invalid entries go (hand-edited file, older version), limits applied.
function GS.attach(db, onFirstWrite)
  persist = onFirstWrite
  total = 0
  for mapID, list in pairs(db) do
    if not geo().isMapID(mapID) or type(list) ~= "table" then db[mapID] = nil
    else
      local kept = {}
      for _, s in ipairs(list) do
        if valid(s) and #kept < GS.MAX_PER_MAP then
          s.n = cleanName(s.n)
          s.a = positive(s.a) and s.a or GS.DEFAULT_ACCURACY
          s.c = (positive(s.c) and s.c >= 1) and min(floor(s.c), GS.MAX_COUNT) or 1
          s.m = s.m == true or nil
          s.g = positive(s.g) and s.g or nil
          kept[#kept + 1] = s
        end
      end
      db[mapID] = #kept > 0 and kept or nil
      total = total + #kept
    end
  end
  store = db
  while total > GS.MAX_TOTAL do evictOldest() end
  touch()
end

-- ------------------------------------------------------------------ recording
local function findMatch(list, kind, w, h, x, y, acc)
  local best, bestD
  for _, s in ipairs(list) do
    if s.k == kind then
      local d = geo().distance(w, h, s.x, s.y, x, y)
      local limit = max(GS.MERGE_YARDS, min(acc + s.a, GS.MAX_MERGE_YARDS))
      if d <= limit and (not bestD or d < bestD) then best, bestD = s, d end
    end
  end
  return best, bestD
end

--- Remember a spot, or update the nearest of the same kind. own = seen by this character (not only received).
--- A new sighting clears the gathered mark. Returns the spot and "created" | "updated", or nil, why.
function GS.record(kind, name, mapID, x, y, acc, own, at)
  if not store then return nil, "not ready" end
  if not KINDS[kind] then return nil, "bad kind" end
  if not geo().isMapID(mapID) or not isCoord(x) or not isCoord(y) then return nil, "bad position" end
  local w, h = geo().mapSize(mapID)
  if not w then return nil, "no map size" end
  at = at or clock()
  acc = positive(acc) and acc or GS.DEFAULT_ACCURACY
  name = cleanName(name)
  local list = store[mapID]
  local best, bestD
  if list then best, bestD = findMatch(list, kind, w, h, x, y, acc) end
  if best then
    best.t = math.max(best.t, at)
    best.c = min(best.c + 1, GS.MAX_COUNT)
    best.n = name or best.n
    best.g = nil
    if own then best.m = true end
    wrote()
    if acc <= best.a then
      if bestD >= 2 then touch() end
      best.x, best.y, best.a = x, y, acc
    end
    touch()
    return best, "updated"
  end
  list = list or {}
  if #list >= GS.MAX_PER_MAP then table.remove(list, (victim(list))); total = total - 1
  elseif total >= GS.MAX_TOTAL then evictOldest() end
  wrote()
  local s = { x = x, y = y, k = kind, n = name, a = acc, t = at, c = 1, m = own and true or nil }
  list[#list + 1] = s
  store[mapID] = list
  total = total + 1
  touch()
  return s, "created"
end

--- Mark the spot of a node that just went as gathered. Returns the spot or nil.
function GS.markGathered(kind, mapID, x, y, acc, at)
  local list = store and store[mapID]
  if not list or not KINDS[kind] or not isCoord(x) or not isCoord(y) then return nil end
  local w, h = geo().mapSize(mapID)
  if not w then return nil end
  local s = findMatch(list, kind, w, h, x, y, positive(acc) and acc or GS.DEFAULT_ACCURACY)
  if s then wrote(); s.g = at or clock(); touch() end
  return s
end
function GS.recentlyGathered(s, at)
  at = at or clock()
  return s.g ~= nil and at >= s.g and at - s.g < GS.GATHERED_HIDE
end

-- ------------------------------------------------------------------ reading
function GS.onMap(mapID) return store and store[mapID] or {} end
function GS.count(mapID)
  if not store then return 0 end
  if mapID ~= nil then local l = store[mapID]; return l and #l or 0 end
  return total
end
--- The spots of a map nearest to (x, y), at most n (the snapshot a member asks for).
function GS.nearest(mapID, x, y, n)
  local list = store and store[mapID]
  if not list then return {} end
  local w, h = geo().mapSize(mapID)
  local out = {}
  for _, s in ipairs(list) do
    out[#out + 1] = { s = s, d = w and geo().distance(w, h, x, y, s.x, s.y) or ((s.x - x) ^ 2 + (s.y - y) ^ 2) }
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  local res = {}
  for i = 1, math.min(n, #out) do res[i] = out[i].s end
  return res
end
--- Forget every known spot. Returns how many.
function GS.clear()
  if not store then return 0 end
  local n = total
  for k in pairs(store) do store[k] = nil end
  total = 0
  touch()
  return n
end

return GS
