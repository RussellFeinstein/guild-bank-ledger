------------------------------------------------------------------------
-- sandbox_globals_spec.lua — libraries WoW's sandbox does not provide.
--
-- WoW's Lua environment ships without the `os` and `io` standard
-- libraries. The test host is desktop Lua, where both exist, so busted
-- happily runs code that would crash in-game; that is how src/Storage.lua
-- carried os.date/os.time behind a green suite for five months (#62).
-- The mocks cannot close the gap either: spec/mock_wow.lua itself backs
-- the WoW `date()` global with the host's os.date, so nil-ing _G.os
-- would break the harness. A source-level ban over what ships is the
-- enforcement that works.
--
-- Comments are exempt on purpose: "never use os.time here, use
-- GetServerTime()" is exactly the comment someone should be able to
-- write. The matcher also requires an identifier boundary before the
-- library name, because src/Sync.lua legitimately contains
-- `CTL.Prio.ALERT`, whose substring `io.` must not match.
--
-- stripComments / readFile / tocSourceFiles are copies of the ones in
-- spec/ascii_strings_spec.lua (where the stripper also has its own unit
-- tests). Consolidating the pair into spec/helpers.lua is #117/#120
-- territory, not this spec's job.
------------------------------------------------------------------------

--- Blank out Lua comments, leaving code and string literals in place.
-- Comments become runs of spaces so byte offsets and line numbers hold.
-- Long strings are kept (they are literals); long comments are not.
-- @param src string Lua source
-- @return string Source with every comment blanked
local function stripComments(src)
    local out = {}
    local i, n = 1, #src

    --- Consume a long bracket at i, returning its end offset or nil.
    local function longBracketEnd(at, prefixLen)
        local eq = src:match("^%[(=*)%[", at + prefixLen)
        if not eq then return nil end
        local close = "]" .. eq .. "]"
        local from, to = src:find(close, at + prefixLen + #eq + 2, true)
        if not from then return n end
        return to
    end

    while i <= n do
        local c = src:sub(i, i)
        if c == '"' or c == "'" then
            -- Short string literal. Kept verbatim; escapes are skipped so a
            -- quote inside the string does not end it early.
            out[#out + 1] = c
            i = i + 1
            while i <= n do
                local ch = src:sub(i, i)
                if ch == "\\" then
                    out[#out + 1] = src:sub(i, i + 1)
                    i = i + 2
                else
                    out[#out + 1] = ch
                    i = i + 1
                    if ch == c or ch == "\n" then break end
                end
            end
        elseif src:sub(i, i + 1) == "--" then
            local stop = longBracketEnd(i, 2)
            if stop then
                out[#out + 1] = (src:sub(i, stop):gsub("[^\n]", " "))
            else
                stop = (src:find("\n", i, true) or n + 1) - 1
                out[#out + 1] = string.rep(" ", stop - i + 1)
            end
            i = stop + 1
        else
            local stop = longBracketEnd(i, 0)
            if stop then
                out[#out + 1] = src:sub(i, stop)
                i = stop + 1
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
    end

    return table.concat(out)
end

--- Read a whole file, or nil if it cannot be opened.
local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local contents = fh:read("*a")
    fh:close()
    return contents
end

--- Addon source files named by the .toc, Libs excluded.
local function tocSourceFiles()
    local toc = readFile("GuildBankLedger.toc")
    if not toc then return nil end
    local files = {}
    for line in toc:gmatch("[^\r\n]+") do
        local entry = line:match("^%s*([%w_\\/%.%-]+%.lua)%s*$")
        if entry and not entry:match("^Libs") then
            files[#files + 1] = entry:gsub("\\", "/")
        end
    end
    return files
end

--- Line numbers where `<lib>.` appears as a whole identifier reference.
-- The frontier pattern demands a non-identifier character (or start of
-- line) before the name, so `Prio.` cannot satisfy an `io.` scan, and
-- the trailing dot (optionally spaced: `os .time` is valid Lua) is what
-- distinguishes a library access from a variable that merely ends in
-- the same letters.
-- @param code string Source with comments already blanked
-- @param lib string Library name, e.g. "os"
-- @return table Array of line numbers, each listed once
local function libReferenceLines(code, lib)
    local pattern = "%f[%w_]" .. lib .. "%s*%."
    local hits = {}
    local lineNo = 0
    for line in (code .. "\n"):gmatch("(.-)\n") do
        lineNo = lineNo + 1
        if line:find(pattern) then
            hits[#hits + 1] = lineNo
        end
    end
    return hits
end

--- Every `path:line` in shipped source referencing the given library.
local function offendersFor(lib)
    local offenders = {}
    for _, path in ipairs(tocSourceFiles() or {}) do
        local src = readFile(path)
        assert.is_string(src, "could not read " .. path)
        for _, line in ipairs(libReferenceLines(stripComments(src), lib)) do
            offenders[#offenders + 1] = path .. ":" .. line
        end
    end
    return offenders
end

describe("Sandbox globals", function()
    -- The denominator, so a broken .toc parse cannot turn the bans below
    -- into a pass over zero files.
    it("names the addon's own files, and only those, from the .toc", function()
        local files = tocSourceFiles()
        assert.is_table(files, "GuildBankLedger.toc could not be read")
        assert.is_true(#files > 20,
            "the .toc parse found " .. #files .. " files, which is too few")
        for _, path in ipairs(files) do
            assert.is_truthy(path:match("^src/") or path:match("^UI/"),
                path .. " is neither src/ nor UI/")
        end
    end)

    -- The matcher is doing the load-bearing work: too loose and it reds
    -- on healthy code until someone weakens it, too tight and the ban
    -- passes over a real call.
    describe("the matcher", function()
        it("flags a library access", function()
            assert.same({ 1 }, libReferenceLines('local x = os.date("!%Y")', "os"))
            assert.same({ 1 }, libReferenceLines("local f = io.open(p)", "io"))
        end)

        it("flags a spaced access, which is valid Lua", function()
            assert.same({ 1 }, libReferenceLines("local t = os .time()", "os"))
        end)

        -- The real shapes that must not match: src/Sync.lua reads
        -- CTL.Prio.ALERT today, and "outcomes" ends in the other name.
        it("does not flag the substring inside a longer identifier", function()
            assert.same({}, libReferenceLines("local q = CTL.Prio.ALERT.nSize", "io"))
            assert.same({}, libReferenceLines("local r = chunkOutcomes.ratio", "os"))
        end)

        it("does not flag a name that merely starts the same way", function()
            assert.same({}, libReferenceLines("local v = ostensible.field", "os"))
        end)

        it("ignores an access in a comment", function()
            local code = stripComments(
                "-- never use os.time() here, use GetServerTime()\nlocal x = 1")
            assert.same({}, libReferenceLines(code, "os"))
        end)

        it("reports each offending line by number", function()
            assert.same({ 2, 4 }, libReferenceLines(
                "local a = 1\nlocal b = os.time()\nlocal c = 2\nlocal d = os.clock()",
                "os"))
        end)
    end)

    it("calls no os API anywhere the .toc ships", function()
        assert.same({}, offendersFor("os"))
    end)

    it("calls no io API anywhere the .toc ships", function()
        assert.same({}, offendersFor("io"))
    end)
end)
