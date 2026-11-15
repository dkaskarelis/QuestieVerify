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
local VERDICT_LABEL = {
    [HIDE] = "|cffff5555hidden|r",
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
local hookedDraw       -- the wrapped DrawAvailableQuest
local redirecting = false

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
                local req = QField(p, "requiredLevel") or 0
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
        tinsert(why, format("the first step, %s, needs level %d", QuestName(at), QField(at, "requiredLevel") or 0))
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
        if not available[id] then ClearRedirect(id) end
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

local function AddUnlockLines(tooltip)
    local order = tooltip and tooltip.npcAndObjectOrder
    if not order then return false end
    local added = false
    local done = {}
    for _, quests in pairs(order) do
        for _, tip in pairs(quests) do
            local root = type(tip) == "table" and tip.questId
            if root and unlocks[root] and not done[root] then
                done[root] = true
                local names = {}
                for id in pairs(unlocks[root]) do tinsert(names, QuestTitle(id)) end
                table.sort(names)
                if #names > 0 then
                    if not added then tooltip:AddLine(" ") end
                    tooltip:AddLine(format("|cff33ff99QuestieVerify:|r %s unlocks %s", QuestTitle(root), table.concat(names, ", ")),
                        1, 0.82, 0, true)
                    added = true
                end
            end
        end
    end
    return added
end

local function DecorateTooltip(tooltip)
    if not tooltip then return end
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
    local dim = data and data.Type == "available" and data.Id and ShouldDim(data.Id) or false
    if frame.texture and frame.texture.SetDesaturated then
        frame.texture:SetDesaturated(dim)
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
    for id in pairs(questIds) do
        pcall(Q.AQ.RemoveQuest, id)
    end
    Q.AQ.CalculateAndDrawAll()
end
QV.Redraw = Redraw

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

    local originalDraw = Q.AQ.DrawAvailableQuest
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
            status[quest.Id] = { verdict = verdict, why = why, root = redirectOf[quest.Id] }
            return
        end
        ClearRedirect(quest.Id)
        status[quest.Id] = { verdict = verdict, why = why }
        return originalDraw(proxy or quest)
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
            if tooltip and tooltip._Rebuild ~= before then pcall(DecorateTooltip, tooltip) end
        end
    end

    if Q.AQ.CalculateAndDrawAll then
        local originalCalc = Q.AQ.CalculateAndDrawAll
        Q.AQ.CalculateAndDrawAll = function(callback, ...)
            rootCache = {}
            return originalCalc(function(...)
                pcall(PruneRedirects)
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

    hooked = true
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

    local counts = { total = 0, line = 0, btw = 0, questie = 0, fdb = 0, none = 0, [HIDE] = 0, [DIM] = 0, [OK] = 0 }
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
    Print(format("  result: %d hidden, %d dimmed, %d shown (dim mode: %s)", counts[HIDE], counts[DIM], counts[OK], db.settings.dim))
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
    local okEval, verdict, why = pcall(Evaluate, quest)
    if not okEval then Print("error:", tostring(verdict)) return end
    if verdict == HIDE and why.blocker and db.settings.redirect then pcall(ResolveRoot, why.blocker, why) end
    Print(format("%s: %s", QuestName(id), VERDICT_LABEL[verdict]))
    local credit = false
    for _, reason in ipairs(why or {}) do
        Print("   - " .. reason)
        if reason:find("^ForeverDB") then credit = true end
    end
    if credit then Print("   " .. FDB_CREDIT) end
    if not (Q.AQ.__availableQuests or {})[id] then
        Print("   (Questie itself doesn't currently show it as available, so it has no marker either way)")
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Help()
    Print("commands:")
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
    print("  /qv redirect on|off  blocked quests point to the prerequisite to do first (now: " .. (db.settings.redirect and "on" or "off") .. ")")
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
    else
        Help()
    end
end

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
        C_Timer.After(0.5, function() rootCache = {} pcall(PruneRedirects) end)
    elseif event == "QUEST_COMPLETE" or event == "QUEST_PROGRESS" then
        lastQuestEvent = GetTime()
    end
end)

-- Exposed for debugging: /dump QuestieVerify.status[questId]
QV.status = status
function QV.ClearCaches() rootCache = {} end
QV.lineAvailable = lineAvailable
function QV.GetBtWIndex() EnsureBtW() return btw end
