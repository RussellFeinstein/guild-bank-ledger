------------------------------------------------------------------------
-- slash_commands_spec.lua — one command list, three implementations.
--
-- The set of `/gbl` subcommands exists in three places that have to
-- agree, and nothing until now made them:
--
--   1. `HandleSlashCommand` in src/Core.lua, which is the definition of
--      what the addon actually answers to.
--   2. `PrintHelp`, which is what a player sees when they ask.
--   3. The command table in README.md.
--
-- They had drifted in both directions at once. The dispatcher served
-- commands the help text never mentioned (a player could only find them
-- by reading the source), and the help text and the README each listed a
-- different subset of the rest. A command nobody can discover is a
-- feature that does not exist, and a README that lists a subset reads as
-- a complete list to anyone who has not counted.
--
-- The dispatcher is the authority here, deliberately: it is the only one
-- of the three whose content is load-bearing at runtime, so the other
-- two are checked against it rather than the reverse. Adding a command
-- therefore reds this spec until it is documented in both places, which
-- is the whole point.
--
-- Aliases count once. `deviations` and `devs` reach the same handler, so
-- documenting either satisfies the requirement; requiring both would
-- force the docs to list an alias the player does not need.
--
-- The bare `/gbl` form (dispatched as the empty string) is not a name
-- and is excluded; it is documented on its own README row.
------------------------------------------------------------------------

local Helpers = require("spec.helpers")

--- Read a whole file with CRLF normalized away, or nil if unreadable.
-- The repo's files are CRLF on Windows and LF in CI, and every check
-- below is about text structure rather than bytes, so normalizing here
-- is what keeps one `\nend\n` anchor working in both places.
local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local contents = fh:read("*a")
    fh:close()
    return (contents:gsub("\r\n", "\n"))
end

--- Body of a top-level `function GBL:<name>(` block, by source text.
-- Ends at the first `end` in column 1, which is the closing `end` of the
-- function: every `end` inside it is indented.
-- @param src string Lua source
-- @param name string Method name
-- @return string|nil The body, or nil if the function was not found
local function functionBody(src, name)
    local from = src:find("function GBL:" .. name .. "%(")
    if not from then return nil end
    local to = src:find("\nend\n", from, true)
    if not to then return nil end
    return src:sub(from, to)
end

--- Command-name groups the dispatcher answers to, one group per branch.
-- A branch matching several names (an alias) yields one group holding
-- all of them. The empty-string branch contributes no name.
-- @param body string Source of HandleSlashCommand
-- @return table Array of arrays of names
local function dispatchedGroups(body)
    local groups = {}
    -- Splitting on `elseif` keeps an alias pair (`x" or command == "y`)
    -- inside one branch, which is what makes them count once.
    for branch in (body .. "\nelseif"):gmatch("(.-)\n%s*elseif") do
        local names = {}
        for name in branch:gmatch('command == "([%w_%-0-9]*)"') do
            if name ~= "" then names[#names + 1] = name end
        end
        if #names > 0 then groups[#groups + 1] = names end
    end
    return groups
end

--- Does `text` document `/gbl <name>` as a whole word?
-- The trailing boundary stops `logs` from being satisfied by a mention
-- of `logsomething`, and stops a command from being read as documented
-- because a longer one shares its prefix.
-- @param text string
-- @param name string
-- @return boolean
local function documents(text, name)
    local at = 1
    while true do
        local from, to = text:find("/gbl " .. name, at, true)
        if not from then return false end
        local after = text:sub(to + 1, to + 1)
        if not after:match("[%w_]") then return true end
        at = to + 1
    end
end

--- Render a group for a failure message: "deviations (or devs)".
local function describeGroup(names)
    if #names == 1 then return names[1] end
    local rest = {}
    for i = 2, #names do rest[#rest + 1] = names[i] end
    return names[1] .. " (or " .. table.concat(rest, ", ") .. ")"
end

describe("Slash commands", function()
    local core, groups

    setup(function()
        core = readFile("src/Core.lua")
        assert.is_string(core, "could not read src/Core.lua")
        local body = functionBody(core, "HandleSlashCommand")
        assert.is_string(body, "could not find GBL:HandleSlashCommand")
        groups = dispatchedGroups(body)
    end)

    it("finds the dispatcher's command list", function()
        assert.is_true(#groups > 10,
            "the dispatch parse found " .. #groups
            .. " commands, which is too few to be the real list")
        local seen = {}
        for _, names in ipairs(groups) do
            for _, name in ipairs(names) do seen[name] = true end
        end
        -- Spot-check both ends of the list so a parse that silently
        -- matched only part of the function fails here rather than
        -- passing the two checks below vacuously.
        assert.is_true(seen.show, "dispatch parse missed 'show'")
        assert.is_true(seen.restock, "dispatch parse missed 'restock'")
    end)

    it("lists every dispatched command in /gbl help", function()
        Helpers.setupMocks()
        local GBL = Helpers.loadAddon()
        GBL:OnInitialize()
        Helpers.clearPrints()
        GBL:PrintHelp()
        local help = table.concat(Helpers.getPrints(), "\n")

        local missing = {}
        for _, names in ipairs(groups) do
            local found = false
            for _, name in ipairs(names) do
                if documents(help, name) then found = true end
            end
            if not found then missing[#missing + 1] = describeGroup(names) end
        end

        assert.same({}, missing)
    end)

    it("documents every dispatched command in the README table", function()
        local readme = readFile("README.md")
        assert.is_string(readme, "could not read README.md")

        -- Only the command table's rows count. A command mentioned in
        -- prose is not a table row, and the table is what a reader
        -- treats as the list.
        local rows = {}
        for line in readme:gmatch("[^\r\n]+") do
            if line:match("^|%s*`/gbl") then rows[#rows + 1] = line end
        end
        assert.is_true(#rows > 5, "found only " .. #rows .. " command rows in README.md")
        local table_ = table.concat(rows, "\n")

        local missing = {}
        for _, names in ipairs(groups) do
            local found = false
            for _, name in ipairs(names) do
                if documents(table_, name) then found = true end
            end
            if not found then missing[#missing + 1] = describeGroup(names) end
        end

        assert.same({}, missing)
    end)

    describe("dispatch parsing", function()
        it("keeps an alias pair as one group", function()
            local body = [[
    if command == "alpha" then
        self:A()
    elseif command == "beta" or command == "b" then
        self:B()
    end
]]
            local got = dispatchedGroups(body)
            assert.equals(2, #got)
            assert.same({ "alpha" }, got[1])
            assert.same({ "beta", "b" }, got[2])
        end)

        it("drops the bare-command empty string", function()
            local body = [[
    if command == "" or command == "show" then
        self:Toggle()
    end
]]
            assert.same({ { "show" } }, dispatchedGroups(body))
        end)
    end)

    describe("documentation matching", function()
        it("accepts a command followed by a subcommand", function()
            assert.is_true(documents("| `/gbl logs dump [N]` | Dump |", "logs"))
        end)

        it("rejects a longer command that merely starts the same", function()
            assert.is_false(documents("| `/gbl sortlog` | Sort log |", "sort"))
        end)

        it("finds a later occurrence when the first is a prefix match", function()
            assert.is_true(documents("/gbl sortlog\n/gbl sort", "sort"))
        end)
    end)
end)
