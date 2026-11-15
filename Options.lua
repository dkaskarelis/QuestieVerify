-- QuestieVerify options window: Esc > Options > AddOns > QuestieVerify, or type /qv.
-- Every control calls the same code as the chat commands (QuestieVerify.SetSetting / .Command).
local QV = _G.QuestieVerify
if not QV then return end

local panel = CreateFrame("Frame", "QuestieVerifyOptionsPanel")
panel.name = "QuestieVerify"
panel:Hide()

local refreshers = {}   -- functions that read the saved settings into the controls

local function S() return QV.GetSettings() or {} end

local function Tooltip(widget, title, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Heading(text, y)
    local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 16, y)
    fs:SetText(text)
    return fs
end

local function Check(key, label, help, y, x)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x or 16, y)
    cb:SetSize(26, 26)
    local fs = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    fs:SetText(label)
    cb:SetHitRectInsets(0, -(fs:GetStringWidth() + 8), 0, 0)
    cb:SetScript("OnClick", function(self) QV.SetSetting(key, self:GetChecked() and true or false) end)
    Tooltip(cb, label, help)
    tinsert(refreshers, function() cb:SetChecked(S()[key] and true or false) end)
    return cb
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
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("QuestieVerify")
local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local version = getMeta and getMeta("QuestieVerify", "Version")
local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
sub:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
sub:SetJustifyH("LEFT")
sub:SetText((version and ("Version " .. version .. ". ") or "")
    .. "Checks each Questie \"!\" before it's drawn and hides, dims or redirects the ones you can't pick up yet.")

-- Markers
Heading("Markers", -70)
Check("redirect", "Point blocked quests to the quest to do first",
    "A quest whose earlier chain step isn't done keeps a red \"!\". Its tooltip says which quest to pick up first and "
    .. "where. Off: those quests are hidden instead.", -88)

local dimLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
dimLabel:SetPoint("TOPLEFT", 20, -122)
dimLabel:SetText("Dim markers:")
local dimModes = {
    { "off", "Never", "Never dim a marker. Quests are either shown or hidden." },
    { "uncertain", "When unsure", "Dim only markers whose evidence is unclear (the default)." },
    { "unverified", "Also unconfirmed", "Also dim quests that no data source can confirm." },
}
local dimButtons = {}
local dx = 110
for _, mode in ipairs(dimModes) do
    local cb = Check("_dim_" .. mode[1], mode[2], mode[3], -116, dx)
    cb:SetScript("OnClick", function() QV.SetSetting("dim", mode[1]); for _, r in ipairs(refreshers) do r() end end)
    dimButtons[mode[1]] = cb
    dx = dx + 150
end
tinsert(refreshers, function()
    for key, cb in pairs(dimButtons) do cb:SetChecked(S().dim == key) end
end)

-- Data sources
Heading("Data sources", -158)
local fdbBox = Check("foreverdb", "Use ForeverDB.net data",
    "Side, race, class, prerequisites and real quest givers from the ForeverDB addon, built by the installer.", -176)
local fdbStatus = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
fdbStatus:SetPoint("TOPLEFT", fdbBox, "BOTTOMLEFT", 30, 2)
fdbStatus:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
fdbStatus:SetJustifyH("LEFT")
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
    "The game's own quest lines, and BtWQuests chains if BtWQuests is installed.", -232)

-- Learning
Heading("Learning from NPCs", -272)
Check("learn", "Learn which quests NPCs really offer",
    "When you talk to a quest giver, quests Questie expected there that the NPC doesn't offer are hidden at that NPC.", -290)

local revisitLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
revisitLabel:SetPoint("TOPLEFT", 20, -326)
local function RevisitText() revisitLabel:SetText(format("Show those again (dimmed) after %d level%s", S().revisitLevels or 2,
    (S().revisitLevels or 2) == 1 and "" or "s")) end
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
Heading("Other", -360)
Check("autoscan", "Quietly record a scan of each zone",
    "Saves which data sources cover each zone's quests in the SavedVariables file, without chat messages.", -378)
Check("verbose", "Extra chat messages", "Print a chat line when QuestieVerify hides a marker after talking to an NPC.", -404)

-- Actions
Heading("Actions", -444)
local recheck = Button("Re-check markers", 150, "Re-check every quest marker now.", function() QV.Command("refresh") end)
recheck:SetPoint("TOPLEFT", 20, -464)
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
local why = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
why:SetPoint("TOPLEFT", recheck, "BOTTOMLEFT", 0, -10)
why:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
why:SetJustifyH("LEFT")
why:SetText("To see why a marker is shown, dimmed, red or hidden, type /qv why <questID> (turn on Questie > Advanced > "
    .. "Show Quest IDs to see the IDs). /qv help lists every chat command.")

panel:SetScript("OnShow", function() for _, r in ipairs(refreshers) do r() end end)

-- Register with the game's options window; without one, it opens as its own window.
local category
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    category = Settings.RegisterCanvasLayoutCategory(panel, "QuestieVerify")
    Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
end

local function OpenStandalone()
    if not panel.standalone then
        panel.standalone = true
        panel:SetParent(UIParent)
        panel:SetSize(640, 560)
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
    if category and Settings.OpenToCategory then
        local id = (category.GetID and category:GetID()) or category.ID
        if pcall(Settings.OpenToCategory, id) then return end
    elseif not category and InterfaceOptionsFrame_OpenToCategory and InterfaceOptions_AddCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)   -- (the first call can land on the wrong page)
        return
    end
    OpenStandalone()
end
