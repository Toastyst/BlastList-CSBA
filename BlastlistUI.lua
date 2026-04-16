-------------------------------------------------------------------------------
-- BlastlistUI.lua
-- Minimap button, slash command router, confirm popups, and print helper.
-- Depends on Blastlist.lua and BlastlistDB.lua being loaded first.
-------------------------------------------------------------------------------

print("|cffff0000[DEBUG] BlastlistUI.lua — FILE IS LOADING|r")

Blastlist = Blastlist or {}

local ADDON_COLOR = "|cff00aaff"   -- blue brand prefix for all print output

function Blastlist.Print(msg)
    print(ADDON_COLOR .. "[Blastlist]|r " .. msg)
end
-- Minimap button
-- Uses Blizzard's default minimap button approach — circular, draggable.
-------------------------------------------------------------------------------
local minimapButton

local function CreateMinimapButton()
    minimapButton = CreateFrame("Button", "BlastlistMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:SetMovable(true)
    minimapButton:RegisterForDrag("LeftButton")

    -- Icon (separate child texture for proper circular cropping)
    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\ability_warrior_bladestorm")
    icon:SetSize(24, 24)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

    local pushedIcon = minimapButton:CreateTexture(nil, "BACKGROUND")
    pushedIcon:SetTexture("Interface\\Icons\\ability_warrior_bladestorm")
    pushedIcon:SetSize(24, 24)
    pushedIcon:SetPoint("CENTER")
    pushedIcon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    pushedIcon:SetAlpha(0.7)  -- Slightly dimmed for pushed state

    minimapButton:SetNormalTexture(icon)
    minimapButton:SetPushedTexture(pushedIcon)

    -- Custom circular highlight
    local highlight = minimapButton:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetColorTexture(1, 1, 1, 0.3)
    highlight:SetSize(32, 32)
    highlight:SetPoint("CENTER")
    minimapButton:SetHighlightTexture(highlight)

    -- Circular border (the ring around the icon)
    local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
    overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    overlay:SetSize(56, 56)
    overlay:SetPoint("CENTER", 0, 0)

    -- Drag support
    minimapButton:SetScript("OnDragStart", function(self) self:StartMoving() end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)

    -- Click (left click = quick status)
    minimapButton:SetScript("OnClick", function(self, btn)
        if btn == "LeftButton" then
            Blastlist.Print(string.format(
                "Blastlist active — |cffff4444%d|r entries. /blast for commands.",
                BlastlistDB.Count()))
        end
    end)

    -- Tooltip
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Blastlist", 0, 0.67, 1)
        GameTooltip:AddLine(string.format("%d blacklisted players", BlastlistDB.Count()), 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffaaaaaaLeft-click|r — quick status")
        GameTooltip:AddLine("|cffaaaaaa/blast|r — blast current target")
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Starting position
    local angle = 225
    local radius = 80
    local rad = math.rad(angle)
    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        radius * math.cos(rad), radius * math.sin(rad))
end

-------------------------------------------------------------------------------
-- Blastlist.Print(msg)
-- Prefixed chat output. Used everywhere in the addon.
-------------------------------------------------------------------------------
-- Confirm popup — shown before a blast executes
-- Reuses Blizzard's StaticPopup infrastructure so we need zero custom frames.
--
-- Usage:
--   Blastlist.ShowConfirmPopup(targetGuid, targetName, reason, associates)
--   associates = { {guid, name, reason}, ... }
-------------------------------------------------------------------------------
StaticPopupDialogs["BLASTLIST_CONFIRM"] = {
    text          = "%s",   -- filled dynamically
    button1       = "Blast",
    button2       = "Target Only",
    button3       = "Cancel",
    hasEditBox    = false,
    timeout       = 0,
    whileDead     = true,
    hideOnEscape  = true,
    preferredIndex = 3,

    OnAccept = function(self, data)
        -- "Blast" — primary target + all associates
        Blastlist.Blast(data.guid, data.name, data.reason, true)
    end,

    OnAlt = function(self, data)
        -- "Target Only" — blast primary target, skip associates
        Blastlist.Blast(data.guid, data.name, data.reason, false)
    end,

    -- OnCancel fires on Cancel button and Escape — do nothing
}

function Blastlist.ShowConfirmPopup(targetGuid, targetName, reason, associates)
    local assocCount = #associates
    local bodyText

    if assocCount == 0 then
        bodyText = string.format(
            "Blast |cffff4444%s|r?\n\nReason: %s\n\nNo associates detected.",
            targetName, reason or "Manual Blast")
    else
        local names = {}
        for _, a in ipairs(associates) do
            table.insert(names, string.format("  • %s (%s)", a.name, a.reason))
        end
        bodyText = string.format(
            "Blast |cffff4444%s|r and %d associate(s)?\n\nReason: %s\n\nAssociates:\n%s",
            targetName, assocCount, reason or "Manual Blast", table.concat(names, "\n"))
    end

    StaticPopup_Show("BLASTLIST_CONFIRM", bodyText, nil, {
        guid   = targetGuid,
        name   = targetName,
        reason = reason,
    })
end

-------------------------------------------------------------------------------
-- Import popup — native EditBox inside a StaticPopup
-------------------------------------------------------------------------------
StaticPopupDialogs["BLASTLIST_IMPORT"] = {
    text            = "Paste Blastlist export string:",
    button1         = "Import",
    button2         = "Cancel",
    hasEditBox      = true,
    editBoxWidth    = 350,
    maxLetters      = 0,   -- unlimited
    timeout         = 0,
    whileDead       = true,
    hideOnEscape    = true,
    preferredIndex  = 3,

    OnAccept = function(self)
        local str = self.editBox:GetText()
        if not str or str == "" then
            Blastlist.Print("Import cancelled — empty string.")
            return
        end

        local importedEntries, err = BlastlistDB.Deserialize(str)
        if not importedEntries then
            Blastlist.Print("|cffff0000Import failed:|r " .. (err or "unknown error"))
            return
        end

        local added, skipped = BlastlistDB.Merge(importedEntries)
        Blastlist.Print(string.format(
            "Import complete: |cff00ff00%d added|r, |cff888888%d already known|r.", added, skipped))
    end,
}

-------------------------------------------------------------------------------
-- Export popup — read-only EditBox the user can copy from
-------------------------------------------------------------------------------
local function ShowExportPopup(encoded)
    -- Reuse a standard dialog with an EditBox for copy-paste
    -- We create a minimal named dialog on the fly if needed
    if not StaticPopupDialogs["BLASTLIST_EXPORT"] then
        StaticPopupDialogs["BLASTLIST_EXPORT"] = {
            text           = "Copy your Blastlist export string:",
            button1        = "Done",
            hasEditBox     = true,
            editBoxWidth   = 350,
            maxLetters     = 0,
            timeout        = 0,
            whileDead      = true,
            hideOnEscape   = true,
            preferredIndex = 3,
            OnShow = function(self)
                self.editBox:SetText(self.data or "")
                self.editBox:HighlightText()
                self.editBox:SetFocus()
            end,
        }
    end

    local popup = StaticPopup_Show("BLASTLIST_EXPORT")
    if popup then popup.data = encoded end
end



-------------------------------------------------------------------------------
-- Slash command router
-------------------------------------------------------------------------------
local function HandleBlast(input)
    input = input and input:match("^%s*(.-)%s*$") or ""  -- trim whitespace

    -- /blast  (no args) — blast current target
    if input == "" then
        local target = "target"
        if not UnitExists(target) then
            Blastlist.Print("No target selected. Target a player and try again.")
            return
        end
        if not UnitIsPlayer(target) then
            Blastlist.Print("Target is not a player.")
            return
        end

        local guid = UnitGUID(target)
        local name = FullName and FullName(target) or UnitName(target)

        local associates = Blastlist.PreviewAssociates(guid)
        Blastlist.ShowConfirmPopup(guid, name, "Manual Blast", associates)
        return
    end

    -- /blast check
    if input == "check" then
        local warnings = Blastlist.ScanGroup()
        if #warnings == 0 then
            Blastlist.Print("Group scan clean — no blacklisted players found.")
        else
            Blastlist.Print(string.format("|cffff4444%d blacklisted player(s) in group:|r", #warnings))
            for _, w in ipairs(warnings) do
                Blastlist.Print(string.format("  • %s — %s [%s]", w.name, w.reason, w.source))
            end
        end
        return
    end

    -- /blast cleanup
    if input == "cleanup" then
        local removed = BlastlistDB.Prune()
        Blastlist.Print(string.format(
            "Cleanup complete: |cff00ff00%d old entr%s removed|r.",
            removed, removed == 1 and "y" or "ies"))
        return
    end

    -- /blast export
    if input == "export" then
        if BlastlistDB.Count() == 0 then
            Blastlist.Print("Nothing to export — your Blastlist is empty.")
            return
        end
        local encoded, err = BlastlistDB.Serialize()
        if not encoded then
            Blastlist.Print("|cffff0000Export failed:|r " .. (err or "unknown error"))
            return
        end
        ShowExportPopup(encoded)
        return
    end

    -- /blast import [string]  (or just /blast import to open empty box)
    if input == "import" or input:sub(1, 7) == "import " then
        local str = input:sub(8)   -- everything after "import "
        if str and str ~= "" then
            -- string passed directly on the command line
            local importedEntries, err = BlastlistDB.Deserialize(str)
            if not importedEntries then
                Blastlist.Print("|cffff0000Import failed:|r " .. (err or "unknown error"))
                return
            end
            local added, skipped = BlastlistDB.Merge(importedEntries)
            Blastlist.Print(string.format(
                "Import complete: |cff00ff00%d added|r, |cff888888%d already known|r.", added, skipped))
        else
            -- Open the paste box
            StaticPopup_Show("BLASTLIST_IMPORT")
        end
        return
    end

    -- /blast list
    if input == "list" then
        local count = BlastlistDB.Count()
        if count == 0 then
            Blastlist.Print("Your Blastlist is empty.")
            return
        end
        Blastlist.Print(string.format("|cffff4444%d blacklisted player(s):|r", count))
        for guid, entry in pairs(BlastListDB.entries) do
            Blastlist.Print(string.format("  [%s] %s — %s", entry.source, entry.name, entry.reason))
        end
        return
    end

    -- Unknown command — print help
    Blastlist.Print("Commands:")
    Blastlist.Print("  |cffaaaaaa/blast|r              — blast current target")
    Blastlist.Print("  |cffaaaaaa/blast check|r         — scan group for blacklisted players")
    Blastlist.Print("  |cffaaaaaa/blast list|r           — print all entries")
    Blastlist.Print("  |cffaaaaaa/blast cleanup|r        — remove entries older than 180 days")
    Blastlist.Print("  |cffaaaaaa/blast export|r         — generate share string")
    Blastlist.Print("  |cffaaaaaa/blast import [str]|r   — import a share string")
end

-- FullName is defined in Blastlist.lua but BlastlistUI.lua loads after it,
-- so the reference is fine at call-time. Exposed here as a local alias
-- for the slash handler above.
local FullName = function(unit)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    realm = (realm and realm ~= "") and realm or GetRealmName()
    return name .. "-" .. realm
end

-------------------------------------------------------------------------------
-- Blastlist.InitUI()
-- Called from ADDON_LOADED in Blastlist.lua once the DB is ready.
-------------------------------------------------------------------------------
function Blastlist.InitUI()
    print("|cffff0000[DEBUG] Blastlist.InitUI() called — creating minimap button and slash command|r")
    CreateMinimapButton()

    SLASH_BLAST1 = "/blast"
    SlashCmdList["BLAST"] = HandleBlast
    print("|cffff0000[DEBUG] Slash command /blast successfully registered|r")

    Blastlist.Print("Loaded. |cff888888/blast for commands.|r")
end
