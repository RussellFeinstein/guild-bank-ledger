--- wire_helpers.lua — loads the REAL AceSerializer and LibDeflate for wire-contract tests.
--
-- Every other spec in this suite talks to the pass-through serializer mock in
-- spec/mock_ace.lua, which stashes a table and returns "SER:<n>", handing the
-- same table object back on Deserialize. That mock is correct for testing sync
-- logic and useless for testing the wire: it never encodes anything, so numeric
-- key survival, escaping and payload size have never been exercised
-- (docs/DATA-MODEL.md section 9).
--
-- This module loads the vendored Libs/ copies into locals so those properties
-- can be pinned. It deliberately does NOT touch the addon's mixed-in
-- Serialize/Deserialize, and it restores every global it disturbs.
--
-- Loading notes, each one learned the hard way:
--   * require() cannot be used. The module names contain a dot ("AceSerializer-3.0"),
--     which require turns into a path separator. dofile works.
--   * Real LibStub reads _G.LibStub and evaluates `LibStub.minor < 2`. The suite's
--     mock LibStub has no `minor`, so loading the real one on top of it either
--     throws on nil comparison or silently replaces the registry every other spec
--     resolves through. Busted isolates between files, not within one, so the
--     mock has to be stashed and put back.
--   * Real LibStub calls the WoW global strmatch, which no production file in
--     this addon uses. It gets a temporary shim here rather than a permanent
--     entry in mock_wow.lua.
--   * LibDeflate ends with a command-line entry point guarded on _G.arg. Blanking
--     arg for the duration keeps it from ever being considered.

local M = {}

local LIB_PATHS = {
    libstub      = "Libs/LibStub/LibStub.lua",
    serializer   = "Libs/AceSerializer-3.0/AceSerializer-3.0.lua",
    deflate      = "Libs/LibDeflate/LibDeflate.lua",
}

local function assertReadable(what, path)
    local fh = io.open(path, "r")
    if not fh then
        error(("wire_helpers: cannot read %s at %q. Tests must run from the repo root "
            .. "so the vendored Libs/ tree resolves."):format(what, path), 0)
    end
    fh:close()
end

--- Load the real libraries, leaving the global environment exactly as found.
-- @return table,table AceSerializer instance, LibDeflate instance
local function loadRealLibs()
    for what, path in pairs(LIB_PATHS) do
        assertReadable(what, path)
    end

    local savedLibStub = _G.LibStub
    local savedStrmatch = _G.strmatch
    local savedArg = _G.arg

    _G.LibStub = nil                    -- force a fresh registry, do not upgrade the mock
    _G.strmatch = string.match          -- real LibStub needs it
    _G.arg = nil                        -- keep LibDeflate's CLI block unreachable

    local ok, serializer, deflate = pcall(function()
        dofile(LIB_PATHS.libstub)
        dofile(LIB_PATHS.serializer)
        local returned = dofile(LIB_PATHS.deflate)
        local stub = _G.LibStub
        return stub("AceSerializer-3.0"), returned or stub("LibDeflate")
    end)

    _G.LibStub = savedLibStub
    _G.strmatch = savedStrmatch
    _G.arg = savedArg

    if not ok then
        error("wire_helpers: failed to load the vendored libraries: " .. tostring(serializer), 0)
    end
    if not serializer or not deflate then
        error("wire_helpers: libraries loaded but did not register", 0)
    end
    return serializer, deflate
end

local AceSerializer, LibDeflate = loadRealLibs()

--- Serialize with the real AceSerializer.
-- @param value any
-- @return string AceSerializer output (uncompressed, unencoded)
function M.serialize(value)
    return AceSerializer:Serialize(value)
end

--- Deserialize with the real AceSerializer.
-- @param str string
-- @return boolean,any success flag then value (or error string)
function M.deserialize(str)
    return AceSerializer:Deserialize(str)
end

--- Full outbound path: serialize, compress, encode for the addon channel.
-- Mirrors compressMessage() in src/Sync.lua.
-- @param value any
-- @return string Bytes as they would be handed to AceComm
function M.toWire(value)
    return LibDeflate:EncodeForWoWAddonChannel(
        LibDeflate:CompressDeflate(AceSerializer:Serialize(value)))
end

--- Full inbound path: decode, decompress, deserialize.
-- @param encoded string Bytes as they would arrive from AceComm
-- @return boolean,any success flag then value (or error string)
function M.fromWire(encoded)
    local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
    if not compressed then return false, "decode failed" end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return false, "decompress failed" end
    return AceSerializer:Deserialize(serialized)
end

--- Deserialize or raise. Fixtures are committed data; a soft failure there is a
-- corrupt fixture, not a case under test.
-- @param encoded string
-- @return any
function M.fromWireOrDie(encoded)
    local ok, value = M.fromWire(encoded)
    if not ok then
        error("wire_helpers: fixture failed to decode: " .. tostring(value), 2)
    end
    return value
end

return M
