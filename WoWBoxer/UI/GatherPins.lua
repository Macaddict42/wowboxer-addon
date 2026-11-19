--[[ WoWBoxer – Gather sharing: pins on the minimap (and optionally the world map), 02_Spec/Gather-sharing-plan.md §5.
  Pins are UNNAMED children of Minimap (EllesmereUI's button collector only gathers named Buttons, and it clamps
  Minimap's children to its square crop). Placement: the player's map position + the node's position on the same map
  (C_Map conversions only), the offset in yards scaled by the view radius (C_Minimap.GetViewRadius), the minimap's
  rotation (rotateMinimap + GetPlayerFacing; hidden when the facing is secret) and its shape (GetMinimapShape: ROUND
  or anything else = square). Missing data (instance, a secret value) hides the pins: nothing is guessed. Refreshes
  ~10 times a second, only while there is something to show and the minimap is visible. Display only.

  Three looks: live (seen in the last 2 min, full colour), known spot (smaller, faded), spawn point (smallest, faintest);
  herbs green, ore copper. Known spots hide within 20 yd of a live node of the same kind, spawn points within 20 yd of
  either. Tooltip: name, who saw it, how long ago, source, accuracy.

  Placement logic ported from PartyGatherRadar 0.6.0, Map/MinimapOverlay.lua (rewritten for WoWBoxer):

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
local GP = {}
ns.GatherPins = GP

local G = _G
local sqrt, floor = math.sqrt, math.floor
GP.INTERVAL = 0.1
GP.SIZE = 14
GP.HIDE_NEAR = 20 -- yd
GP.ICON = { H = "Interface\\Icons\\INV_Misc_Flower_02", O = "Interface\\Icons\\INV_Ore_Copper_01" }
GP.COLOR = { H = { 0.35, 0.95, 0.35 }, O = { 0.95, 0.6, 0.25 } }
GP.LOOK = { live = { 1, 1 }, known = { 0.75, 0.7 }, spawn = { 0.6, 0.45 } } -- size factor, alpha

local function GA() return ns.Gather end
local function GG() return ns.GatherGeo end
local function C() return ns.Compat end
local function now() return (G.GetTime and G.GetTime()) or 0 end

-- ------------------------------------------------------------------ what to show (pure)
--- The pins around the player: {{key, k, status = "live"|"known"|"spawn", east, north, dist, ref}}.
--- view = {mapID, px, py, w, h, radius, epoch}; live = GA.live; spots = known spots of the map; spawns = points or nil.
function GP.collect(view, live, spots, spawns)
  local out, liveNear, spotNear = {}, {}, {}
  local reach = view.radius * 1.5
  local function off(mapID, x, y)
    if mapID ~= view.mapID then
      x, y = GG().translate(mapID, x, y, view.mapID)
      if not x then return nil end -- another continent: never on the wrong map
    end
    return GG().offsetYards(view.w, view.h, view.px, view.py, x, y)
  end
  local function nearList(list, k, e, n)
    for _, p in ipairs(list) do
      if p.k == k and (p.e - e) ^ 2 + (p.n - n) ^ 2 <= GP.HIDE_NEAR ^ 2 then return true end
    end
    return false
  end
  for _, a in ipairs(live or {}) do
    local e, n = off(a.mapID, a.x, a.y)
    if e then
      liveNear[#liveNear + 1] = { k = a.k, e = e, n = n }
      local d = sqrt(e * e + n * n)
      if d <= reach then out[#out + 1] = { key = a.key, k = a.k, status = "live", east = e, north = n, dist = d, ref = a } end
    end
  end
  for _, s in ipairs(spots or {}) do
    local e, n = GG().offsetYards(view.w, view.h, view.px, view.py, s.x, s.y)
    spotNear[#spotNear + 1] = { k = s.k, e = e, n = n }
    local d = sqrt(e * e + n * n)
    if d <= reach and not ns.GatherSpots.recentlyGathered(s, view.epoch) and not nearList(liveNear, s.k, e, n) then
      out[#out + 1] = { key = s, k = s.k, status = "known", east = e, north = n, dist = d, ref = s }
    end
  end
  for _, p in ipairs(spawns or {}) do
    local e, n = GG().offsetYards(view.w, view.h, view.px, view.py, p.x, p.y)
    local d = sqrt(e * e + n * n)
    if d <= reach and not nearList(liveNear, p.k, e, n) and not nearList(spotNear, p.k, e, n) then
      out[#out + 1] = { key = p.key, k = p.k, status = "spawn", east = e, north = n, dist = d, ref = p }
    end
  end
  return out
end
--- Frame offsets from the minimap centre for the pins that fall inside it (round or square; rotation by facing).
function GP.layout(entries, radius, halfW, halfH, round, facing, margin)
  local out = {}
  for _, it in ipairs(entries) do
    local ox, oy = GG().project(it.east, it.north, radius, halfW, halfH, facing)
    if GG().inside(ox, oy, halfW, halfH, round, margin or 0) then it.ox, it.oy = ox, oy; out[#out + 1] = it end
  end
  return out
end

-- ------------------------------------------------------------------ tooltip
local function age(sec)
  sec = floor(math.max(0, sec) + 0.5)
  if sec < 60 then return sec .. " s ago" end
  if sec < 3600 then return floor(sec / 60) .. " min ago" end
  if sec < 86400 then return floor(sec / 3600) .. " h ago" end
  return floor(sec / 86400) .. " days ago"
end
function GP.tooltipLines(it)
  local r = it.ref
  local lines = {}
  local kind = GA().KIND[it.k] or "Node"
  if it.status == "live" then
    lines[1] = (r.name ~= nil and r.name ~= "") and r.name or kind
    local who = {}
    for n in pairs(r.by or {}) do who[#who + 1] = C().baseName(n) or n end
    table.sort(who)
    lines[#lines + 1] = kind .. " · seen by " .. (#who > 0 and table.concat(who, ", ") or "?") .. " · " .. age(now() - r.seen)
    lines[#lines + 1] = "Source: " .. (GA().SRC[r.src] or "?") .. " · ±" .. floor((r.acc or 15) + 0.5) .. " yd"
  elseif it.status == "known" then
    lines[1] = r.n or kind
    lines[#lines + 1] = kind .. " · known spot · last seen " .. age(((G.time and G.time()) or 0) - r.t) .. " · seen " .. (r.c or 1) .. "x"
    lines[#lines + 1] = (r.m and "Seen by you" or "From your squad") .. " · ±" .. floor((r.a or 15) + 0.5) .. " yd · may not be there now"
  else
    lines[1] = ns.GatherSpawns.nameOf(r) or kind
    lines[#lines + 1] = kind .. " · spawn point (QuestieDB) · may not be there now"
  end
  if it.dist then lines[#lines + 1] = floor(it.dist + 0.5) .. " yd away" end
  return lines
end

-- ------------------------------------------------------------------ frames (minimap)
local pool, active, used = {}, {}, {}
local function newPin(parent)
  local b = CreateFrame("Button", nil, parent) -- unnamed on purpose (EllesmereUI collects named buttons)
  b.ring = b:CreateTexture(nil, "BACKGROUND")
  b.ring:SetAllPoints()
  b.ring:SetColorTexture(1, 1, 1, 1)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 2, -2)
  b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
  if b.CreateMaskTexture then
    for _, t in ipairs({ b.ring, b.icon }) do
      local m = b:CreateMaskTexture()
      m:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      m:SetAllPoints(t)
      if t.AddMaskTexture then t:AddMaskTexture(m) end
    end
  end
  b:SetScript("OnEnter", function(self)
    local GT = G.GameTooltip
    if not (GT and self.item) then return end
    GT:SetOwner(self, "ANCHOR_RIGHT")
    for i, l in ipairs(GP.tooltipLines(self.item)) do
      if i == 1 then local c = GP.COLOR[self.item.k] or { 1, 1, 1 }; GT:AddLine(l, c[1], c[2], c[3]) else GT:AddLine(l, 0.85, 0.85, 0.85, true) end
    end
    GT:Show()
  end)
  b:SetScript("OnLeave", function(self) local GT = G.GameTooltip; if GT and GT.IsOwned and GT:IsOwned(self) then GT:Hide() end end)
  return b
end
local function acquire(store, key, parent)
  local b = store.active[key]
  if b then return b end
  b = table.remove(store.pool) or newPin(parent)
  store.active[key] = b
  return b
end
local function release(store, key)
  local b = store.active[key]
  if not b then return end
  store.active[key] = nil
  b:Hide(); b:ClearAllPoints(); b.item = nil
  store.pool[#store.pool + 1] = b
end
local function style(b, it, base)
  local look = GP.LOOK[it.status]
  local s = floor(base * look[1] + 0.5)
  b:SetSize(s, s)
  b:SetAlpha(look[2])
  local c = GP.COLOR[it.k] or { 1, 1, 1 }
  b.ring:SetVertexColor(c[1], c[2], c[3], 1)
  b.icon:SetTexture(GP.ICON[it.k])
  if b.icon.SetDesaturated then b.icon:SetDesaturated(it.status ~= "live") end
end
GP.mini = { pool = pool, active = active }
GP.world = { pool = {}, active = {} }
local function hideAll(store) for k in pairs(store.active) do release(store, k) end end
function GP.visibleCount() local n = 0; for _ in pairs(GP.mini.active) do n = n + 1 end return n end

--- What the minimap shows now; returns how many pins and whether to keep refreshing.
function GP.refreshMinimap()
  local mm = G.Minimap
  if not (mm and GA().on("show")) or not mm:IsVisible() then hideAll(GP.mini); return 0, false end
  local mapID, px, py = GG().playerPosition()
  if not mapID then hideAll(GP.mini); return 0, #GA().live > 0 end
  local w, h = GG().mapSize(mapID)
  local radius = GG().minimapRadius()
  if not (w and radius) then hideAll(GP.mini); return 0, true end
  local facing
  if tostring(C().getCVar("rotateMinimap")) == "1" then
    facing = G.GetPlayerFacing and G.GetPlayerFacing()
    if facing == nil or C().isSecret(facing) then hideAll(GP.mini); return 0, true end -- rotating, facing unknown
  end
  local spots = GA().on("spots") and ns.GatherSpots.onMap(mapID) or nil
  local spawns = GA().on("spawns") and ns.GatherSpawns.onMap(mapID) or nil
  local view = { mapID = mapID, px = px, py = py, w = w, h = h, radius = radius, epoch = (G.time and G.time()) or 0 }
  local halfW, halfH = mm:GetWidth() / 2, mm:GetHeight() / 2
  local items = GP.layout(GP.collect(view, GA().live, spots, spawns), radius, halfW, halfH, GG().shape() == "ROUND", facing, GP.SIZE / 2)
  for k in pairs(used) do used[k] = nil end
  for _, it in ipairs(items) do
    local b = acquire(GP.mini, it.key, mm)
    b.item = it
    if b.SetFrameLevel and mm.GetFrameLevel then b:SetFrameLevel(mm:GetFrameLevel() + 3) end
    style(b, it, GP.SIZE)
    b:ClearAllPoints()
    b:SetPoint("CENTER", mm, "CENTER", it.ox, it.oy)
    b:Show()
    used[it.key] = true
  end
  for k in pairs(GP.mini.active) do if not used[k] then release(GP.mini, k) end end
  local keep = #GA().live > 0 or (spots and #spots > 0) or (GA().on("spawns") and ns.GatherSpawns.available())
  return #items, keep and true or false
end

--- The world map: live nodes and known spots of the map it shows (when that is on the player's continent).
local wused = {}
function GP.refreshWorld()
  local wm = G.WorldMapFrame
  if not (wm and GA().on("worldmap") and wm.IsShown and wm:IsShown() and wm.GetMapID) then hideAll(GP.world); return 0 end
  local ok, mapID = pcall(wm.GetMapID, wm)
  if not ok or not GG().isMapID(mapID) then hideAll(GP.world); return 0 end
  local canvas = (wm.ScrollContainer and wm.ScrollContainer.Child) or wm
  local cw, ch = canvas:GetWidth(), canvas:GetHeight()
  for k in pairs(wused) do wused[k] = nil end
  local n = 0
  local function put(key, k, status, mx, x, y, ref)
    if mx ~= mapID then x, y = GG().translate(mx, x, y, mapID) end
    if not x or not GG().isCoord(x) or not GG().isCoord(y) then return end
    local it = { key = key, k = k, status = status, ref = ref }
    local b = acquire(GP.world, key, canvas)
    b.item = it
    style(b, it, 18)
    b:ClearAllPoints()
    b:SetPoint("CENTER", canvas, "TOPLEFT", x * cw, -y * ch)
    b:Show()
    wused[key] = true
    n = n + 1
  end
  for _, a in ipairs(GA().live) do put(a.key, a.k, "live", a.mapID, a.x, a.y, a) end
  if GA().on("spots") then
    for _, s in ipairs(ns.GatherSpots.onMap(mapID)) do
      if not ns.GatherSpots.recentlyGathered(s) then put(s, s.k, "known", mapID, s.x, s.y, s) end
    end
  end
  for k in pairs(GP.world.active) do if not wused[k] then release(GP.world, k) end end
  return n
end

-- ------------------------------------------------------------------ the loop (only while something is shown)
local loop = CreateFrame("Frame")
local since = 0
local function onUpdate(_, elapsed)
  since = since + (elapsed or 0)
  if since < GP.INTERVAL then return end
  since = 0
  local ok, a, keep = pcall(GP.refreshMinimap)
  local okW, nw = pcall(GP.refreshWorld)
  if not ok or not okW then
    if ns.Core and ns.Core.log then ns.Core.log("error", "gather pins: " .. tostring(not ok and a or nw)) end
    loop:SetScript("OnUpdate", nil)
    return
  end
  if not keep and (nw or 0) == 0 then loop:SetScript("OnUpdate", nil) end
end
--- Something changed: refresh and keep the loop running while there is something to show.
function GP.invalidate()
  since = GP.INTERVAL
  if not loop:GetScript("OnUpdate") then loop:SetScript("OnUpdate", onUpdate) end
end
function GP.running() return loop:GetScript("OnUpdate") ~= nil end
GP.loop = loop
for _, ev in ipairs({ "MINIMAP_UPDATE_ZOOM", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "CVAR_UPDATE" }) do
  pcall(loop.RegisterEvent, loop, ev)
end
loop:SetScript("OnEvent", function() GP.invalidate() end)

return GP
