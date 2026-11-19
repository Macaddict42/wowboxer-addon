--[[ WoWBoxer – Gather sharing: is a name a herb, an ore or something else? (02_Spec/Gather-sharing-plan.md §1)
  The soft interact target and the minimap tooltip also name chests, mailboxes, quest objects and players, so a name
  is only kept when it is known: the herb list, the ore list plus the shape of vein names ("… Vein", "… Deposit"),
  and names learned from a gather cast (the target of Herb Gathering / Mining is a resource; saved account-wide in
  WoWBoxerDB.gather.learned, at most 200 per kind). An unknown name is never shared. Pure, tested headless.

  Ported from PartyGatherRadar 0.6.0, Detection/ResourceNames.lua (comments translated; the English and French client
  names kept; a few Forever names added):

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
local GN = {}
ns.GatherNames = GN

local type, pairs, ipairs, lower, gsub = type, pairs, ipairs, string.lower, string.gsub
GN.MAX_LEARNED = 200

-- accented letters (UTF-8) to their base letter, lower case
local ACCENTS = {
  ["à"] = "a", ["â"] = "a", ["ä"] = "a", ["á"] = "a", ["ã"] = "a", ["À"] = "a", ["Â"] = "a", ["Ä"] = "a",
  ["ç"] = "c", ["Ç"] = "c",
  ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e", ["É"] = "e", ["È"] = "e", ["Ê"] = "e", ["Ë"] = "e",
  ["î"] = "i", ["ï"] = "i", ["í"] = "i", ["Î"] = "i", ["Ï"] = "i",
  ["ô"] = "o", ["ö"] = "o", ["ó"] = "o", ["õ"] = "o", ["Ô"] = "o", ["Ö"] = "o",
  ["û"] = "u", ["ü"] = "u", ["ù"] = "u", ["ú"] = "u", ["Û"] = "u", ["Ü"] = "u", ["Ù"] = "u",
  ["ÿ"] = "y", ["ñ"] = "n", ["Ñ"] = "n", ["œ"] = "oe", ["Œ"] = "oe", ["æ"] = "ae", ["Æ"] = "ae",
  ["’"] = "'", ["\194\160"] = " ",
}

--- The compare form of a name: lower case, no accents, single spaces. nil when unusable (secret, empty).
function GN.normalize(name)
  if type(name) ~= "string" or (ns.Compat and ns.Compat.isSecret and ns.Compat.isSecret(name)) then return nil end
  local t = gsub(name, "[\194-\223][\128-\191]", ACCENTS)
  t = gsub(t, "[\224-\239][\128-\191][\128-\191]", ACCENTS)
  t = lower(t)
  t = gsub(t, "%s+", " ")
  t = gsub(t, "^ ", "")
  t = gsub(t, " $", "")
  if t == "" then return nil end
  return t
end

GN.HERBS = {
  -- English
  "Peacebloom", "Silverleaf", "Earthroot", "Mageroyal", "Briarthorn", "Stranglekelp", "Bruiseweed",
  "Wild Steelbloom", "Grave Moss", "Kingsblood", "Liferoot", "Fadeleaf", "Goldthorn", "Khadgar's Whisker",
  "Wintersbite", "Firebloom", "Purple Lotus", "Arthas' Tears", "Sungrass", "Blindweed", "Ghost Mushroom",
  "Gromsblood", "Golden Sansam", "Dreamfoil", "Mountain Silversage", "Plaguebloom", "Icecap", "Black Lotus",
  "Bloodthistle",
  -- WoW Forever variants and new herbs (PartyGatherRadar's object list) [AFKLAR: exact client names of the new ones]
  "Wilted Peacebloom", "Stunted Silverleaf", "Serpentbloom", "Star Lotus", "Moonroot",
  -- French
  "Pacifique", "Feuillargent", "Terrestrine", "Mage royal", "Églantine", "Étouffante", "Doulourante",
  "Aciérite sauvage", "Tombeline", "Sang-royal", "Vietérule", "Pâlerette", "Dorépine", "Moustache de Khadgar",
  "Hivernale", "Fleur de feu", "Lotus pourpre", "Larmes d'Arthas", "Soleillette", "Aveuglette",
  "Champignon fantôme", "Gromsang", "Sansam doré", "Feuillerêve", "Sauge-argent des montagnes",
  "Fleur de peste", "Calot de glace", "Lotus noir", "Chardon sanglant",
}
GN.ORES = {
  "Copper Vein", "Tin Vein", "Silver Vein", "Iron Deposit", "Gold Vein", "Mithril Deposit",
  "Truesilver Deposit", "Dark Iron Deposit", "Small Thorium Vein", "Rich Thorium Vein",
  "Incendicite Mineral Vein", "Indurium Mineral Vein", "Lesser Bloodstone Deposit", "Small Obsidian Chunk",
  "Large Obsidian Chunk", "Hakkari Thorium Vein", "Chunk of Amber",
  "Filon de cuivre", "Filon d'étain", "Filon d'argent", "Gisement de fer", "Filon d'or", "Gisement de mithril",
  "Gisement de vrai-argent", "Gisement de sombrefer", "Petit filon de thorium", "Riche filon de thorium",
  "Filon d'incendicite", "Filon d'indurium", "Gisement de pierre de sang inférieure",
  "Petit morceau d'obsidienne", "Grand morceau d'obsidienne", "Filon de thorium hakkari",
}
-- the shape of vein names (after normalize): covers variants missing from the list ("Poor Copper Vein")
GN.ORE_PATTERNS = { "^filon ", "^gisement ", "^petit filon ", "^riche filon ", "morceau d'obsidienne$", " vein$", " deposit$", "obsidian chunk$" }

local known = { H = {}, O = {} }
for _, n in ipairs(GN.HERBS) do known.H[GN.normalize(n)] = true end
for _, n in ipairs(GN.ORES) do known.O[GN.normalize(n)] = true end

local learned -- { H = {[normalized] = shown}, O = {...} }
local persist -- called once on the first learned name (a login never writes SavedVariables)

--- Attach the saved learned names (WoWBoxerDB.gather.learned), cleaning anything invalid.
function GN.attach(store, onFirstWrite)
  persist = onFirstWrite
  for _, k in ipairs({ "H", "O" }) do
    if type(store[k]) ~= "table" then store[k] = {} end
    local n = 0
    for key, v in pairs(store[k]) do
      n = n + 1
      if type(key) ~= "string" or type(v) ~= "string" or n > GN.MAX_LEARNED then store[k][key] = nil end
    end
  end
  learned = store
end

--- "H" (herb), "O" (ore) or nil (anything else: never shared).
function GN.classify(name)
  local key = GN.normalize(name)
  if not key then return nil end
  if known.H[key] or (learned and learned.H[key]) then return "H" end
  if known.O[key] or (learned and learned.O[key]) then return "O" end
  for _, p in ipairs(GN.ORE_PATTERNS) do if key:find(p) then return "O" end end
  return nil
end

--- Remember a resource name seen at a gather cast. True when it was new.
function GN.learn(kind, name)
  if not learned or (kind ~= "H" and kind ~= "O") then return false end
  local key = GN.normalize(name)
  if not key or GN.classify(name) == kind then return false end
  local n = 0
  for _ in pairs(learned[kind]) do n = n + 1 end
  if n >= GN.MAX_LEARNED then return false end
  learned[kind][key] = name:sub(1, 60)
  if persist then local p = persist; persist = nil; p(learned) end
  return true
end

return GN
