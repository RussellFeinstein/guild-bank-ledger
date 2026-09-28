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
-- Three ways that arrangement decays without anything going red:
--   1. A paragraph lands here instead of in its rule file, and the file
--      grows back. The cap below is what stops it.
--   2. A rule file loses its `paths:` list (so it loads at every
--      startup, which is the cost this split removed), or its paths
--      stop naming anything (a renamed source file silently disarms
--      the rule). The frontmatter and path checks stop those.
--   3. A Windows checkout turns the frontmatter into CRLF, a form nobody
--      has seen Claude Code accept. .gitattributes pins the rule files
--      to LF, and the last check pins that attribute.
--
-- The frontmatter shape is pinned to one line, `paths: ["a", "b"]`, so
-- this spec needs no YAML parser. Globs are checked with git's
-- `:(glob)` pathspec, where `*` stops at `/` and `**` crosses
-- directories, which is the reading Claude Code gives them. git has no
-- brace expansion, so an entry with braces is refused rather than
-- checked wrongly.
------------------------------------------------------------------------

local CAP = 60000
local RULES_DIR = ".claude/rules"
local EXPECTED_RULES = {
    ".claude/rules/restock.md",
    ".claude/rules/sort.md",
    ".claude/rules/sync.md",
    ".claude/rules/testing.md",
    ".claude/rules/ui.md",
}

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

local function fileExists(path)
    local fh = io.open(path, "rb")
    if not fh then return false end
    fh:close()
    return true
end

--- Lines a git command prints, deduplicated.
local function gitLines(cmd)
    local ph = io.popen(cmd)
    if not ph then return {} end
    local out = ph:read("*a") or ""
    ph:close()
    local lines, seen = {}, {}
    for line in out:gmatch("[^\r\n]+") do
        if not seen[line] then
            seen[line] = true
            lines[#lines + 1] = line
        end
    end
    return lines
end

--- Paths git knows under a pathspec, tracked or untracked-but-not-ignored,
--- so the spec reads the same before and after `git add`.
local function gitFiles(pathspec)
    return gitLines('git ls-files --cached --others --exclude-standard -- "' .. pathspec .. '"')
end

--- The rule files Claude Code would load: .md files under the rules
--- directory that are present in the working tree.
local function ruleFiles()
    local files = {}
    for _, path in ipairs(gitFiles(RULES_DIR)) do
        if path:match("%.md$") and fileExists(path) then
            files[#files + 1] = path
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
    return path:find("[%*%?%[]") ~= nil
end

describe("CLAUDE.md size and the path-scoped rules", function()
    local rules = ruleFiles()

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
        for _, path in ipairs(rules) do present[path] = true end
        for _, path in ipairs(EXPECTED_RULES) do
            assert.is_true(present[path] == true, path .. " is missing")
        end
    end)

    it("gives every rule file a one-line paths list", function()
        assert.is_true(#rules > 0, "no .md files found under " .. RULES_DIR)
        for _, path in ipairs(rules) do
            local paths, why = rulePaths(readFile(path))
            assert.is_not_nil(paths, path .. ": " .. tostring(why)
                .. ". A rule with no paths list loads at every startup.")
        end
    end)

    it("points every paths entry at something that exists", function()
        for _, path in ipairs(rules) do
            local paths = rulePaths(readFile(path)) or {}
            for _, entry in ipairs(paths) do
                assert.is_nil(entry:find("{", 1, true), path .. ": " .. entry
                    .. " uses braces, which this check cannot expand. Write each "
                    .. "alternative as its own entry.")
                local magic = isGlob(entry) and ":(glob)" or ":(literal)"
                assert.is_true(#gitFiles(magic .. entry) > 0,
                    path .. ": " .. entry .. " matches no file")
            end
        end
    end)

    it("names every rule file from CLAUDE.md", function()
        local contents = readFile("CLAUDE.md") or ""
        for _, path in ipairs(rules) do
            assert.is_not_nil(contents:find(path, 1, true),
                "CLAUDE.md does not mention " .. path)
        end
    end)

    it("pins every rule file to LF line endings", function()
        for _, path in ipairs(rules) do
            local out = gitLines('git check-attr eol -- "' .. path .. '"')[1] or ""
            assert.is_not_nil(out:find(": eol: lf$"), path
                .. " is not pinned to LF in .gitattributes (git says: " .. out .. ")")
        end
    end)
end)
