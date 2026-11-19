--[[ WoWBoxer – Gather sharing: map positions and minimap geometry (02_Spec/Gather-sharing-plan.md §5).
  Positions are map coordinates (uiMapID, x, y in 0..1). Going from one map to another uses only C_Map's own
  GetWorldPosFromMapPos / GetMapPosFromWorldPos; no world-axis convention is assumed. A nil or secret value makes a
  position unavailable: no position is ever guessed. The maths (offsets, minimap projection, round/square shapes) is
  pure and tested headless (tests/test_gather.lua).

  Ported from PartyGatherRadar 0.6.0, Detection/Coordinates.lua (comments translated, trimmed to what WoWBoxer uses):

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
local GG = {}
ns.GatherGeo = GG

local G = _G
local type, floor, sqrt, abs, min, cos, sin, pcall = type, math.floor, math.sqrt, math.abs, math.min, math.cos, math.sin, pcall

-- Minimap view radius (yards) per zoom level 0..5, only when C_Minimap.GetViewRadius is missing (public values).
GG.FALLBACK_RADIUS = {
  outdoor = { [0] = 233.333, 200, 166.667, 133.333, 100, 66.667 },
  indoor = { [0] = 150, 120, 90, 60, 40, 25 },
}
GG.RETRY = 5 -- seconds before a failed conversion is tried again

local sizeCache, continentCache = {}, {}
local function secret(v) return ns.Compat and ns.Compat.isSecret and ns.Compat.isSecret(v) end
local function now() return (G.GetTime and G.GetTime()) or 0 end

function GG.isCoord(v) return type(v) == "number" and v == v and v >= 0 and v <= 1 end
function GG.isMapID(v) return type(v) == "number" and v > 0 and v < 10000000 and floor(v) == v end

local function readVector(v)
  if v == nil or secret(v) or type(v) ~= "table" then return nil end
  local x, y
  if v.GetXY then x, y = v:GetXY() else x, y = v.x, v.y end
  if secret(x) or secret(y) or type(x) ~= "number" or type(y) ~= "number" then return nil end
  return x, y
end
local function vector(x, y)
  if G.CreateVector2D then return G.CreateVector2D(x, y) end
  return { x = x, y = y }
end
local function call(fn, ...)
  local ok, a, b = pcall(fn, ...)
  if not ok then return nil end
  return a, b
end

--- The player's position: mapID, x, y – or nil, why ("api", "nomap", "instance", "secret", "invalid").
function GG.playerPosition()
  local M = G.C_Map
  if not (M and M.GetBestMapForUnit and M.GetPlayerMapPosition) then return nil, "api" end
  local mapID = call(M.GetBestMapForUnit, "player")
  if secret(mapID) then return nil, "secret" end
  if mapID == nil then return nil, "nomap" end
  local pos = call(M.GetPlayerMapPosition, mapID, "player")
  if secret(pos) then return nil, "secret" end
  if pos == nil then return nil, "instance" end
  local x, y = readVector(pos)
  if x == nil then return nil, "secret" end
  if not (GG.isCoord(x) and GG.isCoord(y)) or (x == 0 and y == 0) then return nil, "invalid" end
  return mapID, x, y
end

--- World position (continentID, wx, wy) of a map point, or nil.
function GG.mapToWorld(mapID, x, y)
  local M = G.C_Map
  if not (M and M.GetWorldPosFromMapPos) then return nil end
  local continent, pos = call(M.GetWorldPosFromMapPos, mapID, vector(x, y))
  if continent == nil or secret(continent) then return nil end
  local wx, wy = readVector(pos)
  if wx == nil then return nil end
  return continent, wx, wy
end
--- Coordinates on mapID of a world position, or nil.
function GG.worldToMap(continent, wx, wy, mapID)
  local M = G.C_Map
  if not (M and M.GetMapPosFromWorldPos) then return nil end
  local _, pos = call(M.GetMapPosFromWorldPos, continent, vector(wx, wy), mapID)
  return readVector(pos)
end
function GG.continentOf(mapID)
  local c = continentCache[mapID]
  if c == nil or (c.failedAt and now() - c.failedAt >= GG.RETRY) then
    local id = GG.mapToWorld(mapID, 0.5, 0.5)
    c = id and { id } or { failedAt = now() } -- a failure (loading …) is kept only a few seconds
    continentCache[mapID] = c
  end
  return c[1]
end

--- Size of a map in yards: width, height – or nil.
function GG.mapSize(mapID)
  local c = sizeCache[mapID]
  if c == nil or (c.failedAt and now() - c.failedAt >= GG.RETRY) then
    c = { failedAt = now() }
    local w, h
    local M = G.C_Map
    if M and M.GetMapWorldSize then w, h = call(M.GetMapWorldSize, mapID) end
    if secret(w) or secret(h) or type(w) ~= "number" or w <= 0 then
      w, h = nil, nil
      -- fallback: distances between corners turned into world positions (independent of the axes)
      local c0, x0, y0 = GG.mapToWorld(mapID, 0, 0)
      local c1, x1, y1 = GG.mapToWorld(mapID, 1, 0)
      local c2, x2, y2 = GG.mapToWorld(mapID, 0, 1)
      if c0 and c1 and c2 then
        w = sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
        h = sqrt((x2 - x0) ^ 2 + (y2 - y0) ^ 2)
      end
    end
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then c = { w, h } end
    sizeCache[mapID] = c
  end
  return c[1], c[2]
end

--- A point of sourceMap on targetMap, or nil when the maps are not on the same continent or the conversion fails.
function GG.translate(sourceMap, x, y, targetMap)
  if sourceMap == targetMap then return x, y end
  local continent, wx, wy = GG.mapToWorld(sourceMap, x, y)
  if not continent or GG.continentOf(targetMap) ~= continent then return nil end
  return GG.worldToMap(continent, wx, wy, targetMap)
end

--- Minimap view radius in yards, and where the value came from.
function GG.minimapRadius()
  local mm = G.Minimap
  if not mm then return nil, "no minimap" end
  local CM = G.C_Minimap
  if CM and CM.GetViewRadius then
    local r = call(CM.GetViewRadius)
    if not secret(r) and type(r) == "number" and r > 0 then return r, "C_Minimap.GetViewRadius" end
  end
  local zoom = mm.GetZoom and call(mm.GetZoom, mm)
  if secret(zoom) or type(zoom) ~= "number" then return nil, "zoom unknown" end
  local indoors = G.IsIndoors and call(G.IsIndoors)
  local r = GG.FALLBACK_RADIUS[indoors and "indoor" or "outdoor"][zoom]
  if not r then return nil, "zoom unknown" end
  return r, "fallback table"
end

-- ------------------------------------------------------------------ pure geometry
--- Offset in yards between two points of one map: east (+ east), north (+ north). Map y grows to the south.
function GG.offsetYards(w, h, fromX, fromY, toX, toY) return (toX - fromX) * w, (fromY - toY) * h end
--- A map point moved by (east, north) yards. Bounds are not checked.
function GG.applyOffset(w, h, x, y, east, north) return x + east / w, y - north / h end
--- Distance in yards between two points of one map.
function GG.distance(w, h, x1, y1, x2, y2) local dx, dy = (x2 - x1) * w, (y2 - y1) * h; return sqrt(dx * dx + dy * dy) end

--- An (east, north) offset on the minimap, in frame units from its centre. facing (radians, 0 = north,
--- counter-clockwise) only when the minimap rotates.
function GG.project(east, north, radius, halfW, halfH, facing)
  local x, y = east, north
  if facing then
    local c, s = cos(facing), sin(facing)
    x = east * c + north * s
    y = -east * s + north * c
  end
  return x * halfW / radius, y * halfH / radius
end
--- The reverse of project: frame units from the centre back to (east, north) yards (the hover read).
function GG.unproject(px, py, radius, halfW, halfH, facing)
  local x, y = px * radius / halfW, py * radius / halfH
  if facing then
    local c, s = cos(facing), sin(facing)
    return x * c - y * s, x * s + y * c
  end
  return x, y
end
--- Is a projected point (from the centre) inside the minimap? ROUND = a circle; every other shape counts as a
--- square (SQUARE, and the corner shapes of some UIs: a documented limitation).
function GG.inside(px, py, halfW, halfH, round, margin)
  margin = margin or 0
  if round then
    local r = min(halfW, halfH) - margin
    return px * px + py * py <= r * r
  end
  return abs(px) <= halfW - margin and abs(py) <= halfH - margin
end
--- The minimap's shape: "ROUND" or "SQUARE" (GetMinimapShape is set by minimap addons such as EllesmereUI).
function GG.shape()
  local f = G.GetMinimapShape
  if type(f) ~= "function" then return "ROUND" end
  local ok, s = pcall(f)
  if not ok or type(s) ~= "string" then return "ROUND" end
  return s == "ROUND" and "ROUND" or "SQUARE"
end

function GG.reset() sizeCache, continentCache = {}, {} end

return GG
