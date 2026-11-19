--[[ WoWBoxer – Gather sharing (02_Spec/Gather-sharing-plan.md): herbs and veins your squad finds, on the leader's minimap.

  Blizzard blocks reading the minimap remotely ("Minimap is off limits", WoWUIBugs#894, Nov 2026). WoWBoxer never
  sweeps, probes or moves the minimap. It builds only on what the game allows:
    1. near     – the soft interact target (unit "softinteract", ~15 yd, automatic): a GameObject GUID and its name.
                  Needs the game's soft-target CVars (Setup → Gathering → Nearby detection: Apply, with backup/restore).
    2. gathered – the spot where this character finished Herb Gathering / Mining (UNIT_SPELLCAST_SUCCEEDED): ±3 yd.
    3. hover    – C_TooltipInfo.GetMinimapMouseover() while the REAL cursor is on a minimap blip (a bonus).
    4. spawn    – QuestieDB spawn points when Questie is installed (GatherSpawns.lua, read-only).
    5. known    – every node seen, saved account-wide and offered to the squad (GatherSpots.lua).
  Nothing here casts, targets, moves, follows, interacts or presses a key: it only READS what the game already chose.

  Messages (prefix WBXG) go through Compat.sendAddon (the outbox waits out AddOnMessageLockdown). They are data only
  (a fixed format, numbers and a cleaned name, never code – hard rule 2) and are accepted only from squad members in
  the party (Auto.member, like every other WoWBoxer message):
    N|k|mapID|x|y|src|acc|age|name   a node seen (k = H herb / O ore; x, y = 0..10000; src = n/g/h/k; acc yd; age s)
    G|k|mapID|x|y|name               gathered: gone for everyone (stays a known spot)
    Q|mapID|x|y                      a member asks for the known spots near it (joined, zoned)
    S|mapID|k,x,y,acc,name;…         known spots near the asker (several messages, each ≤ 255)
  [AFKLAR: whether WBXG messages are paused in instances / encounters on Forever – the outbox logs each lockdown]
  [AFKLAR: does soft interact see herbs on a character WITHOUT Herbalism? diag.gather.near counts what each character
   saw, with its professions; tools/read_log.py prints it] ]]
local _, ns = ...
local GA = {}
ns.Gather = GA

local G = _G
GA.PREFIX = "WBXG"
GA.LIVE_TTL = 120        -- a live node is shown this long after its last sighting
GA.DEDUPE_YARDS = 8      -- the same kind within this on the same map = the same node
GA.REACH = 5             -- accuracy (yd) when the soft target is in interact range
GA.RANGE = 15            -- accuracy beyond it (and the soft target's reach)
GA.GATHER_ACC = 3
GA.HOVER_ACC = 15
GA.RESEND = 25           -- seconds before the same node is sent again
GA.NEAR_REFRESH = 5      -- the same soft target is confirmed this often
GA.TICK = 0.5
GA.ASK_EVERY = 60        -- seconds between two known-spot requests
GA.SNAPSHOT_MAX = 24     -- spots per answer
GA.SRC = { n = "near", g = "gathered", h = "hover", k = "known spot" }
GA.KIND = { H = "Herb", O = "Ore" }

-- the soft-target CVars nearby detection needs (from PartyGatherRadar Detection/Proximity.lua); also in R.CVARS
GA.CVARS = {
  { name = "SoftTargetInteract", value = "3" },             -- soft target always on (keyboard and gamepad)
  { name = "SoftTargetInteractArc", value = "2" },          -- all around the character
  { name = "SoftTargetInteractOnlyInRange", value = "0" },  -- also beyond interact range
  { name = "SoftTargetInteractRange", value = "15", atLeast = true }, -- never lowered
}

local function Core() return ns.Core end
local function C() return ns.Compat end
local function GG() return ns.GatherGeo end
local function GN() return ns.GatherNames end
local function GS() return ns.GatherSpots end
local function now() return (G.GetTime and G.GetTime()) or 0 end
local function secret(v) return C().isSecret(v) end

GA.live = {}            -- {key, k, mapID, x, y, name, acc, src, seen, by = {name = true}, guid, sentAt}
GA.version = 0
GA.stats = { near = 0, gathered = 0, hover = 0, sent = 0, received = 0, dropped = 0 }
GA.lastFrom = {}        -- [member name] = GetTime() of the last WBXG message
GA.nearSeen = { H = 0, O = 0, other = 0 } -- soft interact GameObjects this character saw (AFKLAR herbalism)
local keySeq = 0
local function touch() GA.version = GA.version + 1; if ns.GatherPins and ns.GatherPins.invalidate then ns.GatherPins.invalidate() end end

-- ------------------------------------------------------------------ settings (WoWBoxerDB.settings.gather, account-wide)
GA.OPTIONS = {
  { "share", "Share what I find", "Sends the herbs and veins this character finds (near, gathered, hover) to your squad in the party." },
  { "show", "Show on my minimap", "Shows your squad's finds as pins on this character's minimap. On by default on the leader." },
  { "worldmap", "Show on the world map", "Also shows the pins on the world map when it shows the map you are on." },
  { "spawns", "Spawn points (Questie)", "Faint pins where a herb or vein can grow, from QuestieDB. Needs Questie." },
  { "spots", "Known spots", "Remembers every node seen or gathered and shows it as a quiet pin; shared with the squad on request." },
}
local NONE = {}
--- The options as saved (read only: a login never writes them; wsettings() creates the table on the first change).
local function settings()
  local s = Core().db and Core().db.settings
  return (s and type(s.gather) == "table") and s.gather or NONE
end
local function wsettings()
  local s = Core().db.settings
  if type(s.gather) ~= "table" then s.gather = {} end
  return s.gather
end
local function iAmLeader() local _, me = Core().me(); return me ~= nil and me.leader == true end
function GA.on(key)
  local v = settings()[key]
  if v ~= nil then return v == true end
  if key == "show" then return iAmLeader() end
  return key == "share" or key == "spots"
end
function GA.set(key, v)
  wsettings()[key] = v and true or false
  Core().log("info", "gather " .. key .. (v and " on" or " off"))
  touch()
end

-- ------------------------------------------------------------------ what this game has (probes, never project IDs)
function GA.probe()
  local CI = G.C_TooltipInfo
  return {
    softTarget = C().getCVar("SoftTargetInteract") ~= nil,
    map = (G.C_Map and G.C_Map.GetBestMapForUnit and G.C_Map.GetPlayerMapPosition) and true or false,
    hover = (CI and type(CI.GetMinimapMouseover) == "function") and true or false,
    viewRadius = (G.C_Minimap and G.C_Minimap.GetViewRadius) and true or false,
    shape = GG().shape(),
    questie = ns.GatherSpawns.state(),
  }
end

-- ------------------------------------------------------------------ nearby detection CVars (hard rule 4)
--- The plan for the soft-target CVars: {{name, current, want, change}}; missing CVars are left out.
function GA.cvarPlan()
  local out = {}
  for _, e in ipairs(GA.CVARS) do
    local cur = C().getCVar(e.name)
    if cur ~= nil and not secret(cur) then
      cur = tostring(cur)
      local want = e.value
      if e.atLeast and tonumber(cur) and tonumber(cur) >= tonumber(e.value) then want = cur end
      out[#out + 1] = { name = e.name, current = cur, want = want, change = cur ~= want }
    end
  end
  return out
end
--- Apply them: only after a click, out of combat (Core.whenSafe), old values kept in the CVar backup for Restore.
function GA.applyCVars()
  return Core().whenSafe("Nearby detection", function()
    local cdb = Core().cdb
    cdb.cvarBackup = cdb.cvarBackup or {}
    local n = 0
    for _, c in ipairs(GA.cvarPlan()) do
      if c.change then
        if cdb.cvarBackup[c.name] == nil then cdb.cvarBackup[c.name] = c.current end
        if C().setCVarSure(c.name, c.want) then n = n + 1 end
      end
    end
    wsettings().near = true
    Core().log("info", "gather: nearby detection on (" .. n .. " CVar(s) changed)")
    Core().print("Nearby detection on: " .. n .. " game setting(s) changed. Restore puts them back.")
    touch()
  end)
end
--- Put the soft-target CVars back to the values the backup has (and only those).
function GA.restoreCVars()
  return Core().whenSafe("Nearby detection off", function()
    local cdb = Core().cdb
    local n = 0
    for _, e in ipairs(GA.CVARS) do
      local v = cdb.cvarBackup and cdb.cvarBackup[e.name]
      if v ~= nil then
        if C().setCVarSure(e.name, v) then n = n + 1 end
        cdb.cvarBackup[e.name] = nil
      end
    end
    wsettings().near = false
    Core().log("info", "gather: nearby detection off (" .. n .. " CVar(s) restored)")
    Core().print("Nearby detection off: " .. n .. " game setting(s) restored.")
    touch()
  end)
end
--- Is the game's soft interact target on (SoftTargetInteract 2 or 3)?
function GA.softOn()
  local v = C().getCVar("SoftTargetInteract")
  return v ~= nil and not secret(v) and (tostring(v) == "2" or tostring(v) == "3")
end

-- ------------------------------------------------------------------ the protocol (pure)
local function cleanName(n, extra)
  if type(n) ~= "string" or secret(n) then return "" end
  n = n:gsub("[|%c]", "")
  if extra then n = n:gsub("[,;]", "") end
  return n:sub(1, 60)
end
local function coord(v) return math.floor(v * 10000 + 0.5) end
local function uncoord(s) local n = tonumber(s); if not n or n < 0 or n > 10000 or n ~= math.floor(n) then return nil end return n / 10000 end
local function num(s, lo, hi) local n = tonumber(s); if not n or n < lo or n > hi or n ~= math.floor(n) then return nil end return n end
local KINDS = { H = true, O = true }

function GA.encodeNode(n)
  return table.concat({ "N", n.k, n.mapID, coord(n.x), coord(n.y), n.src, math.floor((n.acc or 15) + 0.5), math.floor((n.age or 0) + 0.5), cleanName(n.name) }, "|")
end
function GA.encodeGathered(n) return table.concat({ "G", n.k, n.mapID, coord(n.x), coord(n.y), cleanName(n.name) }, "|") end
function GA.encodeAsk(mapID, x, y) return table.concat({ "Q", mapID, coord(x), coord(y) }, "|") end
--- Known spots as answer messages, each ≤ 255 characters: {"S|mapID|k,x,y,acc,name;…", …}
function GA.encodeSpots(mapID, spots)
  local out, cur = {}, nil
  for _, s in ipairs(spots) do
    local e = table.concat({ s.k, coord(s.x), coord(s.y), math.floor((s.a or 15) + 0.5), cleanName(s.n, true) }, ",")
    if cur and #cur + 1 + #e > 250 then out[#out + 1] = cur; cur = nil end
    cur = cur and (cur .. ";" .. e) or ("S|" .. mapID .. "|" .. e)
  end
  if cur then out[#out + 1] = cur end
  return out
end
--- A message as data, or nil, why. Never runs anything; every field is checked.
function GA.decode(text)
  if type(text) ~= "string" or #text > 255 then return nil, "bad text" end
  local f = {}
  for x in (text .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
  local t = f[1]
  if t == "N" or t == "G" then
    local k, mapID, x, y = f[2], num(f[3], 1, 9999999), uncoord(f[4]), uncoord(f[5])
    if not (KINDS[k] and mapID and x and y) then return nil, "bad node" end
    if t == "G" then return { t = "G", k = k, mapID = mapID, x = x, y = y, name = cleanName(f[6]) } end
    local src, acc, age = f[6], num(f[7], 1, 100), num(f[8], 0, 86400)
    if not (GA.SRC[src] and acc and age) then return nil, "bad node" end
    return { t = "N", k = k, mapID = mapID, x = x, y = y, src = src, acc = acc, age = age, name = cleanName(f[9]) }
  elseif t == "Q" then
    local mapID, x, y = num(f[2], 1, 9999999), uncoord(f[3]), uncoord(f[4])
    if not (mapID and x and y) then return nil, "bad ask" end
    return { t = "Q", mapID = mapID, x = x, y = y }
  elseif t == "S" then
    local mapID = num(f[2], 1, 9999999)
    if not mapID then return nil, "bad spots" end
    local spots = {}
    for e in ((f[3] or "") .. ";"):gmatch("([^;]*);") do
      local k, x, y, acc, name = e:match("^([HO]),(%d+),(%d+),(%d+),([^,]*)$")
      x, y, acc = uncoord(x), uncoord(y), num(acc, 1, 100)
      if k and x and y and acc then spots[#spots + 1] = { k = k, x = x, y = y, acc = acc, name = name } end
    end
    return { t = "S", mapID = mapID, spots = spots }
  end
  return nil, "unknown kind"
end

-- ------------------------------------------------------------------ live nodes (dedupe, expiry)
local function near(a, mapID, x, y, yards)
  if a.mapID ~= mapID then return false end
  local w, h = GG().mapSize(mapID)
  if w then return GG().distance(w, h, a.x, a.y, x, y) <= yards end
  return math.abs(a.x - x) < 0.0015 and math.abs(a.y - y) < 0.0015
end
--- Add or merge a sighting. Returns the live node and true when it is new.
function GA.addLive(n)
  for _, a in ipairs(GA.live) do
    if a.k == n.k and ((n.guid and a.guid == n.guid) or near(a, n.mapID, n.x, n.y, GA.DEDUPE_YARDS)) then
      if (n.acc or 15) <= a.acc then a.x, a.y, a.acc, a.mapID = n.x, n.y, n.acc or 15, n.mapID end
      a.seen = math.max(a.seen, n.seen)
      if n.name and n.name ~= "" then a.name = n.name end
      if n.by then a.by[n.by] = true end
      if n.src == "n" or n.src == "g" then a.src = n.src end
      a.guid = a.guid or n.guid
      touch()
      return a, false
    end
  end
  keySeq = keySeq + 1
  local a = { key = "live" .. keySeq, k = n.k, mapID = n.mapID, x = n.x, y = n.y, name = n.name, acc = n.acc or 15, src = n.src,
    seen = n.seen, by = {}, guid = n.guid }
  if n.by then a.by[n.by] = true end
  GA.live[#GA.live + 1] = a
  touch()
  return a, true
end
--- Remove the live nodes a gather took (same kind within 15 yd). Returns how many.
function GA.removeLive(k, mapID, x, y)
  local n = 0
  for i = #GA.live, 1, -1 do
    local a = GA.live[i]
    if a.k == k and near(a, mapID, x, y, GA.RANGE) then table.remove(GA.live, i); n = n + 1 end
  end
  if n > 0 then touch() end
  return n
end
function GA.expire(t)
  t = t or now()
  local n = 0
  for i = #GA.live, 1, -1 do if t - GA.live[i].seen > GA.LIVE_TTL then table.remove(GA.live, i); n = n + 1 end end
  if n > 0 then touch() end
  return n
end

-- ------------------------------------------------------------------ reporting and sending
local function send(msg, what, latest)
  if not C().inParty() then return false end
  local ok = C().sendAddon(GA.PREFIX, msg, (G.IsInRaid and G.IsInRaid()) and "RAID" or "PARTY", "gather " .. what, false, latest and { latest = latest } or nil)
  if ok then GA.stats.sent = GA.stats.sent + 1 end
  return ok
end
--- This character found a node (near, gathered, hover). Kept live, as a known spot, and sent when Share is on.
function GA.found(k, name, mapID, x, y, acc, src, guid)
  local me = C().playerName()
  local a = GA.addLive({ k = k, name = name, mapID = mapID, x = x, y = y, acc = acc, src = src, seen = now(), by = me, guid = guid })
  if GA.on("spots") then GS().record(k, name, mapID, x, y, acc, true) end
  if GA.on("share") and (not a.sentAt or now() - a.sentAt >= GA.RESEND) then
    a.sentAt = now()
    send(GA.encodeNode({ k = k, mapID = a.mapID, x = a.x, y = a.y, src = src, acc = a.acc, age = 0, name = a.name }), "node", "node" .. a.key)
  end
  return a
end
--- This character gathered a node: gone for everyone.
function GA.gathered(k, name, mapID, x, y)
  GA.stats.gathered = GA.stats.gathered + 1
  GA.removeLive(k, mapID, x, y)
  if GA.on("spots") then GS().record(k, name, mapID, x, y, GA.GATHER_ACC, true); GS().markGathered(k, mapID, x, y, GA.GATHER_ACC) end
  if GA.on("share") then send(GA.encodeGathered({ k = k, mapID = mapID, x = x, y = y, name = name }), "gathered") end
  touch()
end

-- ------------------------------------------------------------------ 1. near: the soft interact target
local UNIT = "softinteract"
local lastGUID, lastReach, lastAt = nil, nil, -1e9
local function unitCall(fn)
  if not fn then return nil end
  local ok, v = pcall(fn, UNIT)
  if not ok or secret(v) then return nil end
  return v
end
--- Read the soft target; report a herb or vein newly targeted, now in reach, or still targeted after NEAR_REFRESH.
function GA.checkNear(t)
  t = t or now()
  if not settings().near or C().inCombat() then lastGUID = nil; return false end
  local guid = unitCall(G.UnitGUID)
  if type(guid) ~= "string" or guid:match("^([^%-]+)") ~= "GameObject" then lastGUID = nil; return false end
  local name = unitCall(G.UnitName)
  local k = type(name) == "string" and GN().classify(name) or nil
  if guid ~= lastGUID then GA.nearSeen[k or "other"] = (GA.nearSeen[k or "other"] or 0) + 1 end
  if not k then lastGUID = guid; return false end -- chests, mailboxes, quest objects: never shared
  local reach = unitCall(G.UnitIsInInteractRange) == true
  if guid == lastGUID and (lastReach or not reach) and t - lastAt < GA.NEAR_REFRESH then return false end
  local mapID, x, y = GG().playerPosition()
  if not mapID then return false end
  lastGUID, lastReach, lastAt = guid, reach, t
  GA.stats.near = GA.stats.near + 1
  GA.found(k, name, mapID, x, y, reach and GA.REACH or GA.RANGE, "n", guid)
  return true
end

-- ------------------------------------------------------------------ 2. gathered: Herb Gathering / Mining finished
local pendingCast
local function gatherKind(spellID)
  local D = ns.Data and ns.Data.gather
  if D then
    for _, id in ipairs(D.herb or {}) do if id == spellID then return "H" end end
    for _, id in ipairs(D.ore or {}) do if id == spellID then return "O" end end
  end
  -- other ranks or Forever's own IDs: compare with the client's own spell names
  local CS = G.C_Spell
  local nameOf = (CS and CS.GetSpellName) or G.GetSpellInfo
  if nameOf and spellID then
    local ok, n = pcall(nameOf, spellID)
    if ok and type(n) == "string" and not secret(n) then
      local okH, h = pcall(nameOf, 2366)
      local okM, mi = pcall(nameOf, 2575)
      if okH and n == h then return "H" end
      if okM and n == mi then return "O" end
    end
  end
  return nil
end
function GA.onCastSent(unit, target, castGUID, spellID)
  if unit ~= "player" or secret(target) or secret(spellID) or type(target) ~= "string" or target == "" then return end
  local k = gatherKind(spellID)
  if not k then return end
  pendingCast = { guid = castGUID, k = k, name = target }
  if GN().learn(k, target) then Core().log("info", "gather: learned the name " .. target .. " (" .. GA.KIND[k] .. ")") end
end
function GA.onCastSucceeded(unit, castGUID)
  if unit ~= "player" or not pendingCast or (castGUID ~= nil and pendingCast.guid ~= nil and castGUID ~= pendingCast.guid) then return end
  local p = pendingCast
  pendingCast = nil
  local mapID, x, y = GG().playerPosition()
  if mapID then GA.gathered(p.k, p.name, mapID, x, y) end
end

-- ------------------------------------------------------------------ 3. hover: the real cursor on a minimap blip
--- Names under the real cursor on the minimap (C_TooltipInfo.GetMinimapMouseover), with where the cursor points.
function GA.checkHover()
  local mm, CI = G.Minimap, G.C_TooltipInfo
  if not (mm and CI and type(CI.GetMinimapMouseover) == "function" and mm.IsMouseOver) then return false end
  local okM, over = pcall(mm.IsMouseOver, mm)
  if not okM or not over or C().inCombat() then return false end
  local ok, info = pcall(CI.GetMinimapMouseover)
  if not ok or type(info) ~= "table" or type(info.lines) ~= "table" then return false end
  local mapID, px, py = GG().playerPosition()
  if not mapID then return false end
  local w, h = GG().mapSize(mapID)
  local radius = GG().minimapRadius()
  if not (w and radius and G.GetCursorPosition and mm.GetCenter) then return false end
  local facing
  if tostring(C().getCVar("rotateMinimap")) == "1" then
    facing = G.GetPlayerFacing and G.GetPlayerFacing()
    if facing == nil or secret(facing) then return false end
  end
  local cx, cy = G.GetCursorPosition()
  local scale = mm:GetEffectiveScale()
  local mx, my = mm:GetCenter()
  if secret(cx) or secret(mx) or not (cx and mx and scale) then return false end
  local east, north = GG().unproject(cx / scale - mx, cy / scale - my, radius, mm:GetWidth() / 2, mm:GetHeight() / 2, facing)
  local x, y = GG().applyOffset(w, h, px, py, east, north)
  if not (GG().isCoord(x) and GG().isCoord(y)) then return false end
  local any = false
  for _, line in ipairs(info.lines) do
    local text = type(line) == "table" and line.leftText
    if type(text) == "string" and not secret(text) then
      for name in (text .. "\n"):gmatch("([^\n]*)\n") do
        name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
        local k = GN().classify(name)
        if k then GA.stats.hover = GA.stats.hover + 1; GA.found(k, name, mapID, x, y, GA.HOVER_ACC, "h"); any = true end
      end
    end
  end
  return any
end

-- ------------------------------------------------------------------ receiving (data only, squad members in the party)
function GA.receive(prefix, text, _, sender)
  if prefix ~= GA.PREFIX or type(text) ~= "string" or #text > 255 then return end
  C().arrived(prefix, sender)
  if C().sameName(sender, C().playerName()) then return end
  local m = ns.Auto.member(sender, true)
  if not m then GA.stats.dropped = GA.stats.dropped + 1; return C().drop(prefix, sender, "not a squad member in your party (name not matched)") end
  local msg, why = GA.decode(text)
  if not msg then GA.stats.dropped = GA.stats.dropped + 1; Core().log("warn", "gather: bad message from " .. m.name .. " (" .. tostring(why) .. ")"); return end
  GA.lastFrom[m.name] = now()
  GA.stats.received = GA.stats.received + 1
  if msg.t == "N" then
    GA.addLive({ k = msg.k, name = msg.name, mapID = msg.mapID, x = msg.x, y = msg.y, acc = msg.acc, src = msg.src, seen = now() - msg.age, by = m.name })
    if GA.on("spots") then GS().record(msg.k, msg.name, msg.mapID, msg.x, msg.y, msg.acc, false) end
  elseif msg.t == "G" then
    GA.removeLive(msg.k, msg.mapID, msg.x, msg.y)
    if GA.on("spots") then GS().record(msg.k, msg.name, msg.mapID, msg.x, msg.y, GA.GATHER_ACC, false); GS().markGathered(msg.k, msg.mapID, msg.x, msg.y, GA.GATHER_ACC) end
    touch()
  elseif msg.t == "Q" then
    if GA.on("spots") and GA.on("share") then
      for _, s in ipairs(GA.encodeSpots(msg.mapID, GS().nearest(msg.mapID, msg.x, msg.y, GA.SNAPSHOT_MAX))) do send(s, "spots") end
    end
  elseif msg.t == "S" then
    if GA.on("spots") then for _, s in ipairs(msg.spots) do GS().record(s.k, s.name, msg.mapID, s.x, s.y, s.acc, false) end end
    touch()
  end
end
--- Ask the squad for the known spots around here (joined a party, zoned) – at most once a minute.
GA.askedAt = -1e9
function GA.ask(force)
  if not (GA.on("show") and GA.on("spots")) or (not force and now() - GA.askedAt < GA.ASK_EVERY) then return false end
  local mapID, x, y = GG().playerPosition()
  if not mapID then return false end
  GA.askedAt = now()
  return send(GA.encodeAsk(mapID, x, y), "ask")
end

-- ------------------------------------------------------------------ status and diagnose
function GA.professions()
  local f = G.IsPlayerSpell or G.IsSpellKnown
  local names = C().knownSpellNames and C().knownSpellNames() or {}
  local function has(id, n) if f then local ok, y = pcall(f, id); if ok and y then return true end end return names[n] == true end
  return { herb = has(2366, "Herb Gathering") or has(2383, "Find Herbs"), mine = has(2575, "Mining") or has(2580, "Find Minerals") }
end
--- Squad members in the party that sent nothing yet ("no data from <name>": trial accounts can't send addon messages).
function GA.silent()
  local s, me = Core().me()
  local out = {}
  for _, m in ipairs(s and s.members or {}) do
    if m ~= me and ns.Squad.unitOf(C().baseName(m.name) or m.name) and not GA.lastFrom[m.name] then out[#out + 1] = m.name end
  end
  return out
end
function GA.statusLine()
  local p = GA.probe()
  local mapID = GG().playerPosition()
  local parts = {
    "share " .. (GA.on("share") and "on" or "off"),
    "show " .. (GA.on("show") and "on" or "off") .. (GA.on("worldmap") and " (+ world map)" or ""),
    "nearby " .. (not p.softTarget and "not in this game" or (settings().near and (GA.softOn() and "on" or "on, but the game's soft target is off") or "off")),
    #GA.live .. " live",
    GS().count() .. " known spots" .. (mapID and (" (" .. GS().count(mapID) .. " here)") or ""),
    "spawn points " .. (GA.on("spawns") and p.questie or "off"),
  }
  local silent = GA.silent()
  if #silent > 0 then parts[#parts + 1] = "no data from " .. table.concat(silent, ", ") end
  if G.IsTrialAccount and G.IsTrialAccount() then parts[#parts + 1] = "trial account: the game sends no addon messages" end
  return table.concat(parts, " · ")
end
function GA.diag()
  local prof = GA.professions()
  return { probe = GA.probe(), on = { share = GA.on("share"), show = GA.on("show"), worldmap = GA.on("worldmap"), spawns = GA.on("spawns"), spots = GA.on("spots"),
    near = settings().near and true or false }, softOn = GA.softOn(), cvars = GA.cvarPlan(), stats = GA.stats, near = GA.nearSeen,
    professions = prof, live = #GA.live, spots = GS().count(), silent = GA.silent(), pgr = C().addonState("PartyGatherRadar") }
end
function GA.slash(rest)
  rest = (rest or ""):lower()
  if rest == "clear" then Core().print("Gathering: " .. GS().clear() .. " known spot(s) forgotten."); touch(); return end
  if rest == "ask" then GA.ask(true) end
  Core().print("Gathering: " .. GA.statusLine() .. ". Setup → Gathering… for the options.")
end
--- Forget every known spot (Setup → Gathering → Clear).
function GA.clearSpots() local n = GS().clear(); Core().log("info", "gather: " .. n .. " known spot(s) cleared"); touch(); return n end

-- ------------------------------------------------------------------ events
local f = CreateFrame("Frame")
GA.frame = f
function GA.Init()
  local db = Core().db
  local g = type(db.gather) == "table" and db.gather or {}
  -- the saved tables are only written into WoWBoxerDB on the first spot / learned name (a login never writes)
  local function keep(key) return function(t) if type(db.gather) ~= "table" then db.gather = g end db.gather[key] = t end end
  GS().attach(type(g.spots) == "table" and g.spots or {}, keep("spots"))
  GN().attach(type(g.learned) == "table" and g.learned or {}, keep("learned"))
  local CI = G.C_ChatInfo
  local regp = (CI and CI.RegisterAddonMessagePrefix) or G.RegisterAddonMessagePrefix
  if regp then pcall(regp, GA.PREFIX) end
  for _, ev in ipairs({ "CHAT_MSG_ADDON", "PLAYER_SOFT_INTERACT_CHANGED", "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED",
    "GROUP_ROSTER_UPDATE", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do pcall(f.RegisterEvent, f, ev) end
  if G.C_Timer and G.C_Timer.NewTicker then
    pcall(G.C_Timer.NewTicker, GA.TICK, function()
      local ok, err = pcall(function()
        GA.checkNear()
        GA.expire()
        if GA.on("share") then GA.checkHover() end
      end)
      if not ok then Core().log("error", "gather tick: " .. tostring(err)) end
    end)
  end
  local wm = G.WorldMapFrame
  if wm and wm.HookScript then pcall(wm.HookScript, wm, "OnShow", function() if ns.GatherPins then ns.GatherPins.invalidate() end end) end
  touch()
  if C().addonState("PartyGatherRadar") == "loaded" then
    Core().log("info", "gather: PartyGatherRadar is loaded too")
    if not g.pgrTold then
      g.pgrTold = true
      db.gather = g
      Core().print("PartyGatherRadar is on too: one node may show two pins. Setup → Gathering… → untick Show on my minimap to hide WoWBoxer's.")
    end
  end
end
f:SetScript("OnEvent", function(_, event, a, b, c, d)
  if not Core().db then return end
  local ok, err = pcall(function()
    if event == "CHAT_MSG_ADDON" then GA.receive(a, b, c, d)
    elseif event == "PLAYER_SOFT_INTERACT_CHANGED" then GA.checkNear()
    elseif event == "UNIT_SPELLCAST_SENT" then GA.onCastSent(a, b, c, d)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then GA.onCastSucceeded(a, b)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then GA.ask(); touch()
    end
  end)
  if not ok then Core().log("error", "gather " .. event .. ": " .. tostring(err)) end
end)

return GA
