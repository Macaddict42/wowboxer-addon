--[[ WoWBoxer – Setup → Gathering… (02_Spec/Gather-sharing-plan.md): share, show, world map, spawn points, known spots
  (+ Clear), nearby detection with Apply / Restore, and one status line. A page of Setup (no rail row of its own).
  Settings live in WoWBoxerDB.settings.gather (account-wide); the CVars only change after the Apply click, out of
  combat, with the old values kept for Restore. ]]
local _, ns = ...
local UI, W = ns.UI, ns.Widgets
local tab = { key = "gather", label = "Gathering", icon = "INV_Misc_Flower_02", hidden = true,
  tip = "Herbs and veins your squad finds, on the leader's minimap." }

local function GA() return ns.Gather end

function tab.build(p)
  p.title = W.text(p, "GameFontNormalLarge", 15, W.GOLD)
  p.title:SetPoint("TOPLEFT", 2, -2)
  p.title:SetText("Gathering")
  p.title.wbxCopy = "label"
  p.back = W.button(p, "‹ Setup", 80, 22, function() UI.Select("setup") end, "Back to Setup.")
  p.back:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
  p.sub = W.text(p, "GameFontHighlightSmall", nil, W.MUTED)
  p.sub:SetPoint("TOPLEFT", 2, -24)
  p.sub:SetWidth(640)
  p.sub:SetText("Your squad's herbs and veins on your minimap")
  p.sub.wbxCopy = "hint"
  p.ticks = {}
  for i, o in ipairs(GA().OPTIONS) do
    local key = o[1]
    local c = W.check(p, o[2], function(_, v) GA().set(key, v); UI.Refresh() end)
    c:SetPoint("TOPLEFT", -2, -50 - (i - 1) * 34)
    c.line = W.line(p, "GameFontHighlightSmall", 10, W.MUTED)
    c.line:SetPoint("TOPLEFT", 24, -50 - (i - 1) * 34 - 19)
    c.line:SetWidth(330)
    c.line:SetText(o[3])
    c.line.wbxCopy = "data"
    W.tip(c, o[2], o[3])
    c.key = key
    p.ticks[#p.ticks + 1] = c
  end
  local y = -50 - #GA().OPTIONS * 34
  p.clear = W.button(p, "Clear spots", 100, 22, function()
    UI.Popup("Forget every known spot on this account?", {
      { "Clear", function() GA().clearSpots(); UI.Refresh() end, "Removes every saved herb and vein spot." },
      { "Cancel", function() end, "Keeps them." } })
  end, "Forgets every saved herb and vein spot on this WoW account.")
  p.clear:SetPoint("TOPLEFT", 24, y - 4)

  -- nearby detection (the soft-target CVars)
  local X = 380
  p.nearTitle = W.text(p, "GameFontNormal", nil, W.GOLD)
  p.nearTitle:SetPoint("TOPLEFT", X, -50)
  p.nearTitle:SetText("Nearby detection")
  p.nearLine = W.text(p, "GameFontHighlightSmall", nil, W.MUTED)
  p.nearLine:SetPoint("TOPLEFT", X, -68)
  p.nearLine:SetWidth(280)
  p.nearLine:SetText("Finds nodes within about 15 yards")
  p.nearLine.wbxCopy = "hint"
  p.apply = W.button(p, "Apply", 80, 22, function() GA().applyCVars() end,
    "Sees herbs and veins within about 15 yards by itself, on every character. It turns on the game's soft interact target, so your Interact keybind also targets nearby objects. Sets SoftTargetInteract 3, SoftTargetInteractArc 2, SoftTargetInteractOnlyInRange 0 and SoftTargetInteractRange at least 15. Out of combat only; Restore puts the old values back.")
  p.apply:SetPoint("TOPLEFT", X, -130)
  p.restore = W.button(p, "Restore", 80, 22, function() GA().restoreCVars() end, "Puts the game settings back as they were before Apply and turns nearby detection off.")
  p.restore:SetPoint("LEFT", p.apply, "RIGHT", 6, 0)
  p.nearState = W.text(p, "GameFontHighlightSmall", nil, W.TEXT)
  p.nearState:SetPoint("TOPLEFT", X, -158)
  p.nearState:SetWidth(280)
  p.nearState.wbxCopy = "data"

  p.status = W.text(p, "GameFontHighlightSmall", nil, W.TEXT)
  p.status:SetPoint("BOTTOMLEFT", 2, 6)
  p.status:SetWidth(660)
  p.status.wbxCopy = "data"
  p.credit = W.text(p, "GameFontHighlightSmall", 10, W.MUTED)
  p.credit:SetPoint("BOTTOMLEFT", p.status, "TOPLEFT", 0, 6)
  p.credit:SetWidth(660)
  p.credit:SetText("Parts from PartyGatherRadar (MIT, C. Vandermeulen)")
  p.credit.wbxCopy = "hint"
end

function tab.refresh(p)
  local probe = GA().probe()
  for _, c in ipairs(p.ticks) do
    c:SetChecked(GA().on(c.key))
    if c.key == "spawns" and probe.questie ~= "ready" and probe.questie ~= "building" then
      c.line:SetText("Faint pins where a herb or vein can grow, from QuestieDB – " .. (probe.questie == "absent" and "install Questie to use it." or ("QuestieDB not usable (" .. tostring(probe.questie) .. ").")))
    end
  end
  local db = ns.Core.db
  local nearOn = db and db.settings.gather and db.settings.gather.near
  if not probe.softTarget then
    p.nearState:SetText("Not in this game (no soft interact target).")
    p.apply:SetEnabled(false); p.restore:SetEnabled(false)
  else
    local changes = 0
    for _, c in ipairs(GA().cvarPlan()) do if c.change then changes = changes + 1 end end
    p.nearState:SetText(nearOn and (changes == 0 and "On: the game settings are set." or ("On, but " .. changes .. " game setting(s) changed since – Apply again.")) or "Off.")
    p.apply:SetEnabled(true); p.restore:SetEnabled(nearOn and true or false)
  end
  p.status:SetText(GA().statusLine())
end

UI.RegisterTab(tab)
