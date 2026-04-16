-------------------------------------------------------------------------------
-- BlastlistDB.lua
-- Owns the SavedVariables schema, all read/write accessors, and prune logic.
-- No WoW events are registered here — this is pure data layer.
-------------------------------------------------------------------------------

Blastlist = Blastlist or {}
BLASTLIST_DB_VERSION = 1

-- ---------------------------------------------------------------------------
-- Default schema — merged over BlastListDB on first load / missing keys
-- ---------------------------------------------------------------------------
local DEFAULTS = {
    version  = BLASTLIST_DB_VERSION,
    entries  = {},          -- [guid] = entry table (see BlastlistDB.NewEntry)
    settings = {
        pruneDays       = 180,  -- entries older than this are removed by cleanup
        aggressiveMode  = true, -- auto-blast guild/simultaneous associates
        clusterWindowMs = 100,  -- milliseconds window for premade fingerprint
    },
    minimapIcon = { hide = false },
}

-- ---------------------------------------------------------------------------
-- BlastlistDB  (module table, not the SavedVariable)
-- ---------------------------------------------------------------------------
BlastlistDB = BlastlistDB or {}
local DB = BlastlistDB   -- shorthand used throughout this file

-------------------------------------------------------------------------------
-- Internal: deep-merge defaults into target (non-destructive)
-------------------------------------------------------------------------------
local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                ApplyDefaults(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            ApplyDefaults(target[k], v)
        end
    end
end

-------------------------------------------------------------------------------
-- DB.Init()
-- Called from ADDON_LOADED. Bootstraps BlastListDB SavedVariable.
-------------------------------------------------------------------------------
function DB.Init()
    -- BlastListDB is the actual SavedVariable declared in the .toc
    if type(BlastListDB) ~= "table" then
        BlastListDB = {}
    end
    ApplyDefaults(BlastListDB, DEFAULTS)

    -- Schema migration hook — increment BLASTLIST_DB_VERSION and add cases here
    if (BlastListDB.version or 0) < BLASTLIST_DB_VERSION then
        -- future migrations go here
        BlastListDB.version = BLASTLIST_DB_VERSION
    end
end

-------------------------------------------------------------------------------
-- DB.NewEntry(guid, name, reason, source, associates)
-- Constructs a fresh entry table. All writes go through here for consistency.
--   guid       : "Player-XXXX-YYYYYYYY"  (permanent key)
--   name       : "Charname-Realm"         (display only, may change)
--   source     : "Manual Blast" | "Auto-Association" | "Import"
--   associates : optional table of guids (stored for context, not re-blasted here)
-------------------------------------------------------------------------------
function DB.NewEntry(guid, name, reason, source, associates)
    return {
        name       = name       or "Unknown",
        reason     = reason     or "No reason given",
        timestamp  = GetServerTime(),
        source     = source     or "Manual Blast",
        associates = associates or {},
    }
end

-------------------------------------------------------------------------------
-- DB.Add(guid, name, reason, source, associates)
-- Inserts or updates an entry.
-- Conflict rule: if the GUID already exists, keep whichever timestamp is NEWER.
-- This prevents a stale import from resetting the prune clock on an active entry.
-------------------------------------------------------------------------------
function DB.Add(guid, name, reason, source, associates)
    if not guid or guid == "" then return false end

    local existing = BlastListDB.entries[guid]
    local incoming = DB.NewEntry(guid, name, reason, source, associates)

    if existing then
        -- Keep newer timestamp; update display name in case of rename
        if incoming.timestamp > existing.timestamp then
            BlastListDB.entries[guid] = incoming
        else
            -- Still refresh the name in case the player renamed
            existing.name = incoming.name
        end
        return false  -- was already present
    end

    BlastListDB.entries[guid] = incoming
    return true  -- newly added
end

-------------------------------------------------------------------------------
-- DB.Remove(guid)
-------------------------------------------------------------------------------
function DB.Remove(guid)
    if BlastListDB.entries[guid] then
        BlastListDB.entries[guid] = nil
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- DB.Has(guid) → bool
-------------------------------------------------------------------------------
function DB.Has(guid)
    return BlastListDB.entries[guid] ~= nil
end

-------------------------------------------------------------------------------
-- DB.Get(guid) → entry or nil
-------------------------------------------------------------------------------
function DB.Get(guid)
    return BlastListDB.entries[guid]
end

-------------------------------------------------------------------------------
-- DB.Count() → number of entries
-------------------------------------------------------------------------------
function DB.Count()
    local n = 0
    for _ in pairs(BlastListDB.entries) do n = n + 1 end
    return n
end

-------------------------------------------------------------------------------
-- DB.Prune()
-- Removes all entries older than settings.pruneDays.
-- Returns the number of entries removed.
-------------------------------------------------------------------------------
function DB.Prune()
    local cutoff  = GetServerTime() - (86400 * BlastListDB.settings.pruneDays)
    local removed = 0

    for guid, entry in pairs(BlastListDB.entries) do
        if entry.timestamp < cutoff then
            BlastListDB.entries[guid] = nil
            removed = removed + 1
        end
    end
    return removed
end

-------------------------------------------------------------------------------
-- DB.GetSetting(key) / DB.SetSetting(key, value)
-------------------------------------------------------------------------------
function DB.GetSetting(key)
    return BlastListDB.settings[key]
end

function DB.SetSetting(key, value)
    BlastListDB.settings[key] = value
end

-------------------------------------------------------------------------------
-- DB.Serialize() → string  (LibDeflate pipeline)
-- DB.Deserialize(str) → table or nil, errorMsg
--
-- Both functions are stubs that Blastlist.lua will call after the libs load.
-- They are defined here so the data layer owns the encode/decode contract.
-------------------------------------------------------------------------------
function DB.Serialize()
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate   = LibStub and LibStub("LibDeflate",   true)

    if not LibSerialize or not LibDeflate then
        return nil, "Missing LibSerialize or LibDeflate"
    end

    local serialized  = LibSerialize:Serialize(BlastListDB.entries)
    local compressed  = LibDeflate:CompressDeflate(serialized)
    local encoded     = LibDeflate:EncodeForPrint(compressed)
    return encoded
end

function DB.Deserialize(encoded)
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate   = LibStub and LibStub("LibDeflate",   true)

    if not LibSerialize or not LibDeflate then
        return nil, "Missing LibSerialize or LibDeflate"
    end

    local compressed = LibDeflate:DecodeForPrint(encoded)
    if not compressed then return nil, "Decode failed — string may be corrupted" end

    local decompressed = LibDeflate:DecompressDeflate(compressed)
    if not decompressed then return nil, "Decompress failed" end

    local ok, data = LibSerialize:Deserialize(decompressed)
    if not ok then return nil, "Deserialize failed: " .. tostring(data) end

    return data
end

-------------------------------------------------------------------------------
-- DB.Merge(importedEntries) → added, skipped counts
-- Merge rule: newer timestamp wins (same as DB.Add conflict rule).
-------------------------------------------------------------------------------
function DB.Merge(importedEntries)
    if type(importedEntries) ~= "table" then return 0, 0 end

    local added, skipped = 0, 0
    for guid, entry in pairs(importedEntries) do
        local wasNew = DB.Add(guid, entry.name, entry.reason, "Import", entry.associates)
        if wasNew then added = added + 1 else skipped = skipped + 1 end
    end
    return added, skipped
end