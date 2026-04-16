------------------------------------------------------------------------
-- GuildBankLedger — UI/ChangelogView.lua
-- Changelog tab: embedded version history and in-game renderer.
------------------------------------------------------------------------

local ADDON_NAME = "GuildBankLedger"
local GBL = LibStub("AceAddon-3.0"):GetAddon(ADDON_NAME)

------------------------------------------------------------------------
-- Section rendering order and colors
------------------------------------------------------------------------

local SECTION_ORDER = { "Added", "Changed", "Fixed", "Removed", "Deprecated", "Security" }

local CHANGELOG_PAGE_SIZE = 10

local SECTION_COLORS = {
    Added      = "|cff55ff55",
    Changed    = "|cff55bbff",
    Fixed      = "|cffffaa55",
    Removed    = "|cffff5555",
    Deprecated = "|cff999999",
    Security   = "|cffcc66ff",
}

------------------------------------------------------------------------
-- Changelog data — newest first, concise summaries only.
-- Format: { version, date, { SectionType = { entries } }, milestone? }
------------------------------------------------------------------------

GBL.CHANGELOG_DATA = {
    -- v0.24.0
    {"0.24.0", "2026-04-15", {
        Added = {
            "\"Show minimap button\" toggle — hide the minimap icon while keeping the LDB launcher for display addons (requested by Rox)",
        },
    }},
    -- v0.23.0
    {"0.23.0", "2026-04-15", {
        Changed = {
            "Sync chunk budget doubled and record cap raised (15→25) — halves chunk count for faster syncs",
            "ACK timeout reduced from 15s to 8s with more retries (3→5) — faster recovery from message loss",
            "ACK and NACK messages now sent with ALERT priority for faster delivery",
        },
        Fixed = {
            "Stale ACKs from retried chunks no longer orphan active timers (could cause 120s stalls)",
        },
    }},
    -- v0.22.4
    {"0.22.4", "2026-04-15", {
        Added = {
            "Peers in M+ or raids stay visible via guild roster fallback",
            "Known peers persisted across sessions for instant discovery on login",
        },
    }},
    -- v0.22.3
    {"0.22.3", "2026-04-15", {
        Fixed = {
            "Sync status now shows both Sending and Receiving when active simultaneously",
            "Receive progress shows waiting instead of 0/0 while awaiting first chunk",
        },
    }},
    -- v0.22.2
    {"0.22.2", "2026-04-15", {
        Fixed = {
            "Pending peers queue no longer requests sync from peers detected as offline",
            "FinishReceiving now removes the sender from the pending queue to prevent immediate re-request",
        },
    }},
    -- v0.22.1
    {"0.22.1", "2026-04-15", {
        Fixed = {
            "Automatic duplicate cleanup now runs after bank scan refreshes eventCounts",
        },
    }},
    -- v0.22.0
    {"0.22.0", "2026-04-15", {
        Added = {
            "BUSY message: declined sync requests now respond immediately instead of 60s dead air",
            "Pending peers queue: missed sync opportunities automatically retried after current sync",
            "Post-sync HELLO broadcast to trigger reciprocal sync",
            "Bidirectional sync: checks if peer has data we need after sending",
            "Combat guard: sync deferred during combat, resumes after",
            "Sync jitter: 0-2s random delay prevents mutual request collisions",
            "Sender offline detection: aborts early if sender disconnects mid-sync",
            "NACK backoff: progressive timeouts (20s, 30s, 45s) for retries",
        },
        Changed = {
            "First-chunk timeout reduced from 20s to 10s for faster failure detection",
        },
    }},
    -- v0.21.0
    {"0.21.0", "2026-04-14", {
        Added = {
            "About tab with addon info, Ko-fi donation link, CurseForge link, and credits",
            "GitHub Sponsors integration and README support section",
        },
    }},
    -- v0.20.1
    {"0.20.1", "2026-04-14", {
        Changed = {
            "Roadmap: moved Export feature to post-1.0; Stabilization is now the next milestone",
        },
    }},
    -- v0.20.0
    {"0.20.0", "2026-04-14", {
        Changed = {
            "Documentation sync for beta preparation: README, ROADMAP, CurseForge description updated",
        },
        Fixed = {
            "Changelog tab showing blank content — nav bar moved inside scroll frame",
        },
        Removed = {
            "Obsolete planning docs (IMPLEMENTATION_PLAN.md, PLAN.md) deleted",
        },
    }},
    -- v0.19.3
    {"0.19.3", "2026-04-14", {
        Changed = {
            "Sync and Changelog tabs right-aligned in tab bar to separate from data tabs",
        },
    }},
    -- v0.19.2
    {"0.19.2", "2026-04-14", {
        Changed = {
            "Changelog tab now paginates (10 versions per page) for faster loading",
            "Previous/Next navigation with accessible disabled-state labels",
        },
    }},
    -- v0.19.1
    {"0.19.1", "2026-04-14", {
        Fixed = {
            "Sync chunk 1 no longer oversized — eventCounts spread across chunks",
        },
    }},
    -- v0.19.0
    {"0.19.0", "2026-04-14", {
        Changed = {
            "Consumption tab redesigned as guild-wide overview dashboard",
            "Three sections: Guild Totals, Top Consumers (top 10), Most Used Items (top 15)",
            "Most Used Items shows withdrawal counts with 7d/30d/all-time trend columns",
            "Top Consumers shows full gold in/out/net breakdown per player",
            "Click player name in Top Consumers to jump to Transactions tab filtered by that player",
        },
        Removed = {
            "Collapsible player rows replaced by flat ranked tables",
        },
    }},
    -- v0.18.1
    {"0.18.1", "2026-04-14", {
        Fixed = {
            "Changelog tab now displays full content instead of truncating with '...'",
        },
    }},
    -- v0.18.0
    {"0.18.0", "2026-04-14", {
        Added = {
            "Directional peer version status — shows who needs to update",
            "Version label in top-right corner with peer-based update detection",
            "CompareSemver utility and GetHighestPeerVersion getter",
        },
    }},
    -- v0.17.0
    {"0.17.0", "2026-04-14", {
        Added = {
            "Event count metadata — persists API-observed counts for accurate dedup",
            "Count-based cleanup replaces heuristic anchor logic",
            "Post-sync cleanup trims diverged-index duplicates automatically",
            "eventCounts synced between peers (max wins, backwards-compatible)",
        },
        Fixed = {"Genuine synced records no longer deleted by cleanup"},
    }},
    -- v0.16.0
    {"0.16.0", "2026-04-14", {
        Added = {"Changelog tab in addon UI — scrollable version history"},
    }},
    -- v0.15.x
    {"0.15.2", "2026-04-14", {
        Fixed = {"Sync re-introducing duplicates after cleanup"},
        Added = {"DeduplicateRecords function for startup dedup"},
    }},
    {"0.15.1", "2026-04-13", {
        Fixed = {"ItemCache error on uncached items (wrong API for numeric itemID)"},
    }},
    {"0.15.0", "2026-04-13", {
        Added = {
            "GM-configurable access control system",
            "Access control sync via HELLO protocol",
        },
        Changed = {
            "Settings visible to all full-access users",
            "Tab list rebuilds dynamically on access changes",
        },
        Fixed = {"Migration now runs full dedup cleanup"},
        Removed = {"IsOfficerRank() replaced by access control"},
    }},
    -- v0.14.x
    {"0.14.3", "2026-04-13", {
        Fixed = {
            "Duplicate records from seenTxHashes gaps after sync",
            "Duplicate records from split adjacent slots",
            "Occurrence ID collision after normalization",
        },
    }},
    {"0.14.2", "2026-04-13", {
        Fixed = {"Existing duplicate records removed on upgrade"},
        Added = {"/gbl cleanup command"},
    }},
    {"0.14.1", "2026-04-13", {
        Fixed = {"Within-slot duplicate records on rescan"},
    }},
    {"0.14.0", "2026-04-13", {
        Fixed = {"Duplicate records from occurrence index shift"},
        Changed = {"Per-slot occurrence reindexing, sync protocol v4"},
    }},
    -- v0.13.x
    {"0.13.2", "2026-04-13", {
        Fixed = {"Player name consolidation failure at login"},
    }},
    {"0.13.1", "2026-04-13", {
        Fixed = {"Outdated peers now visible in Online Peers"},
    }},
    {"0.13.0", "2026-04-13", {
        Added = {
            "Item name resolution for synced records",
            "Guild roster cache for cross-realm tracking",
        },
        Changed = {
            "Player names always stored as Name-Realm",
            "Sync restricted to exact version match",
        },
        Fixed = {
            "Sync chunk count off-by-one",
            "Consumption view player fragmentation",
        },
    }},
    -- v0.12.x
    {"0.12.2", "2026-04-12", {
        Fixed = {"Corrupted sync records from serialization"},
    }},
    {"0.12.1", "2026-04-12", {
        Added = {"Chat Log toggle on Sync tab"},
    }},
    {"0.12.0", "2026-04-12", {
        Fixed = {"Cross-client false positives for adjacent-hour events"},
        Added = {"Occurrence scheme migration (v1 to v2)"},
    }},
    -- v0.11.x
    {"0.11.3", "2026-04-12", {
        Added = {"20 regression tests for sync convergence"},
    }},
    {"0.11.2", "2026-04-12", {
        Fixed = {"Bucket hashes mismatching after ID normalization"},
    }},
    {"0.11.1", "2026-04-12", {
        Fixed = {
            "Sync looping after normalization (sender-wins)",
            "Bucket hash mismatch from timestamp divergence",
        },
    }},
    {"0.11.0", "2026-04-12", {
        Added = {
            "Sync ID normalization for convergence",
            "Compaction guard during sync receive",
        },
    }},
    -- v0.10.x
    {"0.10.2", "2026-04-12", {
        Fixed = {"Sync dedup false positives for consecutive-hour events"},
    }},
    {"0.10.1", "2026-04-12", {
        Fixed = {"Stale peers wiped while still online (added heartbeat)"},
    }},
    {"0.10.0", "2026-04-11", {
        Added = {"LibDeflate compression for sync messages"},
        Changed = {"Sync protocol version bumped to 2"},
    }},
    -- v0.9.x
    {"0.9.7", "2026-04-11", {
        Fixed = {"Stale peers in Online list (5-minute expiry)"},
    }},
    {"0.9.6", "2026-04-11", {
        Changed = {"Sync buckets use 6-hour windows instead of daily"},
    }},
    {"0.9.5", "2026-04-11", {
        Fixed = {"Audit trail flooding from chunk logging"},
    }},
    {"0.9.4", "2026-04-11", {
        Added = {"/gbl synclog command"},
    }},
    {"0.9.3", "2026-04-11", {
        Fixed = {
            "Peer discovery after reload",
            "Known-peer reply gate blocking rediscovery",
        },
        Changed = {"HELLO replies use targeted WHISPER"},
    }},
    {"0.9.2", "2026-04-11", {
        Changed = {"Verbose sync audit trail diagnostics"},
    }},
    {"0.9.1", "2026-04-11", {
        Fixed = {"Hash-mismatch sync gap between peers"},
        Changed = {"Hash comparison as primary sync trigger"},
    }},
    {"0.9.0", "2026-04-11", {
        Added = {
            "Receive-side NACK retry for sync",
            "Zone change protection during sync",
            "FPS-adaptive throttling",
        },
        Changed = {"Smaller sync chunks (15 to 5 records)"},
    }},
    -- v0.8.x
    {"0.8.0", "2026-04-11", {
        Added = {
            "Fingerprint-based sync (hash comparison)",
            "Bucket-filtered delta sync",
        },
    }},
    -- v0.7.x
    {"0.7.17", "2026-04-11", {
        Changed = {"Reverted inter-chunk delay to 100ms"},
    }},
    {"0.7.15", "2026-04-11", {
        Changed = {"Reduced chunk byte budget for reliability"},
    }},
    {"0.7.14", "2026-04-11", {
        Fixed = {"Crash syncing records with missing fields"},
    }},
    {"0.7.13", "2026-04-10", {
        Fixed = {"Cross-realm sync name format mismatch"},
    }},
    {"0.7.12", "2026-04-10", {
        Fixed = {"Sync chunks exceeding WHISPER size limit"},
    }},
    {"0.7.11", "2026-04-10", {
        Fixed = {"Sync request stalling permanently"},
    }},
    {"0.7.10", "2026-04-10", {
        Added = {"Chat output for sync events"},
    }},
    {"0.7.9", "2026-04-10", {
        Fixed = {"Crash syncing records without timestamp"},
    }},
    {"0.7.8", "2026-04-10", {
        Changed = {
            "Sync chunk size increased to 10",
            "Sync strips reconstructable fields",
        },
    }},
    {"0.7.7", "2026-04-10", {
        Fixed = {
            "Sync chunks too large for WHISPER",
            "Single dropped chunk now retries",
        },
    }},
    {"0.7.6", "2026-04-10", {
        Fixed = {
            "Sync timers never firing in WoW",
            "Manual Hello button cooldown bypass",
        },
    }},
    {"0.7.5", "2026-04-10", {
        Fixed = {"Peer discovery failure from cooldown"},
        Added = {"HELLO on guild bank open"},
    }},
    {"0.7.4", "2026-04-10", {
        Added = {
            "HELLO response for mutual peer discovery",
            "Version indicator in peer list",
        },
    }},
    {"0.7.3", "2026-04-10", {
        Fixed = {"Sync data rejected from name format mismatch"},
    }},
    {"0.7.2", "2026-04-10", {
        Fixed = {"Column text wrapping to new lines"},
    }},
    {"0.7.1", "2026-04-10", {
        Fixed = {
            "Sync ACK timeout starting too early",
            "Self-message filtering in retail WoW",
        },
        Changed = {"Chunk size reduced, ACK timeout increased"},
    }},
    {"0.7.0", "2026-04-08", {
        Added = {
            "Gold summary panel on Gold Log tab",
            "Date range filters (1h, 3h, 24h)",
            "Pagination for Transactions tab",
        },
        Fixed = {"Re-scan no longer resets filters"},
    }},
    -- v0.6.x
    {"0.6.2", "2026-04-07", {
        Fixed = {"Re-scan not detecting new transactions"},
    }},
    {"0.6.1", "2026-04-07", {
        Fixed = {"Periodic re-scan not functioning in-game"},
    }},
    {"0.6.0", "2026-04-07", {
        Added = {
            "Periodic re-scan while guild bank open",
            "Auto re-scan toggle",
        },
    }},
    -- v0.5.0
    {"0.5.0", "2026-04-07", {
        Added = {
            "Multi-officer sync via AceComm",
            "Sync tab with controls, peer list, audit trail",
            "ACK timeout and receive timeout",
            "HELLO broadcast on login and bank close",
        },
    }, "Milestone M5: Multi-Officer Sync"},
    -- v0.4.x
    {"0.4.1", "2026-04-07", {
        Fixed = {
            "Gold transactions in Transactions tab",
            "Money tab queried at correct index",
            "Type normalization (withdrawal to withdraw)",
        },
    }},
    {"0.4.0", "2026-04-07", {
        Added = {
            "Click-to-expand player rows in consumption",
            "Sortable consumption column headers",
            "Category filter on consumption tab",
        },
        Fixed = {"Guild bank open stutter (deferred scanning)"},
    }, "Milestone M4: Consumption Detail + UI Polish"},
    -- v0.3.x
    {"0.3.3", "2026-04-07", {
        Fixed = {"Sort direction indicators (UTF-8 to text)"},
    }},
    {"0.3.2", "2026-04-07", {
        Fixed = {
            "UI rows overflowed frame (added ScrollFrame)",
            "Interface version updated to 120001",
        },
    }},
    {"0.3.1", "2026-04-07", {
        Fixed = {"fetch-libs.sh repo URLs corrected"},
    }},
    {"0.3.0", "2026-04-07", {
        Added = {
            "Main UI window with tabs",
            "Transaction ledger with sortable columns",
            "Filter bar and consumption summary",
            "Minimap button",
            "Accessibility features (WCAG 2.1 AA)",
            "Keyboard navigation",
        },
    }, "Milestone M3: UI"},
    -- v0.2.x
    {"0.2.6", "2026-04-07", {
        Added = {"Keyboard navigation and focus handling"},
    }},
    {"0.2.5", "2026-04-07", {
        Added = {"Main UI window, filter widgets, minimap button"},
    }},
    {"0.2.4", "2026-04-07", {
        Added = {
            "Per-player consumption aggregation",
            "Money formatting utility",
        },
    }},
    {"0.2.3", "2026-04-07", {
        Added = {"Transaction filter logic"},
    }},
    {"0.2.2", "2026-04-06", {
        Added = {
            "Accessibility module (WCAG 2.1 AA)",
            "Colorblind-safe palettes",
            "Triple encoding for transaction types",
        },
    }},
    {"0.2.1", "2026-04-06", {
        Added = {"Library fetch script for development"},
    }},
    {"0.2.0", "2026-04-06", {
        Added = {
            "Transaction recording from guild bank logs",
            "Item categorization by classID/subclassID",
            "Hour-bucket deduplication",
            "Money transaction tracking",
            "Per-player statistics",
            "Tiered storage compaction",
        },
    }, "Milestone M2: Ledger + Dedup + Categories + Storage"},
    -- v0.1.0
    {"0.1.0", "2026-04-06", {
        Added = {
            "AceAddon bootstrap with lifecycle",
            "Guild bank open/close detection",
            "Slot-level guild bank scanning",
            "Slash commands and AceDB saved variables",
        },
    }, "Milestone M1: Scaffold + Scanner"},
}

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------

--- Format a single changelog version entry into a WoW-colored string.
-- @param entry table { version, date, sections, milestone? }
-- @return string Formatted string with WoW color codes and newlines
function GBL:FormatChangelogEntry(entry)
    local version, date, sections, milestone = entry[1], entry[2], entry[3], entry[4]
    local lines = {}

    -- Version header
    lines[#lines + 1] = string.format("|cffffcc00v%s|r  |cff999999(%s)|r", version, date)

    -- Milestone label
    if milestone then
        lines[#lines + 1] = "  |cffffcc00" .. milestone .. "|r"
    end

    -- Section entries in standard order
    for _, sType in ipairs(SECTION_ORDER) do
        local entries = sections[sType]
        if entries then
            local color = SECTION_COLORS[sType] or "|cffcccccc"
            lines[#lines + 1] = "  " .. color .. sType .. ":|r"
            for _, text in ipairs(entries) do
                lines[#lines + 1] = "    - " .. text
            end
        end
    end

    -- Trailing blank line for spacing
    lines[#lines + 1] = ""

    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Tab builder
------------------------------------------------------------------------

--- Build the Changelog tab inside a container.
-- Paginates by version entry (CHANGELOG_PAGE_SIZE per page).
-- @param container AceGUI container (the TabGroup content area)
function GBL:BuildChangelogTab(container)
    local AceGUI = LibStub("AceGUI-3.0")

    local data = self.CHANGELOG_DATA or {}
    local totalEntries = #data

    -- Pagination math
    self._changelogCurrentPage = self._changelogCurrentPage or 1
    local totalPages = math.max(1, math.ceil(totalEntries / CHANGELOG_PAGE_SIZE))
    local page = math.max(1, math.min(self._changelogCurrentPage, totalPages))
    self._changelogCurrentPage = page
    local startIdx = (page - 1) * CHANGELOG_PAGE_SIZE + 1
    local endIdx = math.min(startIdx + CHANGELOG_PAGE_SIZE - 1, totalEntries)

    -- Scrollable content (only direct child of container, so List layout
    -- gives it proper height — adding siblings before it breaks sizing)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetFullWidth(true)
    scroll:SetFullHeight(true)
    scroll:SetLayout("List")
    container:AddChild(scroll)

    -- Navigation bar inside scroll (only when multiple pages)
    if totalPages > 1 then
        local navGroup = AceGUI:Create("SimpleGroup")
        navGroup:SetFullWidth(true)
        navGroup:SetLayout("Flow")
        scroll:AddChild(navGroup)

        -- Previous button
        local prevBtn = AceGUI:Create("Button")
        prevBtn:SetWidth(100)
        if page <= 1 then
            prevBtn:SetText("- Previous -")
            prevBtn:SetDisabled(true)
        else
            prevBtn:SetText("< Previous")
            prevBtn:SetDisabled(false)
        end
        prevBtn:SetCallback("OnClick", function()
            self._changelogCurrentPage = page - 1
            container:ReleaseChildren()
            self:BuildChangelogTab(container)
        end)
        navGroup:AddChild(prevBtn)

        -- Page label
        local pageLabel = AceGUI:Create("Label")
        pageLabel:SetWidth(140)
        pageLabel:SetText(string.format("  Page %d of %d", page, totalPages))
        pageLabel:SetJustifyH("CENTER")
        local fontPath, fontSize = self:GetScaledFont()
        pageLabel:SetFont(fontPath, fontSize)
        navGroup:AddChild(pageLabel)

        -- Next button
        local nextBtn = AceGUI:Create("Button")
        nextBtn:SetWidth(100)
        if page >= totalPages then
            nextBtn:SetText("- Next -")
            nextBtn:SetDisabled(true)
        else
            nextBtn:SetText("Next >")
            nextBtn:SetDisabled(false)
        end
        nextBtn:SetCallback("OnClick", function()
            self._changelogCurrentPage = page + 1
            container:ReleaseChildren()
            self:BuildChangelogTab(container)
        end)
        navGroup:AddChild(nextBtn)

        -- Register buttons for keyboard navigation
        self:ClearFocusOrder()
        self:RegisterFocusable(prevBtn, 1)
        self:RegisterFocusable(nextBtn, 2)
    end

    -- Render version entries for current page
    -- (AceGUI Labels are single-line; multi-line \n text gets truncated)
    for i = startIdx, endIdx do
        local entry = data[i]
        local version, date, sections, milestone = entry[1], entry[2], entry[3], entry[4]

        -- Version header (larger font)
        local header = AceGUI:Create("Label")
        header:SetFullWidth(true)
        header:SetFontObject(GameFontNormalLarge)
        header:SetText(string.format("|cffffcc00v%s|r  |cff999999(%s)|r", version, date))
        scroll:AddChild(header)

        -- Milestone label
        if milestone then
            local ml = AceGUI:Create("Label")
            ml:SetFullWidth(true)
            ml:SetText("  |cffffcc00" .. milestone .. "|r")
            scroll:AddChild(ml)
        end

        -- Section entries in standard order
        for _, sType in ipairs(SECTION_ORDER) do
            local entries = sections[sType]
            if entries then
                local color = SECTION_COLORS[sType] or "|cffcccccc"
                local sl = AceGUI:Create("Label")
                sl:SetFullWidth(true)
                sl:SetText("  " .. color .. sType .. ":|r")
                scroll:AddChild(sl)

                for _, text in ipairs(entries) do
                    local el = AceGUI:Create("Label")
                    el:SetFullWidth(true)
                    el:SetText("    - " .. text)
                    scroll:AddChild(el)
                end
            end
        end

        -- Spacer between entries
        local spacer = AceGUI:Create("Label")
        spacer:SetFullWidth(true)
        spacer:SetText(" ")
        scroll:AddChild(spacer)
    end
end
