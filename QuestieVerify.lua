-- QuestieVerify
--
-- Questie draws a "!" for every quest its database thinks you can take. When the database is
-- missing a prerequisite (common for quest chains changed or added in WoW Forever) or lists the
-- wrong quest giver, you travel there for nothing. This add-on second-guesses each "!" before
-- Questie draws it:
--
--   0. ForeverDB.net data (Data/ForeverDB.lua, built locally by the installer, tools/install.ps1, from the
--      ForeverDB.net Companion addon) and xelblch/questie-forever-fixes: side, race and class,
--      prerequisites, exclusive quests, who a quest isn't offered to, and who really gives it.
--      Data from ForeverDB.net (https://foreverdb.net)
--   1. The game's own quest-line data (C_QuestLine): if the quest is a step in a quest line and the
--      step before it isn't completed or in your log, the "!" is hidden.
--   2. BtWQuests chain data, for quests the game doesn't put in a quest line and Questie has no
--      prerequisite for: same check.
--   3. What NPCs actually offer: when you talk to a quest giver, every quest Questie expected there
--      that the NPC didn't offer is hidden at that NPC from then on (per character). It comes back
--      if the NPC later offers it. If you then get that quest somewhere else, the NPC is remembered
--      account-wide as a wrong quest giver.
--   4. Optional dimming of "!" markers that are uncertain (see /qv dim).
--
-- Nothing in Questie's files is changed; everything is done by wrapping two Questie functions.

local ADDON_NAME, ns = ...
ns = ns or {}

local QV = {}
_G.QuestieVerify = QV

local HIDE, DIM, OK = "hide", "dim", "ok"
local LOCK = "lock"      -- blocked by an earlier chain step: shown as a red "!" that points to the step to do first
local VERDICT_LABEL = {
    [HIDE] = "|cffff5555hidden|r",
    [LOCK] = "|cffff7755locked|r (red marker that points to the step to do first)",
    [DIM] = "|cffaaaaaadimmed|r",
    [OK] = "|cff55ff55shown|r",
}

local DEFAULTS = {
    dim = "uncertain",   -- "off" | "uncertain" | "unverified"
    learn = true,        -- learn from what NPCs offer
    chains = true,       -- use quest-line / BtWQuests chain data
    revisitLevels = 2,   -- a "not offered here" marker comes back (dimmed) after this many levels
    foreverdb = true,    -- use the local ForeverDB.net / community data (Data/ForeverDB.lua)
    redirect = true,     -- a quest blocked by a missing prerequisite points to that prerequisite instead
    autoscan = true,     -- record a scan of each zone you enter (no chat output)
    verbose = false,
}

local db, cdb            -- saved variables (account, character)
local Q = {}             -- Questie modules
local status = {}        -- [questId] = { verdict = ..., why = {...} } from the last draw
local lineAvailable = {} -- [questId] = true: the game lists it as a startable quest-line quest
local lineCache = {}     -- [questId] = { t = time, quests = {...}, lineId = n, name = s }
local btw                -- BtWQuests index, built once after login
local loggedIn = false
local hooked = false
local lastDialog = { guid = nil, npcId = nil, t = 0 }
local lastQuestEvent = 0
local warnedError = false

local format, tinsert = string.format, table.insert

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Print(...)
    print("|cff33ff99QuestieVerify|r:", ...)
end

local function Verbose(...)
    if db and db.settings.verbose then Print(...) end
end

local function Import(name)
    if not QuestieLoader then return nil end
    local ok, mod = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
    if ok then return mod end
end

local function QField(id, field)
    if not (Q.DB and Q.DB.QueryQuestSingle) then return nil end
    local ok, value = pcall(Q.DB.QueryQuestSingle, id, field)
    if ok then return value end
end

local function QuestName(id)
    if not id then return "?" end
    local name = QField(id, "name")
    if (not name) and C_QuestLog and C_QuestLog.GetTitleForQuestID then
        name = C_QuestLog.GetTitleForQuestID(id)
    end
    return format("%s (%d)", name or "quest", id)
end

local function NpcName(npcId)
    if Q.DB and Q.DB.QueryNPCSingle then
        local ok, name = pcall(Q.DB.QueryNPCSingle, npcId, "name")
        if ok and name then return format("%s (%d)", name, npcId) end
    end
    return format("NPC %d", npcId)
end

local function PlayerLevel()
    return UnitLevel("player") or 1
end

--- Handed in.
local function IsComplete(id)
    if not id then return false end
    local complete = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
    if complete and complete[id] then return true end
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) then return true end
    return false
end

--- In the quest log now.
local function InLog(id)
    if not id then return false end
    if C_QuestLog then
        if C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id) then return true end
        if C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) then return true end
    end
    if GetQuestLogIndexByID and (GetQuestLogIndexByID(id) or 0) > 0 then return true end
    return false
end

--- Handed in, or in the quest log. (A prerequisite counts only when handed in: IsComplete.)
local function IsDone(id)
    return IsComplete(id) or InLog(id)
end

--- The first quest of the list that's handed in, or nil.
local function AnyComplete(list)
    for _, q in ipairs(list or {}) do
        if IsComplete(q) then return q end
    end
    return nil
end

--- Whether this character's race and class can take the quest (true when Questie doesn't know it).
local function PlayerCanDo(id)
    if not Q.Player then return true end
    local races = QField(id, "requiredRaces")
    if races and Q.Player.HasRequiredRace and not Q.Player.HasRequiredRace(races) then return false end
    local classes = QField(id, "requiredClasses")
    if classes and Q.Player.HasRequiredClass and not Q.Player.HasRequiredClass(classes) then return false end
    return true
end

local function QuestieHasPrereq(id)
    return QField(id, "preQuestSingle") or QField(id, "preQuestGroup")
        or QField(id, "parentQuest") or QField(id, "availableStartingWith")
end

local function QuestieHasChainInfo(id)
    return QuestieHasPrereq(id) or QField(id, "childQuests") or QField(id, "nextQuestInChain")
        or QField(id, "breadcrumbForQuestId")
end

local function QuestUiMap(id)
    local zone = QField(id, "zoneOrSort")
    if zone and zone > 0 and Q.Zone and Q.Zone.GetUiMapIdByAreaId then
        local ok, mapId = pcall(Q.Zone.GetUiMapIdByAreaId, Q.Zone, zone)
        if ok and mapId then return mapId end
    end
    return nil
end

local function PlayerMap()
    return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
end

local function MapName(mapId)
    local info = mapId and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId)
    return info and info.name or "?"
end

---------------------------------------------------------------------------
-- Source 1: the game's quest-line data
---------------------------------------------------------------------------

local function HasLineApi()
    return C_QuestLine and C_QuestLine.GetQuestLineInfo and C_QuestLine.GetQuestLineQuests and true or false
end

local function GetLine(id)
    if not HasLineApi() then return nil end
    local now = GetTime()
    local cached = lineCache[id]
    if cached and (cached.quests or now - cached.t < 120) then
        return cached.quests and cached or nil
    end

    local entry = { t = now }
    local mapId = QuestUiMap(id) or PlayerMap()
    local ok, info = pcall(C_QuestLine.GetQuestLineInfo, id, mapId)
    if not (ok and type(info) == "table" and info.questLineID) then
        ok, info = pcall(C_QuestLine.GetQuestLineInfo, id)
    end
    if ok and type(info) == "table" and info.questLineID then
        local ok2, quests = pcall(C_QuestLine.GetQuestLineQuests, info.questLineID)
        if ok2 and type(quests) == "table" and #quests > 0 then
            entry.quests = quests
            entry.lineId = info.questLineID
            entry.name = info.questLineName
        end
    end
    lineCache[id] = entry
    return entry.quests and entry or nil
end

local function CheckQuestLine(id, why)
    local line = GetLine(id)
    if not line then return nil end
    local list = line.quests
    local index
    for i = 1, #list do
        if list[i] == id then index = i; break end
    end
    if not index then return nil end
    local lineName = line.name or ("#" .. tostring(line.lineId))

    for i = index + 1, #list do
        if IsDone(list[i]) then
            tinsert(why, format("game quest line '%s': a later step is already done", lineName))
            return OK
        end
    end

    -- The nearest earlier steps this character can do (other-faction or other-class steps are skipped).
    local p1, p2
    for i = index - 1, 1, -1 do
        if PlayerCanDo(list[i]) then
            if not p1 then
                p1 = list[i]
            else
                p2 = list[i]
                break
            end
        end
    end

    if not p1 then
        tinsert(why, format("game quest line '%s': first step", lineName))
        return OK
    end
    if IsComplete(p1) then
        tinsert(why, format("game quest line '%s': previous step %s is done", lineName, QuestName(p1)))
        return OK
    end
    if InLog(p1) then
        tinsert(why, format("game quest line '%s': previous step %s is still in your quest log", lineName, QuestName(p1)))
        why.blocker = p1
        return HIDE
    end
    if p2 and IsComplete(p2) then
        -- Quest lines are flat lists; parallel steps look sequential. Not sure enough to hide.
        tinsert(why, format("game quest line '%s': previous step %s isn't done (could be a side branch)", lineName, QuestName(p1)))
        return DIM
    end
    tinsert(why, format("game quest line '%s': previous step %s isn't done", lineName, QuestName(p1)))
    why.blocker = p1
    return HIDE
end

local function ReadAvailableLines(mapId)
    mapId = mapId or PlayerMap()
    if not (mapId and C_QuestLine and C_QuestLine.GetAvailableQuestLines) then return nil end
    local ok, list = pcall(C_QuestLine.GetAvailableQuestLines, mapId)
    if not (ok and type(list) == "table") then return nil end
    local changed = {}
    for _, info in ipairs(list) do
        local id = info.questID
        if id and not lineAvailable[id] then
            lineAvailable[id] = true
            changed[id] = true
        end
    end
    return list, changed
end

---------------------------------------------------------------------------
-- Source 2: BtWQuests chains
---------------------------------------------------------------------------

local function BuildBtW()
    btw = { quests = {}, chains = 0, ok = false }
    local DB = BtWQuestsDatabase
    if not DB then return end
    if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.LoadAddOn and not C_AddOns.IsAddOnLoaded("BtWQuestsClassic") then
        pcall(C_AddOns.LoadAddOn, "BtWQuestsClassic")
    end
    if type(DB.chain) ~= "table" then return end

    local character
    if BtWQuestsCharacters and BtWQuestsCharacters.GetPlayer then
        local ok, c = pcall(BtWQuestsCharacters.GetPlayer, BtWQuestsCharacters)
        if ok then character = c end
    end

    local function valid(restrictions)
        if restrictions == nil or not character then return true end
        local ok, result = pcall(DB.IsItemValidForCharacter, DB, { restrictions = restrictions }, character)
        return (not ok) or (result and true or false)
    end

    local function addIds(dst, item, fallback)
        local ids = item.ids or (fallback and fallback.ids)
        local id = item.id or (fallback and fallback.id)
        if ids then
            for _, q in ipairs(ids) do tinsert(dst, q) end
        elseif id then
            tinsert(dst, id)
        end
    end

    local function offset(connection)
        local first = tostring(connection):match("^%-?%d+")
        return tonumber(first)
    end

    for chainId, chain in pairs(DB.chain) do
        if type(chain) == "table" and type(chain.items) == "table" and valid(chain.restrictions) then
            btw.chains = btw.chains + 1
            local nodes, preds = {}, {}
            local items = chain.items
            local i = 1
            while items[i] ~= nil do
                local item = items[i]
                local node = { ids = {}, breadcrumb = item.breadcrumb and true or false }
                local connections = {}

                if item[1] ~= nil then
                    -- a group of alternatives drawn at one spot
                    for _, sub in ipairs(item) do
                        if sub.type == "quest" and valid(sub.restrictions) then addIds(node.ids, sub) end
                        if sub.breadcrumb then node.breadcrumb = true end
                        if sub.connections then
                            for _, c in ipairs(sub.connections) do tinsert(connections, c) end
                        end
                    end
                elseif item.variations then
                    -- BtWQuests uses the first variation valid for the character, else the last one
                    local chosen
                    for _, v in ipairs(item.variations) do
                        local r = v.restrictions
                        if r == nil then r = item.restrictions end
                        if valid(r) then chosen = v; break end
                    end
                    chosen = chosen or item.variations[#item.variations]
                    if chosen and (chosen.type or item.type) == "quest" then addIds(node.ids, chosen, item) end
                    if chosen and chosen.breadcrumb then node.breadcrumb = true end
                elseif item.type == "quest" and valid(item.restrictions) then
                    addIds(node.ids, item)
                end

                if item.connections then
                    for _, c in ipairs(item.connections) do tinsert(connections, c) end
                end
                node.isQuest = #node.ids > 0
                nodes[i] = node
                for _, c in ipairs(connections) do
                    local off = offset(c)
                    if off and off ~= 0 then
                        local j = i + off
                        preds[j] = preds[j] or {}
                        tinsert(preds[j], i)
                    end
                end
                i = i + 1
            end

            local record = { id = chainId, nodes = nodes, preds = preds }
            for index, node in pairs(nodes) do
                for _, q in ipairs(node.ids) do
                    btw.quests[q] = btw.quests[q] or {}
                    tinsert(btw.quests[q], { chain = record, node = index })
                end
            end
        end
    end
    btw.ok = true
end

local function EnsureBtW()
    if btw == nil and loggedIn then
        local ok, err = pcall(BuildBtW)
        if not ok then
            btw = { quests = {}, chains = 0, ok = false }
            Print("couldn't read BtWQuests data:", tostring(err))
        end
    end
end

--- Earlier quest steps of a chain node, skipping NPCs, breadcrumbs and steps this character can't do.
local function EffectivePreds(record, index)
    local out, seen, stack = {}, {}, {}
    for _, p in ipairs(record.preds[index] or {}) do tinsert(stack, p) end
    while #stack > 0 do
        local p = table.remove(stack)
        if not seen[p] then
            seen[p] = true
            local node = record.nodes[p]
            local usable = false
            if node and node.isQuest and not node.breadcrumb then
                for _, q in ipairs(node.ids) do
                    if PlayerCanDo(q) then usable = true; break end
                end
            end
            if usable then
                tinsert(out, node)
            else
                for _, pp in ipairs(record.preds[p] or {}) do tinsert(stack, pp) end
            end
        end
    end
    return out
end

local function NodeDone(node)
    for _, q in ipairs(node.ids) do
        if IsComplete(q) then return true end
    end
    return false
end

local function CheckBtW(id, why)
    EnsureBtW()
    if not (btw and btw.ok) then return nil end
    local entries = btw.quests[id]
    if not entries then return nil end

    local blockedBy
    for _, entry in ipairs(entries) do
        local preds = EffectivePreds(entry.chain, entry.node)
        if #preds == 0 then
            tinsert(why, "BtWQuests chain: first step")
            return OK
        end
        for _, node in ipairs(preds) do
            if NodeDone(node) then
                tinsert(why, format("BtWQuests chain: previous step %s is done", QuestName(node.ids[1])))
                return OK
            end
        end
        blockedBy = blockedBy or preds[1].ids[1]
    end

    if blockedBy and QField(blockedBy, "breadcrumbForQuestId") == id then
        tinsert(why, format("BtWQuests chain: %s comes first, but Questie says it's an optional breadcrumb", QuestName(blockedBy)))
        return OK
    end
    tinsert(why, format("BtWQuests chain: previous step %s isn't done", QuestName(blockedBy)))
    why.blocker = blockedBy
    return HIDE
end

---------------------------------------------------------------------------
-- Source 3: what NPCs actually offered
---------------------------------------------------------------------------

local function MarkExpired(mark)
    return PlayerLevel() >= (mark.lvl or 0) + (db.settings.revisitLevels or 2)
end

local function GloballyOffered(id, npcs)
    local by = db.offeredBy[id]
    if not (by and npcs) then return false end
    for _, npc in ipairs(npcs) do
        if by[npc] then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Source 0: ForeverDB.net data (Data/ForeverDB.lua, built locally by the installer, tools/install.ps1, from the
-- ForeverDB.net Companion addon), plus xelblch/questie-forever-fixes prerequisites.
-- Data from ForeverDB.net (https://foreverdb.net)
---------------------------------------------------------------------------

local FDB_CREDIT = "Data from ForeverDB.net (https://foreverdb.net)"
local CLASS_IDS = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6,
    SHAMAN = 7, MAGE = 8, WARLOCK = 9, MONK = 10, DRUID = 11 }
local SIDE_NAME = { a = "Alliance", h = "Horde" }
local fdbCache = {}
local trainerClasses
local npcMapCache = {}

local function Ids(s)
    local out = {}
    for w in (s or ""):gmatch("%d+") do out[#out + 1] = tonumber(w) end
    return out
end

local function HasBit(mask, n)
    return math.floor(mask / 2 ^ (n - 1)) % 2 == 1
end

local exclCache, fixCache = {}, {}

local function ExclGroup(g)
    if not (g and g > 0 and ns.fdb and ns.fdb.excl) then return nil end
    local c = exclCache[g]
    if c == nil then
        c = ns.fdb.excl[g] and Ids(ns.fdb.excl[g]) or false
        exclCache[g] = c
    end
    return c or nil
end

local function FixLists(id)
    if not ns.qff then return nil end
    local c = fixCache[id]
    if c == nil then
        local fix = ns.qff[id]
        c = fix and { single = Ids(fix[1]), all = Ids(fix[2]) } or false
        fixCache[id] = c
    end
    return c or nil
end

local function HasFdb()
    return ns.fdb and ns.fdb.quests and db.settings.foreverdb ~= false
end

local function FdbQuest(id)
    if not (ns.fdb and ns.fdb.quests) then return nil end
    local c = fdbCache[id]
    if c ~= nil then return c or nil end
    local r = ns.fdb.quests[id]
    if not r then fdbCache[id] = false return nil end
    local q = {
        id = id, side = r[1], races = r[2], classes = r[3], needAll = Ids(r[4]), needAny = Ids(r[5]),
        excl = r[6], after = r[7], starts = {}, startsSrc = r[9], gone = r[10] == 1, by = r[11],
        new = r[12] == 1, offerMaps = {}, offerMapsSrc = r[14], min = r[15], seenMin = r[16], forever = r[17] == 1,
    }
    for k, n in (r[8] or ""):gmatch("(%a)(%d+)") do tinsert(q.starts, { k = k, id = tonumber(n) }) end
    for _, m in ipairs(Ids(r[13])) do q.offerMaps[m] = true; q.hasOfferMaps = true end
    if q.after > 0 then
        local have = false
        for _, p in ipairs(q.needAll) do if p == q.after then have = true end end
        if not have then tinsert(q.needAll, q.after) end
    end
    fdbCache[id] = q
    return q
end

local function Me()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local _, classFile, classId = UnitClass("player")
    local _, raceFile, raceId = UnitRace("player")
    return {
        side = faction == "Alliance" and "a" or faction == "Horde" and "h" or "",
        classFile = classFile, raceFile = raceFile,
        class = tonumber(classId) or CLASS_IDS[classFile or ""], race = tonumber(raceId),
    }
end

local function TrainerClasses()
    if trainerClasses then return trainerClasses end
    trainerClasses = {}
    for class, list in pairs(ns.fdb and ns.fdb.trainers or {}) do
        local cid = CLASS_IDS[class]
        if cid then
            for _, npc in ipairs(list) do
                trainerClasses[npc] = trainerClasses[npc] or {}
                trainerClasses[npc][cid] = true
            end
        end
    end
    return trainerClasses
end

--- Whether the quest is for this character's side, race and class (as ForeverDB's addon decides it).
local function FdbFits(q, me)
    if q.side ~= "" and me.side ~= "" and q.side ~= me.side then
        return false, format("ForeverDB: it's an %s quest", SIDE_NAME[q.side] or q.side)
    end
    if q.races > 0 and me.race then
        local wholeSide = q.races == 77 or q.races == 178 or q.races == 255
        if not (wholeSide and me.race > 8) and not HasBit(q.races, me.race) then
            return false, "ForeverDB: not for your race"
        end
    end
    if q.classes > 0 and me.class and not HasBit(q.classes, me.class) then
        return false, "ForeverDB: not for your class"
    end
    if q.classes == 0 and me.class then
        local allowed
        for _, ref in ipairs(q.starts) do
            local classes = ref.k == "n" and TrainerClasses()[ref.id]
            if classes then
                allowed = allowed or {}
                for cid in pairs(classes) do allowed[cid] = true end
            end
        end
        if allowed and not allowed[me.class] then
            return false, "ForeverDB: it starts at another class's trainer"
        end
    end
    return true
end

local function FdbOfferRuledOut(id, me)
    local rules = ns.fdb and ns.fdb.offers and ns.fdb.offers[id]
    if not rules then return false end
    for _, rule in ipairs(rules) do
        local s, c, r = rule:match("^([^;]*);([^;]*);([^;]*)$")
        if s and (s ~= "" or c ~= "" or r ~= "")
            and (s == "" or s == me.side) and (c == "" or c == me.classFile) and (r == "" or r == me.raceFile) then
            return true
        end
    end
    return false
end

--- The uiMaps where Questie says an NPC stands.
local function NpcUiMaps(npc)
    local hit = npcMapCache[npc]
    if hit ~= nil then return hit or nil end
    local maps
    if Q.DB and Q.DB.QueryNPCSingle and Q.Zone and Q.Zone.GetUiMapIdByAreaId then
        local ok, spawns = pcall(Q.DB.QueryNPCSingle, npc, "spawns")
        if ok and type(spawns) == "table" then
            for areaId in pairs(spawns) do
                local ok2, m = pcall(Q.Zone.GetUiMapIdByAreaId, Q.Zone, areaId)
                if ok2 and m then
                    maps = maps or {}
                    maps[m] = true
                end
            end
        end
    end
    npcMapCache[npc] = maps or false
    return maps
end

--- Whether ForeverDB players' records show this NPC doesn't give the quest. Returns a reason when it doesn't,
--- and whether the evidence is strong (several players got it from someone else) or only a map mismatch,
--- which can be wrong for city NPCs and quests with several givers.
local function FdbWrongStarter(id, npc)
    if not HasFdb() then return nil end
    local q = FdbQuest(id)
    if not q then return nil end
    local npcMaps = NpcUiMaps(npc)
    local onOfferMap = false
    if npcMaps and q.hasOfferMaps then
        for m in pairs(npcMaps) do if q.offerMaps[m] then onOfferMap = true end end
    end
    if q.startsSrc == "s" and #q.starts > 0 then
        local listed = false
        for _, ref in ipairs(q.starts) do if ref.k == "n" and ref.id == npc then listed = true end end
        if listed then return nil end
        if not onOfferMap then
            local names = {}
            for _, ref in ipairs(q.starts) do
                tinsert(names, ref.k == "n" and NpcName(ref.id) or ref.k == "i" and format("item %d", ref.id)
                    or format("object %d", ref.id))
            end
            return format("ForeverDB: players got it from %s, not %s", table.concat(names, ", "), NpcName(npc)), (q.by or 0) >= 3
        end
    end
    if npcMaps and q.hasOfferMaps and q.offerMapsSrc == "s" and not onOfferMap then
        local where = {}
        for m in pairs(q.offerMaps) do tinsert(where, MapName(m)) end
        table.sort(where)
        return format("ForeverDB: players were offered it in %s, but %s isn't there", table.concat(where, ", "), NpcName(npc)), false
    end
    return nil
end

--- Whether this character can never take quest p (another side/race/class, not offered to them, gone from
--- Forever, or a quest of its exclusive group is already done or taken).
local function FdbNeverTakeable(p, me)
    local pq = FdbQuest(p)
    if not pq then return false end
    if not FdbFits(pq, me) or FdbOfferRuledOut(p, me) or pq.gone then return true end
    for _, o in ipairs(ExclGroup(pq.excl) or {}) do
        if o ~= p and IsDone(o) then return true end
    end
    return false
end

--- HIDE when ForeverDB (or the community fix list) says this character can't take it yet,
--- OK when the data knows its prerequisites and they're met, nil when the data has nothing to say.
local function CheckForeverDB(id, why)
    if not HasFdb() then return nil end
    local q = FdbQuest(id)
    local fix = FixLists(id)
    if not (q or fix) then return nil end
    local me = Me()
    local known = false

    if q then
        local fits, reason = FdbFits(q, me)
        if not fits then tinsert(why, reason) return HIDE end
        if FdbOfferRuledOut(id, me) then
            tinsert(why, "ForeverDB: players saw its giver doesn't offer it to characters like you")
            return HIDE
        end
        if q.gone then
            tinsert(why, "ForeverDB: a Classic quest players have never been offered in Forever")
            return HIDE
        end
        for _, p in ipairs(q.needAll) do
            if not IsComplete(p) then
                -- "offered after" is an order players saw, not always a rule: it doesn't count when the earlier
                -- quest isn't one this character can take (another race's or class's version)
                local soft = p == q.after and not InLog(p) and FdbNeverTakeable(p, me)
                if not soft then
                    tinsert(why, format("ForeverDB: needs %s first", QuestName(p)))
                    why.blocker = p
                    return HIDE
                end
            end
            known = true
        end
        if #q.needAny > 0 then
            if not AnyComplete(q.needAny) then
                local pick = q.needAny[1]
                for _, p in ipairs(q.needAny) do
                    local pq = FdbQuest(p)
                    if InLog(p) or (pq and FdbFits(pq, me) and not FdbOfferRuledOut(p, me)) then pick = p break end
                end
                tinsert(why, format("ForeverDB: needs %s (or another quest of its set) first", QuestName(pick)))
                why.blocker = pick
                return HIDE
            end
            known = true
        end
        local group = ExclGroup(q.excl)
        if group then
            for _, o in ipairs(group) do
                if o ~= id and IsDone(o) then
                    tinsert(why, format("ForeverDB: you did %s, and only one of these can be done", QuestName(o)))
                    return HIDE
                end
            end
        end
    end

    if fix then
        local single, all = fix.single, fix.all
        if #single > 0 then
            if not AnyComplete(single) then
                tinsert(why, format("questie-forever-fixes: needs %s first", QuestName(single[1])))
                why.blocker = single[1]
                return HIDE
            end
            known = true
        end
        for _, p in ipairs(all) do
            if not IsComplete(p) then
                tinsert(why, format("questie-forever-fixes: needs %s first", QuestName(p)))
                why.blocker = p
                return HIDE
            end
            known = true
        end
    end

    if known then
        tinsert(why, "ForeverDB / community data: its prerequisites are done")
        return OK
    end
    if q and q.forever and q.by > 0 and q.after == 0 then
        tinsert(why, format("ForeverDB: %d players picked it up, none right after another quest", q.by))
        return "weak"
    end
    return nil
end

QV.FdbQuest = FdbQuest

---------------------------------------------------------------------------
-- The verdict for one quest
---------------------------------------------------------------------------

--- Returns verdict, reasons, and (when some quest givers were filtered out) a stand-in quest object.
local function Evaluate(quest)
    local id = quest.Id
    local why = {}
    local settings = db.settings
    local starts = quest.Starts or {}
    local proxy
    local dimFromMark = false

    -- Quest givers this character visited that didn't offer it, or that are known to be wrong.
    local npcs = starts.NPC
    if npcs and #npcs > 0 then
        local keep, dropped = {}, false
        local wrong = db.wrongStarter[id]
        local marks = cdb.notOffered[id]
        local offered = db.offeredBy[id]
        local weak = {}
        for _, npc in ipairs(npcs) do
            local fdbWrong, strong
            if not (offered and offered[npc]) then fdbWrong, strong = FdbWrongStarter(id, npc) end
            if fdbWrong and strong then
                dropped = true
                tinsert(why, fdbWrong)
            elseif fdbWrong then
                tinsert(weak, { npc = npc, why = fdbWrong })
            elseif wrong and wrong[npc] then
                dropped = true
                tinsert(why, format("%s doesn't give this quest (it was picked up elsewhere)", NpcName(npc)))
            elseif marks and marks[npc] then
                if MarkExpired(marks[npc]) then
                    tinsert(keep, npc)
                    dimFromMark = true
                    tinsert(why, format("%s didn't offer it when you visited at level %d", NpcName(npc), marks[npc].lvl or 0))
                else
                    dropped = true
                    tinsert(why, format("%s didn't offer it when you visited at level %d (marker comes back at level %d)",
                        NpcName(npc), marks[npc].lvl or 0, (marks[npc].lvl or 0) + (settings.revisitLevels or 2)))
                end
            else
                tinsert(keep, npc)
            end
        end
        if #weak > 0 then
            if #keep > 0 or starts.GameObject or starts.Item then
                dropped = true
                for _, w in ipairs(weak) do tinsert(why, w.why) end
            else
                for _, w in ipairs(weak) do
                    tinsert(keep, w.npc)
                    tinsert(why, w.why .. " (kept, dimmed: no other giver is known)")
                end
                dimFromMark = true
            end
        end
        if dropped then
            local newStarts = {
                NPC = (#keep > 0) and keep or nil,
                GameObject = starts.GameObject,
                Item = starts.Item,
            }
            if not (newStarts.NPC or newStarts.GameObject or newStarts.Item) then
                return HIDE, why
            end
            proxy = setmetatable({ Starts = newStarts }, { __index = quest })
        end
    end

    if cdb.confirmed[id] then
        tinsert(why, "an NPC offered it to you")
        return OK, why, proxy
    end
    if lineAvailable[id] then
        tinsert(why, "the game lists it as a quest you can start here")
        return OK, why, proxy
    end

    local verdict
    local fdbVerdict = CheckForeverDB(id, why)
    if fdbVerdict == HIDE then return HIDE, why end
    if fdbVerdict == OK then
        if dimFromMark then return DIM, why, proxy end
        return OK, why, proxy
    end
    if settings.chains then
        verdict = CheckQuestLine(id, why)
        if verdict == HIDE then return HIDE, why end
        if verdict == nil then
            if QuestieHasPrereq(id) then
                tinsert(why, "Questie has its own prerequisite for it, and it's met")
                verdict = OK
            else
                verdict = CheckBtW(id, why)
                if verdict == HIDE then return HIDE, why end
            end
        end
    end

    if dimFromMark or verdict == DIM then
        return DIM, why, proxy
    end
    if verdict == nil then
        if QuestieHasChainInfo(id) then
            tinsert(why, "Questie knows its chain")
        elseif fdbVerdict == "weak" then
            -- (the reason is already in the list)
        elseif GloballyOffered(id, (proxy or quest).Starts and (proxy or quest).Starts.NPC) then
            tinsert(why, "this NPC has offered it on one of your characters")
        else
            tinsert(why, "no chain data anywhere, never seen offered")
            if settings.dim == "unverified" then return DIM, why, proxy end
        end
    end
    return OK, why, proxy
end

---------------------------------------------------------------------------
-- Pointing to the missing prerequisite
---------------------------------------------------------------------------
-- A quest hidden because a prerequisite isn't done points to the first quest of its chain you can
-- pick up now: that quest gets a marker (QuestieVerify draws it if Questie doesn't), and its tooltip
-- says what it unlocks.

local unlocks = {}     -- [root quest] = { [blocked quest] = true }
local redirectOf = {}  -- [blocked quest] = root quest
local forced = {}      -- [root quest] = true: its marker was drawn by QuestieVerify, not Questie
local extraLocked = {} -- [quest] = key: red markers QuestieVerify drew for chain steps Questie doesn't list itself
local hookedDraw       -- the wrapped DrawAvailableQuest
local rawDraw          -- Questie's own DrawAvailableQuest
local childrenOf       -- [quest] = { quests that need it }: Questie's and ForeverDB's prerequisites, built after login
local parentsOf        -- [quest] = { quests it needs }, built with childrenOf
local redirecting = false

--- The level a quest can be picked up from: ForeverDB's when it knows, else Questie's. Questie's data often has no
--- required level, and Questie then uses the quest's own level (The Swarm Grows: level 33, but taken from 29).
local function RequiredLevel(id)
    local q = db.settings.foreverdb and FdbQuest(id)
    if q and (q.min or 0) > 0 then return q.min end
    local req = QField(id, "requiredLevel") or 0
    if req == 0 then req = QField(id, "questLevel") or 0 end
    return req
end

local function QuestieBlocker(id)
    local single = QField(id, "preQuestSingle")
    if type(single) == "table" and #single > 0 then
        if not AnyComplete(single) then
            for _, p in ipairs(single) do if InLog(p) or PlayerCanDo(p) then return p end end
            return single[1]
        end
    end
    local group = QField(id, "preQuestGroup")
    if type(group) == "table" then
        for _, p in ipairs(group) do if not IsComplete(p) then return p end end
    end
    return nil
end

--- Evaluate, plus Questie's own prerequisites. Questie checks those itself before it asks QuestieVerify about
--- a quest, so Evaluate doesn't; this is for the quests Questie leaves out (chain steps, /qv why).
local function EvaluateWithPrereqs(quest)
    local verdict, why, proxy = Evaluate(quest)
    if verdict ~= HIDE then
        local blocker = QuestieBlocker(quest.Id)
        if blocker then
            local kept = {}
            for _, reason in ipairs(why or {}) do
                if not reason:find("^Questie has its own prerequisite") then tinsert(kept, reason) end
            end
            why = kept
            tinsert(why, format("Questie: needs %s first", QuestName(blocker)))
            why.blocker = blocker
            return HIDE, why
        end
    end
    return verdict, why, proxy
end

--- Whether Questie's settings hide quests like this one (repeatable, dungeon, raid, PvP).
local function FilteredByQuestie(p)
    local prof = Questie and Questie.db and Questie.db.profile
    if not (prof and Q.DB) then return false end
    local function is(name)
        local f = Q.DB[name]
        if not f then return false end
        local ok, r = pcall(f, p)
        return ok and r and true or false
    end
    if prof.showRepeatableQuests == false and is("IsRepeatable") then return true end
    if prof.showDungeonQuests == false and is("IsDungeonQuest") then return true end
    if prof.showRaidQuests == false and is("IsRaidQuest") then return true end
    if prof.showPvPQuests == false and is("IsPvPQuest") then return true end
    return false
end

--- The first quest of the chain leading to `p` that this character can pick up now.
--- Returns root, or nil plus why not ("log", "level", "cant") and the quest it stopped at.
local function FindRoot(p)
    local seen = {}
    for _ = 1, 15 do
        if not p or seen[p] then return nil, "cant", p end
        seen[p] = true
        if IsComplete(p) then return nil end
        if InLog(p) then return nil, "log", p end
        local nextP = QuestieBlocker(p)
        if not nextP then
            local okQ, quest = pcall(Q.DB.GetQuest, p)
            if not (okQ and quest) then return nil, "cant", p end
            local okE, verdict, why = pcall(Evaluate, quest)
            if not okE then return nil, "cant", p end
            if verdict == HIDE then
                if not why.blocker then return nil, "cant", p end
                nextP = why.blocker
            else
                local req = RequiredLevel(p)
                if req > PlayerLevel() then return nil, "level", p end
                if not (Q.AQ.__availableQuests or {})[p] and FilteredByQuestie(p) then return nil, "filtered", p end
                if Q.DB.IsDoable then
                    local okD, doable = pcall(Q.DB.IsDoable, p)
                    if okD and doable == false then return nil, "cant", p end
                end
                return p
            end
        end
        p = nextP
    end
    return nil, "cant", p
end

-- FindRoot results, cleared when Questie starts a new pass and after quest events.
local rootCache = {}

local function CachedRoot(p)
    local c = rootCache[p]
    if not c then
        local root, reason, at = FindRoot(p)
        c = { root = root, reason = reason, at = at }
        rootCache[p] = c
    end
    return c.root, c.reason, c.at
end

--- Explains where a quest blocked by `blocker` leads; returns the quest to point to, if any.
local function ResolveRoot(blocker, why)
    local root, reason, at = CachedRoot(blocker)
    if root then
        tinsert(why, format("its marker points to %s instead: pick that up first", QuestName(root)))
    elseif reason == "log" then
        tinsert(why, format("%s is in your quest log: hand it in first", QuestName(at)))
    elseif reason == "level" then
        tinsert(why, format("the first step, %s, needs level %d", QuestName(at), RequiredLevel(at)))
    elseif reason == "filtered" then
        tinsert(why, format("the first step, %s, is a kind of quest your Questie settings hide", QuestName(at)))
    elseif reason == "cant" then
        tinsert(why, format("no step of the chain can be picked up now (stopped at %s)", QuestName(at)))
    end
    return root
end

--- Whether Questie has an available-quest marker drawn for this quest right now.
local function HasMarker(id)
    if not (Q.Map and Q.Map.GetFramesForQuest) then return false end
    local ok, frames = pcall(Q.Map.GetFramesForQuest, Q.Map, id)
    if not (ok and type(frames) == "table") then return false end
    for _, f in pairs(frames) do
        if f and f.data and f.data.Type == "available" then return true end
    end
    return false
end

local function UnloadMarker(id)
    if Q.Map and Q.Map.UnloadQuestFrames then pcall(Q.Map.UnloadQuestFrames, Q.Map, id) end
    if Q.Tooltips and Q.Tooltips.RemoveQuest then pcall(Q.Tooltips.RemoveQuest, Q.Tooltips, id) end
end

local function ReleaseRoot(root)
    if unlocks[root] and next(unlocks[root]) then return end
    unlocks[root] = nil
    if forced[root] then
        forced[root] = nil
        if not (Q.AQ.__availableQuests or {})[root] then UnloadMarker(root) end
    end
end

local function ClearRedirect(id)
    local old = redirectOf[id]
    if not old then return end
    redirectOf[id] = nil
    if unlocks[old] then unlocks[old][id] = nil end
    ReleaseRoot(old)
end

local function ClearAllRedirects()
    for root in pairs(forced) do
        if not (Q.AQ and (Q.AQ.__availableQuests or {})[root]) then UnloadMarker(root) end
    end
    unlocks, redirectOf, forced = {}, {}, {}
end

--- The NPCs and objects that start a quest, as one set ("n<id>", "o<id>").
local function StarterSet(id)
    local set = {}
    local by = QField(id, "startedBy")
    if type(by) == "table" then
        for _, n in ipairs(by[1] or {}) do set["n" .. n] = true end
        for _, o in ipairs(by[2] or {}) do set["o" .. o] = true end
    end
    return set
end

local function SameStarter(a, b)
    local sa = StarterSet(a)
    for k in pairs(StarterSet(b)) do if sa[k] then return true end end
    return false
end

--- Whether a quest blocked by `blocker` keeps a (red, locked) marker that points to the step to do first.
--- Not when that step is at the same NPC: its own "!" is already there, and says what it unlocks.
local function ShowsLocked(id, blocker)
    if not (blocker and db.settings.redirect) then return false end
    local root, reason, at = CachedRoot(blocker)
    local target = root or ((reason == "log" or reason == "level") and at) or nil
    return target ~= nil and not SameStarter(id, target)
end

--- HIDE becomes LOCK for a quest that keeps a locked marker.
local function FinalVerdict(id, verdict, why)
    if verdict == HIDE and why and ShowsLocked(id, why.blocker) then return LOCK end
    return verdict
end

--- Called for a quest that is being hidden.
local function Redirect(id, why)
    local blocker = why.blocker
    if not (blocker and db.settings.redirect) or redirecting then ClearRedirect(id) return end
    local root = ResolveRoot(blocker, why)
    if not root then ClearRedirect(id) return end
    if redirectOf[id] ~= root then ClearRedirect(id) end
    redirectOf[id] = root
    unlocks[root] = unlocks[root] or {}
    unlocks[root][id] = true
    -- (checks the map itself: Questie can drop markers on a full reset without telling anyone)
    if not (Q.AQ.__availableQuests or {})[root] and not HasMarker(root) and hookedDraw then
        local okQ, rootQuest = pcall(Q.DB.GetQuest, root)
        if okQ and rootQuest then
            forced[root] = true
            redirecting = true
            pcall(hookedDraw, rootQuest)
            redirecting = false
        end
    end
end

--- After a Questie pass or a quest event: drop pointers from quests Questie no longer lists, and markers
--- QuestieVerify drew for quests now done or taken.
local function PruneRedirects()
    local available = Q.AQ and Q.AQ.__availableQuests or {}
    for id in pairs(redirectOf) do
        if not (available[id] or extraLocked[id]) then ClearRedirect(id) end
    end
    for root in pairs(unlocks) do
        if IsComplete(root) or InLog(root) then
            for id in pairs(unlocks[root]) do redirectOf[id] = nil end
            unlocks[root] = {}
            ReleaseRoot(root)
        end
    end
end

local function QuestTitle(id)
    local name = QField(id, "name")
    return name or ("quest " .. tostring(id))
end

--- " from <NPC> in <zone>" for where a quest is picked up, or "" when unknown.
local function StarterText(id)
    local by = QField(id, "startedBy")
    if type(by) ~= "table" then return "" end
    local npc = (by[1] or {})[1]
    if npc then
        local okN, name = pcall(Q.DB.QueryNPCSingle, npc, "name")
        local text = " from " .. ((okN and name) or ("NPC " .. npc))
        local maps = NpcUiMaps(npc)
        local map = maps and next(maps)
        if map then text = text .. " in " .. MapName(map) end
        if #by[1] > 1 then text = text .. " (or another giver)" end
        return text
    end
    local obj = (by[2] or {})[1]
    if obj and Q.DB.QueryObjectSingle then
        local okO, name = pcall(Q.DB.QueryObjectSingle, obj, "name")
        if okO and name then return " from " .. name end
    end
    if (by[3] or {})[1] then return " from an item" end
    return ""
end

local longestAfter = {}  -- [quest] = the most steps that come after it (cached; the chain data doesn't change)

--- Where a quest sits in its chain: step, total (nil when it isn't part of a chain).
local function ChainPosition(id)
    if not (childrenOf and parentsOf) then return nil end
    local before, step, seen = 0, id, { [id] = true }
    while before < 25 do
        local nextStep
        for _, p in ipairs(parentsOf[step] or {}) do
            if not seen[p] then nextStep = p break end
        end
        if not nextStep then break end
        seen[nextStep] = true
        before, step = before + 1, nextStep
    end
    local function Longest(q, depth)
        if longestAfter[q] then return longestAfter[q] end
        if depth > 25 then return 0 end
        local best = 0
        for _, k in ipairs(childrenOf[q] or {}) do
            local n = 1 + Longest(k, depth + 1)
            if n > best then best = n end
        end
        longestAfter[q] = best
        return best
    end
    local total = before + 1 + Longest(id, 0)
    if total < 2 then return nil end
    return before + 1, total
end

--- ", step 2 of 5" for a quest in a chain, else "" (`mid`: with a closing comma, for the middle of a sentence).
local function StepText(id, mid)
    local pos, total = ChainPosition(id)
    return pos and format(", step %d of %d%s", pos, total, mid and "," or "") or ""
end

--- The tooltip line of a locked marker: which quest to do first, and where.
local function LockedLine(id, blocker)
    if not blocker then return nil end
    local root, reason, at = CachedRoot(blocker)
    local text
    if root then
        text = format("first pick up %s%s", QuestName(root), StarterText(root))
    elseif reason == "log" then
        text = format("first hand in %s (it's in your quest log)", QuestName(at))
    elseif reason == "level" then
        text = format("first do %s%s, from level %d", QuestName(at), StarterText(at), RequiredLevel(at))
    else
        text = "an earlier step of this chain isn't done"
    end
    return format("|cffff7755QuestieVerify: %s%s is locked:|r %s", QuestName(id), StepText(id, true), text)
end

--- [NPC name] = { locked quests whose red marker was left out at that NPC because it has a real "!" }
local function LockedAtNpcs()
    local available = Q.AQ and Q.AQ.__availableQuests or {}
    local byName = {}
    for id, st in pairs(status) do
        if st.lockedAt and (available[id] or extraLocked[id]) then
            for _, npc in ipairs(st.lockedAt) do
                local ok, name = pcall(Q.DB.QueryNPCSingle, npc, "name")
                if ok and name then
                    byName[name] = byName[name] or {}
                    tinsert(byName[name], id)
                end
            end
        end
    end
    return byName
end

local function AddUnlockLines(tooltip)
    local order = tooltip and tooltip.npcAndObjectOrder
    if not order then return false end
    local added = false
    local done = {}
    -- Locked quests of an NPC that has a real "!": no red marker there, so list them in its tooltip.
    local lockedAt = LockedAtNpcs()
    for giver in pairs(order) do
        for _, id in ipairs(lockedAt[giver] or {}) do
            local line = not done["l" .. id] and LockedLine(id, status[id].blocker)
            if line then
                done["l" .. id] = true
                if not added then tooltip:AddLine(" ") end
                tooltip:AddLine(line, 1, 0.82, 0, true)
                added = true
            end
        end
    end
    for _, quests in pairs(order) do
        for _, tip in pairs(quests) do
            local root = type(tip) == "table" and tip.questId
            local st = root and status[root]
            local locked = st and st.verdict == LOCK and not done["l" .. root] and LockedLine(root, st.blocker)
            if locked then
                done["l" .. root] = true
                if not added then tooltip:AddLine(" ") end
                tooltip:AddLine(locked, 1, 0.82, 0, true)
                added = true
            end
            if root and unlocks[root] and not done[root] then
                done[root] = true
                local names = {}
                for id in pairs(unlocks[root]) do tinsert(names, QuestName(id)) end
                table.sort(names)
                if #names > 0 then
                    if not added then tooltip:AddLine(" ") end
                    tooltip:AddLine(format("|cff33ff99QuestieVerify:|r %s%s unlocks %s", QuestName(root), StepText(root, true),
                        table.concat(names, ", ")), 1, 0.82, 0, true)
                    added = true
                end
            end
            -- any other quest in a chain: where it sits
            if root and not done["l" .. root] and not done[root] and not done["s" .. root] then
                done["s" .. root] = true
                local pos, total = ChainPosition(root)
                if pos then
                    if not added then tooltip:AddLine(" ") end
                    tooltip:AddLine(format("|cff33ff99QuestieVerify:|r %s is step %d of %d of its chain", QuestName(root), pos, total),
                        1, 0.82, 0, true)
                    added = true
                end
            end
        end
    end
    return added
end

local warnedTooltip = false

local function DecorateTooltip(tooltip)
    if not tooltip then return end
    if db.settings.verbose then
        local givers, quests = 0, {}
        for _, qs in pairs(tooltip.npcAndObjectOrder or {}) do
            givers = givers + 1
            for _, tip in pairs(qs) do
                local id = type(tip) == "table" and tip.questId
                if id then
                    local st = status[id]
                    quests[#quests + 1] = format("%d %s%s", id, st and st.verdict or "-", unlocks[id] and " unlocks" or "")
                end
            end
        end
        Verbose(format("map tooltip: %d givers, quests: %s", givers, #quests > 0 and table.concat(quests, ", ") or "none"))
    end
    local rebuild = tooltip._Rebuild
    if rebuild then
        tooltip._Rebuild = function(t, ...)
            rebuild(t, ...)
            if AddUnlockLines(t) then t:Show() end
        end
    end
    if AddUnlockLines(tooltip) then tooltip:Show() end
end

---------------------------------------------------------------------------
-- Dimming
---------------------------------------------------------------------------

local function ShouldDim(questId)
    if db.settings.dim == "off" then return false end
    local st = status[questId]
    return st and st.verdict == DIM or false
end

local function ApplyDim(frame)
    local data = frame.data
    local available = data and data.Type == "available" and data.Id
    local st = available and status[data.Id]
    local locked = st and st.verdict == LOCK or false
    local dim = not locked and available and ShouldDim(data.Id) or false
    if frame.texture and frame.texture.SetDesaturated then
        frame.texture:SetDesaturated(dim or locked)
    end
    if locked and frame.texture and frame.texture.GetVertexColor then
        -- red "!": a grey icon tinted red (Questie sets the colour again on its next update; its fading keeps it)
        local _, _, _, a = frame.texture:GetVertexColor()
        frame.texture:SetVertexColor(1, 0.35, 0.3, a or 1)
    end
    if dim then frame:SetAlpha(0.45) end
end

---------------------------------------------------------------------------
-- Redrawing
---------------------------------------------------------------------------

local function QuestieReady()
    return Questie and Questie.started and Q.AQ and Q.AQ.CalculateAndDrawAll and true or false
end

--- Throw away the drawn "!" of these quests (nil = all) and let Questie redraw them through our check.
local function Redraw(questIds)
    if not QuestieReady() then return end
    rootCache = {}
    if questIds == nil then
        ClearAllRedirects()
        questIds = {}
        for id in pairs(Q.AQ.__availableQuests or {}) do questIds[id] = true end
    end
    -- Questie unloads a quest's frames through a thread callback; recalculating before that has finished
    -- would see the old frames, skip the quest, and then lose its marker. So wait for every removal.
    local pending, started = 0, false
    local function Start()
        if started then return end
        started = true
        Q.AQ.CalculateAndDrawAll()
    end
    for _ in pairs(questIds) do pending = pending + 1 end
    for id in pairs(questIds) do
        local ok = pcall(Q.AQ.RemoveQuest, id, function()
            pending = pending - 1
            if pending <= 0 then Start() end
        end)
        if not ok then pending = pending - 1 end
    end
    if pending <= 0 then Start() end
    C_Timer.After(1, Start)   -- (in case a Questie version never calls back)
end
QV.Redraw = Redraw

--- The NPCs that have a normal or dimmed "!" from Questie right now. A red marker isn't drawn there:
--- it could cover the "!" the NPC really has for you.
local function ShownNpcs()
    local available = Q.AQ and Q.AQ.__availableQuests or {}
    local shown = {}
    for id, st in pairs(status) do
        if (st.verdict == OK or st.verdict == DIM) and available[id] and st.npcs then
            for _, npc in ipairs(st.npcs) do shown[npc] = true end
        end
    end
    return shown
end

--- A locked quest's starters without the NPCs in `shown`, and a key naming the ones left out.
local function LockedStarts(quest, shown)
    local starts = quest.Starts or {}
    local keep, out = {}, {}
    for _, npc in ipairs(starts.NPC or {}) do
        if shown[npc] then tinsert(out, npc) else tinsert(keep, npc) end
    end
    table.sort(out)
    local newStarts = { NPC = (#keep > 0) and keep or nil, GameObject = starts.GameObject, Item = starts.Item }
    local any = newStarts.NPC or newStarts.GameObject or newStarts.Item
    return any and newStarts or nil, table.concat(out, ","), (#out > 0) and out or nil
end

local recheckAt = {}   -- [questId] = GetTime() of its last re-check redraw (stops redraw loops)

--- After each Questie pass: Questie never redraws a quest that already has a marker, so re-check the red ones.
--- A step of their chain may be done now, they may point to a different step, or an NPC may have gained a "!".
local function RecheckLocked()
    if not QuestieReady() then return end
    local available = Q.AQ.__availableQuests or {}
    local shown = ShownNpcs()
    local now = GetTime()
    local changed = {}
    for id, st in pairs(status) do
        if st.verdict == LOCK and available[id] and (recheckAt[id] or -10) < now - 2 then
            local okQ, quest = pcall(Q.DB.GetQuest, id)
            local final, key
            if okQ and quest then
                local okE, verdict, why = pcall(Evaluate, quest)
                if okE then
                    local okF, f = pcall(FinalVerdict, id, verdict, why)
                    if okF then final = f end
                end
                key = select(2, LockedStarts(quest, shown))
            end
            if final ~= LOCK or key ~= st.excluded then
                recheckAt[id] = now
                changed[id] = true
            end
        end
    end
    if next(changed) then Redraw(changed) end
end

--- Draws a locked quest's red marker; not at NPCs that have a real "!" (the red one could cover it), where it's
--- listed in that "!"'s tooltip instead (lockedAt). Returns whether a marker was drawn.
local function DrawLocked(quest, why)
    local starts, excluded, lockedAt = LockedStarts(quest, ShownNpcs())
    if starts then
        status[quest.Id] = { verdict = LOCK, why = why, root = redirectOf[quest.Id], blocker = why.blocker,
            excluded = excluded, lockedAt = lockedAt }
        rawDraw(setmetatable({ Starts = starts }, { __index = quest }))
        return true
    end
    status[quest.Id] = { verdict = HIDE, why = why, root = redirectOf[quest.Id], blocker = why.blocker,
        lockedAt = lockedAt }
    return false
end

-- Chain steps Questie leaves out. Questie only asks QuestieVerify about quests whose prerequisites it thinks are
-- done, so the later steps of a chain it knows never reach the hook. They're found here instead: the quests that
-- need one you can pick up now or have in your log, then the ones after those.

local childrenBuilding = false
local parentLevel = {}  -- [quest with later steps] = its required level (cached: checked on every pass)
local CHAIN_DEPTH = 4   -- how many steps past a quest you can pick up still get a red marker
local LEVELS_AHEAD = 5  -- a first step this many levels above you still starts a chain (later steps: any level)

--- Builds childrenOf a few hundred quests at a time, so logging in doesn't stall.
local chainError          -- the first error of the chain-marker code, shown once in chat and by /qv why
local chainQuestCount = 0 -- how many quests the index was built from (for /qv why)

local function ChainError(err)
    if chainError then return end
    chainError = tostring(err)
    Print("error in the red chain markers (the rest works as before): " .. chainError)
end

--- Builds childrenOf a few hundred quests at a time, so logging in doesn't stall. Retried later when Questie's
--- quest list isn't ready yet.
local function BuildChildren(done)
    if childrenOf or childrenBuilding then return end
    local pointers = Q.DB and Q.DB.QuestPointers
    if type(pointers) ~= "table" then return end
    local ids = {}
    for id in pairs(pointers) do ids[#ids + 1] = id end
    if #ids == 0 then return end
    childrenBuilding = true
    local index, parents, i = {}, {}, 0
    local function Add(parent, child)
        if type(parent) ~= "number" then return end
        index[parent] = index[parent] or {}
        tinsert(index[parent], child)
        parents[child] = parents[child] or {}
        tinsert(parents[child], parent)
    end
    local function Step()
        for _ = 1, 400 do
            i = i + 1
            local id = ids[i]
            if id == nil then
                -- ForeverDB's prerequisites too: Questie's data often lacks them (The Swarm Grows 1146 -> 1147)
                for fid in pairs(ns.fdb and ns.fdb.quests or {}) do
                    local q = pointers[fid] and FdbQuest(fid)
                    if q then
                        for _, p in ipairs(q.needAll) do Add(p, fid) end
                        for _, p in ipairs(q.needAny) do Add(p, fid) end
                    end
                end
                childrenOf, parentsOf, childrenBuilding, chainQuestCount = index, parents, false, #ids
                if done then done() end
                return
            end
            for _, field in ipairs({ "preQuestSingle", "preQuestGroup" }) do
                local list = QField(id, field)
                if type(list) == "table" then
                    for _, p in ipairs(list) do Add(p, id) end
                end
            end
        end
        C_Timer.After(0, function()
            local ok, err = pcall(Step)
            if not ok then childrenBuilding = false; ChainError(err) end
        end)
    end
    local ok, err = pcall(Step)
    if not ok then childrenBuilding = false; ChainError(err) end
end

local function LogQuestIds()
    local ids = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, (C_QuestLog.GetNumQuestLogEntries() or 0) do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and (info.questID or 0) > 0 then tinsert(ids, info.questID) end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        for i = 1, (GetNumQuestLogEntries() or 0) do
            local _, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
            if not isHeader and (questID or 0) > 0 then tinsert(ids, questID) end
        end
    end
    return ids
end

--- Whether a chain step could be a quest for this character at all, apart from its earlier steps.
local function ChainStepFits(id, available, laterStep)
    if available[id] then return false, "Questie shows it" end
    if IsComplete(id) then return false, "handed in" end
    if InLog(id) then return false, "in your quest log" end
    local char = Questie and Questie.db and Questie.db.char
    if char and char.hidden and char.hidden[id] then return false, "you hid it in Questie" end
    if Q.DB.autoBlacklist and Q.DB.autoBlacklist[id] then return false, "Questie's automatic blacklist" end
    if Q.Corr and Q.Corr.hiddenQuests and Q.Corr.hiddenQuests[id] then return false, "hidden by Questie's corrections" end
    if not PlayerCanDo(id) then return false, "not for your race or class (Questie)" end
    local req = RequiredLevel(id)
    if not laterStep and req > PlayerLevel() + LEVELS_AHEAD then
        return false, format("needs level %d, more than %d above you", req, LEVELS_AHEAD)
    end
    for _, other in ipairs(QField(id, "exclusiveTo") or {}) do
        if IsDone(other) then return false, format("only one of it and %s can be done", QuestName(other)) end
    end
    if FilteredByQuestie(id) then return false, "a kind of quest your Questie settings hide" end
    return true
end

--- Whether ForeverDB lists a prerequisite of this quest that isn't handed in.
local function FdbBlocked(id)
    local q = db.settings.foreverdb and FdbQuest(id)
    if not q then return false end
    for _, p in ipairs(q.needAll) do if not IsComplete(p) then return true end end
    return #q.needAny > 0 and not AnyComplete(q.needAny)
end

--- The chain steps that should have a red marker: up to CHAIN_DEPTH steps past each quest you can pick up now or
--- have in your log.
local function ChainSteps()
    local available = Q.AQ.__availableQuests or {}
    local want, queue, depth = {}, {}, {}
    local function Seed(id)
        if depth[id] == nil then depth[id] = 0; tinsert(queue, id) end
    end
    for id in pairs(available) do Seed(id) end
    for _, id in ipairs(LogQuestIds()) do Seed(id) end
    -- first steps a few levels above you (Questie doesn't show those): their later steps say from which level
    local level = PlayerLevel()
    for id in pairs(childrenOf) do
        local req = parentLevel[id]
        if not req then req = RequiredLevel(id); parentLevel[id] = req end
        if req > level and req <= level + LEVELS_AHEAD and depth[id] == nil
            and not QuestieBlocker(id) and not FdbBlocked(id) and ChainStepFits(id, available) then
            Seed(id)
        end
    end
    local i = 1
    while queue[i] do
        local p = queue[i]
        i = i + 1
        if depth[p] < CHAIN_DEPTH then
            for _, c in ipairs(childrenOf[p] or {}) do
                if depth[c] == nil then
                    depth[c] = depth[p] + 1
                    if ChainStepFits(c, available, true) then
                        want[c] = true
                        tinsert(queue, c)
                    end
                end
            end
        end
    end
    return want
end

local function DropExtra(id)
    extraLocked[id] = nil
    status[id] = nil
    ClearRedirect(id)
    UnloadMarker(id)
end

--- After each Questie pass: draws, updates and removes the red markers of chain steps Questie leaves out.
local DrawLockedChainsSafe

local function DrawLockedChains()
    if not (rawDraw and QuestieReady()) then return end
    if not childrenOf then
        BuildChildren(function() DrawLockedChainsSafe() end)
        return
    end
    local available = Q.AQ.__availableQuests or {}
    local want = db.settings.redirect and ChainSteps() or {}
    local nowAvailable = {}
    for id in pairs(extraLocked) do
        if not want[id] then
            DropExtra(id)
            -- (Questie skipped it this pass because our red marker was there: let it draw its own)
            if available[id] then nowAvailable[id] = true end
        end
    end
    local shown = ShownNpcs()
    for id in pairs(want) do
        local okQ, quest = pcall(Q.DB.GetQuest, id)
        local final, why
        if okQ and quest then
            local okE, verdict, w = pcall(EvaluateWithPrereqs, quest)
            if okE and verdict == HIDE and w and w.blocker then
                why = w
                local okF, f = pcall(FinalVerdict, id, verdict, why)
                if okF then final = f end
            end
        end
        if final == LOCK then
            pcall(Redirect, id, why)
            local root, reason, at = CachedRoot(why.blocker)
            local key = select(2, LockedStarts(quest, shown)) .. "|" .. tostring(root or at) .. "|" .. tostring(reason)
            if extraLocked[id] ~= key or (status[id] and status[id].verdict == LOCK and not HasMarker(id)) then
                UnloadMarker(id)
                extraLocked[id] = key
                DrawLocked(quest, why)
            end
        elseif extraLocked[id] then
            DropExtra(id)
        end
    end
    if next(nowAvailable) then Redraw(nowAvailable) end
end

DrawLockedChainsSafe = function()
    local ok, err = pcall(DrawLockedChains)
    if not ok then ChainError(err) end
end

---------------------------------------------------------------------------
-- Hooks into Questie
---------------------------------------------------------------------------

local function InstallHooks()
    if hooked then return true end
    Q.AQ = Import("AvailableQuests")
    Q.DB = Import("QuestieDB")
    Q.Player = Import("QuestiePlayer")
    Q.Zone = Import("ZoneDB")
    Q.Map = Import("QuestieMap")
    Q.Pool = Import("QuestieFramePool")
    Q.Compat = Import("QuestieCompat")
    if not (Q.AQ and Q.AQ.DrawAvailableQuest and Q.DB) then
        Print("couldn't find Questie's available-quest code; this Questie version isn't supported. Nothing was changed.")
        return false
    end

    Q.Corr = Import("QuestieCorrections")
    local originalDraw = Q.AQ.DrawAvailableQuest
    rawDraw = originalDraw
    Q.AQ.DrawAvailableQuest = function(quest)
        if not (quest and quest.Id and db) then return originalDraw(quest) end
        local ok, verdict, why, proxy = pcall(Evaluate, quest)
        if not ok then
            if not warnedError then
                warnedError = true
                Print("error while checking a quest, showing Questie's markers unchanged:", tostring(verdict))
            end
            return originalDraw(quest)
        end
        if verdict == HIDE then
            pcall(Redirect, quest.Id, why)
            local okL, final = pcall(FinalVerdict, quest.Id, verdict, why)
            if okL and final == LOCK then
                -- keep this quest's marker, drawn red, with a tooltip line naming the step to do first
                DrawLocked(quest, why)
                return
            end
            status[quest.Id] = { verdict = verdict, why = why, root = redirectOf[quest.Id] }
            return
        end
        ClearRedirect(quest.Id)
        local drawnQuest = proxy or quest
        status[quest.Id] = { verdict = verdict, why = why, npcs = drawnQuest.Starts and drawnQuest.Starts.NPC }
        return originalDraw(drawnQuest)
    end
    hookedDraw = Q.AQ.DrawAvailableQuest

    Q.Tooltips = Import("QuestieTooltips")
    local MIT = Import("MapIconTooltip")
    if MIT and MIT.ShowOnTooltip then
        local originalShow = MIT.ShowOnTooltip
        MIT.ShowOnTooltip = function(self, tooltip, ...)
            local before = tooltip and tooltip._Rebuild
            originalShow(self, tooltip, ...)
            -- Questie sets a new _Rebuild only when it actually built this tooltip (it returns early for
            -- faded icons and repeated hovers): only then are its quest lists ours to annotate.
            if tooltip and tooltip._Rebuild ~= before then
                local ok, err = pcall(DecorateTooltip, tooltip)
                if not ok and not warnedTooltip then
                    warnedTooltip = true
                    Print("error while adding to a map tooltip: " .. tostring(err))
                end
            elseif tooltip then
                Verbose("map tooltip: Questie didn't rebuild it, so nothing was added")
            end
        end
    end

    if Q.AQ.CalculateAndDrawAll then
        local originalCalc = Q.AQ.CalculateAndDrawAll
        Q.AQ.CalculateAndDrawAll = function(callback, ...)
            rootCache = {}
            return originalCalc(function(...)
                pcall(PruneRedirects)
                DrawLockedChainsSafe()
                pcall(RecheckLocked)
                if callback then return callback(...) end
            end, ...)
        end
    end

    if Q.Pool and Q.Pool.GetFrame then
        local originalGetFrame = Q.Pool.GetFrame
        Q.Pool.GetFrame = function(self, ...)
            local frame = originalGetFrame(self, ...)
            if frame and not frame.__questieVerify and frame.UpdateTexture then
                frame.__questieVerify = true
                local originalUpdate = frame.UpdateTexture
                frame.UpdateTexture = function(f, ...)
                    originalUpdate(f, ...)
                    pcall(ApplyDim, f)
                end
            end
            return frame
        end
    end

    -- Questie's icon-colour option recolours every icon directly; put the red back on locked markers.
    if Q.Pool and Q.Pool.UpdateColorConfig then
        local originalColors = Q.Pool.UpdateColorConfig
        Q.Pool.UpdateColorConfig = function(...)
            originalColors(...)
            if not (Q.Map and Q.Map.GetFramesForQuest) then return end
            for id, st in pairs(status) do
                if st.verdict == LOCK then
                    local ok, frames = pcall(Q.Map.GetFramesForQuest, Q.Map, id)
                    if ok and type(frames) == "table" then
                        for _, f in pairs(frames) do pcall(ApplyDim, f) end
                    end
                end
            end
        end
    end

    hooked = true
    BuildChildren(DrawLockedChainsSafe)
    return true
end

---------------------------------------------------------------------------
-- Learning from NPC dialogs
---------------------------------------------------------------------------

local function NpcFromUnit(unit)
    local guid = UnitGUID(unit)
    if not guid or (issecretvalue and issecretvalue(guid)) then return nil, nil end
    local kind, _, _, _, _, npcId = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then
        return guid, tonumber(npcId)
    end
    return guid, nil
end

local function GreenRange()
    if Q.Compat and Q.Compat.GetQuestGreenRange then
        local ok, range = pcall(Q.Compat.GetQuestGreenRange, "player")
        if ok and range then return range end
    end
    if GetQuestGreenRange then return GetQuestGreenRange("player") or 8 end
    return 8
end

--- Whether an NPC not listing this quest really means it isn't available.
local function CanJudgeAbsence(id, level)
    local available = Q.AQ and Q.AQ.__availableQuests
    if not (available and available[id]) then return false end
    if IsDone(id) then return false end
    local requiredLevel = QField(id, "requiredLevel") or 1
    if level < requiredLevel then return false end
    local questLevel = QField(id, "questLevel")
    if questLevel and questLevel > 0 and level - questLevel > GreenRange() then
        return false -- gray quests may be filtered out of the NPC's list by the game
    end
    for _, fn in ipairs({ "IsRepeatable", "IsDailyQuest", "IsWeeklyQuest" }) do
        if Q.DB[fn] then
            local ok, yes = pcall(Q.DB[fn], id)
            if ok and yes then return false end -- Questie handles these itself
        end
    end
    return true
end

--- offered: quests the NPC offers; present: quests it lists as active (turn-ins).
--- complete: the lists are known to be complete, so absence means "not offered".
local function Learn(npcId, offered, present, complete)
    local changed = {}
    for id in pairs(offered) do
        cdb.confirmed[id] = time()
        if npcId then
            db.offeredBy[id] = db.offeredBy[id] or {}
            db.offeredBy[id][npcId] = true
            if cdb.notOffered[id] and cdb.notOffered[id][npcId] then
                cdb.notOffered[id][npcId] = nil
                changed[id] = true
            end
            if db.wrongStarter[id] and db.wrongStarter[id][npcId] then
                db.wrongStarter[id][npcId] = nil
                changed[id] = true
            end
        end
        local st = status[id]
        if st and st.verdict ~= OK then changed[id] = true end
    end

    if npcId and complete and db.settings.learn then
        local expected = Q.AQ.__availableQuestsByNpc and Q.AQ.__availableQuestsByNpc[npcId]
        if expected then
            local level = PlayerLevel()
            for id in pairs(expected) do
                if not offered[id] and not present[id] and CanJudgeAbsence(id, level) then
                    cdb.notOffered[id] = cdb.notOffered[id] or {}
                    cdb.notOffered[id][npcId] = { lvl = level, t = time() }
                    cdb.confirmed[id] = nil
                    changed[id] = true
                    Print(format("%s doesn't offer %s yet; hiding that marker.", NpcName(npcId), QuestName(id)))
                end
            end
        end
    end

    if next(changed) then Redraw(changed) end
end

local function OnGossipShow()
    if not hooked then return end
    local guid, npcId = NpcFromUnit("npc")
    lastDialog.guid, lastDialog.npcId, lastDialog.t = guid, npcId, GetTime()
    lastQuestEvent = GetTime()
    if not (C_GossipInfo and C_GossipInfo.GetAvailableQuests) then return end

    local offered, present = {}, {}
    local complete = true
    for _, info in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
        if info.questID and info.questID > 0 then offered[info.questID] = true else complete = false end
    end
    if C_GossipInfo.GetActiveQuests then
        for _, info in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
            if info.questID and info.questID > 0 then present[info.questID] = true end
        end
    end
    Learn(npcId, offered, present, complete)
end

local function OnQuestGreeting()
    if not hooked then return end
    local guid, npcId = NpcFromUnit("npc")
    lastDialog.guid, lastDialog.npcId, lastDialog.t = guid, npcId, GetTime()
    lastQuestEvent = GetTime()

    local offered, present = {}, {}
    local complete = true
    local getId = Q.Compat and Q.Compat.GetQuestGreetingQuestID
    if not getId then return end
    for i = 1, (GetNumActiveQuests and GetNumActiveQuests() or 0) do
        local ok, id = pcall(getId, i, true, guid)
        if ok and id and id > 0 then present[id] = true end
    end
    for i = 1, (GetNumAvailableQuests and GetNumAvailableQuests() or 0) do
        local ok, id = pcall(getId, i, false, guid)
        if ok and id and id > 0 then offered[id] = true else complete = false end
    end
    Learn(npcId, offered, present, complete)
end

local function OnQuestDetail()
    if not hooked then return end
    local id = GetQuestID and GetQuestID() or 0
    if id == 0 then return end
    local guid, npcId = NpcFromUnit("questnpc")
    if not guid then guid, npcId = NpcFromUnit("npc") end
    local now = GetTime()
    -- Straight to the quest text with no list first: the NPC has exactly this one quest for you.
    -- Not provable right after a list, a turn-in or an accept (follow-up quests open by themselves).
    local fresh = (now - lastQuestEvent) > 5 and not (guid and lastDialog.guid == guid and now - lastDialog.t < 30)
    lastDialog.guid, lastDialog.npcId, lastDialog.t = guid, npcId, now
    Learn(npcId, { [id] = true }, {}, fresh and npcId ~= nil)
end

local function OnQuestAccepted(a, b)
    local id = b or a
    lastQuestEvent = GetTime()
    if type(id) ~= "number" or not db then return end
    local marks = cdb.notOffered[id]
    if marks then
        local fromNpc = (GetTime() - lastDialog.t < 15) and lastDialog.npcId or nil
        for npc in pairs(marks) do
            if npc ~= fromNpc then
                db.wrongStarter[id] = db.wrongStarter[id] or {}
                db.wrongStarter[id][npc] = true
                Verbose(format("%s: remembered %s as a wrong quest giver.", QuestName(id), NpcName(npc)))
            end
        end
        cdb.notOffered[id] = nil
    end
    cdb.confirmed[id] = nil
end

---------------------------------------------------------------------------
-- Quest-line refresh
---------------------------------------------------------------------------

local function RefreshLines()
    local _, changed = ReadAvailableLines()
    if changed and next(changed) then
        local redraw = {}
        for id in pairs(changed) do
            if status[id] and status[id].verdict ~= OK then redraw[id] = true end
        end
        if next(redraw) then Redraw(redraw) end
    end
end

local function RequestLines()
    local mapId = PlayerMap()
    if mapId and C_QuestLine and C_QuestLine.RequestQuestLinesForMap then
        pcall(C_QuestLine.RequestQuestLinesForMap, mapId)
    end
    C_Timer.After(1.5, RefreshLines)
end

---------------------------------------------------------------------------
-- /qv scan
---------------------------------------------------------------------------

function QV.Scan(all, quiet)
    if not QuestieReady() then if quiet then return end Print("Questie hasn't finished loading yet; try again in a moment.") return end
    EnsureBtW()
    local mapId = PlayerMap()
    local where = all and "all zones" or format("%s (map %s)", MapName(mapId), tostring(mapId))

    local api = {
        GetQuestLineInfo = C_QuestLine and C_QuestLine.GetQuestLineInfo and true or false,
        GetQuestLineQuests = C_QuestLine and C_QuestLine.GetQuestLineQuests and true or false,
        GetAvailableQuestLines = C_QuestLine and C_QuestLine.GetAvailableQuestLines and true or false,
        RequestQuestLinesForMap = C_QuestLine and C_QuestLine.RequestQuestLinesForMap and true or false,
        GossipAvailableQuests = C_GossipInfo and C_GossipInfo.GetAvailableQuests and true or false,
    }

    local counts = { total = 0, line = 0, btw = 0, questie = 0, fdb = 0, none = 0, [HIDE] = 0, [LOCK] = 0, [DIM] = 0, [OK] = 0 }
    local rows = {}
    for id in pairs(Q.AQ.__availableQuests or {}) do
        local qMap = QuestUiMap(id)
        if all or (qMap and qMap == mapId) then
            local okQuest, quest = pcall(Q.DB.GetQuest, id)
            if okQuest and quest then
                counts.total = counts.total + 1
                local inLine = GetLine(id) ~= nil
                local inBtw = btw and btw.quests[id] ~= nil or false
                local hasPrereq = QuestieHasPrereq(id) and true or false
                local inFdb = (FdbQuest(id) or (ns.qff and ns.qff[id])) and true or false
                if inFdb then counts.fdb = counts.fdb + 1 end
                if inLine then counts.line = counts.line + 1 end
                if inBtw then counts.btw = counts.btw + 1 end
                if hasPrereq then counts.questie = counts.questie + 1 end
                if not (inLine or inBtw or hasPrereq or inFdb) then counts.none = counts.none + 1 end
                local okEval, verdict, why = pcall(Evaluate, quest)
                if not okEval then verdict, why = OK, { "error: " .. tostring(verdict) } end
                if verdict == HIDE and why.blocker and db.settings.redirect then pcall(ResolveRoot, why.blocker, why) end
                local okF, final = pcall(FinalVerdict, id, verdict, why)
                if okF then verdict = final end
                counts[verdict] = counts[verdict] + 1
                tinsert(rows, {
                    id = id, name = QField(id, "name"), map = qMap,
                    gameLine = inLine, btw = inBtw, questiePrereq = hasPrereq, foreverdb = inFdb,
                    verdict = verdict, why = table.concat(why or {}, "; "),
                })
            end
        end
    end
    table.sort(rows, function(x, y) return x.id < y.id end)

    local lines = {}
    local list = ReadAvailableLines(mapId)
    local lineSummary = "not available in this client"
    if list then
        local shown, notShown = 0, 0
        for _, info in ipairs(list) do
            local byQuestie = Q.AQ.__availableQuests[info.questID] and true or false
            if byQuestie then shown = shown + 1 else notShown = notShown + 1 end
            tinsert(lines, { id = info.questID, name = info.questName, line = info.questLineName, questieShows = byQuestie })
        end
        lineSummary = format("%d (Questie also shows %d; %d Questie doesn't show)", #list, shown, notShown)
    end

    local btwSummary = btw and btw.ok and format("%d chains loaded", btw.chains) or "not installed / not loaded"

    db.scans = db.scans or {}
    db.scans[all and "ALL" or tostring(mapId)] = {
        when = date("%Y-%m-%d %H:%M"), zone = all and "ALL" or MapName(mapId), mapId = mapId,
        level = PlayerLevel(), api = api, counts = counts, rows = rows, serverLines = lines,
        btw = btwSummary,
    }

    if quiet then return end
    local function yn(b) return b and "yes" or "|cffff5555no|r" end
    Print(format("scan of %s: Questie shows %d available quests.", where, counts.total))
    Print(format("  in ForeverDB data: %d   in a game quest line: %d   in a BtWQuests chain: %d   Questie has a prerequisite: %d   none of these: %d",
        counts.fdb, counts.line, counts.btw, counts.questie, counts.none))
    Print(format("  result: %d hidden, %d locked (red, pointing to the step before), %d dimmed, %d shown (dim mode: %s)",
        counts[HIDE], counts[LOCK], counts[DIM], counts[OK], db.settings.dim))
    Print("  game's own list of startable quest-line quests here: " .. lineSummary)
    Print(format("  APIs: GetQuestLineInfo %s, GetQuestLineQuests %s, GetAvailableQuestLines %s, gossip quest IDs %s; BtWQuests: %s",
        yn(api.GetQuestLineInfo), yn(api.GetQuestLineQuests), yn(api.GetAvailableQuestLines), yn(api.GossipAvailableQuests), btwSummary))
    Print("  full list saved; /qv why <questID> explains any one quest.")
    if ns.fdb then Print("  " .. FDB_CREDIT) end
end

function QV.Why(id)
    if not QuestieReady() then Print("Questie hasn't finished loading yet.") return end
    local ok, quest = pcall(Q.DB.GetQuest, id)
    if not (ok and quest) then Print(format("Questie doesn't know quest %d.", id)) return end
    local okEval, verdict, why = pcall(EvaluateWithPrereqs, quest)
    if not okEval then Print("error:", tostring(verdict)) return end
    if verdict == HIDE and why.blocker and db.settings.redirect then pcall(ResolveRoot, why.blocker, why) end
    local okF, final = pcall(FinalVerdict, id, verdict, why)
    if okF then verdict = final end
    Print(format("%s: %s", QuestName(id), VERDICT_LABEL[verdict]))
    local from = StarterText(id)
    Print(format("   picked up%s, from level %d%s", from ~= "" and from or " (giver unknown to Questie)", RequiredLevel(id),
        StepText(id)))
    if verdict == LOCK then
        local line = LockedLine(id, why.blocker)
        if line then Print("   " .. line) end
    end
    local credit = false
    for _, reason in ipairs(why or {}) do
        Print("   - " .. reason)
        if reason:find("^ForeverDB") then credit = true end
    end
    if credit then Print("   " .. FDB_CREDIT) end
    if extraLocked[id] then
        Print("   (a later step of a chain Questie doesn't show: QuestieVerify draws its red marker itself)")
    elseif not (Q.AQ.__availableQuests or {})[id] then
        Print("   (Questie itself doesn't currently show it as available, so it has no marker either way)")
    end
    -- what the red chain markers see, for a locked quest Questie doesn't show
    if verdict == LOCK and not extraLocked[id] and not (Q.AQ.__availableQuests or {})[id] then
        if chainError then
            Print("   chain markers stopped by an error: " .. chainError)
        elseif not childrenOf then
            Print(childrenBuilding and "   chain markers: still reading Questie's quest list"
                or "   chain markers: Questie's quest list wasn't ready yet; it's read on the next marker update")
        else
            -- walk the chain back and say where it stops
            local available = Q.AQ.__availableQuests or {}
            local level = PlayerLevel()
            local function ParentsOf(q)
                local out = {}
                for p, kids in pairs(childrenOf) do
                    for _, c in ipairs(kids) do if c == q then out[#out + 1] = p break end end
                end
                return out
            end
            Print(format("   chain markers (%d quests read), walking back from this quest:", chainQuestCount))
            local step, seen = id, {}
            for _ = 1, CHAIN_DEPTH + 2 do
                if seen[step] then break end
                seen[step] = true
                local fits, reason = ChainStepFits(step, available, true)
                local open = nil
                for _, p in ipairs(ParentsOf(step)) do
                    if not IsComplete(p) then open = p break end
                end
                if open then
                    Print(format("     %s: %s; comes after %s", QuestName(step), fits and "ok" or ("left out (" .. reason .. ")"),
                        QuestName(open)))
                    step = open
                else
                    local req = RequiredLevel(step)
                    local start
                    if available[step] then start = "Questie shows it, so the chain starts here"
                    elseif InLog(step) then start = "it's in your log, so the chain starts here"
                    elseif QuestieBlocker(step) then start = "Questie says it needs " .. QuestName(QuestieBlocker(step))
                    elseif FdbBlocked(step) then start = "ForeverDB lists an earlier step that isn't handed in"
                    elseif req <= level then start = format("needs level %d, but Questie doesn't show it", req)
                    elseif req > level + LEVELS_AHEAD then start = format("needs level %d: too far above you", req)
                    elseif not fits then start = "left out (" .. reason .. ")"
                    else start = format("needs level %d: should start a chain", req) end
                    Print(format("     %s: first step; %s", QuestName(step), start))
                    break
                end
            end
            local okW, want = pcall(ChainSteps)
            Print("     red marker wanted for this quest: " .. (okW and tostring(want[id] and true or false)
                or ("error: " .. tostring(want))))
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Help()
    Print("commands (or type /qv on its own for the options window):")
    print("  /qv scan          test the current zone: which quests each data source covers")
    print("  /qv scan all      the same for every quest Questie shows")
    print("  /qv why <id>      why a quest's marker is shown, dimmed or hidden")
    print("  /qv dim off|uncertain|unverified   dimming (now: " .. db.settings.dim .. ")")
    print("      uncertain  = only when the evidence is unclear")
    print("      unverified = also quests no source can confirm")
    print("  /qv learn on|off  learn from what NPCs offer (now: " .. (db.settings.learn and "on" or "off") .. ")")
    print("  /qv chains on|off use quest-chain data (now: " .. (db.settings.chains and "on" or "off") .. ")")
    print("  /qv foreverdb on|off  use ForeverDB.net data (now: " .. (db.settings.foreverdb and "on" or "off")
        .. (ns.fdb and (", ForeverDB " .. tostring(ns.fdb.version) .. ")") or ", data file missing)"))
    print("      " .. FDB_CREDIT)
    print("  /qv redirect on|off  blocked quests show a red marker that points to the quest to do first (now: " .. (db.settings.redirect and "on" or "off") .. ")")
    print("  /qv autoscan on|off  quietly record a scan of each zone you enter (now: " .. (db.settings.autoscan and "on" or "off") .. ")")
    print("  /qv revisit <n>   levels before a 'not offered' marker comes back dimmed (now: " .. db.settings.revisitLevels .. ")")
    print("  /qv forget <id>   forget what was learned about a quest   |   /qv forget all")
    print("  /qv refresh       re-check every marker now")
    print("  /qv verbose       toggle extra chat messages")
end

local function Slash(msg)
    local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    arg = arg or ""
    if cmd == "scan" then
        QV.Scan(arg:lower() == "all")
    elseif cmd == "why" then
        local id = tonumber(arg:match("%d+") or "")
        if id then QV.Why(id) else Print("usage: /qv why <questID>  (turn on Questie > Advanced > Show Quest IDs to see IDs)") end
    elseif cmd == "dim" then
        arg = arg:lower()
        if arg == "off" or arg == "uncertain" or arg == "unverified" then
            db.settings.dim = arg
            Print("dim mode: " .. arg)
            Redraw()
        else
            Print("usage: /qv dim off|uncertain|unverified")
        end
    elseif cmd == "learn" or cmd == "chains" or cmd == "foreverdb" or cmd == "redirect" or cmd == "autoscan" then
        local value = arg:lower()
        if value == "on" or value == "off" then
            db.settings[cmd] = (value == "on")
            Print(cmd .. ": " .. value)
            Redraw()
        else
            Print("usage: /qv " .. cmd .. " on|off")
        end
    elseif cmd == "revisit" then
        local n = tonumber(arg)
        if n and n >= 0 then
            db.settings.revisitLevels = math.floor(n)
            Print("revisit after " .. db.settings.revisitLevels .. " levels")
            Redraw()
        else
            Print("usage: /qv revisit <levels>")
        end
    elseif cmd == "forget" then
        if arg:lower() == "all" then
            cdb.notOffered, cdb.confirmed = {}, {}
            db.wrongStarter, db.offeredBy = {}, {}
            Print("forgot everything learned from NPCs.")
        else
            local id = tonumber(arg)
            if not id then Print("usage: /qv forget <questID> | all") return end
            cdb.notOffered[id], cdb.confirmed[id] = nil, nil
            db.wrongStarter[id], db.offeredBy[id] = nil, nil
            Print("forgot what was learned about " .. QuestName(id))
        end
        Redraw()
    elseif cmd == "refresh" then
        lineCache = {}
        btw = nil
        EnsureBtW()
        RequestLines()
        Redraw()
        Print("re-checking all markers.")
    elseif cmd == "verbose" then
        db.settings.verbose = not db.settings.verbose
        Print("verbose: " .. (db.settings.verbose and "on" or "off"))
    elseif (cmd == "" or cmd == "options" or cmd == "config") and QV.OpenOptions then
        QV.OpenOptions()
    else
        Help()
    end
end

-- For the options panel (Options.lua).
QV.Command = function(msg) Slash(msg) end
QV.GetSettings = function() return db and db.settings end
local redrawQueued = false
QV.SetSetting = function(key, value)
    if not (db and DEFAULTS[key] ~= nil) or db.settings[key] == value then return end
    db.settings[key] = value
    if key == "verbose" or key == "autoscan" or redrawQueued then return end
    -- one redraw shortly after the last click, not one per click
    redrawQueued = true
    C_Timer.After(0.5, function() redrawQueued = false; Redraw() end)
end
QV.FdbInfo = function() return ns.fdb and ns.fdb.version, ns.fdb and ns.fdb.build, FDB_CREDIT end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

local function InitSaved()
    QuestieVerifyDB = QuestieVerifyDB or {}
    QuestieVerifyCharDB = QuestieVerifyCharDB or {}
    db, cdb = QuestieVerifyDB, QuestieVerifyCharDB
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.wrongStarter = db.wrongStarter or {}
    db.offeredBy = db.offeredBy or {}
    cdb.notOffered = cdb.notOffered or {}
    cdb.confirmed = cdb.confirmed or {}
end

local function WhenQuestieReady(fn, tries)
    tries = tries or 0
    if QuestieReady() then
        fn()
    elseif tries < 120 then
        C_Timer.After(1, function() WhenQuestieReady(fn, tries + 1) end)
    end
end

local lastAutoScan = {}
local function AutoScan()
    if not (db and db.settings.autoscan) then return end
    C_Timer.After(8, function()
        WhenQuestieReady(function()
            local mapId = PlayerMap()
            if not mapId or (lastAutoScan[mapId] and GetTime() - lastAutoScan[mapId] < 60) then return end
            lastAutoScan[mapId] = GetTime()
            pcall(QV.Scan, false, true)
        end)
    end)
end

-- The data file is built from the installed ForeverDB addon by the installer; say so once when it's missing or older.
-- The version comes from ForeverDB's .toc, which the game reads even when ForeverDB is switched off in game.
local function InstalledFdbVersion()
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
    local ok, v = pcall(meta, "ForeverDB", "Version")
    if ok and type(v) == "string" and v ~= "" then return v end
    local fc = _G.ForeverDB_Companion
    return type(fc) == "table" and fc.version or nil
end

local function CheckFdbData()
    local have = InstalledFdbVersion()
    if not have or not db or db.fdbNotice == have then return end
    local built = ns.fdb and ns.fdb.version
    if built == have then return end
    db.fdbNotice = have
    if built then
        Print(format("ForeverDB was updated (%s to %s). To refresh QuestieVerify's copy of its data, quit WoW, "
            .. "double-click 'Install QuestieVerify' again and restart WoW.", built, have))
    else
        Print("ForeverDB is installed, but QuestieVerify hasn't read its data yet. Quit WoW, double-click "
            .. "'Install QuestieVerify' and restart WoW to catch many more wrong quest markers.")
    end
end

local frame = CreateFrame("Frame")
for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_DETAIL", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "QUEST_COMPLETE", "QUEST_PROGRESS", "QUESTLINE_UPDATE",
}) do
    pcall(frame.RegisterEvent, frame, event) -- an event this client doesn't have is skipped
end

local firstWorld = true
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then
            InitSaved()
            InstallHooks()
            SLASH_QUESTIEVERIFY1 = "/qv"
            SLASH_QUESTIEVERIFY2 = "/questieverify"
            SlashCmdList.QUESTIEVERIFY = Slash
        end
    elseif not db or not hooked then
        return
    elseif event == "PLAYER_LOGIN" then
        loggedIn = true
        C_Timer.After(12, CheckFdbData)
    elseif event == "PLAYER_ENTERING_WORLD" then
        RequestLines()
        if firstWorld then
            firstWorld = false
            -- BtWQuests loads its zone data around login; build the index once that's done,
            -- then re-check whatever Questie already drew.
            C_Timer.After(2, function()
                EnsureBtW()
                WhenQuestieReady(function() Redraw() end)
            end)
        end
        AutoScan()
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        RequestLines()
        AutoScan()
    elseif event == "QUESTLINE_UPDATE" then
        RefreshLines()
    elseif event == "GOSSIP_SHOW" then
        OnGossipShow()
    elseif event == "QUEST_GREETING" then
        OnQuestGreeting()
    elseif event == "QUEST_DETAIL" then
        OnQuestDetail()
    elseif event == "QUEST_ACCEPTED" then
        OnQuestAccepted(...)
        C_Timer.After(1, RequestLines)
        C_Timer.After(0.5, function() rootCache = {} pcall(PruneRedirects) end)
    elseif event == "QUEST_TURNED_IN" then
        lastQuestEvent = GetTime()
        C_Timer.After(1, RequestLines)
        C_Timer.After(0.5, function()
            rootCache = {}
            pcall(PruneRedirects)
            pcall(RecheckLocked)   -- (Questie's own pass after a turn-in re-checks them too)
        end)
    elseif event == "QUEST_COMPLETE" or event == "QUEST_PROGRESS" then
        lastQuestEvent = GetTime()
    end
end)

-- Exposed for debugging: /dump QuestieVerify.status[questId]
QV.status = status
QV._internal = { ApplyDim = ApplyDim,   -- for the test harness only; not an API
    RebuildChildren = function() childrenOf = nil; parentLevel = {}; longestAfter = {}; BuildChildren() end }
function QV.ClearCaches() rootCache = {} end
QV.lineAvailable = lineAvailable
function QV.GetBtWIndex() EnsureBtW() return btw end
