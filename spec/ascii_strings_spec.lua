------------------------------------------------------------------------
-- ascii_strings_spec.lua — every string the addon can put on screen is ASCII.
--
-- WoW's default fonts carry Latin-1 and little beyond it. A character
-- outside that range draws as a blank or a box depending on the font and
-- the client's locale, which is how "Executing — 4/9" became "Executing
-- 4/9" with a hole in it. Symbols used as UI encoding fail worse than
-- punctuation does: a check mark that does not draw leaves a row whose
-- state is carried by colour alone, which is the accessibility failure
-- the triple-encoding rule exists to prevent.
--
-- Comments are exempt. They never reach a player, and holding them to
-- the same bar would mean rewriting years of prose that reads fine in an
-- editor. That exemption is the whole reason this check strips comments
-- rather than grepping the file.
--
-- The file list comes from the .toc, which is the definition of what
-- ships: a new file is covered the moment it is loadable, with nothing
-- to remember here.
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

describe("In-game strings", function()
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

    it("contains no character outside ASCII", function()
        local offenders = {}

        for _, path in ipairs(tocSourceFiles() or {}) do
            local src = readFile(path)
            assert.is_string(src, "could not read " .. path)

            local code = stripComments(src)
            local line = 1
            local reportedOnLine = nil
            for i = 1, #code do
                local byte = code:byte(i)
                if byte == 10 then
                    line = line + 1
                elseif byte > 127 and reportedOnLine ~= line then
                    reportedOnLine = line
                    offenders[#offenders + 1] = path .. ":" .. line
                end
            end
        end

        assert.same({}, offenders)
    end)

    -- The stripper is doing the load-bearing work: get it wrong in the
    -- permissive direction and the check above passes on a file full of
    -- box glyphs.
    describe("comment stripping", function()
        it("keeps a short string literal", function()
            assert.equals('x = "keep"', stripComments('x = "keep"'))
        end)

        it("blanks a line comment but holds the line count", function()
            local out = stripComments("a\n-- gone\nb")
            assert.equals("a\n       \nb", out)
        end)

        it("blanks a long comment across lines", function()
            local out = stripComments("a\n--[[ one\ntwo ]]\nb")
            assert.equals("a\n        \n      \nb", out)
        end)

        it("keeps a long string literal", function()
            assert.equals("x = [[keep\nthis]]", stripComments("x = [[keep\nthis]]"))
        end)

        it("does not treat a comment marker inside a string as a comment",
        function()
            assert.equals('x = "a -- b"', stripComments('x = "a -- b"'))
        end)

        it("does not end a string on an escaped quote", function()
            local src = 'x = "a\\"-- still string"'
            assert.equals(src, stripComments(src))
        end)
    end)
end)
