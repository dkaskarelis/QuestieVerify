-- QuestieVerify
--
-- Questie draws a "!" for every quest its database thinks you can take. When the database is
-- missing a prerequisite (common for quest chains changed or added in WoW Forever) or lists the
-- wrong quest giver, you travel there for nothing. This add-on second-guesses each "!" before
-- Questie draws it:
--
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

local ADDON_NAME = ...

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

--- Completed, or currently in the quest log.
local function IsDone(id)
    if not id then return false end
    local complete = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
    if complete and complete[id] then return true end
    if C_QuestLog then
        if C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) then return true end
        if C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id) then return true end
        if C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) then return true end
    end
    if GetQuestLogIndexByID and (GetQuestLogIndexByID(id) or 0) > 0 then return true end
    return false
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
    if IsDone(p1) then
        tinsert(why, format("game quest line '%s': previous step %s is done", lineName, QuestName(p1)))
        return OK
    end
    if p2 and IsDone(p2) then
        -- Quest lines are flat lists; parallel steps look sequential. Not sure enough to hide.
        tinsert(why, format("game quest line '%s': previous step %s isn't done (could be a side branch)", lineName, QuestName(p1)))
        return DIM
    end
    tinsert(why, format("game quest line '%s': previous step %s isn't done", lineName, QuestName(p1)))
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
        if IsDone(q) then return true end
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
        for _, npc in ipairs(npcs) do
            if wrong and wrong[npc] then
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
    if questIds == nil then
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
        status[quest.Id] = { verdict = verdict, why = why }
        if verdict == HIDE then return end
        return originalDraw(proxy or quest)
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

function QV.Scan(all)
    if not QuestieReady() then Print("Questie hasn't finished loading yet; try again in a moment.") return end
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

    local counts = { total = 0, line = 0, btw = 0, questie = 0, none = 0, [HIDE] = 0, [DIM] = 0, [OK] = 0 }
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
                if inLine then counts.line = counts.line + 1 end
                if inBtw then counts.btw = counts.btw + 1 end
                if hasPrereq then counts.questie = counts.questie + 1 end
                if not (inLine or inBtw or hasPrereq) then counts.none = counts.none + 1 end
                local okEval, verdict, why = pcall(Evaluate, quest)
                if not okEval then verdict, why = OK, { "error: " .. tostring(verdict) } end
                counts[verdict] = counts[verdict] + 1
                tinsert(rows, {
                    id = id, name = QField(id, "name"), map = qMap,
                    gameLine = inLine, btw = inBtw, questiePrereq = hasPrereq,
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

    local function yn(b) return b and "yes" or "|cffff5555no|r" end
    Print(format("scan of %s: Questie shows %d available quests.", where, counts.total))
    Print(format("  in a game quest line: %d   in a BtWQuests chain: %d   Questie has a prerequisite: %d   none of these: %d",
        counts.line, counts.btw, counts.questie, counts.none))
    Print(format("  result: %d hidden, %d dimmed, %d shown (dim mode: %s)", counts[HIDE], counts[DIM], counts[OK], db.settings.dim))
    Print("  game's own list of startable quest-line quests here: " .. lineSummary)
    Print(format("  APIs: GetQuestLineInfo %s, GetQuestLineQuests %s, GetAvailableQuestLines %s, gossip quest IDs %s; BtWQuests: %s",
        yn(api.GetQuestLineInfo), yn(api.GetQuestLineQuests), yn(api.GetAvailableQuestLines), yn(api.GossipAvailableQuests), btwSummary))
    Print("  full list saved; /qv why <questID> explains any one quest.")
end

function QV.Why(id)
    if not QuestieReady() then Print("Questie hasn't finished loading yet.") return end
    local ok, quest = pcall(Q.DB.GetQuest, id)
    if not (ok and quest) then Print(format("Questie doesn't know quest %d.", id)) return end
    local okEval, verdict, why = pcall(Evaluate, quest)
    if not okEval then Print("error:", tostring(verdict)) return end
    Print(format("%s: %s", QuestName(id), VERDICT_LABEL[verdict]))
    for _, reason in ipairs(why or {}) do Print("   - " .. reason) end
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
    elseif cmd == "learn" or cmd == "chains" then
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
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        RequestLines()
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
    elseif event == "QUEST_TURNED_IN" then
        lastQuestEvent = GetTime()
        C_Timer.After(1, RequestLines)
    elseif event == "QUEST_COMPLETE" or event == "QUEST_PROGRESS" then
        lastQuestEvent = GetTime()
    end
end)

-- Exposed for debugging: /dump QuestieVerify.status[questId]
QV.status = status
QV.lineAvailable = lineAvailable
function QV.GetBtWIndex() EnsureBtW() return btw end
