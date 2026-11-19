-- Gather sharing (WoWBoxer/Gather*.lua, UI/GatherPins.lua; 02_Spec/Gather-sharing-plan.md): the WBXG protocol
-- (encode/decode, data only), squad-only accept, dedupe, gathered = gone for everyone, known spots, the coordinate
-- maths and pin positions on round and square minimaps (rotation, zoom), the soft-target CVars (only after a click, out
-- of combat, backup + restore, never in "Apply settings"), nearby detection, gather casts, the Questie zone table read
-- as data. Nothing here may cast, target, move, follow or interact.
local dir = (arg[0]:match("^(.*)/[^/]+$") or ".")
local H = dofile(dir .. "/harness.lua")
local Mock = dofile(dir .. "/wowmock.lua")

local PAL = { class = "PALADIN", race = "Human", level = 20 }
local LOCK = { class = "WARLOCK", race = "Human", level = 20 }
local PRI = { class = "PRIEST", race = "Human", level = 20 }
local MAP, SIZE = 1426, 1000 -- a 1000 x 1000 yd map
local function boot(me, opts)
  opts = opts or {}
  local party = me == "Rip" and { party1 = "Rap", party2 = "Rup" } or { party1 = "Rip", party2 = me == "Rap" and "Rup" or "Rap" }
  local info = me == "Rip" and { party1 = LOCK, party2 = PRI } or { party1 = PAL, party2 = me == "Rap" and PRI or LOCK }
  local W = Mock.new(H, { name = me, class = me == "Rip" and "PALADIN" or (me == "Rap" and "WARLOCK" or "PRIEST"), race = "Human", level = 20,
    party = party, partyInfo = info, cvars = opts.cvars })
  local G = W.env
  W.pos = { x = 0.5, y = 0.5 }
  G.C_Map = {
    GetBestMapForUnit = function() return MAP end,
    GetPlayerMapPosition = function() return { x = W.pos.x, y = W.pos.y } end,
    GetMapWorldSize = function(id) if id == MAP then return SIZE, SIZE end return 0, 0 end,
  }
  W.radius = 200
  G.C_Minimap = { GetViewRadius = function() return W.radius end }
  W.shape = "ROUND"
  G.GetMinimapShape = function() return W.shape end
  W.facing = 0
  G.GetPlayerFacing = function() return W.facing end
  G.Minimap:SetSize(140, 140)
  -- the soft interact target
  W.soft = nil
  local un, ug = G.UnitName, G.UnitGUID
  G.UnitName = function(u) if u == "softinteract" then return W.soft and W.soft.name end return un(u) end
  G.UnitGUID = function(u) if u == "softinteract" then return W.soft and W.soft.guid end return ug(u) end
  G.UnitIsInInteractRange = function(u) return u == "softinteract" and W.soft and W.soft.reach or false end
  W.acted = {}
  for _, fn in ipairs({ "CastSpellByName", "TargetUnit", "FollowUnit", "InteractUnit", "UseAction" }) do G[fn] = function() W.acted[#W.acted + 1] = fn end end
  local ns = H.loadAddon({ env = G })
  W.fire("ADDON_LOADED", "WoWBoxer"); W.fire("PLAYER_LOGIN")
  local sq = ns.State.newSquad({ name = "Trio", members = {
    { name = "Rip", cls = "paladin", race = "human", role = "tank", leader = true },
    { name = "Rap", cls = "warlock", race = "human", role = "ranged" },
    { name = "Rup", cls = "priest", race = "human", role = "healer" } } })
  ns.Core.db.squads = { sq }; ns.Core.db.active = sq.id
  return W, ns
end
local function sentG(W, kind)
  local out = {}
  for _, m in ipairs(W.sent) do if m.prefix == "WBXG" and (not kind or m.msg:sub(1, #kind) == kind) then out[#out + 1] = m.msg end end
  return out
end
local function deliver(W, from, text) W.fire("CHAT_MSG_ADDON", "WBXG", text, "PARTY", from) end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ------------------------------------------------------------------ 1. protocol (pure)
do
  local W, ns = boot("Rip")
  local GA = ns.Gather
  H.ok(W.prefixes.WBXG, "the WBXG prefix is registered")
  local msg = GA.encodeNode({ k = "H", mapID = MAP, x = 0.51234, y = 0.44, src = "n", acc = 5, age = 12, name = "Peacebloom" })
  H.eq(msg, "N|H|1426|5123|4400|n|5|12|Peacebloom", "node message: 4-decimal coordinates")
  local d = GA.decode(msg)
  H.ok(d and d.t == "N" and d.k == "H" and d.mapID == MAP and near(d.x, 0.5123) and d.y == 0.44 and d.src == "n" and d.acc == 5 and d.age == 12 and d.name == "Peacebloom", "node decodes")
  local g = GA.decode(GA.encodeGathered({ k = "O", mapID = MAP, x = 0.1, y = 0.2, name = "Copper Vein" }))
  H.ok(g and g.t == "G" and g.k == "O" and g.name == "Copper Vein", "gathered decodes")
  local q = GA.decode(GA.encodeAsk(MAP, 0.5, 0.5))
  H.ok(q and q.t == "Q" and q.mapID == MAP and q.x == 0.5, "ask decodes")
  local spots = {}
  for i = 1, 30 do spots[i] = { k = i % 2 == 0 and "H" or "O", x = i / 100, y = 0.5, a = 15, n = "Name, with; marks " .. i } end
  local parts = GA.encodeSpots(MAP, spots)
  local total, maxLen = 0, 0
  for _, p in ipairs(parts) do
    maxLen = math.max(maxLen, #p)
    local s = GA.decode(p)
    total = total + (s and #s.spots or 0)
    if s and s.spots[1] then H.ok(not s.spots[1].name:find("[,;]"), "spot names lose , and ;") end
  end
  H.ok(#parts > 1 and maxLen <= 255, "spots split into messages of at most 255 characters (" .. #parts .. ", longest " .. maxLen .. ")")
  H.eq(total, 30, "every spot arrives")
  -- bad input: never anything but data
  for _, bad in ipairs({ "N|X|1426|5000|5000|n|5|0|Peacebloom", "N|H|0|5000|5000|n|5|0|a", "N|H|1426|10001|5000|n|5|0|a", "N|H|1426|5000|5000|z|5|0|a",
    "N|H|1426|5000|5000|n|500|0|a", "N|H|1426|50.5|5000|n|5|0|a", "loadstring('x')()", "Q|abc|1|1", string.rep("N", 300) }) do
    H.eq(GA.decode(bad), nil, "rejected: " .. bad:sub(1, 40))
  end
  H.eq(GA.decode("N|H|1426|5000|5000|n|5|0|Peace\124cffbloom") ~= nil, true, "a | in a name only ends the field")
  local x = GA.decode("N|H|1426|5000|5000|n|5|0|" .. string.rep("a", 80))
  H.eq(x and #x.name, 60, "names capped at 60")
end

-- ------------------------------------------------------------------ 2. squad-only accept, dedupe, gathered = gone
do
  local W, ns = boot("Rip")
  local GA = ns.Gather
  deliver(W, "Stranger", "N|H|1426|5000|5000|n|5|0|Peacebloom")
  H.eq(#GA.live, 0, "a stranger's message is dropped")
  W.party.party3 = "Outsider"
  deliver(W, "Outsider", "N|H|1426|5000|5000|n|5|0|Peacebloom")
  H.eq(#GA.live, 0, "a party member outside the squad is dropped")
  W.party.party3 = nil
  deliver(W, "Rap", "N|H|1426|5000|5000|n|15|0|Peacebloom")
  H.eq(#GA.live, 1, "a squad member in the party: one live node")
  deliver(W, "Rup", "N|H|1426|5030|5000|n|5|0|Peacebloom") -- 3 yd east
  H.eq(#GA.live, 1, "the same herb 3 yd away from another member: still one node")
  H.ok(GA.live[1].by.Rap and GA.live[1].by.Rup, "both members named as having seen it")
  H.ok(near(GA.live[1].x, 0.503) and GA.live[1].acc == 5, "the more accurate position wins")
  deliver(W, "Rap", "N|O|1426|5030|5000|n|5|0|Copper Vein")
  H.eq(#GA.live, 2, "an ore at the same place is another node")
  deliver(W, "Rap", "N|H|1426|5200|5000|n|5|0|Peacebloom") -- 20 yd
  H.eq(#GA.live, 3, "20 yd away: another herb")
  H.ok(ns.GatherSpots.count(MAP) >= 3, "received nodes become known spots")
  deliver(W, "Rap", "G|H|1426|5010|5000|Peacebloom")
  local herbs = 0
  for _, a in ipairs(GA.live) do if a.k == "H" then herbs = herbs + 1 end end
  H.eq(herbs, 1, "gathered: the herb is gone for everyone (the one 20 yd away stays)")
  local gone
  for _, s in ipairs(ns.GatherSpots.onMap(MAP)) do if s.k == "H" and near(s.x, 0.502, 0.004) then gone = s end end
  H.ok(gone and ns.GatherSpots.recentlyGathered(gone), "its known spot is marked gathered (hidden for 5 min)")
  -- an old sighting expires
  GA.expire(4e9)
  H.eq(#GA.live, 0, "live nodes expire after 2 minutes")
  H.eq(#W.acted, 0, "nothing acted")
end

-- ------------------------------------------------------------------ 3. coordinate maths (pure)
do
  local _, ns = boot("Rip")
  local GG = ns.GatherGeo
  local e, n = GG.offsetYards(SIZE, SIZE, 0.5, 0.5, 0.51, 0.49)
  H.ok(near(e, 10) and near(n, 10), "offset: +x is east, -y is north (" .. e .. ", " .. n .. ")")
  local x, y = GG.applyOffset(SIZE, SIZE, 0.5, 0.5, 10, 10)
  H.ok(near(x, 0.51) and near(y, 0.49), "applyOffset is the reverse")
  local px, py = GG.project(100, 0, 200, 70, 70)
  H.ok(near(px, 35) and near(py, 0), "100 yd east at radius 200 on a 140 px minimap: 35 px right")
  px, py = GG.project(0, 100, 200, 70, 70, math.pi / 2)
  H.ok(near(px, 35) and near(py, 0, 1e-9), "rotating minimap, facing west: north is to the right")
  local ue, un = GG.unproject(px, py, 200, 70, 70, math.pi / 2)
  H.ok(near(ue, 0, 1e-9) and near(un, 100), "unproject is the reverse (hover)")
  H.ok(GG.inside(60, 60, 70, 70, false, 0), "square: a corner point is inside")
  H.ok(not GG.inside(60, 60, 70, 70, true, 0), "round: the same point is outside")
  H.ok(not GG.inside(68, 0, 70, 70, true, 7), "the margin keeps a pin off the edge")
  H.ok(near(GG.distance(SIZE, SIZE, 0.5, 0.5, 0.503, 0.504), 5), "distance in yards")
end

-- ------------------------------------------------------------------ 4. pins on round and square minimaps
do
  local W, ns = boot("Rip")
  local GA, GP = ns.Gather, ns.GatherPins
  H.ok(GA.on("show"), "the leader shows pins by default")
  ns.GatherSpots.clear()
  deliver(W, "Rap", "N|H|1426|5700|5000|n|5|0|Peacebloom")   -- 70 yd east
  deliver(W, "Rap", "N|O|1426|6710|3290|n|5|0|Copper Vein")  -- 171 yd east and north: a corner of the square
  local n = GP.refreshMinimap()
  H.eq(n, 1, "round minimap: the corner vein falls outside, the herb shows")
  local pin
  for _, b in pairs(GP.mini.active) do pin = b end
  local _, rel, _, ox, oy = pin:GetPoint(1)
  H.ok(rel == W.env.Minimap and near(ox, 24.5) and near(oy, 0), "herb pin 70 yd east: 24.5 px right of centre (" .. tostring(ox) .. ")")
  H.eq(pin:GetName(), nil, "pins are unnamed (EllesmereUI collects named buttons)")
  H.ok(pin._parent == W.env.Minimap, "pins are children of Minimap")
  W.shape = "SQUARE"
  H.eq(GP.refreshMinimap(), 2, "square minimap (EllesmereUI): the corner vein shows too")
  W.radius = 100
  GP.refreshMinimap()
  for _, b in pairs(GP.mini.active) do if b.item.k == "H" then _, _, _, ox = b:GetPoint(1) end end
  H.ok(near(ox, 49), "zoomed in (radius 100): the herb moves to 49 px")
  W.cvars.rotateMinimap = "1"
  W.facing = math.pi -- facing south: east is to the left
  W.radius = 200
  GP.refreshMinimap()
  for _, b in pairs(GP.mini.active) do if b.item.k == "H" then _, _, _, ox = b:GetPoint(1) end end
  H.ok(near(ox, -24.5), "rotating minimap facing south: the east herb is on the left (" .. tostring(ox) .. ")")
  W.env.GetPlayerFacing = function() return nil end
  H.eq(GP.refreshMinimap(), 0, "rotating and the facing unknown: no pins (nothing is guessed)")
  W.cvars.rotateMinimap = "0"
  W.env.GetPlayerFacing = function() return 0 end
  ns.Gather.set("show", false)
  H.eq(GP.refreshMinimap(), 0, "Show on my minimap off: no pins")
  ns.Core.db.settings.gather.show = nil
  -- a known spot near a live node hides; tooltip lines
  W.shape = "ROUND"
  GP.refreshMinimap()
  local lines
  for _, b in pairs(GP.mini.active) do if b.item.k == "H" then lines = GP.tooltipLines(b.item) end end
  H.ok(lines and lines[1] == "Peacebloom" and lines[2]:find("seen by Rap", 1, true) and lines[3]:find("near", 1, true), "tooltip: name, who, age, source")
  local kinds = {}
  for _, b in pairs(GP.mini.active) do kinds[b.item.status] = (kinds[b.item.status] or 0) + 1 end
  H.eq(kinds.known, nil, "the known spot under a live node is not shown twice")
  -- the world map
  ns.Gather.set("worldmap", true)
  local wm = W.env.CreateFrame("Frame", nil, W.env.UIParent)
  wm.GetMapID = function() return MAP end
  wm.ScrollContainer = { Child = W.env.CreateFrame("Frame", nil, wm) }
  wm.ScrollContainer.Child:SetSize(1000, 700)
  W.env.WorldMapFrame = wm
  local okW, nW = pcall(GP.refreshWorld)
  H.ok(okW and nW >= 2, "world map: live pins on the map it shows (" .. tostring(nW) .. ", shown " .. tostring(wm:IsShown()) .. ")")
  local _, _, rp, wx, wy
  for _, b in pairs(GP.world.active) do if b.item.k == "H" and b.item.status == "live" then _, _, rp, wx, wy = b:GetPoint(1) end end
  H.ok(rp == "TOPLEFT" and near(wx, 570) and near(wy, -350), "world map pin at x * width, -y * height")
end

-- ------------------------------------------------------------------ 5. the soft-target CVars
do
  local cv = { autoLootDefault = "0", deselectOnClick = "1", autoSelfCast = "1", maxfpsbk = "8", SoftTargetInteract = "1", SoftTargetInteractArc = "0",
    SoftTargetInteractOnlyInRange = "1", SoftTargetInteractRange = "30" }
  local W, ns = boot("Rap", { cvars = cv })
  local GA, Core = ns.Gather, ns.Core
  for _, c in ipairs(Core.cvarPlan()) do H.ok(not c.name:find("^SoftTarget"), "Apply settings never lists " .. c.name) end
  Core.applyCVars()
  W.flush()
  H.eq(W.cvars.SoftTargetInteract, "1", "Apply settings leaves the soft target alone")
  W.combat = true
  GA.applyCVars()
  H.eq(W.cvars.SoftTargetInteract, "1", "in combat: nothing changes yet")
  W.combat = false
  W.fire("PLAYER_REGEN_ENABLED"); W.flush()
  H.eq(W.cvars.SoftTargetInteract, "3", "after combat: SoftTargetInteract 3")
  H.eq(W.cvars.SoftTargetInteractArc, "2", "Arc 2")
  H.eq(W.cvars.SoftTargetInteractOnlyInRange, "0", "OnlyInRange 0")
  H.eq(W.cvars.SoftTargetInteractRange, "30", "the range is never lowered (30 stays 30)")
  H.eq(Core.cdb.cvarBackup.SoftTargetInteract, "1", "the old value is kept for Restore")
  H.eq(Core.cdb.cvarBackup.SoftTargetInteractRange, nil, "an unchanged CVar has no backup")
  GA.restoreCVars(); W.flush()
  H.eq(W.cvars.SoftTargetInteract, "1", "Restore puts SoftTargetInteract back")
  H.eq(W.cvars.SoftTargetInteractArc, "0", "and Arc")
  H.eq(Core.cdb.cvarBackup.SoftTargetInteract, nil, "the backup is used up")
  H.ok(not Core.db.settings.gather.near, "nearby detection off after Restore")
  -- the share string never carries them
  local imp = ns.Share.validate({ f = "wowboxer/1", game = "any", squad = { name = "S", members = { { name = "A", cls = "mage", race = "human", role = "ranged" } } },
    cvars = { SoftTargetInteract = "3", autoLootDefault = "1" } })
  H.ok(imp and imp.cvars and imp.cvars.autoLootDefault == "1" and imp.cvars.SoftTargetInteract == nil, "a share string can't set the soft-target CVars " .. H.show(imp and imp.cvars))
end

-- ------------------------------------------------------------------ 6. nearby detection (soft interact) and gather casts
do
  local cv = { SoftTargetInteract = "1", SoftTargetInteractArc = "0", SoftTargetInteractOnlyInRange = "1", SoftTargetInteractRange = "10" }
  local W, ns = boot("Rap", { cvars = cv })
  local GA = ns.Gather
  W.soft = { guid = "GameObject-0-1-2-3-1618-0000", name = "Peacebloom", reach = false }
  H.eq(GA.checkNear(), false, "nearby detection off: the soft target is not read")
  GA.applyCVars(); W.flush()
  H.eq(W.cvars.SoftTargetInteractRange, "15", "range raised to 15")
  H.ok(GA.checkNear(), "a herb as the soft target is found")
  local n = sentG(W, "N|")
  H.eq(n[1], "N|H|1426|5000|5000|n|15|0|Peacebloom", "and shared at the player's position, ±15 yd")
  H.eq(GA.checkNear(), false, "the same target again at once: not sent twice")
  W.soft.reach = true
  H.ok(GA.checkNear(), "now in interact range: reported again (±5 yd)")
  H.eq(GA.live[1].acc, 5, "the better accuracy is kept")
  W.soft = { guid = "GameObject-0-1-2-3-9999-0000", name = "Battered Chest" }
  H.eq(GA.checkNear(), false, "a chest is never shared")
  W.soft = { guid = "Creature-0-1-2-3-99-0000", name = "Peacebloom" }
  H.eq(GA.checkNear(), false, "only GameObjects count")
  W.combat = true
  W.soft = { guid = "GameObject-0-1-2-3-1731-0001", name = "Copper Vein" }
  H.eq(GA.checkNear(), false, "never in combat")
  W.combat = false
  H.ok(GA.checkNear(), "a vein after combat")
  H.eq(GA.nearSeen.H, 1, "diag counts herbs seen nearby")
  H.ok(GA.nearSeen.O == 1 and GA.nearSeen.other >= 1, "and veins and other objects")
  -- gathered: Herb Gathering on a learned name
  W.sent = {}
  W.pos = { x = 0.6, y = 0.6 }
  W.fire("UNIT_SPELLCAST_SENT", "player", "Ghostcap", "cast-1", 2366)
  W.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 2366)
  H.eq(sentG(W, "G|")[1], "G|H|1426|6000|6000|Ghostcap", "gathered: G message at the player's spot")
  H.eq(ns.GatherNames.classify("Ghostcap"), "H", "the gathered name is learned as a herb")
  H.eq(#W.acted, 0, "nothing acted")
  -- share off: nothing goes out
  W.sent = {}
  ns.Gather.set("share", false)
  W.soft = { guid = "GameObject-0-1-2-3-1618-0009", name = "Silverleaf", reach = true }
  GA.checkNear()
  H.eq(#sentG(W), 0, "Share off: nothing is sent")
end

-- ------------------------------------------------------------------ 7. known spots: ask and answer, limits, names
do
  local W, ns = boot("Rup")
  local GA, GS = ns.Gather, ns.GatherSpots
  GS.clear()
  for i = 1, 5 do GS.record("H", "Peacebloom", MAP, 0.5 + i / 20, 0.5, 5, true) end
  GS.record("H", "Peacebloom", MAP, 0.555, 0.5, 5, true)
  H.eq(GS.count(MAP), 5, "a sighting 5 yd from a known spot updates it")
  W.sent = {}
  deliver(W, "Rip", GA.encodeAsk(MAP, 0.5, 0.5))
  local s = sentG(W, "S|")
  H.ok(#s >= 1, "a squad member's ask gets the known spots near it")
  local d = GA.decode(s[1])
  H.eq(d and #d.spots, 5, "all five spots in the answer")
  local W2, ns2 = boot("Rip")
  ns2.GatherSpots.clear()
  deliver(W2, "Rup", s[1])
  H.eq(ns2.GatherSpots.count(MAP), 5, "the answer becomes known spots (received)")
  local own = false
  for _, x in ipairs(ns2.GatherSpots.onMap(MAP)) do if x.m then own = true end end
  H.ok(not own, "received spots are not marked as seen by this character")
  H.eq(ns.GatherNames.classify("Poor Copper Vein"), "O", "vein names by shape")
  H.eq(ns.GatherNames.classify("Églantine"), "H", "French names, accents")
  H.eq(ns.GatherNames.classify("Rip"), nil, "a player name is not a resource")
end

-- ------------------------------------------------------------------ 8. Questie's zone table: read as data, never run
do
  local _, ns = boot("Rip")
  local SP = ns.GatherSpawns
  local t, any = SP.parseAreaTable("return {\n [1] = 1426, -- Dun Morogh\n [2] = 1436,\n [0] = 0, os.exit(1), [3] = 'x' }")
  H.ok(any and t[1] == 1426 and t[2] == 1436 and t[0] == nil and t[3] == nil, "only [number] = number pairs; 0 removes; the rest is ignored")
  H.eq(SP.state(), "absent", "without QuestieDB: spawn points absent")
end
do
  local W, ns = boot("Rip")
  local objs = { [1618] = { [1] = { { 50, 50 }, { 60, 40 } }, [9] = { { 10, 10 } } }, [1731] = { [1] = { { 50, 50 } } } }
  W.env.LibQuestieDB = { RequireContract = function(v) return v == 4 end,
    Object = { spawns = function(id) return objs[id] end, name = function(id) return id == 1618 and "Peacebloom" or "Copper Vein" end },
    Support = { Get = function(n) if n == "ZoneDB" then return { private = { areaIdToUiMapId = "return { [1] = 1426, [9] = 1411 }" } } end end } }
  local SP = ns.GatherSpawns
  SP.reset()
  H.eq(SP.state(), "ready", "QuestieDB with contract 4: ready")
  H.eq(SP.onMap(MAP), nil, "the first ask starts building the map")
  for _ = 1, 30 do W.flush() end
  local pts = SP.onMap(MAP)
  H.eq(pts and #pts, 3, "map 1426: two herb points and one vein point (another zone's point left out)")
  ns.Gather.set("spawns", true)
  ns.GatherSpots.clear()
  local GP = ns.GatherPins
  W.radius = 200
  GP.refreshMinimap()
  local spawnPins, name = 0, nil
  for _, b in pairs(GP.mini.active) do if b.item.status == "spawn" then spawnPins = spawnPins + 1; name = GP.tooltipLines(b.item)[1] end end
  H.ok(spawnPins >= 2 and (name == "Peacebloom" or name == "Copper Vein"), "spawn pins show, named from QuestieDB (" .. spawnPins .. ")")
end

-- ------------------------------------------------------------------ 9. status, diagnose, slash, the Setup page
do
  local W, ns = boot("Rip")
  local GA = ns.Gather
  local line = GA.statusLine()
  H.ok(line:find("share on", 1, true) and line:find("show on", 1, true) and line:find("no data from Rap, Rup", 1, true), "status line: " .. line)
  deliver(W, "Rap", "N|H|1426|5000|5000|n|5|0|Peacebloom")
  H.ok(not GA.statusLine():find("Rap,", 1, true), "a member that sent something is not 'no data' any more")
  local d = GA.diag()
  H.ok(d.probe and d.probe.map and d.stats and d.near and d.professions, "diag.gather has probe, stats, near counts and professions")
  local r = ns.Core.selftest(true)
  H.ok(type(r.gather) == "table" and r.gather.on, "selftest writes diag.gather")
  W.chat = {}
  ns.Core.slash("gather")
  H.ok(W.chatHas("Gathering:"), "/wbx gather prints the status")
  ns.UI.Open("setup")
  H.ok(ns.UI.panels.setup.gatherBtn ~= nil, "Setup has a Gathering… button")
  ns.UI.panels.setup.gatherBtn:Click()
  H.eq(ns.UI.current, "gather", "it opens the Gathering page")
  H.eq(ns.UI.tabButtons.gather, nil, "the Gathering page has no rail row of its own")
  local p = ns.UI.panels.gather
  H.ok(p.status:GetText() and p.status:GetText():find("share", 1, true), "the page shows the status line")
  local seen = {}
  for _, c in ipairs(p.ticks) do seen[c.key] = true end
  H.ok(seen.share and seen.show and seen.worldmap and seen.spawns and seen.spots, "share, show, world map, spawn points, known spots")
  for _, c in ipairs(p.ticks) do if c.key == "share" then c:Click() end end
  H.eq(ns.Core.db.settings.gather.share, false, "the Share tick turns sharing off")
end

-- ------------------------------------------------------------------ 9b. a login writes nothing to SavedVariables
do
  local _, ns = boot("Rap")
  H.eq(ns.Core.db.gather, nil, "no WoWBoxerDB.gather before the first spot")
  H.eq(ns.Core.db.settings.gather, nil, "no settings.gather before the first change")
  ns.GatherSpots.record("H", "Peacebloom", MAP, 0.5, 0.5, 5, true)
  H.ok(ns.Core.db.gather and ns.Core.db.gather.spots[MAP] and #ns.Core.db.gather.spots[MAP] == 1, "the first spot is saved")
  ns.GatherNames.learn("H", "Ghostcap")
  H.ok(ns.Core.db.gather.learned.H.ghostcap == "Ghostcap", "a learned name is saved")
end

-- ------------------------------------------------------------------ 10. Classic Era: what the game lacks is hidden
do
  local W, ns = boot("Rip")
  W.cvars.SoftTargetInteract = nil
  local probe = ns.Gather.probe()
  H.eq(probe.softTarget, false, "no soft-target CVar: nearby detection not in this game")
  ns.UI.Open("gather")
  H.ok(ns.UI.panels.gather.nearState:GetText():find("Not in this game", 1, true), "the page says so")
  H.ok(not ns.UI.panels.gather.apply:IsEnabled(), "Apply is off")
  H.ok(ns.Gather.statusLine():find("nearby not in this game", 1, true), "and the status line")
end

H.report("gather")
