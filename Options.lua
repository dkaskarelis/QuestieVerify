-- QuestieVerify options window: Esc > Options > AddOns > QuestieVerify, or type /qv.
-- Every control calls the same code as the chat commands (QuestieVerify.SetSetting / .Command).
local QV = _G.QuestieVerify
if not QV then return end

local panel = CreateFrame("Frame", "QuestieVerifyOptionsPanel")
panel.name = "QuestieVerify"
panel:Hide()

local refreshers = {}   -- functions that read the saved settings into the controls
local last              -- the element the next row goes under

local function S() return QV.GetSettings() or {} end
local function RefreshAll() for _, r in ipairs(refreshers) do r() end end

local function Tooltip(widget, title, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Puts a row under the previous one (so wrapped text pushes the rest down), `indent` from the left edge.
local function Row(widget, gap, indent, fullWidth)
    if last then
        widget:SetPoint("TOP", last, "BOTTOM", 0, -gap)
    else
        widget:SetPoint("TOP", panel, "TOP", 0, -16)
    end
    widget:SetPoint("LEFT", panel, "LEFT", indent, 0)
    if fullWidth then widget:SetPoint("RIGHT", panel, "RIGHT", -16, 0) end
    last = widget
    return widget
end

local function Text(template, text, gap, indent)
    local fs = panel:CreateFontString(nil, "ARTWORK", template)
    fs:SetJustifyH("LEFT")
    if text then fs:SetText(text) end
    return Row(fs, gap, indent, true)
end

--- A check box with a label; `onClick` is called with the new state.
local function Box(label, help, onClick)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    fs:SetText(label)
    cb:SetHitRectInsets(0, -(fs:GetStringWidth() + 8), 0, 0)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    Tooltip(cb, label, help)
    return cb
end

--- A check box row for an on/off setting.
local function Check(key, label, help, gap)
    local cb = Box(label, help, function(on) QV.SetSetting(key, on) end)
    tinsert(refreshers, function() cb:SetChecked(S()[key] and true or false) end)
    return Row(cb, gap or 2, 16)
end

local function Button(label, width, help, onClick)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    Tooltip(b, label, help)
    return b
end

-- Title
Text("GameFontNormalLarge", "QuestieVerify", 0, 16)
local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local version = getMeta and getMeta("QuestieVerify", "Version")
Text("GameFontHighlightSmall", (version and ("Version " .. version .. ". ") or "")
    .. "Checks each Questie \"!\" before it's drawn and hides, dims or redirects the ones you can't pick up yet.", 6, 16)

-- Markers
Text("GameFontNormal", "Markers", 16, 16)
Check("redirect", "Point blocked quests to the quest to do first",
    "A quest whose earlier chain step isn't done keeps a red \"!\". Its tooltip says which quest to pick up first and "
    .. "where. Off: those quests are hidden instead.", 4)

local dimLabel = Text("GameFontHighlight", "Dim markers:", 10, 20)
local dimModes = {
    { "off", "Never", "Never dim a marker. Quests are either shown or hidden." },
    { "uncertain", "When unsure", "Dim only markers whose evidence is unclear (the default)." },
    { "unverified", "Also unconfirmed", "Also dim quests that no data source can confirm." },
}
local prev
for i, mode in ipairs(dimModes) do
    local cb = Box(mode[2], mode[3], function()
        QV.SetSetting("dim", mode[1])
        RefreshAll()
    end)
    tinsert(refreshers, function() cb:SetChecked(S().dim == mode[1]) end)
    if i == 1 then Row(cb, 2, 30) else cb:SetPoint("LEFT", prev, "RIGHT", 130, 0) end
    prev = cb   -- (only the first choice is a row, so the next row goes under the choices)
end

-- Data sources
Text("GameFontNormal", "Data sources", 16, 16)
Check("foreverdb", "Use ForeverDB.net data",
    "Side, race, class, prerequisites and real quest givers from the ForeverDB addon, built by the installer.", 4)
local fdbStatus = Text("GameFontDisableSmall", nil, 0, 46)
tinsert(refreshers, function()
    local v, build, credit = QV.FdbInfo()
    if v then
        fdbStatus:SetText(format("ForeverDB %s, client build %s. %s", v, build or "?", credit))
    else
        fdbStatus:SetText("No ForeverDB data yet: install the ForeverDB addon, then run 'Install QuestieVerify' again. "
            .. credit)
    end
end)
Check("chains", "Use quest-chain data",
    "The game's own quest lines, and BtWQuests chains if BtWQuests is installed.", 6)

-- Learning
Text("GameFontNormal", "Learning from NPCs", 16, 16)
Check("learn", "Learn which quests NPCs really offer",
    "When you talk to a quest giver, quests Questie expected there that the NPC doesn't offer are hidden at that NPC.", 4)
local revisitLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
Row(revisitLabel, 10, 20)
local function RevisitText()
    local n = S().revisitLevels or 2
    revisitLabel:SetText(format("Show those again (dimmed) after %d level%s", n, n == 1 and "" or "s"))
end
local minus = Button("-", 26, "One level fewer before a 'not offered here' marker comes back dimmed.", function()
    QV.SetSetting("revisitLevels", math.max(0, (S().revisitLevels or 2) - 1)); RevisitText()
end)
local plus = Button("+", 26, "One level more before a 'not offered here' marker comes back dimmed.", function()
    QV.SetSetting("revisitLevels", math.min(20, (S().revisitLevels or 2) + 1)); RevisitText()
end)
minus:SetPoint("LEFT", revisitLabel, "RIGHT", 10, 0)
plus:SetPoint("LEFT", minus, "RIGHT", 2, 0)
tinsert(refreshers, RevisitText)

-- Other
Text("GameFontNormal", "Other", 18, 16)
Check("autoscan", "Quietly record a scan of each zone",
    "Saves which data sources cover each zone's quests in the SavedVariables file, without chat messages.", 4)
Check("verbose", "Extra chat messages", "Print a chat line when QuestieVerify hides a marker after talking to an NPC.")

-- Actions
Text("GameFontNormal", "Actions", 16, 16)
local recheck = Button("Re-check markers", 150, "Re-check every quest marker now.", function() QV.Command("refresh") end)
Row(recheck, 6, 20)
local scan = Button("Scan this zone", 150, "Print which data sources cover the quests in this zone.",
    function() QV.Command("scan") end)
scan:SetPoint("LEFT", recheck, "RIGHT", 8, 0)
local forget, armed
forget = Button("Forget learned", 150, "Forget everything learned from talking to NPCs, on all characters. Click twice.",
    function()
        if armed then
            armed = false
            forget:SetText("Forget learned")
            QV.Command("forget all")
        else
            armed = true
            forget:SetText("Click again")
            C_Timer.After(3, function() if armed then armed = false; forget:SetText("Forget learned") end end)
        end
    end)
forget:SetPoint("LEFT", scan, "RIGHT", 8, 0)
Text("GameFontDisableSmall", "To see why a marker is shown, dimmed, red or hidden, type /qv why <questID> (turn on "
    .. "Questie > Advanced > Show Quest IDs to see the IDs). /qv help lists every chat command.", 10, 20)

panel:SetScript("OnShow", RefreshAll)

-- Register with the game's options window; only without one does it open as its own window.
local category, legacy
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, "QuestieVerify")
    Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
    legacy = true
end

local function OpenStandalone()
    if not panel.standalone then
        panel.standalone = true
        panel:SetParent(UIParent)
        panel:SetSize(640, 600)
        panel:SetPoint("CENTER")
        panel:SetFrameStrata("DIALOG")
        panel:EnableMouse(true)
        panel:SetMovable(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        local bg = panel:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)
        local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)
        tinsert(UISpecialFrames, "QuestieVerifyOptionsPanel")
    end
    panel:Show()
end

function QV.OpenOptions()
    if InCombatLockdown and InCombatLockdown() then
        print("|cff33ff99QuestieVerify|r: the options window opens after combat.")
        return
    end
    if category then
        local id = (category.GetID and category:GetID()) or category.ID
        if not pcall(Settings.OpenToCategory, id) then
            print("|cff33ff99QuestieVerify|r: couldn't open the options; find it under Esc > Options > AddOns.")
        end
    elseif legacy and InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)   -- (the first call can land on the wrong page)
    else
        OpenStandalone()
    end
end
