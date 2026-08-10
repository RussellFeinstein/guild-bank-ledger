--- Golden wire fixtures for the record codec.
--
-- Each case is what a v0.36.x peer puts on the wire for one record, frozen.
-- These strings are NOT regenerated when the record shape changes. That is the
-- whole point: they are what an older peer sends, so the cross-version contract
-- the MIN_SYNC_VERSION floor (#74) rests on is "this still decodes correctly",
-- forever. A change to the record shape (#67) adds new cases beside these; it
-- never edits them.
--
-- `serialized` is AceSerializer output, deliberately not the compressed and
-- encoded channel bytes. Compression is a pure function of this string and is
-- covered by its own round-trip assertion, while this form is readable in a
-- diff: a reviewer can see ^Stype^Sdeposit change. A hex blob could not be
-- reviewed at all.
--
-- `stripped` is hand-written from docs/DATA-MODEL.md section 4, never pasted
-- from program output. A characterization fixture built from what the code
-- prints can only ever agree with the code.
--
-- Field counts below are the STORED key counts from DATA-MODEL.md section 4.
-- The wire form drops the seven fields stripForSync removes, of which only the
-- ones actually present on a given record shape can be dropped.

-- 1775580307 sits in hour slot 493216 (floor(ts / 3600)). Same instant used by
-- the money-record example in DATA-MODEL.md section 4.
local TS = 1775580307
local HOUR_SLOT = 493216

return {
    -- Stored: 13 keys. Wire: 8 (loses itemLink, category, scanTime, scannedBy,
    -- _occurrence; tabName and destTabName were already nil).
    {
        name = "item deposit, locally scanned",
        accepted = true,
        serialized = "^1^T^Stype^Sdeposit^Splayer^SAlice-Stormrage^SitemID^N191318^Scount^N20^SclassID^N0^SsubclassID^N3^Stimestamp^N1775580307^Sid^Sdeposit|Alice-Stormrage|191318|20|0|493216:0^t^^",
        stripped = {
            type = "deposit",
            player = "Alice-Stormrage",
            itemID = 191318,
            count = 20,
            classID = 0,
            subclassID = 3,
            timestamp = TS,
            id = "deposit|Alice-Stormrage|191318|20|0|" .. HOUR_SLOT .. ":0",
        },
        -- classID 0 / subclassID 3 is Consumable / Flask per src/Categories.lua
        reconstructed = { _occurrence = 0, category = "flask", timestamp = TS },
    },

    -- The same deposit as recorded from v0.37.0 on, kept beside the case above
    -- rather than replacing it. Both are real: the one above is what every peer
    -- sent until the floor release and what is already on disk everywhere, and
    -- this one is what new scans produce.
    --
    -- The difference is one key, and it moves the id, because buildPrefix reads
    -- record.tab (src/Dedup.lua). That is what makes #67 a compatibility break
    -- rather than an additive field, and why it had to ride the floor release:
    -- after this, an id-format change costs a floor raise forever.
    {
        name = "item deposit, v0.37.0 with its tab recorded",
        accepted = true,
        serialized = "^1^T^Stype^Sdeposit^Splayer^SAlice-Stormrage^SitemID^N191318^Scount^N20^Stab^N3^SclassID^N0^SsubclassID^N3^Stimestamp^N1775580307^Sid^Sdeposit|Alice-Stormrage|191318|20|3|493216:0^t^^",
        stripped = {
            type = "deposit",
            player = "Alice-Stormrage",
            itemID = 191318,
            count = 20,
            tab = 3,
            classID = 0,
            subclassID = 3,
            timestamp = TS,
            id = "deposit|Alice-Stormrage|191318|20|3|" .. HOUR_SLOT .. ":0",
        },
        reconstructed = { _occurrence = 0, category = "flask", timestamp = TS },
    },

    -- Stored: 17 keys, the only shape carrying tab fields. Wire: 10.
    -- Occurrence 1 rather than 0 so a non-zero suffix is exercised.
    {
        name = "item move, locally scanned",
        accepted = true,
        serialized = "^1^T^Stype^Smove^Splayer^SBob-Stormrage^SitemID^N210796^Scount^N5^Stab^N2^SdestTab^N5^SclassID^N7^SsubclassID^N9^Stimestamp^N1775580307^Sid^Smove|Bob-Stormrage|210796|5|2|493216:1^t^^",
        stripped = {
            type = "move",
            player = "Bob-Stormrage",
            itemID = 210796,
            count = 5,
            tab = 2,
            destTab = 5,
            classID = 7,
            subclassID = 9,
            timestamp = TS,
            id = "move|Bob-Stormrage|210796|5|2|" .. HOUR_SLOT .. ":1",
        },
        -- classID 7 / subclassID 9 is Tradeskill / Herb
        reconstructed = { _occurrence = 1, category = "herb", timestamp = TS },
    },

    -- Stored: 8 keys. Wire: 5. Verbatim from the DATA-MODEL.md section 4 example.
    {
        name = "money withdraw",
        accepted = true,
        serialized = "^1^T^Stype^Swithdraw^Splayer^SSpeaknglide-Area52^Samount^N10000000^Stimestamp^N1775580307^Sid^Swithdraw|Speaknglide-Area52|10000000|493216:0^t^^",
        stripped = {
            type = "withdraw",
            player = "Speaknglide-Area52",
            amount = 10000000,
            timestamp = TS,
            id = "withdraw|Speaknglide-Area52|10000000|" .. HOUR_SLOT .. ":0",
        },
        -- Money records never get category back: reconstruct needs itemID AND classID.
        reconstructed = { _occurrence = 0, category = nil, timestamp = TS },
    },

    -- The 108-record population (#69). No itemID, so buildPrefix falls through
    -- to the money branch and the prefix reads type|player|0|.
    --
    -- The frozen string is unchanged; the verdict on it flipped in v0.37.0.
    -- Until then this decoded and was stored, which is the bug: it collides
    -- with every other itemID-less record from the same player, type and hour,
    -- and via NormalizeRecordId it could overwrite a real money record's
    -- identity (DATA-MODEL.md section 5). #68's shape check refuses it at
    -- intake instead. This expectation change IS the reviewable record of that,
    -- which is why the case stays here rather than being deleted.
    {
        name = "item record with no itemID",
        accepted = false,
        serialized = "^1^T^Stype^Sdeposit^Splayer^SCarol-Stormrage^Scount^N4^SclassID^N0^SsubclassID^N3^Stimestamp^N1775580307^Sid^Sdeposit|Carol-Stormrage|0|493216:0^t^^",
        stripped = {
            type = "deposit",
            player = "Carol-Stormrage",
            count = 4,
            classID = 0,
            subclassID = 3,
            timestamp = TS,
            id = "deposit|Carol-Stormrage|0|" .. HOUR_SLOT .. ":0",
        },
        -- No itemID means category is NOT restored, even though classID is present.
        reconstructed = { _occurrence = 0, category = nil, timestamp = TS },
    },

    -- The corruption shape DATA-MODEL.md section 8 describes: adjacent field
    -- boundaries merged, here type+player into one key. Must be rejected.
    {
        name = "mangled key, type and player merged",
        accepted = false,
        serialized = "^1^T^Styper^SdepositAlice-Stormrage^SitemID^N191318^Scount^N20^Stimestamp^N1775580307^Sid^Sdeposit|Alice-Stormrage|191318|20|0|493216:0^t^^",
        stripped = {
            typer = "depositAlice-Stormrage",
            itemID = 191318,
            count = 20,
            timestamp = TS,
            id = "deposit|Alice-Stormrage|191318|20|0|" .. HOUR_SLOT .. ":0",
        },
    },

    -- The two rejection checks, isolated. The merged-key case above is missing
    -- both fields, so it cannot tell which check fired; these can, which is what
    -- makes the mutation gate on each check meaningful.
    {
        name = "missing player only",
        accepted = false,
        serialized = "^1^T^Stype^Sdeposit^SitemID^N191318^Scount^N2^Stimestamp^N1775580307^Sid^Sdeposit|Grace-Stormrage|191318|2|0|493216:0^t^^",
        stripped = {
            type = "deposit",
            itemID = 191318,
            count = 2,
            timestamp = TS,
            id = "deposit|Grace-Stormrage|191318|2|0|" .. HOUR_SLOT .. ":0",
        },
    },
    {
        name = "missing type only",
        accepted = false,
        serialized = "^1^T^Splayer^SHeidi-Stormrage^SitemID^N191318^Scount^N2^Stimestamp^N1775580307^Sid^Sdeposit|Heidi-Stormrage|191318|2|0|493216:0^t^^",
        stripped = {
            player = "Heidi-Stormrage",
            itemID = 191318,
            count = 2,
            timestamp = TS,
            id = "deposit|Heidi-Stormrage|191318|2|0|" .. HOUR_SLOT .. ":0",
        },
    },
    {
        name = "empty type string",
        accepted = false,
        serialized = "^1^T^Stype^S^Splayer^SIvan-Stormrage^SitemID^N191318^Scount^N2^Stimestamp^N1775580307^Sid^Sdeposit|Ivan-Stormrage|191318|2|0|493216:0^t^^",
        stripped = {
            type = "",
            player = "Ivan-Stormrage",
            itemID = 191318,
            count = 2,
            timestamp = TS,
            id = "deposit|Ivan-Stormrage|191318|2|0|" .. HOUR_SLOT .. ":0",
        },
    },

    -- No timestamp on the wire. reconstructSyncRecord recovers one from the id's
    -- trailing numeric group as hourSlot * 3600, so it lands on the hour boundary
    -- rather than the original instant. The id doubles as a backup clock.
    {
        name = "no timestamp, recovered from the id",
        accepted = true,
        serialized = "^1^T^Stype^Sdeposit^Splayer^SDave-Stormrage^SitemID^N191318^Scount^N3^SclassID^N0^SsubclassID^N3^Sid^Sdeposit|Dave-Stormrage|191318|3|0|493216:0^t^^",
        stripped = {
            type = "deposit",
            player = "Dave-Stormrage",
            itemID = 191318,
            count = 3,
            classID = 0,
            subclassID = 3,
            id = "deposit|Dave-Stormrage|191318|3|0|" .. HOUR_SLOT .. ":0",
        },
        reconstructed = { _occurrence = 0, category = "flask", timestamp = HOUR_SLOT * 3600 },
    },

    -- Hour slot 0 recovers as timestamp 0, which IsValidTimestamp rejects, so the
    -- guard at src/Sync.lua falls back to now. This is the epoch-0 leak shape.
    {
        name = "epoch-zero id falls back to now",
        accepted = true,
        expectNowTimestamp = true,
        serialized = "^1^T^Stype^Sdeposit^Splayer^SEve-Stormrage^SitemID^N191318^Scount^N1^SclassID^N0^SsubclassID^N3^Sid^Sdeposit|Eve-Stormrage|191318|1|0|0:0^t^^",
        stripped = {
            type = "deposit",
            player = "Eve-Stormrage",
            itemID = 191318,
            count = 1,
            classID = 0,
            subclassID = 3,
            id = "deposit|Eve-Stormrage|191318|1|0|0:0",
        },
        reconstructed = { _occurrence = 0, category = "flask" },
    },

    -- The contract the whole break taxonomy rests on: stripForSync copies with
    -- pairs() and reconstructSyncRecord reads only named fields, so a field a
    -- future version adds survives a round trip through an older client
    -- untouched. An unknown-key whitelist at intake would destroy this, which is
    -- why #68 must validate enums, types and shape only.
    {
        name = "unknown future field passes through untouched",
        accepted = true,
        serialized = "^1^T^Stype^Sdeposit^Splayer^SFrank-Stormrage^SitemID^N191318^Scount^N7^SclassID^N0^SsubclassID^N3^Stimestamp^N1775580307^SsourceTab^N4^SfutureFlag^Bt^Sid^Sdeposit|Frank-Stormrage|191318|7|0|493216:0^t^^",
        stripped = {
            type = "deposit",
            player = "Frank-Stormrage",
            itemID = 191318,
            count = 7,
            classID = 0,
            subclassID = 3,
            timestamp = TS,
            sourceTab = 4,
            futureFlag = true,
            id = "deposit|Frank-Stormrage|191318|7|0|" .. HOUR_SLOT .. ":0",
        },
        reconstructed = {
            _occurrence = 0,
            category = "flask",
            timestamp = TS,
            sourceTab = 4,
            futureFlag = true,
        },
    },
}
