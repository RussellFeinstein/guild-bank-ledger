--- wire_helpers.lua — loads a REAL AceSerializer for the wire-contract tests.
--
-- Every other spec in this suite talks to the pass-through serializer mock in
-- spec/mock_ace.lua, which stashes a table and returns "SER:<n>", handing the
-- same table object back on Deserialize. That mock is correct for testing sync
-- logic and useless for testing the wire: it never encodes anything, so numeric
-- key survival, escaping and payload size had never been exercised
-- (docs/DATA-MODEL.md section 9).
--
-- The loading itself moved to spec/vendor_helpers.lua when spec/savedvariables_spec.lua
-- needed a real AceDB for the same reason (#77). Its header carries the three
-- loading traps this file discovered; what stays here is the serializer-shaped
-- API the wire specs and the fixture generator read.

local Vendor = require("spec.vendor_helpers")

local M = {}

M.VENDOR_DIR = Vendor.VENDOR_DIR
M.LIB_FILES = {
    libstub = "LibStub.lua",
    serializer = "AceSerializer-3.0.lua",
}

local AceSerializer = Vendor.loadVendored(
    { M.LIB_FILES.libstub, M.LIB_FILES.serializer },
    "AceSerializer-3.0"
)

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
