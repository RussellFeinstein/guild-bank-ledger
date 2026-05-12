--- chatfilters_spec.lua — Tests for ChatFilters module

local Helpers = require("spec.helpers")

describe("ChatFilters", function()
    local GBL

    before_each(function()
        Helpers.setupMocks()
        Helpers.MockWoW.guild.name = "Test Guild"
        GBL = Helpers.loadAddon()
        GBL:OnInitialize()
    end)

    describe("_IsMutedAmbientNPC", function()
        it("returns false when toggle is off, even for a matching name", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = false
            assert.is_false(GBL:_IsMutedAmbientNPC("Silvermoon Citizen"))
        end)

        it("returns true when toggle is on and sender is in the muted set", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            assert.is_true(GBL:_IsMutedAmbientNPC("Silvermoon Citizen"))
        end)

        it("returns false when toggle is on but sender is not in the muted set", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            assert.is_false(GBL:_IsMutedAmbientNPC("Random Guard"))
        end)

        it("returns false for nil sender (defensive)", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            assert.is_false(GBL:_IsMutedAmbientNPC(nil))
        end)

        it("returns false for non-string sender (secret key regression)", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            assert.is_false(GBL:_IsMutedAmbientNPC(42))
            assert.is_false(GBL:_IsMutedAmbientNPC(true))
            assert.is_false(GBL:_IsMutedAmbientNPC({}))
        end)

        it("is case-sensitive (matches WoW chat sender as-is)", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            assert.is_false(GBL:_IsMutedAmbientNPC("silvermoon citizen"))
            assert.is_false(GBL:_IsMutedAmbientNPC("SILVERMOON CITIZEN"))
        end)

        it("defaults to off on a fresh profile", function()
            assert.is_false(GBL.db.profile.chatFilters.muteAmbientNPCs)
            assert.is_false(GBL:_IsMutedAmbientNPC("Silvermoon Citizen"))
        end)
    end)

    describe("_OnAmbientMonsterChat instance guard", function()
        before_each(function()
            GBL:_ClearPendingBubbleSuppressions()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
        end)

        it("queues suppression in open world", function()
            Helpers.MockWoW.instanceType = "none"
            GBL:_OnAmbientMonsterChat("CHAT_MSG_MONSTER_SAY", "Welcome.", "Silvermoon Citizen")
            assert.is_true(GBL:_PendingBubbleHas("Welcome."))
        end)

        for _, itype in ipairs({ "party", "raid", "pvp", "arena", "scenario" }) do
            it("skips suppression when in a " .. itype .. " instance", function()
                Helpers.MockWoW.instanceType = itype
                GBL:_OnAmbientMonsterChat("CHAT_MSG_MONSTER_SAY", "Welcome.", "Silvermoon Citizen")
                assert.is_false(GBL:_PendingBubbleHas("Welcome."))
            end)
        end
    end)

    describe("chatFrameFilter (registered chat-frame filter)", function()
        local filter

        before_each(function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            Helpers.MockWoW.instanceType = "none"
            filter = Helpers.MockWoW.chatMessageFilters["CHAT_MSG_MONSTER_SAY"][1]
            assert.is_function(filter)
        end)

        it("returns true (suppress) for a muted ambient NPC in open world", function()
            assert.is_true(filter(nil, "CHAT_MSG_MONSTER_SAY", "msg", "Silvermoon Citizen"))
        end)

        it("returns false (pass through) when toggle is off", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = false
            assert.is_false(filter(nil, "CHAT_MSG_MONSTER_SAY", "msg", "Silvermoon Citizen"))
        end)

        it("returns false for non-string sender (secret-key regression)", function()
            assert.is_false(filter(nil, "CHAT_MSG_MONSTER_SAY", "msg", {}))
            assert.is_false(filter(nil, "CHAT_MSG_MONSTER_SAY", "msg", 42))
            assert.is_false(filter(nil, "CHAT_MSG_MONSTER_SAY", "msg", true))
        end)

        it("returns false when in any instance (does not consult the predicate)", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            for _, itype in ipairs({ "party", "raid", "pvp", "arena", "scenario" }) do
                Helpers.MockWoW.instanceType = itype
                assert.is_false(
                    filter(nil, "CHAT_MSG_MONSTER_SAY", "msg", "Silvermoon Citizen"),
                    "expected false for instanceType=" .. itype
                )
            end
        end)

        it("is also registered for EMOTE and is instance-guarded there", function()
            local emoteFilter = Helpers.MockWoW.chatMessageFilters["CHAT_MSG_MONSTER_EMOTE"][1]
            assert.is_function(emoteFilter)
            assert.is_true(emoteFilter(nil, "CHAT_MSG_MONSTER_EMOTE", "waves", "Silvermoon Citizen"))
            Helpers.MockWoW.instanceType = "party"
            assert.is_false(emoteFilter(nil, "CHAT_MSG_MONSTER_EMOTE", "waves", "Silvermoon Citizen"))
        end)
    end)

    describe("muted-name set", function()
        it("is the single source of truth, adding a name makes it suppressed", function()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
            assert.is_false(GBL:_IsMutedAmbientNPC("Future Annoying NPC"))
            GBL._mutedAmbientNPCs["Future Annoying NPC"] = true
            assert.is_true(GBL:_IsMutedAmbientNPC("Future Annoying NPC"))
            GBL._mutedAmbientNPCs["Future Annoying NPC"] = nil
        end)
    end)

    describe("_StripChatFormatting", function()
        it("returns empty string for nil or empty input", function()
            assert.equals("", GBL:_StripChatFormatting(nil))
            assert.equals("", GBL:_StripChatFormatting(""))
        end)

        it("leaves a plain string untouched", function()
            assert.equals("Hello there.", GBL:_StripChatFormatting("Hello there."))
        end)

        it("strips color escape sequences", function()
            assert.equals("Hello",
                GBL:_StripChatFormatting("|cffff8800Hello|r"))
        end)

        it("strips item hyperlink wrappers but keeps the visible text", function()
            local link = "|cffff8000|Hitem:12345::::::::70:::::|h[Thunderfury]|h|r"
            assert.equals("[Thunderfury]", GBL:_StripChatFormatting(link))
        end)

        it("trims surrounding whitespace", function()
            assert.equals("Hello", GBL:_StripChatFormatting("  Hello  "))
            assert.equals("Hello world", GBL:_StripChatFormatting("\nHello world\t"))
        end)
    end)

    describe("_BubbleTextMatches", function()
        before_each(function()
            GBL:_ClearPendingBubbleSuppressions()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
        end)

        it("returns false when nothing is queued", function()
            assert.is_false(GBL:_BubbleTextMatches("Hello"))
        end)

        it("matches exact text after stripping formatting", function()
            GBL:_QueueBubbleSuppression("Hello citizen!")
            assert.is_true(GBL:_BubbleTextMatches("Hello citizen!"))
            assert.is_true(GBL:_BubbleTextMatches("|cffff8800Hello citizen!|r"))
        end)

        it("matches on substring when bubble text wraps the queued message", function()
            GBL:_QueueBubbleSuppression("Welcome.")
            assert.is_true(GBL:_BubbleTextMatches("<say> Welcome. </say>"))
        end)

        it("matches on substring when queued text wraps the bubble text", function()
            GBL:_QueueBubbleSuppression("The streets are bustling today.")
            assert.is_true(GBL:_BubbleTextMatches("streets are bustling"))
        end)

        it("returns false on empty bubble text", function()
            GBL:_QueueBubbleSuppression("Hello citizen!")
            assert.is_false(GBL:_BubbleTextMatches(""))
            assert.is_false(GBL:_BubbleTextMatches(nil))
        end)
    end)

    describe("bubble suppression queue", function()
        before_each(function()
            GBL:_ClearPendingBubbleSuppressions()
            GBL.db.profile.chatFilters.muteAmbientNPCs = true
        end)

        it("queues a stripped form of the message", function()
            GBL:_QueueBubbleSuppression("|cffff8800Hello|r")
            assert.is_true(GBL:_PendingBubbleHas("Hello"))
            assert.is_false(GBL:_PendingBubbleHas("|cffff8800Hello|r"))
        end)

        it("ignores nil and empty messages", function()
            GBL:_QueueBubbleSuppression(nil)
            GBL:_QueueBubbleSuppression("")
            assert.is_false(GBL:_PendingBubbleHas(""))
        end)

        it("clear wipes everything", function()
            GBL:_QueueBubbleSuppression("Citizens of Silvermoon, rejoice!")
            assert.is_true(GBL:_PendingBubbleHas("Citizens of Silvermoon, rejoice!"))
            GBL:_ClearPendingBubbleSuppressions()
            assert.is_false(GBL:_PendingBubbleHas("Citizens of Silvermoon, rejoice!"))
        end)
    end)
end)
