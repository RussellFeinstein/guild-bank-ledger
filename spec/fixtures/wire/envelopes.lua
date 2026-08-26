--- Golden wire fixtures for the sync message envelopes.
--
-- Same freezing rule as records.lua: these are what a v0.36.x peer sends, and
-- they stay frozen so "an older peer's messages still decode" keeps meaning
-- something after the MIN_SYNC_VERSION floor (#74) lands.
--
-- Coverage is deliberately not all nine message types. Two tiers are here:
--
--   * What the floor release changes: HELLO (both builders, BroadcastHello and
--     SendHelloReply) and SYNC_DATA (both builders, the empty-chunk path in
--     HandleSyncRequest and the real one in SendNextChunk), which wraps the
--     records #67 and #68 change.
--   * What carries a numeric-keyed table: SYNC_REQUEST and MANIFEST send bucket
--     tables, and bucketKeyForRecord (src/Fingerprint.lua) returns math.floor(),
--     so those keys are numbers riding the hot path on every single sync.
--     LAYOUT_DATA carries numeric-keyed stockReserves and bankLayout item rows.
--
-- ACK, NACK, BUSY and LAYOUT_REQUEST are excluded: three to five scalar keys
-- each, no nesting, no numeric keys, nothing a serializer can get wrong. Pinning
-- them would enlarge the surface every future sync change has to touch without
-- guarding anything, which is how a characterization suite becomes a rubber stamp.

local TS = 1775580307
local HOUR_SLOT = 493216

-- Bucket keys are floor(hourSlot / BUCKET_HOURS). These are numbers, and that is
-- the property under test.
local BUCKET_A = 123304
local BUCKET_B = 123305

return {
    {
        name = "HELLO broadcast",
        serialized = "^1^T^Stype^SHELLO^Sguild^STest~`Guild^SdataHash^S8f3a21c4^StxCount^N12310^SlastScanTime^N1775580000^Sversion^S0.36.0^SaccessControl^T^SrankThreshold^N3^SconfiguredBy^SOfficerA-Stormrage^SrestrictedMode^B^SconfiguredAt^N1775000000^t^SlayoutUpdatedAt^N1775200000^SsortAccess^T^SupdatedBy^SGuildMaster-Stormrage^SupdatedAt^N1775100000^Swrite^T^SrankThreshold^N1^Sdelegates^T^SBob-Stormrage^B^t^t^Ssort^T^SrankThreshold^N4^Sdelegates^T^t^t^t^SprotocolVersion^N4^t^^",
        decoded = {
            type = "HELLO",
            version = "0.36.0",
            protocolVersion = 4,
            guild = "Test Guild",
            txCount = 12310,
            dataHash = "8f3a21c4",
            lastScanTime = 1775580000,
            accessControl = {
                rankThreshold = 3,
                restrictedMode = true,
                configuredBy = "OfficerA-Stormrage",
                configuredAt = 1775000000,
            },
            sortAccess = {
                write = { rankThreshold = 1, delegates = { ["Bob-Stormrage"] = true } },
                sort = { rankThreshold = 4, delegates = {} },
                updatedBy = "GuildMaster-Stormrage",
                updatedAt = 1775100000,
            },
            layoutUpdatedAt = 1775200000,
        },
    },

    -- The reply builder differs from the broadcast by exactly one key. That is
    -- what the parity test asserts, and it is why #74 adding minSyncVersion to
    -- only one of the two would be a silent guild-splitting bug: a peer that
    -- only ever sees the reply would fall back to exact-version matching.
    {
        name = "HELLO reply",
        serialized = "^1^T^Stype^SHELLO^Sguild^STest~`Guild^SdataHash^S8f3a21c4^StxCount^N12310^SisReply^B^SlastScanTime^N1775580000^Sversion^S0.36.0^SaccessControl^T^SconfiguredAt^N0^t^SlayoutUpdatedAt^N1775200000^SprotocolVersion^N4^t^^",
        decoded = {
            type = "HELLO",
            version = "0.36.0",
            protocolVersion = 4,
            guild = "Test Guild",
            txCount = 12310,
            dataHash = "8f3a21c4",
            lastScanTime = 1775580000,
            isReply = true,
            accessControl = { configuredAt = 0 },
            layoutUpdatedAt = 1775200000,
        },
    },

    -- The floor release's own HELLO, recorded beside the v0.36.0 pair rather
    -- than replacing them. Both shapes are now live on the wire at once, which
    -- is the whole point of the floor, so both belong here. The added key is
    -- minSyncVersion; everything else is unchanged, which is what makes adding
    -- a field free.
    {
        name = "HELLO broadcast, v0.37.0 floor-aware",
        serialized = "^1^T^Stype^SHELLO^Sguild^STest~`Guild^SdataHash^S8f3a21c4^StxCount^N12310^SlastScanTime^N1775580000^Sversion^S0.37.0^SaccessControl^T^SconfiguredAt^N0^t^SminSyncVersion^S0.37.0^SlayoutUpdatedAt^N1775200000^SprotocolVersion^N4^t^^",
        decoded = {
            type = "HELLO",
            version = "0.37.0",
            minSyncVersion = "0.37.0",
            protocolVersion = 4,
            guild = "Test Guild",
            txCount = 12310,
            dataHash = "8f3a21c4",
            lastScanTime = 1775580000,
            accessControl = { configuredAt = 0 },
            layoutUpdatedAt = 1775200000,
        },
    },

    -- SYNC_REQUEST gained both fields, because HandleSyncRequest is a door the
    -- HELLO gate never sees: RequestSync whispers a peer directly.
    {
        name = "SYNC_REQUEST, v0.37.0 floor-aware",
        serialized = "^1^T^Stype^SSYNC_REQUEST^Sversion^S0.37.0^SbucketHashes^T^N123304^N2863311530^N123305^N1431655765^t^SminSyncVersion^S0.37.0^Sguild^STest~`Guild^SsinceTimestamp^N1775000000^SprotocolVersion^N4^t^^",
        decoded = {
            type = "SYNC_REQUEST",
            sinceTimestamp = 1775000000,
            bucketHashes = { [BUCKET_A] = 2863311530, [BUCKET_B] = 1431655765 },
            version = "0.37.0",
            minSyncVersion = "0.37.0",
            protocolVersion = 4,
            guild = "Test Guild",
        },
        numericKeyPaths = { { "bucketHashes" } },
    },

    -- bucketHashes keys are numbers. If they arrived as strings every lookup on
    -- the receiving side would miss, every bucket would look different, and every
    -- sync would resend everything while reporting a high duplicate rate.
    {
        name = "SYNC_REQUEST with numeric bucket hashes",
        serialized = "^1^T^Stype^SSYNC_REQUEST^SprotocolVersion^N4^SbucketHashes^T^N123304^N2863311530^N123305^N1431655765^t^SsinceTimestamp^N1775000000^Sguild^STest~`Guild^t^^",
        decoded = {
            type = "SYNC_REQUEST",
            sinceTimestamp = 1775000000,
            bucketHashes = { [BUCKET_A] = 2863311530, [BUCKET_B] = 1431655765 },
            protocolVersion = 4,
            guild = "Test Guild",
        },
        numericKeyPaths = { { "bucketHashes" } },
    },

    -- The hierarchical manifest (#108). Recorded beside the two cases above
    -- rather than replacing them, for the same reason the v0.37.0 HELLO was:
    -- both shapes are live on the wire at once. A peer that predates this sends
    -- exactly those, and the serving side still reads them, because no floor
    -- raise accompanies this change.
    --
    -- bucketHashes keeps its name and its numeric keys and now carries only the
    -- recent detail window. `spans` covers everything older, tiling the range
    -- below the detail window so a bucket the requester has never held still
    -- falls inside a declared span. Its keys are array indices, and they have to
    -- stay numeric or ipairs would walk nothing and every span would be skipped.
    {
        name = "SYNC_REQUEST with a hierarchical manifest",
        serialized = "^1^T^Sguild^STest~`Guild^Stype^SSYNC_REQUEST^Sversion^S0.37.0^SbucketHashes^T^N123304^N2863311530^N123305^N1431655765^t^Sspans^T^N1^T^Se^N123150^Sh^N3735928559^Ss^N123000^t^N2^T^Se^N123303^Sh^N2596069104^Ss^N123151^t^t^SprotocolVersion^N4^SsinceTimestamp^N1775000000^SminSyncVersion^S0.37.0^t^^",
        decoded = {
            type = "SYNC_REQUEST",
            sinceTimestamp = 1775000000,
            bucketHashes = { [BUCKET_A] = 2863311530, [BUCKET_B] = 1431655765 },
            spans = {
                { s = 123000, e = 123150, h = 3735928559 },
                { s = 123151, e = 123303, h = 2596069104 },
            },
            version = "0.37.0",
            minSyncVersion = "0.37.0",
            protocolVersion = 4,
            guild = "Test Guild",
        },
        numericKeyPaths = { { "bucketHashes" }, { "spans" } },
    },

    {
        name = "MANIFEST with numeric buckets",
        serialized = "^1^T^Stype^SMANIFEST^SprotocolVersion^N4^SdataHash^S8f3a21c4^Sbuckets^T^N123304^N2863311530^N123305^N1431655765^t^StxCount^N12310^Sguild^STest~`Guild^t^^",
        decoded = {
            type = "MANIFEST",
            protocolVersion = 4,
            guild = "Test Guild",
            dataHash = "8f3a21c4",
            txCount = 12310,
            buckets = { [BUCKET_A] = 2863311530, [BUCKET_B] = 1431655765 },
        },
        numericKeyPaths = { { "buckets" } },
    },

    -- The empty-chunk builder inside HandleSyncRequest. Sent so a receiver with
    -- nothing to collect still finishes cleanly.
    {
        name = "SYNC_DATA empty chunk",
        serialized = "^1^T^Sguild^STest~`Guild^Stype^SSYNC_DATA^SprotocolVersion^N4^StotalChunks^N1^Schunk^N1^Stransactions^T^t^SeventCounts^T^t^SmoneyTransactions^T^t^t^^",
        decoded = {
            type = "SYNC_DATA",
            chunk = 1,
            totalChunks = 1,
            transactions = {},
            moneyTransactions = {},
            eventCounts = {},
            protocolVersion = 4,
            guild = "Test Guild",
        },
    },

    -- The real builder in SendNextChunk, carrying stripped records of both kinds.
    -- eventCounts keys are prefix + hourSlot with no occurrence suffix, per
    -- DATA-MODEL.md section 5.
    {
        name = "SYNC_DATA with records",
        serialized = "^1^T^Sguild^STest~`Guild^Stype^SSYNC_DATA^SprotocolVersion^N4^StotalChunks^N5^Schunk^N2^Stransactions^T^N1^T^Scount^N20^Stype^Sdeposit^SitemID^N191318^Stimestamp^N1775580307^Sid^Sdeposit|Alice-Stormrage|191318|20|0|493216:0^SsubclassID^N3^SclassID^N0^Splayer^SAlice-Stormrage^t^t^SeventCounts^T^Sdeposit|Alice-Stormrage|191318|20|0|493216^T^Scount^N1^SasOf^N1775580307^t^t^SmoneyTransactions^T^N1^T^Stype^Swithdraw^Samount^N10000000^Sid^Swithdraw|Speaknglide-Area52|10000000|493216:0^Stimestamp^N1775580307^Splayer^SSpeaknglide-Area52^t^t^t^^",
        decoded = {
            type = "SYNC_DATA",
            chunk = 2,
            totalChunks = 5,
            transactions = {
                {
                    type = "deposit",
                    player = "Alice-Stormrage",
                    itemID = 191318,
                    count = 20,
                    classID = 0,
                    subclassID = 3,
                    timestamp = TS,
                    id = "deposit|Alice-Stormrage|191318|20|0|" .. HOUR_SLOT .. ":0",
                },
            },
            moneyTransactions = {
                {
                    type = "withdraw",
                    player = "Speaknglide-Area52",
                    amount = 10000000,
                    timestamp = TS,
                    id = "withdraw|Speaknglide-Area52|10000000|" .. HOUR_SLOT .. ":0",
                },
            },
            eventCounts = {
                ["deposit|Alice-Stormrage|191318|20|0|" .. HOUR_SLOT] = { count = 1, asOf = TS },
            },
            protocolVersion = 4,
            guild = "Test Guild",
        },
    },

    -- Both nested numeric-keyed stores in one message. bankLayout.tabs is keyed
    -- by tab index and tabs[].items by itemID; BankLayout.Validate rejects a
    -- non-numeric item key outright, so a degraded key here would be a rejected
    -- layout in the field, not a silent type change.
    {
        name = "LAYOUT_DATA with numeric item and reserve keys",
        serialized = "^1^T^Stype^SLAYOUT_DATA^Sguild^STest~`Guild^Schunk^N1^SbankLayout^T^Stabs^T^N1^T^Sitems^T^N191318^T^Sslots^N2^SperSlot^N20^t^N210796^T^Sslots^N1^SperSlot^N200^t^t^Smode^Sdisplay^SslotOrder^T^N1^N191318^N2^N210796^t^t^N2^T^Smode^Soverflow^t^N3^T^Smode^Signore^t^t^SupdatedAt^N1775200000^Sversion^N3^SupdatedBy^SGuildMaster-Stormrage^t^Snchunks^N1^SstockReserves^T^N191318^N40^N210796^N500^t^t^^",
        decoded = {
            type = "LAYOUT_DATA",
            guild = "Test Guild",
            nchunks = 1,
            chunk = 1,
            bankLayout = {
                version = 3,
                updatedBy = "GuildMaster-Stormrage",
                updatedAt = 1775200000,
                tabs = {
                    [1] = {
                        mode = "display",
                        items = {
                            [191318] = { slots = 2, perSlot = 20 },
                            [210796] = { slots = 1, perSlot = 200 },
                        },
                        slotOrder = { 191318, 210796 },
                    },
                    [2] = { mode = "overflow" },
                    [3] = { mode = "ignore" },
                },
            },
            stockReserves = { [191318] = 40, [210796] = 500 },
        },
        numericKeyPaths = {
            { "stockReserves" },
            { "bankLayout", "tabs" },
            { "bankLayout", "tabs", 1, "items" },
        },
        -- Must still satisfy BankLayout.Validate after a real round trip.
        validatesAsLayout = true,
    },

    -- The #57 shape: more than one overflow tab, with the optional routing
    -- priority on one of them. Recorded beside the single-overflow case above
    -- rather than replacing it, because both shapes are live on the wire at
    -- once: a pre-#57 peer still serves single-overflow layouts, and a #57
    -- peer's layout reaches pre-#57 peers, who reject it at Validate and
    -- re-request until they update (see the gate comment in BankLayout.lua).
    -- This case proves overflowPriority survives a real AceSerializer round
    -- trip and that the round-tripped layout passes the relaxed Validate.
    {
        name = "LAYOUT_DATA with two overflow tabs, one prioritized",
        serialized = "",
        decoded = {
            type = "LAYOUT_DATA",
            guild = "Test Guild",
            nchunks = 1,
            chunk = 1,
            bankLayout = {
                version = 4,
                updatedBy = "GuildMaster-Stormrage",
                updatedAt = 1775300000,
                tabs = {
                    [1] = {
                        mode = "display",
                        items = {
                            [191318] = { slots = 2, perSlot = 20 },
                        },
                        slotOrder = { 191318 },
                    },
                    [2] = { mode = "overflow" },
                    [5] = { mode = "overflow", overflowPriority = 1 },
                },
            },
            stockReserves = { [191318] = 40 },
        },
        numericKeyPaths = {
            { "stockReserves" },
            { "bankLayout", "tabs" },
            { "bankLayout", "tabs", 1, "items" },
        },
        validatesAsLayout = true,
    },
}
