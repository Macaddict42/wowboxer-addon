-- All spells holds every spell the character can cast, the spells of the talents really spent included (owner,
-- 15 Nov 2026: Rip's Paladin and Rup's Priest spent points and the talent spells were not in All spells; the book
-- scan did not see them and data talent spells only showed when the PLAN had the talent). Third source: the talents
-- spent in the game – C_Traits on Forever (override spells included), GetTalentInfo + the spellbook on Era/TBC.
-- Fakes for every source: the spellbook (with a skill line per tree), C_Traits, GetTalentInfo.
local dir = (arg[0]:match("^(.*)/[^/]+$") or ".")
local H = dofile(dir .. "/harness.lua")
local Mock = dofile(dir .. "/wowmock.lua")

local function boot(opts)
  local W = Mock.new(H, opts)
  local ns = H.loadAddon({ env = W.env })
  W.fire("ADDON_LOADED", "WoWBoxer"); W.fire("PLAYER_LOGIN")
  ns.Core.cdb.guide = "done"
  ns.State.quickStart(ns.Core.db, ns.Core.cdb, ns.Core.playerInfo())
  for _, s in ipairs(ns.Data.spells[(opts.class or "PALADIN"):lower()]) do
    if s.level <= (opts.level or 10) and s.gate ~= "talent" then W.known[s.name] = true end
  end
  return W, ns
end
local function sections(ns, q)
  local secs = ns.Book.spellSections(ns.Core.compute(), q)
  local learned, future, count = {}, {}, {}
  for _, c in ipairs(secs[1].cells) do learned[c.label] = c; count[c.label] = (count[c.label] or 0) + 1 end
  for _, c in ipairs(secs[2].cells) do future[c.label] = c; count[c.label] = (count[c.label] or 0) + 1 end
  return learned, future, count
end

-- A fake C_Traits: nodes = {{spell, spent, name?}}, one tree. overrides = {[base] = override}, passive = {[id] = true}.
local function fakeTraits(W, nodes, names, overrides, passive)
  local G = W.env
  G.C_ClassTalents = { GetActiveConfigID = function() return 77 end }
  G.C_Traits = {
    GetConfigInfo = function(id) return id == 77 and { treeIDs = { 900 } } or nil end,
    GetTreeNodes = function() local t = {}; for i in ipairs(nodes) do t[i] = 5000 + i end return t end,
    GetNodeInfo = function(_, nodeID)
      local n = nodes[nodeID - 5000]
      return { ID = nodeID, ranksPurchased = n.spent, currentRank = n.spent, maxRanks = n.max or 1, entryIDs = { 6000 + nodeID - 5000 },
        activeEntry = n.spent > 0 and { entryID = 6000 + nodeID - 5000 } or nil }
    end,
    GetEntryInfo = function(_, entryID) return { definitionID = 7000 + entryID - 6000 } end,
    GetDefinitionInfo = function(defID) return { spellID = nodes[defID - 7000].spell } end,
  }
  G.C_Spell.GetSpellName = function(id) return names[id] or ("Spell" .. tostring(id)) end
  G.C_Spell.GetOverrideSpell = function(id) return overrides and overrides[id] or id end
  G.C_Spell.IsSpellPassive = function(id) return passive and passive[id] or false end
end

-- ------------------------------------------------------------------ 1. Forever, C_Traits: Rup's priest (owner's diag 15 Nov)
do
  local W, ns = boot({ name = "Rup", class = "PRIEST", race = "Human", level = 30 })
  -- the plan (the default guide) may or may not take Holy Nova; force a plan without it
  local me = ns.Core.compute().member
  me.build = {}
  local names = { [15237] = "Holy Nova", [14908] = "Improved Renew", [14523] = "Wand Specialization", [920001] = "Radiant Lance",
    [920002] = "Radiant Lance II", [920003] = "Inspiration" }
  fakeTraits(W, {
    { spell = 15237, spent = 1 },         -- Holy Nova: a data talent spell outside the plan
    { spell = 14908, spent = 3, max = 3 }, -- Improved Renew: passive talent
    { spell = 14523, spent = 2, max = 2 }, -- Wand Specialization: passive
    { spell = 920001, spent = 1 },        -- a new Forever talent spell the data lacks, overridden by 920002
    { spell = 920003, spent = 0 },        -- not spent
  }, names, { [920001] = 920002 }, { [14908] = true, [14523] = true })
  ns.Compat.invalidateSpellbook()
  local list, src = ns.Compat.talentSpells()
  H.eq(src, "C_Traits", "Forever: the talents come from C_Traits")
  H.eq(#list, 4, "four spent nodes (the unspent one is left out)")
  local learned, future, count = sections(ns)
  H.ok(learned["Holy Nova"] ~= nil, "Holy Nova (spent, not in the plan) is under the learned spells")
  H.ok(learned["Holy Nova"] and learned["Holy Nova"].fromTalents, "Holy Nova: tooltip From your talents")
  H.eq(count["Holy Nova"], 1, "Holy Nova listed once")
  H.ok(learned["Radiant Lance II"] ~= nil, "a new talent spell: the override's game name")
  H.ok(not learned["Radiant Lance"] and not future["Radiant Lance"], "the overridden base spell is not listed")
  local rl = learned["Radiant Lance II"]
  H.eq(rl and rl.spell.ranks[1].id, 920002, "the override's spell id")
  H.eq(rl and rl.spell.icon, 200000 + 920002, "the game's icon")
  H.ok(rl and rl.fromTalents and rl.spell.fromTalents, "the new spell says From your talents")
  H.ok(not learned["Improved Renew"] and not learned["Wand Specialization"], "passive talents are not listed")
  H.ok(not learned["Inspiration"] and not future["Inspiration"], "an unspent talent is not listed")
  -- the tooltip
  local GT = W.env.GameTooltip
  local lines = {}
  local add = GT.AddLine
  GT.AddLine = function(self, t, ...) lines[#lines + 1] = t; return add(self, t, ...) end
  ns.UI.Open("spells")
  local p = ns.UI.panels.spells
  p.query = "radiant"; ns.UI.Refresh()
  local row
  for _, r in ipairs(p.cells or {}) do if r:IsShown() and r.cell and r.cell.label == "Radiant Lance II" then row = r end end
  H.ok(row ~= nil, "the talent card is on the page")
  if row then row:GetScript("OnEnter")(row) end
  H.ok(table.concat(lines, "\n"):find(ns.Book.FROM_TALENTS, 1, true) ~= nil, "tooltip: From your talents")
  GT.AddLine = add
  -- drag: the spell itself (no macro needed), the override's id
  local picked
  W.env.PickupSpell = function(id) picked = id end
  W.env.C_Spell.PickupSpell = function(id) picked = id end
  local ok, why = ns.Core.pickupSpell(rl.spell.id)
  H.ok(ok, "drag a talent spell works (" .. tostring(why) .. ")")
  H.eq(picked, 920002, "the talent's spell goes on the cursor")
  -- Holy Nova drags too (a data spell; cast by its data rules)
  local okHN, whyHN = ns.Core.pickupSpell(learned["Holy Nova"].spell.id)
  H.ok(okHN, "drag Holy Nova works (" .. tostring(whyHN) .. ")")
  -- Edit macro: the spell becomes an own macro, and it resolves (usable) although the plan lacks the talent
  me = ns.Core.compute().member
  local inEditor = {}
  for _, s in ipairs(ns.KeyEditor.spellChoices(me, me.level)) do inEditor[s.name] = true end
  H.ok(inEditor["Holy Nova"] and inEditor["Radiant Lance II"], "the Macro editor offers both talent spells")
  local i = ns.Core.newSingle(learned["Holy Nova"].spell)
  H.ok(i ~= nil, "Edit macro: Holy Nova becomes an own macro")
  local d
  for _, x in ipairs(ns.Core.compute().desired) do if x.name == "WBX C" .. tostring(i) then d = x end end
  H.ok(d and d.body and d.body:find("Holy Nova", 1, true) ~= nil, "the own macro casts Holy Nova: " .. tostring(d and d.body))
  local i2 = ns.Core.newSingle(rl.spell)
  local d2
  for _, x in ipairs(ns.Core.compute().desired) do if x.name == "WBX C" .. tostring(i2) then d2 = x end end
  H.ok(d2 and d2.body and d2.body:find("Radiant Lance II", 1, true) ~= nil, "the own macro casts the new talent spell: " .. tostring(d2 and d2.body))
  -- diag.talentSpells
  local diag = ns.Core.talentSpellsDiag()
  local txt = {}
  for _, x in ipairs(diag.spells) do txt[#txt + 1] = x.name .. "=" .. x.shown end
  H.eq(table.concat(txt, ","), "Holy Nova=data,Improved Renew=passive,Wand Specialization=passive,Radiant Lance II=talent", "diag.talentSpells: " .. table.concat(txt, ","))
  H.eq(diag.source, "C_Traits", "diag.talentSpells source")
  local r = ns.Core.selftest(true)
  H.ok(type(r.talentSpells) == "table" and #r.talentSpells.spells == 4, "selftest writes diag.talentSpells")
  H.ok(type(r.spellbookLines) == "table" and r.spellbookLines[1] and r.spellbookLines[1].items ~= nil, "selftest writes diag.spellbookLines")
  -- unlearn the talent: TRAIT_CONFIG_UPDATED refreshes, Holy Nova leaves the learned spells
  W.env.C_Traits.GetNodeInfo = (function(orig) return function(c, id) local n = orig(c, id); if id == 5001 then n.ranksPurchased, n.currentRank, n.activeEntry = 0, 0, nil end return n end end)(W.env.C_Traits.GetNodeInfo)
  W.fire("TRAIT_CONFIG_UPDATED"); W.flush()
  local l2 = sections(ns)
  H.ok(l2["Holy Nova"] == nil, "talent unlearned + TRAIT_CONFIG_UPDATED: Holy Nova is gone")
  H.ok(l2["Radiant Lance II"] ~= nil, "the other talent spell stays")
  -- the other events refresh too
  for _, ev in ipairs({ "PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED", "SPELLS_CHANGED" }) do
    names[920002] = "Radiant Lance " .. ev
    W.fire(ev); W.flush()
    H.ok(sections(ns)["Radiant Lance " .. ev] ~= nil, ev .. " refreshes the talent spells")
  end
end

-- ------------------------------------------------------------------ 2. no duplicates: book + talents + data
do
  local W, ns = boot({ name = "Rip", class = "PALADIN", race = "Human", level = 30 })
  local G = W.env
  -- the spellbook: a class line with Sense Undead (book only) and Templar's Bulwark (book + talents), plus a tree
  -- line with offSpecID 0 (a client without specs) holding Swift Judgement
  local tabs = {
    { name = "General", items = { { name = "First Aid", id = 3273 } } },
    { name = "Paladin", items = { { name = "Sense Undead", id = 5502 }, { name = "Templar's Bulwark", id = 1311015 } } },
    { name = "Protection", offSpecID = 0, items = { { name = "Swift Judgement", id = 1310994 }, { name = "Redoubt", id = 20127, passive = true } } },
    { name = "Retribution", offSpecID = 70, items = { { name = "Other Spec Spell", id = 930001 } } },
  }
  local flat, off = {}, {}
  for i, t in ipairs(tabs) do off[i] = #flat; for _, it in ipairs(t.items) do flat[#flat + 1] = it end end
  G.Enum = { SpellBookSpellBank = { Player = 0, Pet = 1 }, SpellBookItemType = { Spell = 1, FutureSpell = 2 } }
  G.C_SpellBook = {
    GetNumSpellBookSkillLines = function() return #tabs end,
    GetSpellBookSkillLineInfo = function(i) return { name = tabs[i].name, itemIndexOffset = off[i], numSpellBookItems = #tabs[i].items, offSpecID = tabs[i].offSpecID } end,
    GetSpellBookItemName = function(j) return flat[j] and flat[j].name end,
    GetSpellBookItemInfo = function(j) local it = flat[j]; if not it then return nil end
      return { name = it.name, spellID = it.id, iconID = 100 + it.id, isPassive = it.passive or false, itemType = 1 } end,
  }
  local names = { [1311015] = "Templar's Bulwark", [1224697] = "Sacred Duty", [1310994] = "Swift Judgement", [20127] = "Redoubt" }
  fakeTraits(W, { { spell = 1311015, spent = 1 }, { spell = 1224697, spent = 2, max = 2 }, { spell = 1310994, spent = 1 }, { spell = 20127, spent = 3 } },
    names, nil, { [20127] = true, [1224697] = true })
  ns.Compat.invalidateSpellbook()
  local learned, _, count = sections(ns)
  for n, c in pairs(count) do H.ok(c == 1, n .. " listed once (" .. c .. ")") end
  H.ok(learned["Templar's Bulwark"] and learned["Templar's Bulwark"].fromTalents, "Templar's Bulwark (book + talents): one card, From your talents")
  H.ok(learned["Swift Judgement"] ~= nil, "Swift Judgement listed")
  H.ok(learned["Sense Undead"] and learned["Sense Undead"].fromBook, "Sense Undead: from the spellbook")
  H.ok(not learned["Sacred Duty"] and not learned["Redoubt"], "passive talents are not listed")
  H.ok(not learned["Other Spec Spell"], "a real off-spec line is still skipped")
  -- the book scan now reads a line with offSpecID 0
  local seen = {}
  for _, it in ipairs(ns.Compat.spellbookItems()) do seen[it.name] = true end
  H.ok(seen["Swift Judgement"], "book scan: a line with offSpecID 0 is not off-spec")
  -- diag.spellbookLines: name, offSpecID, shouldHide, item count, passives
  local lines = ns.Compat.spellbookLinesDiag()
  H.eq(#lines, 4, "every skill line in the diagnose")
  H.eq(lines[3].name, "Protection", "line name")
  H.eq(lines[3].offSpecID, 0, "offSpecID")
  H.eq(lines[3].items, 2, "item count")
  H.eq(lines[3].passive, 1, "passive count")
  H.eq(lines[3].skipped, nil, "offSpecID 0 is not skipped")
  H.eq(lines[4].skipped, "offSpec", "a real off-spec line is marked skipped")
  H.eq(lines[1].skipped, "General", "General is marked skipped")
  -- extraSpells no longer double-lists a talent spell
  local ex = {}
  for _, x in ipairs(ns.Core.extraSpellsDiag()) do ex[#ex + 1] = x.name end
  H.eq(table.concat(ex, ","), "Sense Undead", "diag.extraSpells: book-only spells, talent spells not twice")
end

-- ------------------------------------------------------------------ 3. a data spell renamed in the game
do
  local W, ns = boot({ name = "Rup", class = "PRIEST", race = "Human", level = 30 })
  ns.Core.compute().member.build = {}
  fakeTraits(W, { { spell = 15237, spent = 1 } }, { [15237] = "Holy Nova of Light" })
  ns.Compat.invalidateSpellbook()
  local learned, future = sections(ns)
  H.ok(learned["Holy Nova of Light"] ~= nil, "renamed: the game's name is listed")
  H.ok(not learned["Holy Nova"] and not future["Holy Nova"], "renamed: the data's old name is not listed too")
end

-- ------------------------------------------------------------------ 4. Era / TBC: GetTalentInfo + the spellbook
for _, toc in ipairs({ 11509, 20506 }) do
  local W, ns = boot({ name = "Eric", class = "PRIEST", race = "Human", level = 30, toc = toc, spellbookStyle = "classic" })
  ns.Core.compute().member.build = {}
  local G = W.env
  local tabs = {
    { name = "General", items = { { name = "Attack", id = 6603 } } },
    { name = "Holy", items = { { name = "Smite", id = 585 }, { name = "Holy Nova", id = 15237 }, { name = "Holy Nova", id = 15430 }, { name = "Spirit Tap", id = 15270, passive = true } } },
  }
  local flat, off = {}, {}
  for i, t in ipairs(tabs) do off[i] = #flat; for _, it in ipairs(t.items) do flat[#flat + 1] = it end end
  G.GetNumSpellTabs = function() return #tabs end
  G.GetSpellTabInfo = function(i) return tabs[i].name, nil, off[i], #tabs[i].items end
  G.GetSpellBookItemName = function(j) return flat[j] and flat[j].name, "" end
  G.GetSpellBookItemInfo = function(j) local it = flat[j]; if not it then return nil end return "SPELL", it.id end
  G.IsPassiveSpell = function(j) return flat[j] and flat[j].passive or false end
  G.GetSpellBookItemTexture = function(j) return flat[j] and 100 + flat[j].id end
  local talents = { { "Holy Nova", 1 }, { "Spirit Tap", 5 }, { "Improved Renew", 3 }, { "Inner Focus", 0 } }
  G.GetNumTalentTabs = function() return 1 end
  G.GetNumTalents = function() return #talents end
  G.GetTalentInfo = function(_, i) local t = talents[i]; return t[1], 1000 + i, 1, i, t[2], 5 end
  ns.Compat.invalidateSpellbook()
  local list, src = ns.Compat.talentSpells()
  H.eq(src, "GetTalentInfo", toc .. ": talents from GetTalentInfo")
  H.eq(#list, 3, toc .. ": three spent talents")
  H.eq(list[1].id, 15430, toc .. ": Holy Nova's highest rank from the book")
  H.ok(list[2].passive and list[3].passive, toc .. ": a talent without a book spell is passive")
  local learned, _, count = sections(ns)
  H.ok(learned["Holy Nova"] ~= nil and learned["Holy Nova"].fromTalents, toc .. ": Holy Nova (outside the plan) is learned, From your talents")
  H.eq(count["Holy Nova"], 1, toc .. ": Holy Nova once")
  H.ok(not learned["Spirit Tap"] and not learned["Improved Renew"], toc .. ": passives not listed")
end

-- ------------------------------------------------------------------ 5. no talent API (the plain mock): nothing changes
do
  local W, ns = boot({ name = "Plain", class = "PRIEST", race = "Human", level = 30 })
  local list, src = ns.Compat.talentSpells()
  H.eq(list, nil, "no talent API: no talent spells")
  H.eq(src, "none", "source none")
  local me = ns.Core.compute().member
  H.eq(#ns.Kit.liveTalents(me).spells, 0, "no talent cards")
  H.ok(not ns.Kit.gameTalent(me, { name = "Holy Nova" }), "gameTalent false without the API")
  local other = { id = "zz", name = "Other", cls = "priest", race = "human", level = 30 }
  H.eq(ns.Kit.liveTalents(other).live, false, "another member: never the logged-in character's talents")
end

H.report("talent-spells")
