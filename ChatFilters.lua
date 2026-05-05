------------------------------------------------------------------------
-- GuildBankLedger — ChatFilters.lua
-- Optional client-side suppression for ambient NPC chatter that shares
-- space with the guild bank (e.g. Silvermoon Citizen). Hides both the
-- chat-frame line and the world speech bubble.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

-- Localized NPC display names. Sender for MONSTER_* events is the
-- localized name on the client, so this set only matches on enUS.
local MUTED_AMBIENT_NPCS = {
    ["Silvermoon Citizen"] = true,
}

local CHAT_EVENTS = {
    "CHAT_MSG_MONSTER_SAY",
    "CHAT_MSG_MONSTER_YELL",
    "CHAT_MSG_MONSTER_EMOTE",
}

-- Only SAY and YELL spawn world bubbles; EMOTE does not.
local BUBBLE_EVENTS = {
    "CHAT_MSG_MONSTER_SAY",
    "CHAT_MSG_MONSTER_YELL",
}

local PENDING_BUBBLE_TTL = 4.0
local BUBBLE_POLL_INTERVAL = 0.05
local FONTSTRING_WALK_DEPTH = 4

-- text -> game-time at which to forget the entry
local pendingBubbleTexts = {}

------------------------------------------------------------------------
-- Public predicate (kept for the chat-frame filter and tests).
------------------------------------------------------------------------

function GBL:_IsMutedAmbientNPC(sender)
    if not sender then return false end
    if not self.db or not self.db.profile or not self.db.profile.chatFilters
            or not self.db.profile.chatFilters.muteAmbientNPCs then
        return false
    end
    return MUTED_AMBIENT_NPCS[sender] == true
end

------------------------------------------------------------------------
-- Bubble-text helpers. Pure functions, exposed for tests.
------------------------------------------------------------------------

--- Strip WoW chat formatting tokens and trim whitespace.
function GBL:_StripChatFormatting(text)
    if not text or text == "" then return "" end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("|H[^|]*|h", "")
    text = text:gsub("|h", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

function GBL:_QueueBubbleSuppression(msg)
    if not msg or msg == "" then return end
    local now = GetTime and GetTime() or 0
    pendingBubbleTexts[self:_StripChatFormatting(msg)] = now + PENDING_BUBBLE_TTL
end

function GBL:_PendingBubbleHas(text)
    return pendingBubbleTexts[text or ""] ~= nil
end

function GBL:_ClearPendingBubbleSuppressions()
    pendingBubbleTexts = {}
end

--- Test whether a bubble's stripped text matches anything in the queue.
-- Tries exact match first, then substring (bubble may wrap or be wrapped).
function GBL:_BubbleTextMatches(bubbleText)
    bubbleText = self:_StripChatFormatting(bubbleText or "")
    if bubbleText == "" then return false end
    if pendingBubbleTexts[bubbleText] then return true end
    for queued, _ in pairs(pendingBubbleTexts) do
        if queued ~= "" and (bubbleText:find(queued, 1, true)
                or queued:find(bubbleText, 1, true)) then
            return true
        end
    end
    return false
end

local function expirePending()
    if not GetTime then return end
    local now = GetTime()
    for text, expire in pairs(pendingBubbleTexts) do
        if now > expire then
            pendingBubbleTexts[text] = nil
        end
    end
end

------------------------------------------------------------------------
-- Bubble walking and hiding.
------------------------------------------------------------------------

local function collectFontStringTexts(frame, out, depth)
    if not frame or depth <= 0 then return out end
    if frame.GetRegions then
        for _, region in ipairs({ frame:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then
                local t = region.GetText and region:GetText() or nil
                if t and t ~= "" then
                    out[#out + 1] = t
                end
            end
        end
    end
    if frame.GetChildren then
        for _, child in ipairs({ frame:GetChildren() }) do
            collectFontStringTexts(child, out, depth - 1)
        end
    end
    return out
end

function GBL:_BubbleTexts(bubble)
    return collectFontStringTexts(bubble, {}, FONTSTRING_WALK_DEPTH)
end

local hiddenParent
local function getHiddenParent()
    if hiddenParent then return hiddenParent end
    if not CreateFrame then return nil end
    hiddenParent = CreateFrame("Frame")
    if hiddenParent.Hide then hiddenParent:Hide() end
    return hiddenParent
end

local function hideBubble(bubble)
    if not bubble then return end
    if bubble.SetAlpha then bubble:SetAlpha(0) end
    if bubble.Hide then bubble:Hide() end
    if bubble.GetRegions then
        for _, region in ipairs({ bubble:GetRegions() }) do
            if region.SetAlpha then region:SetAlpha(0) end
            if region.Hide then region:Hide() end
        end
    end
    local hp = getHiddenParent()
    if hp and bubble.SetParent then
        bubble:SetParent(hp)
    end
end

local function pollBubbles()
    expirePending()
    if next(pendingBubbleTexts) == nil then return end
    if not C_ChatBubbles or not C_ChatBubbles.GetAllChatBubbles then return end
    for _, bubble in ipairs(C_ChatBubbles.GetAllChatBubbles()) do
        local texts = GBL:_BubbleTexts(bubble)
        for _, text in ipairs(texts) do
            if GBL:_BubbleTextMatches(text) then
                hideBubble(bubble)
                break
            end
        end
    end
end

------------------------------------------------------------------------
-- Event handlers (registered via AceEvent for reliability).
------------------------------------------------------------------------

function GBL:_OnAmbientMonsterChat(_event, msg, sender)
    if self:_IsMutedAmbientNPC(sender) then
        self:_QueueBubbleSuppression(msg)
    end
end

------------------------------------------------------------------------
-- Diagnostic. Triggered by `/gbl bubbletest`.
------------------------------------------------------------------------

function GBL:DumpBubbleDiagnostics()
    self:Print("|cffffcc00Bubble diagnostics|r")
    if not C_ChatBubbles or not C_ChatBubbles.GetAllChatBubbles then
        self:Print("  C_ChatBubbles.GetAllChatBubbles: |cffff4040missing|r")
        return
    end
    self:Print("  C_ChatBubbles.GetAllChatBubbles: |cff40ff40present|r")
    local toggle = self.db and self.db.profile and self.db.profile.chatFilters
        and self.db.profile.chatFilters.muteAmbientNPCs
    self:Print("  Toggle: " .. (toggle and "ON" or "OFF"))
    local pendingCount = 0
    for _ in pairs(pendingBubbleTexts) do pendingCount = pendingCount + 1 end
    self:Print("  Pending suppressions: " .. pendingCount)
    for text in pairs(pendingBubbleTexts) do
        self:Print("    queued: \"" .. text .. "\"")
    end
    local bubbles = C_ChatBubbles.GetAllChatBubbles()
    self:Print("  Active bubbles: " .. #bubbles)
    for i, bubble in ipairs(bubbles) do
        local texts = self:_BubbleTexts(bubble)
        if #texts == 0 then
            self:Print("    bubble " .. i .. ": (no FontString text found)")
        else
            for j, t in ipairs(texts) do
                local match = self:_BubbleTextMatches(t) and " [MATCH]" or ""
                self:Print("    bubble " .. i .. " text " .. j .. ": \""
                    .. self:_StripChatFormatting(t) .. "\"" .. match)
            end
        end
    end
end

------------------------------------------------------------------------
-- Wiring. All side-effecting registration is guarded so the module
-- still loads cleanly under busted.
------------------------------------------------------------------------

local function chatFrameFilter(_chatFrame, _event, _msg, sender)
    return GBL:_IsMutedAmbientNPC(sender)
end

if ChatFrame_AddMessageEventFilter then
    for _, ev in ipairs(CHAT_EVENTS) do
        ChatFrame_AddMessageEventFilter(ev, chatFrameFilter)
    end
end

if GBL.RegisterEvent then
    for _, ev in ipairs(BUBBLE_EVENTS) do
        GBL:RegisterEvent(ev, "_OnAmbientMonsterChat")
    end
end

if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(BUBBLE_POLL_INTERVAL, pollBubbles)
end

-- Exposed for tests to verify the data structure is the only place names
-- are listed (i.e. no hard-coded comparisons elsewhere in this module).
GBL._mutedAmbientNPCs = MUTED_AMBIENT_NPCS
