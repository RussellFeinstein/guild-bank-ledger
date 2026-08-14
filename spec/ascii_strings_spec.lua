------------------------------------------------------------------------
-- ascii_strings_spec.lua — what the addon may put on screen.
--
-- Two independent properties, both about strings surviving WoW's
-- renderer, and a file can satisfy either while breaking the other.
--
-- 1. ASCII only. WoW's default fonts carry Latin-1 and little beyond it.
--    A character outside that range draws as a blank or a box depending
--    on the font and the client's locale, which is how "Executing — 4/9"
--    became "Executing 4/9" with a hole in it. Symbols used as UI
--    encoding fail worse than punctuation does: a check mark that does
--    not draw leaves a row whose state is carried by colour alone, which
--    is the accessibility failure the triple-encoding rule exists to
--    prevent.
--
-- 2. Every pipe begins a valid escape. WoW reads `|` as the introducer
--    for colour, texture, link and newline codes, so a lone `|` is an
--    incomplete code: it renders unreliably and can swallow the
--    character after it. A literal pipe is written `||`. This was
--    learned in v0.29.x on a Restock row and then shipped again in
--    v0.37.4's peer tags, which is what this check is here to stop
--    happening a third time. Note that `|` is ASCII, so property 1 is
--    blind to it.
--
-- Comments are exempt from both. They never reach a player, and holding
-- them to the same bar would mean rewriting years of prose that reads
-- fine in an editor. That exemption is the whole reason this check
-- strips comments rather than grepping the file.
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

--- Line numbers carrying a byte above 127, decimal escapes included.
-- `"\226\156\147"` is ASCII on disk and a check mark on screen, so reading
-- the source bytes alone misses it. Backslashes are consumed as escapes so
-- an escaped backslash cannot make the digits after it look like one.
-- @param code string Source with comments already blanked
-- @return table Array of line numbers, each listed once
local function nonAsciiLines(code)
    local hits, seen = {}, {}
    local line, i, n = 1, 1, #code

    local function report()
        if not seen[line] then
            seen[line] = true
            hits[#hits + 1] = line
        end
    end

    while i <= n do
        local byte = code:byte(i)
        if byte == 10 then
            line = line + 1
            i = i + 1
        elseif byte == 92 then
            local digits = code:match("^\\(%d%d?%d?)", i)
            if digits then
                if tonumber(digits) > 127 then report() end
                i = i + 1 + #digits
            else
                if code:byte(i + 1) == 10 then line = line + 1 end
                i = i + 2
            end
        else
            if byte > 127 then report() end
            i = i + 1
        end
    end

    return hits
end

--- Every string literal in comment-stripped source, with its line number.
-- Boundaries matter because the pipe rule exempts a handful of literals by
-- their exact content: a scan over raw lines could not tell the record-id
-- pattern from a label that happens to sit on the same line.
-- @param code string Source with comments already blanked
-- @return table Array of { text = <literal body>, line = <number> }
local function stringLiterals(code)
    local out = {}
    local line, i, n = 1, 1, #code

    while i <= n do
        local c = code:sub(i, i)
        if c == '"' or c == "'" then
            local startLine = line
            local body = {}
            i = i + 1
            while i <= n do
                local ch = code:sub(i, i)
                if ch == "\\" then
                    -- Consume the escape whole, so an escaped quote does
                    -- not end the literal and an escaped backslash cannot
                    -- make the next character look escaped.
                    local digits = code:match("^\\(%d%d?%d?)", i)
                    body[#body + 1] = code:sub(i, i + (digits and #digits or 1))
                    if code:byte(i + 1) == 10 then line = line + 1 end
                    i = i + 1 + (digits and #digits or 1)
                else
                    i = i + 1
                    if ch == c then break end
                    if ch == "\n" then line = line + 1 break end
                    body[#body + 1] = ch
                end
            end
            out[#out + 1] = { text = table.concat(body), line = startLine }
        else
            local eq = code:match("^%[(=*)%[", i)
            if eq then
                local close = "]" .. eq .. "]"
                local from, to = code:find(close, i + #eq + 2, true)
                local stop = to or n
                local text = code:sub(i + #eq + 2, (from or n + 1) - 1)
                out[#out + 1] = { text = text, line = line }
                local _, breaks = code:sub(i, stop):gsub("\n", "")
                line = line + breaks
                i = stop + 1
            else
                if c == "\n" then line = line + 1 end
                i = i + 1
            end
        end
    end

    return out
end

-- The escape letters WoW actually defines. `||` is the literal pipe and
-- is handled separately, by consuming both characters.
local PIPE_CODES = {
    c = true, r = true,   -- colour open / close
    H = true, h = true,   -- hyperlink
    T = true, t = true,   -- inline texture
    A = true, a = true,   -- atlas
    K = true, k = true,   -- keybind / battle pet
    n = true,             -- newline
}

-- Literals whose pipes are data rather than display, matched on exact
-- content so a near-miss is not silently waved through. Record ids are
-- BUILT from pipes (see the wire notes in CLAUDE.md), the record-id
-- pattern parses that separator back out, and the hyperlink pattern is a
-- Lua pattern rather than a display string.
local PIPE_EXEMPT_LITERALS = {
    ["|"] = true,
    ["|(%d+):%d+$"] = true,
    ["|H[^|]*|h"] = true,
}

--- Line numbers whose literals contain a pipe that starts no valid escape.
-- @param code string Source with comments already blanked
-- @return table Array of { line = <number>, text = <literal body> }
local function badPipeLiterals(code)
    local hits = {}

    for _, lit in ipairs(stringLiterals(code)) do
        if not PIPE_EXEMPT_LITERALS[lit.text] then
            local text = lit.text
            local i, n = 1, #text
            while i <= n do
                local ch = text:sub(i, i)
                if ch == "\\" then
                    i = i + 2
                elseif ch == "|" then
                    local nxt = text:sub(i + 1, i + 1)
                    if nxt == "|" then
                        i = i + 2
                    else
                        if not PIPE_CODES[nxt] then
                            hits[#hits + 1] = { line = lit.line, text = text }
                            break
                        end
                        i = i + 1
                    end
                else
                    i = i + 1
                end
            end
        end
    end

    return hits
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
            for _, line in ipairs(nonAsciiLines(stripComments(src))) do
                offenders[#offenders + 1] = path .. ":" .. line
            end
        end

        assert.same({}, offenders)
    end)

    it("starts a valid escape with every pipe", function()
        local offenders = {}

        for _, path in ipairs(tocSourceFiles() or {}) do
            local src = readFile(path)
            assert.is_string(src, "could not read " .. path)
            for _, hit in ipairs(badPipeLiterals(stripComments(src))) do
                offenders[#offenders + 1] =
                    path .. ":" .. hit.line .. "  " .. hit.text
            end
        end

        assert.same({}, offenders)
    end)

    describe("pipe scanning", function()
        it("accepts a doubled pipe", function()
            assert.same({}, badPipeLiterals([[x = "a || b"]]))
        end)

        it("accepts the colour codes", function()
            assert.same({}, badPipeLiterals([[x = "|cff00ff00green|r"]]))
        end)

        it("rejects a bare pipe used as a separator", function()
            local hits = badPipeLiterals([[x = "too old | sync refused"]])
            assert.equals(1, #hits)
            assert.equals(1, hits[1].line)
        end)

        -- The v0.37.4 shape exactly: valid codes around an invalid one.
        it("rejects a bare pipe between valid colour codes", function()
            assert.equals(1,
                #badPipeLiterals([[x = "|cffff4400(too old | sync refused)|r"]]))
        end)

        it("exempts the data and pattern literals by exact content", function()
            assert.same({}, badPipeLiterals([[x = "|"]]))
            assert.same({}, badPipeLiterals([[x = "|(%d+):%d+$"]]))
            assert.same({}, badPipeLiterals([[x = "|H[^|]*|h"]]))
        end)

        -- Exact content, so a label that merely contains an exempt string
        -- is still checked.
        it("does not extend an exemption to a longer literal", function()
            assert.equals(1, #badPipeLiterals([[x = "target 4 | bank 2"]]))
        end)

        it("ignores a pipe in a comment", function()
            assert.same({}, badPipeLiterals(stripComments("-- a | b\nx = 1")))
        end)

        it("reports the line the literal starts on", function()
            local hits = badPipeLiterals('a\nb\nx = "p | q"')
            assert.equals(1, #hits)
            assert.equals(3, hits[1].line)
        end)
    end)

    describe("escape decoding", function()
        it("flags a decimal escape above 127", function()
            assert.same({ 1 }, nonAsciiLines([[x = "\226\156\147"]]))
        end)

        it("passes a decimal escape inside ASCII", function()
            assert.same({}, nonAsciiLines([[x = "\65\66"]]))
        end)

        -- The backslash of an escaped backslash swallows the second one, so
        -- the digits after it are text rather than an escape.
        it("does not read digits after an escaped backslash as an escape",
        function()
            assert.same({}, nonAsciiLines('x = "a\\\\226"'))
        end)

        it("reports each line once and counts lines correctly", function()
            assert.same({ 2 }, nonAsciiLines('a\nx = "\\200\\201"\nb'))
        end)
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
