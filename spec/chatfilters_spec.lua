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
