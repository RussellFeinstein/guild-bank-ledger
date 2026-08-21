------------------------------------------------------------------------
-- Toolchain invariant: the suite runs under Lua 5.1
------------------------------------------------------------------------
-- The addon lives inside WoW's Lua 5.1 sandbox, so a suite executed by a
-- later interpreter accepts syntax and semantics the game rejects and then
-- reports green over code that breaks in-game.
--
-- This is a live check rather than a note in a doc because the interpreter is
-- chosen outside the repository: CI installs it from the distribution's
-- packages and every developer machine supplies its own. In CI the versioned
-- `luarocks-5.1` is what binds busted to Lua 5.1; plain `luarocks` would build
-- it against whichever interpreter the distribution defaults to, which is a
-- one-word edit away in .github/workflows/ci.yml and would otherwise change
-- nothing visible.
--
-- LuaJIT reports "Lua 5.1" here too, which is correct: that is what the game
-- ships.

describe("toolchain", function()
    it("runs the suite under Lua 5.1", function()
        assert.equal("Lua 5.1", _VERSION)
    end)
end)
