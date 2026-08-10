--- wire_helpers.lua — loads a REAL AceSerializer for the wire-contract tests.
--
-- Every other spec in this suite talks to the pass-through serializer mock in
-- spec/mock_ace.lua, which stashes a table and returns "SER:<n>", handing the
-- same table object back on Deserialize. That mock is correct for testing sync
-- logic and useless for testing the wire: it never encodes anything, so numeric
-- key survival, escaping and payload size had never been exercised
-- (docs/DATA-MODEL.md section 9).
--
-- The libraries come from spec/vendor/, not from Libs/. Libs/ is gitignored and
-- fetched by the packager from .pkgmeta externals, so it exists on a developer
-- machine and nowhere else; CI has no Libs/ tree. See spec/vendor/README.md.
--
-- This module does NOT touch the addon's mixed-in Serialize/Deserialize, and it
-- restores every global it disturbs.
--
-- Loading notes, each one learned the hard way:
--   * require() cannot be used. The module names contain a dot
--     ("AceSerializer-3.0"), which require turns into a path separator. dofile
--     works.
--   * Real LibStub reads _G.LibStub and evaluates `LibStub.minor < 2`. The
--     suite's mock LibStub has no `minor`, so loading the real one on top of it
--     either throws on a nil comparison or silently replaces the registry every
--     other spec resolves through. Busted isolates between files, not within
--     one, so the mock has to be stashed and put back.
--   * Real LibStub calls the WoW global strmatch, which no production file in
--     this addon uses. It gets a temporary shim here rather than a permanent
--     entry in mock_wow.lua.

local M = {}

M.VENDOR_DIR = "spec/vendor/"
M.LIB_FILES = {
    libstub = "LibStub.lua",
    serializer = "AceSerializer-3.0.lua",
}

local function assertReadable(path)
    local fh = io.open(path, "r")
    if not fh then
        error(("wire_helpers: cannot read %q. Tests must run from the repo root."):format(path), 0)
    end
    fh:close()
end

--- Load a real AceSerializer, leaving the global environment exactly as found.
-- @return table AceSerializer instance
local function loadSerializer()
    local libstub = M.VENDOR_DIR .. M.LIB_FILES.libstub
    local serializer = M.VENDOR_DIR .. M.LIB_FILES.serializer
    assertReadable(libstub)
    assertReadable(serializer)

    local savedLibStub = _G.LibStub
    local savedStrmatch = _G.strmatch

    _G.LibStub = nil              -- force a fresh registry, do not upgrade the mock
    _G.strmatch = string.match    -- real LibStub needs it

    local ok, lib = pcall(function()
        dofile(libstub)
        dofile(serializer)
        return _G.LibStub("AceSerializer-3.0")
    end)

    _G.LibStub = savedLibStub
    _G.strmatch = savedStrmatch

    if not ok then
        error("wire_helpers: failed to load the vendored serializer: " .. tostring(lib), 0)
    end
    if not lib then
        error("wire_helpers: serializer loaded but did not register", 0)
    end
    return lib
end

local AceSerializer = loadSerializer()

--- Serialize with the real AceSerializer.
-- @param value any
-- @return string AceSerializer output
function M.serialize(value)
    return AceSerializer:Serialize(value)
end

--- Deserialize with the real AceSerializer.
-- @param str string
-- @return boolean,any success flag then value (or error string)
function M.deserialize(str)
    return AceSerializer:Deserialize(str)
end

--- Serialize then deserialize, raising on failure.
-- @param value any
-- @return any
function M.roundTrip(value)
    local ok, back = M.deserialize(M.serialize(value))
    if not ok then
        error("wire_helpers: round trip failed: " .. tostring(back), 2)
    end
    return back
end

--- Deserialize or raise. Fixtures are committed data, so a soft failure there is
-- a corrupt fixture rather than a case under test.
-- @param serialized string
-- @return any
function M.deserializeOrDie(serialized)
    local ok, value = M.deserialize(serialized)
    if not ok then
        error("wire_helpers: fixture failed to decode: " .. tostring(value), 2)
    end
    return value
end

return M
