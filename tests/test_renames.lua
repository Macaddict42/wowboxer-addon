-- Macros you renamed (Rename..., the name New macro asks for): found under your name in character AND general slots
-- (never made twice), the book shows your name, a renamed key stays a macro, renaming back gives WoWBoxer's name for
-- that slot, deleting an own macro takes its keybinds along, your own text shows the spells it really casts, and the
-- squad Wand macro has its own "leader's target" choice and never keeps a friendly target.
local dir = (arg[0]:match("^(.*)/[^/]+$") or ".")
local H = dofile(dir .. "/harness.lua")
local Mock = dofile(dir .. "/wowmock.lua")

local function boot(opts)
  local W = Mock.new(H, opts)
  local ns = H.loadAddon({ env = W.env })
  W.fire("ADDON_LOADED", "WoWBoxer")
  W.fire("PLAYER_LOGIN")
  for _, s in ipairs(ns.Data.spells[opts.class:lower()]) do if s.level <= opts.level and s.gate ~= "talent" then W.known[s.name] = true end end
  return W, ns
end
local function items(ns) local t = {}; for _, it in ipairs(ns.Core.compute().macros.items) do t[it.name] = it end return t end
local function desired(ns) local t = {}; for _, d in ipairs(ns.Core.compute().desired) do t[d.name] = d end return t end

-- ------------------------------------------------------------------ general (account) slots
do
  local W, ns = boot({ name = "Lock", class = "WARLOCK", race = "Scourge", level = 30, maxChar = 2 })
  local Core, M = ns.Core, ns.Macros
  W.addMacro("Mine", "/cast Fear", true)
  ns.State.quickStart(Core.db, Core.cdb, Core.playerInfo())
  Core.sync()
  local key
  for _, it in pairs(items(ns)) do if it.account and it.status == "same" and not key then key = it.name end end
  H.ok(key ~= nil, "a macro in a general slot: " .. tostring(key))
  local before = #W.acc
  H.ok(Core.renameMacro(key, "Bolt"), "renamed")
  H.ok(W.env.GetMacroIndexByName("Bolt") > 0, "the general macro has your name in the game")
  local it = items(ns)[key]
  H.ok(it.status ~= "create" and it.status ~= "noslot", "found under your name, nothing to create: " .. it.status)
  H.eq(it.gameName, "Bolt", "its game name is yours")
  H.eq(M.findIndex(key), W.env.GetMacroIndexByName("Bolt"), "WoWBoxer finds it (Remove, Pick up)")
  Core.sync()
  H.eq(#W.acc, before, "Update makes no copy")
  H.eq(desired(ns)[key].label, "Bolt", "the book shows your name")
  H.ok(Core.renameMacro(key, ""), "renamed back")
  H.eq(W.env.GetMacroIndexByName("Bolt"), 0, "your name is gone")
  H.ok(W.env.GetMacroIndexByName(M.accountName(key, Core.macroTag())) > 0, "it has WoWBoxer's general-slot name again")
  H.eq(items(ns)[key].status, "same", "and is found as before")
end

-- ------------------------------------------------------------------ labels, plain spells, own text, Wand
do
  local W, ns = boot({ name = "Anna", class = "PRIEST", race = "Scourge", level = 20, party = { party1 = "Dorin" },
    partyInfo = { party1 = { class = "PALADIN", race = "Scourge", level = 20, leader = true } } })
  local Core, M = ns.Core, ns.Macros
  local sq = ns.State.newSquad({ name = "Duo", members = {
    { name = "Dorin", cls = "paladin", race = "undead", role = "tank", leader = true },
    { name = "Anna", cls = "priest", race = "undead", role = "healer", unit = "party1" } } })
  Core.db.squads = { sq }; Core.db.active = sq.id
  Core.cdb.guide = "done"
  Core.cdb.squadKeys = { Wand = true }
  Core.sync()
  -- a plain spell's key that you rename stays a macro
  -- your own text: the spells it really casts
  local _, me = Core.me()
  local idx = ns.KeyEditor.save(me, { name = "", kind = "sequence", aim = "harm", steps = { "Smite" }, filler = "Smite", fills = 1, reset = "combat" })
  local seq = "WBX C" .. tostring(idx)
  H.ok(desired(ns)[seq] and desired(ns)[seq].seq, "an own sequence macro")
  Core.setOverride(seq, { text = "#showtooltip\n/castsequence [harm,nodead] reset=target Shadow Word: Pain, Smite" })
  local d = desired(ns)[seq]
  local names = {}
  for _, s in ipairs(d.steps or {}) do names[#names + 1] = s.name end
  H.eq(table.concat(names, ","), "Shadow Word: Pain,Smite", "the book shows your text's spells, not WoWBoxer's")
  -- the Wand macro: the leader's target, never a friendly one; its own choice beats the switch
  local w = desired(ns)["WBX Wand"].body
  H.ok(w:find("/assist [noharm][dead] Dorin\n/cleartarget [help]\n", 1, true) ~= nil, "Wand: leader's target, a friendly one cleared: " .. w)
  Core.setLine("assist", false)
  H.ok(not desired(ns)["WBX Wand"].body:find("/assist", 1, true), "switch off: the Wand macro shoots your own target")
  Core.cdb.keyLines = { ["WBX Wand"] = { assist = true } }
  H.ok(desired(ns)["WBX Wand"].body:find("/assist", 1, true) ~= nil, "the Wand macro's own choice beats the switch")
end

-- ------------------------------------------------------------------ renaming a key that is the spell itself
do
  local W, ns = boot({ name = "Lock", class = "WARLOCK", race = "Scourge", level = 20 })
  local Core = ns.Core
  ns.State.quickStart(Core.db, Core.cdb, Core.playerInfo())
  Core.cdb.extras = { "warlock-demon-skin", "warlock-life-tap" }
  local plain, spell
  for _, d in ipairs(Core.compute().desired) do if d.plain and not plain then plain, spell = d.name, d.spell end end
  H.ok(plain ~= nil, "a key that is the spell itself on the bar: " .. tostring(plain))
  if plain then
    local id = ns.Compat.bestRankId(spell) or (spell.ranks and spell.ranks[1] and spell.ranks[1].id)
    W.combat = false; W.env.PickupSpell(id); W.env.PlaceAction(40); W.env.ClearCursor()
    H.eq((ns.Compat.actionInfo(40) or {}).kind, "spell", "the spell is on button 40")
    H.ok(Core.renameMacro(plain, "Mine"), "renamed")
    H.ok(not desired(ns)[plain].plain, "it is a macro now")
    H.eq(ns.Book.shortLabel(items(ns)[plain]), "Mine", "the book's label is your name")
    Core.plainToMacro(plain, spell)
    H.ok(W.env.GetMacroIndexByName("Mine") > 0, "the macro is made at once")
    H.eq(W.slotMacroName(40), "Mine", "and takes the spell's button")
    -- the menu offers Rename on such a key
    Core.renameMacro(plain, "")
    ns.UI.Open("keys")
    local cell
    for _, b in ipairs(ns.UI.panels.keys.cells) do if b:IsShown() and b.cell and b.cell.name == plain then cell = b end end
    H.ok(cell ~= nil, "its card on the Macros page")
    if cell then
      cell:Click("RightButton")
      local labels, removeRow = {}, nil
      for _, r in ipairs(ns.Widgets.menuFrame.rows) do
        if r:IsShown() then labels[#labels + 1] = r.label._text; if r.label._text == "Remove" then removeRow = r end end
      end
      H.ok(table.concat(labels, ","):find("Rename…", 1, true) ~= nil, "Rename… in its menu")
      H.ok(table.concat(labels, ","):find("Copy…", 1, true) ~= nil, "Copy… in its menu")
      H.ok(removeRow ~= nil, "Remove in its menu: " .. table.concat(labels, ", "))
      -- Remove: off the list and off its buttons
      W.combat = false; W.env.PickupSpell(id); W.env.PlaceAction(41); W.env.ClearCursor()
      H.eq((ns.Compat.actionInfo(41) or {}).kind, "spell", "the spell is on button 41")
      if removeRow then removeRow:Click() end
      H.eq(ns.Compat.actionInfo(41), nil, "Remove: its button is empty")
      H.eq(items(ns)[plain].status, "skipped", "Remove: WoWBoxer's own key shows as Removed (Use again brings it back)")
    end
  end
end

-- ------------------------------------------------------------------ dual spec: talents of the other spec
-- A talent spell you added from All spells keeps its macro when this spec doesn't have the talent (it is in your
-- other spec): never "no longer used", never offered for removal.
do
  local W, ns = boot({ name = "Lock", class = "WARLOCK", race = "Scourge", level = 40 })
  local Core, M = ns.Core, ns.Macros
  ns.State.quickStart(Core.db, Core.cdb, Core.playerInfo())
  local ctx = Core.compute()
  local talent
  for _, s in ipairs(ns.Data.spells.warlock) do
    if not talent and s.gate == "talent" and s.action ~= "passive" and not ns.Engine.isPlain(s, ns.Kit.memberCtx(ctx.member))
      and M.pendingOf(ctx.member, s, 40, ctx.live) == false then talent = s end -- (a macro, not the spell itself)
  end
  H.ok(talent ~= nil, "a talent spell this character doesn't have and its plan doesn't take: " .. tostring(talent and talent.name))
  if talent then
    Core.cdb.extras = { talent.id }
    local d
    for _, x in ipairs(Core.compute().desired) do if x.key == "X:" .. talent.id then d = x end end
    H.ok(d ~= nil, "its macro is still wanted (it works again in the other spec)")
    H.eq(d and d.pending, "talent", "marked as a talent not taken now")
    if d then W.addMacro(d.name, d.body, true) end -- (made when you dragged it to your bar, in the other spec)
    local m = Core.compute().macros
    local unusedHas = false
    for _, n in ipairs(m.unused or {}) do if d and n == d.name then unusedHas = true end end
    H.ok(d and ns.Macros.findIndex(d.name) ~= nil, "its macro exists")
    H.ok(not unusedHas, "and is not offered for removal")
    H.eq(ns.Book.unlockText("talent"), "Talent not taken now", "the book says why it does nothing now")
  end
end

-- ------------------------------------------------------------------ deleting an own macro takes its keybinds
do
  local W, ns = boot({ name = "Lock", class = "WARLOCK", race = "Scourge", level = 20 })
  local Core, KE = ns.Core, ns.KeyEditor
  ns.State.quickStart(Core.db, Core.cdb, Core.playerInfo())
  local _, me = Core.me()
  for i = 1, 2 do
    local idx = KE.save(me, { name = "", kind = "single", aim = "harm", steps = { "Shadow Bolt" }, filler = "", fills = 1, reset = "combat" })
    H.eq(idx, i, "own macro " .. i)
  end
  Core.sync()
  W.env.SetBindingMacro("F7", "WBX C1")
  KE.delete(me, 1)
  H.ok(W.bindings.F7 ~= "MACRO WBX C1", "the deleted macro's key does not press the one that moved up: " .. tostring(W.bindings.F7))
end

os.exit(H.report("renames") and 0 or 1)
