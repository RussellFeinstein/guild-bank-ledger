--- Authoring aid for the golden wire fixtures. Run from the repo root:
---
---     lua spec/fixtures/generate_wire_fixtures.lua
---
--- What it does NOT do is refresh the committed fixtures. The frozen strings in
--- spec/fixtures/wire/*.lua represent what a v0.36.x peer puts on the wire, and
--- they stay frozen so the cross-version contract behind MIN_SYNC_VERSION (#74)
--- keeps meaning something. A record-shape change (#67) adds cases beside them;
--- it never rewrites them. Regenerating everything on each change would turn the
--- fixtures into a mirror of whatever the code currently does, which catches
--- nothing.
---
--- So this script has two jobs:
---   1. Print the `serialized` line for a case whose table you just hand-wrote,
---      ready to paste. Field order inside the string comes from pairs() and
---      cannot be written by hand, which is the only reason generation is
---      involved at all. Order never matters on the way back: the tests decode
---      these strings, they never compare a fresh Serialize against them.
---   2. Report any committed string that no longer decodes to its hand-written
---      table, which is how an upstream AceSerializer or LibDeflate change would
---      announce itself.

package.path = "?.lua;spec/?.lua;" .. package.path

local Wire = require("spec.wire_helpers")

local FIXTURE_FILES = {
    "spec/fixtures/wire/records.lua",
    "spec/fixtures/wire/envelopes.lua",
}

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function sourceTable(case)
    -- Records carry `stripped`; envelopes carry `decoded`.
    return case.stripped or case.decoded
end

local problems = 0

for _, path in ipairs(FIXTURE_FILES) do
    local chunk = loadfile(path)
    if not chunk then
        print(("!! cannot load %s"):format(path))
        problems = problems + 1
    else
        print(("\n=== %s ==="):format(path))
        for _, case in ipairs(chunk()) do
            local fresh = Wire.serialize(sourceTable(case))
            local committed = case.serialized

            if committed == nil or committed == "" then
                print(("\n-- %s (NEW, paste this)"):format(case.name))
                print(("        serialized = %q,"):format(fresh))
                problems = problems + 1
            else
                local ok, decoded = Wire.deserialize(committed)
                if not ok then
                    print(("!! %s: committed string does not deserialize: %s")
                        :format(case.name, tostring(decoded)))
                    problems = problems + 1
                elseif not deepEqual(decoded, sourceTable(case)) then
                    print(("!! %s: committed string decodes to something other than the "
                        .. "hand-written table. Replace with:"):format(case.name))
                    print(("        serialized = %q,"):format(fresh))
                    problems = problems + 1
                else
                    print(("ok  %s (%d B serialized)"):format(case.name, #committed))
                end
            end
        end
    end
end

-- The tests always run against spec/vendor/, so they are deterministic on any
-- machine. That leaves one question open: has upstream moved since those copies
-- were taken? Libs/ is gitignored and only exists where the packager has run, so
-- when it is present, compare. This is the only place that check can live.
local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local content = fh:read("*a")
    fh:close()
    return content
end

local UPSTREAM = {
    ["LibStub.lua"] = "Libs/LibStub/LibStub.lua",
    ["AceSerializer-3.0.lua"] = "Libs/AceSerializer-3.0/AceSerializer-3.0.lua",
}

print("\n=== vendored libraries vs Libs/ ===")
for vendored, upstream in pairs(UPSTREAM) do
    local theirs = readFile(upstream)
    if not theirs then
        print(("--  %s: no Libs/ tree here, nothing to compare"):format(vendored))
    elseif readFile(Wire.VENDOR_DIR .. vendored) == theirs then
        print(("ok  %s matches %s"):format(vendored, upstream))
    else
        print(("!! %s differs from %s. Upstream has moved. Copy it over and run the "
            .. "full suite: a real behavior change shows up as fixtures that stop decoding.")
            :format(vendored, upstream))
        problems = problems + 1
    end
end

print("")
if problems == 0 then
    print("All fixtures agree with their hand-written tables.")
else
    print(("%d fixture(s) need attention."):format(problems))
    os.exit(1)
end
