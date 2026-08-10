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
                    -- Also confirm the full compress + encode path survives.
                    local wire = Wire.toWire(sourceTable(case))
                    local rok, rback = Wire.fromWire(wire)
                    if not rok or not deepEqual(rback, sourceTable(case)) then
                        print(("!! %s: full wire round trip failed"):format(case.name))
                        problems = problems + 1
                    else
                        print(("ok  %s (%d B serialized, %d B on the wire)")
                            :format(case.name, #committed, #wire))
                    end
                end
            end
        end
    end
end

print("")
if problems == 0 then
    print("All fixtures agree with their hand-written tables.")
else
    print(("%d fixture(s) need attention."):format(problems))
    os.exit(1)
end
