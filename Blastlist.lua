-------------------------------------------------------------------------------
-- Blastlist.lua
-- Event registration, premade cluster detection, safe-guard checks,
-- association engine, and the core Blast action pipeline.
-------------------------------------------------------------------------------

print("|cffff0000[DEBUG] Blastlist.lua — FILE IS LOADING AT TOP|r")

local ADDON_NAME = "Blastlist"

-------------------------------------------------------------------------------
-- Module frame — all events hang off this
-------------------------------------------------------------------------------
local Frame = CreateFrame("Frame", "BlastlistFrame", UIParent)

-------------------------------------------------------------------------------
-- Cluster tracking
-- joinLog[guid] = GetTime() timestamp of when that guid entered the group
-------------------------------------------------------------------------------
local joinLog     = {}   -- guid  → join time (seconds, from GetTime())
local rosterCache = {}   -- guid  → { name, realm, guild } snapshot

-------------------------------------------------------------------------------
-- Internal helpers
-------------------------------------------------------------------------------

-- Normalise realm: UnitFullName returns nil realm when on home server
local function FullName(unit)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    realm = (realm and realm ~= "") and realm or GetRealmName()
    return name .. "-" .. realm
end

-- Resolve the token for group member n (1-based) into a unit token string
-- Works for 5-man groups only (party1..party4 + "player")
local function GroupUnitToken(index)
    if index == 0 then return "player" end
    return "party" .. index
end

-- Iterate all group members including the player, calling fn(unitToken)
local function ForEachGroupMember(fn)
    fn("player")
    for i = 1, GetNumGroupMembers() do
        local token = GroupUnitToken(i)
        if UnitExists(token) then fn(token) end
    end
end

-- Pull a snapshot of the current group into rosterCache
local function RefreshRosterCache()
    rosterCache = {}
    ForEachGroupMember(function(unit)
        local guid = UnitGUID(unit)
        if guid then
            rosterCache[guid] = {
                name  = FullName(unit),
                realm = select(2, UnitFullName(unit)) or GetRealmName(),
                guild = GetGuildInfo(unit),
                unit  = unit,
            }
        end
    end)
end

-------------------------------------------------------------------------------
-- Safe-guard: returns true if a guid belongs to a friend or guildmate
-- We NEVER blast these players regardless of any other logic.
-------------------------------------------------------------------------------
local function IsSafeGuard(guid)
    if not guid then return false end

    -- Check friends list by iterating (C_FriendList has no direct GUID lookup)
    local numFriends = C_FriendList.GetNumFriends()
    for i = 1, numFriends do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.guid == guid then return true end
    end

    -- Check guild roster
    if IsInGuild() then
        local numTotal, _, numOnline = GetNumGuildMembers()
        -- scan online members first (faster path), then all
        for i = 1, numTotal do
            local _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, memberGuid =
                GetGuildRosterInfo(i)
            if memberGuid == guid then return true end
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- Association engine
-- Given a target GUID already confirmed for blasting, return a list of
-- associated GUIDs (and their names) that should also be blasted.
--
-- Two paths:
--   A) Premade cluster — joined within clusterWindowMs of target
--   B) Guild match    — same guild as target in current group snapshot
-------------------------------------------------------------------------------
local function FindAssociates(targetGuid)
    local associates = {}
    local windowSec  = (BlastlistDB.settings.clusterWindowMs or 100) / 1000
    local targetJoin = joinLog[targetGuid]
    local targetData = rosterCache[targetGuid]

    for guid, data in pairs(rosterCache) do
        if guid ~= targetGuid and not IsSafeGuard(guid) then
            local clusterMatch = false
            local guildMatch   = false

            -- Path A: simultaneous join
            if targetJoin and joinLog[guid] then
                clusterMatch = math.abs(joinLog[guid] - targetJoin) <= windowSec
            end

            -- Path B: guild match (both must have a guild, and it must be the same one)
            if targetData and targetData.guild and targetData.guild ~= ""
               and data.guild and data.guild ~= ""
               and data.guild == targetData.guild then
                guildMatch = true
            end

            if clusterMatch or guildMatch then
                table.insert(associates, {
                    guid   = guid,
                    name   = data.name or "Unknown",
                    reason = clusterMatch and "Premade cluster with " .. (targetData and targetData.name or "target")
                                          or "Guild-premade with "   .. (targetData and targetData.name or "target"),
                })
            end
        end
    end
    return associates
end

-------------------------------------------------------------------------------
-- Core Blast pipeline
-- Steps: 1) DB write  2) mark for filtering  3) kick (if in group, out of combat)
--
-- targetGuid   : the primary target
-- targetName   : display name
-- reason       : free text
-- blastAssocs  : bool — whether to also blast the detected associates
-------------------------------------------------------------------------------
local kickQueue = {}  -- guids waiting to be kicked once out of combat

local function ExecuteKick(guid)
    -- Find the unit token for this guid in the current group
    local unitToKick = nil
    ForEachGroupMember(function(unit)
        if UnitGUID(unit) == guid then unitToKick = unit end
    end)

    if not unitToKick then return end  -- already left

    if InCombatLockdown() then
        -- Queue for after combat
        kickQueue[guid] = true
        Blastlist.Print("|cffff9900Blast queued:|r " ..
            (UnitName(unitToKick) or "target") .. " will be kicked after combat.")
        return
    end

    UninviteUnit(unitToKick)
end

local function BlastSingle(guid, name, reason, source, associates)
    if IsSafeGuard(guid) then
        Blastlist.Print("|cff00ff00Safe-guard:|r " .. (name or guid) ..
            " is a friend or guildmate — skipping.")
        return false
    end

    -- 1) DB write (now correctly passes the associates list for context)
    local wasNew = BlastlistDB.Add(guid, name, reason, source, associates or {})

    -- 2) ExecuteKick (handles combat lockdown internally)
    ExecuteKick(guid)

    Blastlist.Print(string.format("|cffff4444Blasted:|r %s — %s", name or guid, reason or ""))
    return true
end

function Blastlist.Blast(targetGuid, targetName, reason, blastAssocs)
    if not targetGuid then
        Blastlist.Print("No valid target GUID — make sure the target is in your group.")
        return
    end

    if IsSafeGuard(targetGuid) then
        Blastlist.Print("|cff00ff00Safe-guard:|r " .. (targetName or targetGuid) ..
            " is protected and cannot be blasted.")
        return
    end

    local associates = FindAssociates(targetGuid)

    -- Record associates on the primary entry for context
    local assocGuids = {}
    for _, a in ipairs(associates) do table.insert(assocGuids, a.guid) end

    -- 1+2+3: DB → filter → kick for primary target
    BlastSingle(targetGuid, targetName, reason or "Manual Blast", "Manual Blast", assocGuids)

    -- Blast associates if confirmed
    if blastAssocs then
        for _, assoc in ipairs(associates) do
            BlastSingle(assoc.guid, assoc.name, assoc.reason, "Auto-Association")
        end
    end
end

-- Returns associates without blasting — used by UI to build the confirm popup
function Blastlist.PreviewAssociates(targetGuid)
    RefreshRosterCache()
    return FindAssociates(targetGuid)
end

-------------------------------------------------------------------------------
-- Group scan — used by /blast check and LFG applicant screening
-------------------------------------------------------------------------------
function Blastlist.ScanGroup()
    RefreshRosterCache()
    local warnings = {}
    ForEachGroupMember(function(unit)
        local guid = UnitGUID(unit)
        if guid and guid ~= UnitGUID("player") then
            local entry = BlastlistDB.Get(guid)
            if entry then
                table.insert(warnings, {
                    name   = entry.name,
                    reason = entry.reason,
                    source = entry.source,
                })
            end
        end
    end)
    return warnings
end

-- Screen an LFG applicant GUID before accepting
function Blastlist.IsBlacklisted(guid)
    return BlastlistDB.Has(guid)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------
Frame:RegisterEvent("ADDON_LOADED")
Frame:RegisterEvent("GROUP_ROSTER_UPDATE")
Frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- combat ended → flush kick queue
Frame:RegisterEvent("LFG_LIST_APPLICANT_UPDATED")

Frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            BlastlistDB.Init()
            Blastlist.InitUI()   -- defined in BlastlistUI.lua
            Blastlist.Print("Loaded. |cff888888/blast for commands.|r")
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Detect new arrivals by diffing against rosterCache
        local prev = {}
        for guid in pairs(rosterCache) do prev[guid] = true end

        RefreshRosterCache()

        local now = GetTime()
        for guid in pairs(rosterCache) do
            if not prev[guid] then
                -- This guid is new to the group
                joinLog[guid] = now

                -- Warn if they're already on the list
                local entry = BlastlistDB.Get(guid)
                if entry then
                    Blastlist.Print(string.format(
                        "|cffff4444WARNING:|r %s just joined and is on your Blastlist! (%s)",
                        entry.name, entry.reason))
                end
            end
        end

        -- Clean joinLog of guids that are no longer in the group
        for guid in pairs(joinLog) do
            if not rosterCache[guid] then joinLog[guid] = nil end
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended — flush kick queue
        for guid in pairs(kickQueue) do
            ExecuteKick(guid)
            kickQueue[guid] = nil
        end

    elseif event == "LFG_LIST_APPLICANT_UPDATED" then
        -- Auto-reject blacklisted applicants when we are the group leader
        if not IsInGroup() or not UnitIsGroupLeader("player") then return end

        local searchID = ...
        -- Iterate applicants on the active listing
        -- C_LFGList.GetApplicants() returns a list of applicant IDs
        local applicants = C_LFGList.GetApplicants()
        if not applicants then return end

        for _, applicantID in ipairs(applicants) do
            local info = C_LFGList.GetApplicantInfo(applicantID)
            if info then
                -- Each applicant may have multiple members (pre-made groups applying)
                for memberIndex = 1, info.numMembers do
                    local memberInfo = C_LFGList.GetApplicantMemberInfo(applicantID, memberIndex)
                    if memberInfo then
                        -- memberInfo.guid available in recent retail builds
                        local guid = memberInfo.guid
                        if guid and BlastlistDB.Has(guid) and not IsSafeGuard(guid) then
                            local entry = BlastlistDB.Get(guid)
                            Blastlist.Print(string.format(
                                "|cffff4444Auto-rejected applicant:|r %s (%s)",
                                entry.name, entry.reason))
                            C_LFGList.DeclineApplicant(applicantID)
                            break  -- reject the whole application if any member is listed
                        end
                    end
                end
            end
        end
    end
end)