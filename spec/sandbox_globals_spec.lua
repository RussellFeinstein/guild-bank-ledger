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
--
-- The same gap runs the other way for client globals the game has
-- dropped: spec/mock_wow.lua defined GetItemInfo after the 12.1.5 client
-- removed it, so every item lookup errored in game behind a green suite
-- (#360). Five of the item globals C_Item replaced are banned here by
-- name, read through _G included, which luacheck cannot see. luacheck's
-- undefined-global check covers the rest of that family, because
-- .luacheckrc whitelists none of them. Two limits of a line matcher: a
-- local alias of the C_Item function needs a name of its own, and a
-- string literal that names a banned global counts as a reference.
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

--- Line numbers where `name` is referenced as a bare global.
-- A whole-identifier match (so GetItemInfoInstant and GetCachedItemInfo
-- do not satisfy a GetItemInfo scan) that is not a field or method
-- access: the last non-space character before it is not a lone `.` or a
-- `:`. A `..` before it is the concat operator, which is still a bare
-- reference, and so is a field of `_G`, which is the global itself.
-- References are banned, not only calls, because `local f = GetItemInfo`
-- caches the global for a later call.
-- @param code string Source with comments already blanked
-- @param name string Global name, letters only
-- @return table Array of line numbers, each listed once
local function bareGlobalLines(code, name)
    local pattern = "%f[%w_]" .. name .. "%f[^%w_]"
    local hits = {}
    local lineNo = 0
    for line in (code .. "\n"):gmatch("(.-)\n") do
        lineNo = lineNo + 1
        local from = 1
        while true do
            local s, e = line:find(pattern, from)
            if not s then break end
            local before = line:sub(1, s - 1)
            local viaG = before:match("%f[%w_]_G%s*%.%s*$")
            local accessed = not viaG and (before:match("[^%.]%.%s*$")
                or before:match("^%.%s*$") or before:match(":%s*$"))
            if not accessed then
                hits[#hits + 1] = lineNo
                break
            end
            from = e + 1
        end
    end
    return hits
end

--- Every `path:line` in shipped source referencing `name` as a bare global.
local function bareGlobalOffenders(name)
    local offenders = {}
    for _, path in ipairs(tocSourceFiles() or {}) do
        local src = readFile(path)
        assert.is_string(src, "could not read " .. path)
        for _, line in ipairs(bareGlobalLines(stripComments(src), name)) do
            offenders[#offenders + 1] = path .. ":" .. line
        end
    end
    return offenders
end

-- Five of the item globals C_Item replaced, the ones this addon is likeliest
-- to reach for. GetItemInfo is gone from the 12.1.5 client (#360); the
-- others are superseded, and the old names are what a client drops next.
local REPLACED_ITEM_GLOBALS = {
    { name = "GetItemInfo",         use = "C_Item.GetItemInfo" },
    { name = "GetItemInfoInstant",  use = "C_Item.GetItemInfoInstant" },
    { name = "GetItemCount",        use = "C_Item.GetItemCount" },
    { name = "GetItemIcon",         use = "C_Item.GetItemIconByID" },
    { name = "GetItemQualityColor", use = "C_Item.GetItemQualityColor" },
}

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

    describe("the bare-global matcher", function()
        it("flags a bare call", function()
            assert.same({ 1 }, bareGlobalLines("local n = GetItemInfo(id)", "GetItemInfo"))
        end)

        it("flags a bare reference that caches the global", function()
            assert.same({ 1 }, bareGlobalLines("local f = GetItemInfo", "GetItemInfo"))
        end)

        it("flags a call after the concat operator", function()
            assert.same({ 1 }, bareGlobalLines('local s = "x" .. GetItemInfo(id)', "GetItemInfo"))
        end)

        it("flags a call at the start of a line", function()
            assert.same({ 1 }, bareGlobalLines("GetItemInfo(id)", "GetItemInfo"))
        end)

        -- The repo reads client globals through _G in places
        -- (src/SortExecutor.lua's _G.GetGuildBankItemInfo), and luacheck
        -- does not flag a field of _G, so this spelling has no other guard.
        it("flags a read through _G", function()
            assert.same({ 1 }, bareGlobalLines("local n = _G.GetItemInfo(id)", "GetItemInfo"))
            assert.same({ 1 }, bareGlobalLines("local n = _G . GetItemInfo(id)", "GetItemInfo"))
            assert.same({ 1 }, bareGlobalLines("if _G.GetItemInfo then end", "GetItemInfo"))
        end)

        it("does not flag a field of a table whose name ends in _G", function()
            assert.same({}, bareGlobalLines("local n = MY_G.GetItemInfo(id)", "GetItemInfo"))
        end)

        it("does not flag a namespaced call or a method", function()
            assert.same({}, bareGlobalLines("local n = C_Item.GetItemInfo(id)", "GetItemInfo"))
            assert.same({}, bareGlobalLines("local n = C_Item . GetItemInfo(id)", "GetItemInfo"))
            assert.same({}, bareGlobalLines("local n = self:GetItemInfo(id)", "GetItemInfo"))
        end)

        it("does not flag a longer identifier holding the name", function()
            local code = "a = GetItemInfoInstant(id)\nb = self:GetCachedItemInfo(id)\n"
                .. "c = GetItemInfoFromHyperlink(l)\nd = MyGetItemInfo(id)"
            assert.same({}, bareGlobalLines(code, "GetItemInfo"))
        end)

        it("flags a bare call on a line that also has a namespaced one", function()
            assert.same({ 1 }, bareGlobalLines(
                "local a, b = C_Item.GetItemInfo(x), GetItemInfo(y)", "GetItemInfo"))
        end)

        it("ignores a reference in a comment", function()
            local code = stripComments("-- GetItemInfo(id) is gone in 12.1.5\nlocal x = 1")
            assert.same({}, bareGlobalLines(code, "GetItemInfo"))
        end)

        it("reports each offending line by number", function()
            assert.same({ 2, 4 }, bareGlobalLines(
                "local a = 1\nlocal b = GetItemInfo(x)\nlocal c = 2\nlocal d = GetItemInfo(y)",
                "GetItemInfo"))
        end)
    end)

    for _, g in ipairs(REPLACED_ITEM_GLOBALS) do
        it("references no global " .. g.name .. " anywhere the .toc ships (use "
            .. g.use .. ")", function()
            assert.same({}, bareGlobalOffenders(g.name))
        end)
    end
end)
