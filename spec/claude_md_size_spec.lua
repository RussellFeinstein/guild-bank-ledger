------------------------------------------------------------------------
-- claude_md_size_spec.lua - CLAUDE.md stays small, and the detail it
-- points at stays loadable.
--
-- Claude Code loads CLAUDE.md into every session and warns at startup
-- once the instruction files together pass about 150K characters. This
-- file had reached 225K by 2026-09-28, because nearly every PR added a
-- paragraph to a subsystem bullet. The subsystem detail now lives in
-- .claude/rules/*.md, each with a `paths:` list, and Claude Code loads
-- one of those only when a matching file is opened.
--
-- Two ways that arrangement decays without anything going red:
--   1. A paragraph lands here instead of in its rule file, and the file
--      grows back. The cap below is what stops it.
--   2. A rule file loses its `paths:` list (so it loads at every
--      startup, which is the cost this split removed), or its paths
--      stop naming anything (a renamed source file silently disarms
--      the rule). The frontmatter and path checks stop those.
--
-- The frontmatter shape is pinned to one line, `paths: ["a", "b"]`, so
-- this spec needs no YAML parser.
------------------------------------------------------------------------

local CAP = 60000
local RULES_DIR = ".claude/rules"
local EXPECTED_RULES = { "restock.md", "sort.md", "sync.md", "testing.md", "ui.md" }

--- Read a whole file with carriage returns removed, or nil. The working
--- tree is CRLF on Windows and LF in CI, and the cap has to mean the
--- same number on both.
local function readFile(path)
    local fh = io.open(path, "rb")
    if not fh then return nil end
    local contents = fh:read("*a")
    fh:close()
    return (contents:gsub("\r", ""))
end

--- Paths git knows under a pathspec, tracked or untracked-but-not-ignored,
--- so the spec reads the same before and after `git add`.
local function gitFiles(pathspec)
    local ph = io.popen('git ls-files --cached --others --exclude-standard -- "' .. pathspec .. '"')
    if not ph then return {} end
    local out = ph:read("*a") or ""
    ph:close()
    local files, seen = {}, {}
    for line in out:gmatch("[^\r\n]+") do
        if not seen[line] then
            seen[line] = true
            files[#files + 1] = line
        end
    end
    return files
end

--- The `paths:` list of a rule file, or nil plus the reason it has none.
local function rulePaths(contents)
    local first, second, third = contents:match("^([^\n]*)\n([^\n]*)\n([^\n]*)\n")
    if first ~= "---" or third ~= "---" then
        return nil, "does not open with a three-line --- frontmatter block"
    end
    local list = second:match("^paths: %[(.*)%]$")
    if not list then
        return nil, "frontmatter line 2 is not paths: [...]"
    end
    local paths = {}
    for item in list:gmatch('"([^"]+)"') do
        paths[#paths + 1] = item
    end
    if #paths == 0 then
        return nil, "paths list is empty"
    end
    return paths
end

local function isGlob(path)
    return path:find("[%*%?%[{]") ~= nil
end

describe("CLAUDE.md size and the path-scoped rules", function()
    local ruleFiles = gitFiles(RULES_DIR)

    it("keeps CLAUDE.md under the startup budget", function()
        local contents = readFile("CLAUDE.md")
        assert.is_not_nil(contents, "CLAUDE.md not found")
        local size = #contents
        assert.is_true(size <= CAP, string.format(
            "CLAUDE.md is %d bytes, over the %d cap. Subsystem detail belongs in "
            .. "the matching %s/<area>.md file, not here.", size, CAP, RULES_DIR))
    end)

    it("has every rule file the split created", function()
        local present = {}
        for _, path in ipairs(ruleFiles) do
            present[path:match("[^/]+$")] = true
        end
        for _, name in ipairs(EXPECTED_RULES) do
            assert.is_true(present[name] == true, RULES_DIR .. "/" .. name .. " is missing")
        end
    end)

    it("gives every rule file a one-line paths list", function()
        assert.is_true(#ruleFiles > 0, "no files found under " .. RULES_DIR)
        for _, path in ipairs(ruleFiles) do
            local contents = readFile(path)
            assert.is_not_nil(contents, path .. " cannot be read")
            local paths, why = rulePaths(contents)
            assert.is_not_nil(paths, path .. ": " .. tostring(why)
                .. ". A rule with no paths list loads at every startup.")
        end
    end)

    it("points every paths entry at something that exists", function()
        for _, path in ipairs(ruleFiles) do
            local paths = rulePaths(readFile(path) or "") or {}
            for _, entry in ipairs(paths) do
                if isGlob(entry) then
                    assert.is_true(#gitFiles(entry) > 0,
                        path .. ": glob " .. entry .. " matches no file")
                else
                    assert.is_not_nil(readFile(entry),
                        path .. ": " .. entry .. " does not exist")
                end
            end
        end
    end)

    it("names every rule file from CLAUDE.md", function()
        local contents = readFile("CLAUDE.md") or ""
        for _, path in ipairs(ruleFiles) do
            assert.is_not_nil(contents:find(path, 1, true),
                "CLAUDE.md does not mention " .. path)
        end
    end)
end)
