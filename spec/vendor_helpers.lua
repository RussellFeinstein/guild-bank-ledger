--- vendor_helpers.lua — loads a REAL Ace3 library from spec/vendor/.
--
-- Two specs need a real library rather than the mock that stands in for it
-- everywhere else:
--
--   * spec/wire_contract_spec.lua needs a real AceSerializer, because the mock
--     serializer is pass-through and never encodes anything.
--   * spec/savedvariables_spec.lua needs a real AceDB, because the AceDB mock's
--     removeDefaults is a hand port and a hand port cannot verify itself.
--
-- The libraries come from spec/vendor/, not from Libs/. Libs/ is gitignored and
-- fetched by the packager from .pkgmeta externals, so it exists on a developer
-- machine that has run the packager and nowhere else; CI has no Libs/ tree. See
-- spec/vendor/README.md.
--
-- This module restores every global it disturbs, and never touches the addon's
-- own mixed-in Serialize/Deserialize or its AceDB instance.
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
--     entry in mock_wow.lua, and the same rule governs the `shims` argument:
--     a global a vendored library needs AT LOAD and production never reads is
--     shimmed for the load and restored, so mock_wow keeps describing the
--     client the addon actually talks to.

local M = {}

M.VENDOR_DIR = "spec/vendor/"

local function assertReadable(path)
    local fh = io.open(path, "r")
    if not fh then
        error(("vendor_helpers: cannot read %q. Tests must run from the repo root."):format(path), 0)
    end
    fh:close()
end

--- Load vendored library files and resolve one library from them.
--
-- Every global this touches is restored before returning, on the error path as
-- well as the success path.
--
-- @param files table Array of filenames under spec/vendor/, loaded in order.
--                    LibStub.lua goes first, since the others register into it.
-- @param libName string The LibStub name to resolve once the files are loaded
-- @param shims table|nil [global name] = replacement, installed for the load
--                        only. Applied unconditionally, so a shim may stand in
--                        for a mock that exists but is too small.
-- @return table The library instance
function M.loadVendored(files, libName, shims)
    for _, file in ipairs(files) do
        assertReadable(M.VENDOR_DIR .. file)
    end

    local savedLibStub = _G.LibStub
    local savedStrmatch = _G.strmatch
    local savedShims = {}
    if shims then
        for name in pairs(shims) do savedShims[name] = _G[name] end
    end

    _G.LibStub = nil              -- force a fresh registry, do not upgrade the mock
    _G.strmatch = string.match    -- real LibStub needs it
    if shims then
        for name, value in pairs(shims) do _G[name] = value end
    end

    local ok, lib = pcall(function()
        for _, file in ipairs(files) do
            dofile(M.VENDOR_DIR .. file)
        end
        return _G.LibStub(libName)
    end)

    _G.LibStub = savedLibStub
    _G.strmatch = savedStrmatch
    if shims then
        for name in pairs(shims) do _G[name] = savedShims[name] end
    end

    if not ok then
        error(("vendor_helpers: failed to load %s: %s"):format(libName, tostring(lib)), 0)
    end
    if not lib then
        error(("vendor_helpers: %s loaded but did not register"):format(libName), 0)
    end
    return lib
end

return M
