# Sync Bucket Granularity Analysis

**Date:** 2026-04-19
**Version:** 0.26.0
**Status:** Analysis complete — no changes recommended

## Summary

GuildBankLedger uses 6-hour fingerprint buckets to partition transaction history for delta sync. When peers sync, they exchange per-bucket XOR hashes and only records from differing buckets are transmitted. This analysis evaluated whether smaller buckets (3-hour, 1-hour) would improve epidemic gossip throughput.

**Conclusion: 6-hour buckets are near-optimal for the current protocol.** Smaller buckets reduce sync payload but increase SYNC_REQUEST size proportionally, and the request overhead offsets (or exceeds) the payload savings. The real bottleneck is the protocol's requirement to send ALL bucket hashes in every SYNC_REQUEST.

## Background

### Bucket Hashing System

Each transaction record is assigned to a time-based bucket via the timeSlot embedded in its ID:

```
bucket_key = floor(timeSlot / BUCKET_HOURS)
```

All record IDs in a bucket are hashed (djb2) and XOR'd together to produce a 32-bit bucket fingerprint. XOR is order-independent, so peers with the same records produce identical bucket hashes regardless of insertion order.

**Current constants** (`Fingerprint.lua`):
- `BUCKET_SECONDS = 21600` (6 hours)
- `BUCKET_HOURS = 6`

### Sync Protocol Flow

1. **HELLO** (GUILD broadcast, every 120s): Announces `txCount` and `dataHash`
2. **MANIFEST** (GUILD broadcast, every 300s if changed): Broadcasts bucket-level hashes (capped at 200 most recent)
3. **SYNC_REQUEST** (WHISPER): Requester sends ALL local bucket hashes to target
4. **SYNC_DATA** (WHISPER, chunked): Responder sends records from differing buckets
5. **ACK/NACK**: Chunk-level acknowledgment with timeout and retry
6. **Post-sync HELLO**: Broadcasts updated state for epidemic propagation

### Key Protocol Constraints

| Constraint | Value | Impact |
|-----------|-------|--------|
| AceComm WHISPER reliability | ~2000 bytes | Messages over this threshold have increasing silent-drop risk |
| ChatThrottleLib rate | ~1500 bytes/sec NORMAL | Transmission latency for large messages |
| MANIFEST_MAX_BUCKETS | 200 | Truncates broadcast to most recent buckets |
| MAX_RECORDS_PER_CHUNK | 25 | Records per sync chunk |
| CHUNK_BYTE_BUDGET | 3200 bytes | Size cap per chunk |
| Data retention | 30d raw, 90d compacted | Determines total bucket count |

## Data Profile

Analyzed from live SavedVariables: 3,715 records across 92 days, guild "We Go Again" (100 active members, 60-80 concurrent during raids).

### Bucket Distribution

| Metric | 6-hour | 3-hour | 1-hour |
|--------|--------|--------|--------|
| Populated buckets | 60 | 91 | 194 |
| Median records/bucket | 20 | 18 | 8 |
| Average records/bucket | 62 | 41 | 19 |
| Max records/bucket | 607 | 585 | 485 |

### Activity Pattern

Activity is heavily bursty:

| Active hours within 6h bucket | % of buckets |
|-------------------------------|-------------|
| 1 hour active | 25% |
| 2 hours active | 22% |
| 3 hours active | 12% |
| 4 hours active | 10% |
| 5 hours active | 10% |
| 6 hours active | 22% |

The hottest 1-hour slot (timeSlot 493295) contains 485 records — 80% of its parent 6-hour bucket's 607. Fat tail is driven by scan-heavy periods (initial backfill, post-raid scans), not uniform activity.

### Percentile Analysis: Records Sent Per Single-Record Diff

| Percentile | 6h records | 3h records | 1h records | 6h chunks | 3h chunks | 1h chunks |
|------------|-----------|-----------|-----------|-----------|-----------|-----------|
| P25 | 8 | 5 | 3 | 1 | 1 | 1 |
| **P50** | **20** | **18** | **8** | **1** | **1** | **1** |
| P75 | 55 | 35 | 16 | 3 | 2 | 1 |
| P90 | 102 | 67 | 36 | 5 | 3 | 2 |
| P95 | 312 | 142 | 70 | 13 | 6 | 3 |
| MAX | 607 | 585 | 485 | 25 | 24 | 20 |

**At P50 (the typical sync), all three granularities produce single-chunk transfers.** Improvement only exists at P75+ — the fat tail.

### Steady-State Weighted Waste (Last 7 Days)

Using density-weighted probability (busier time periods are more likely to be the sync target):

| Bucket size | Expected redundant records/sync | Expected chunks/sync |
|-------------|--------------------------------|---------------------|
| 6-hour | 172 | 6.9 |
| 3-hour | 98 | 4.0 |
| 1-hour | 46 | 1.9 |

6h → 3h: **1.75x fewer** redundant records
6h → 1h: **3.7x fewer** redundant records

## The Critical Finding: SYNC_REQUEST Overhead

### How SYNC_REQUEST Works

The requester sends ALL populated bucket hashes in a single AceComm WHISPER message. There is no cap, no truncation, and no sparse mode. The responder compares received hashes against its own and sends records from differing buckets.

### SYNC_REQUEST Size

Each bucket entry is approximately 16 bytes after serialization + LibDeflate compression + WoW addon channel encoding.

| Bucket size | Current guild | Fully active guild (30d) |
|-------------|--------------|--------------------------|
| 6-hour | 60 × 16B = **960B** | 120 × 16B = **1,920B** |
| 3-hour | 91 × 16B = **1,456B** | 240 × 16B = **3,840B** |
| 1-hour | 194 × 16B = **3,104B** | 720 × 16B = **11,520B** |

**AceComm WHISPER reliability threshold: ~2,000 bytes.** Messages above this have increasing probability of silent drop (confirmed empirically in-game: 6,431-byte messages were sent per AceComm callback but never received by the target).

| Bucket size | Current guild | Fully active guild | Reliability |
|-------------|--------------|-------------------|-------------|
| 6-hour | 960B | 1,920B | Safe |
| 3-hour | 1,456B | 3,840B | **At risk** |
| 1-hour | 3,104B | 11,520B | **Fails** |

### SYNC_REQUEST Transmission Latency

ChatThrottleLib transmits WHISPER messages at approximately 1,500 bytes/sec for NORMAL priority:

| Bucket size | Current guild | Fully active guild |
|-------------|--------------|-------------------|
| 6-hour | 0.6s | 1.3s |
| 3-hour | 1.0s | 2.6s |
| 1-hour | 2.1s | 7.7s |

This latency is paid BEFORE any sync data flows — it's dead time added to every epidemic hop.

## End-to-End Per-Hop Analysis

### Timeline Components

Each epidemic gossip hop consists of:

```
T_hop = T_request + T_sync + T_discovery
```

Where:
- **T_request**: SYNC_REQUEST transmission time (scales with bucket count)
- **T_sync**: Chunk transmission (scales inversely with bucket count — fewer redundant records)
- **T_discovery**: HELLO jitter + post-sync HELLO delay (~2.5s average, constant)

### Current Guild (Sparse Buckets)

```
                 Request    Sync       Discovery    Total
  6h buckets:    0.6s    +  2.1s    +   2.5s     = 5.2s/hop
  3h buckets:    1.0s    +  1.2s    +   2.5s     = 4.7s/hop
  1h buckets:    2.1s    +  0.6s    +   2.5s     = 5.1s/hop
```

3h saves 0.5s per hop. 1h is worse than 6h because the request latency exceeds the sync savings.

### Fully Active Guild (All Time Slots Populated)

```
                 Request    Sync       Discovery    Total
  6h (120 bkt):  1.3s    +  2.1s    +   2.5s     = 5.8s/hop
  3h (240 bkt):  2.6s    +  1.2s    +   2.5s     = 6.3s/hop
  1h (720 bkt):  7.7s    +  0.6s    +   2.5s     = 10.8s/hop
```

**For active guilds, 3h is SLOWER than 6h.** 1h is nearly double.

### Small Guild (1-5 Members)

```
                 Request    Sync       Discovery    Total
  6h (~20 bkt):  0.2s    +  0.3s    +   2.5s     = 3.0s/hop
  3h (~25 bkt):  0.3s    +  0.3s    +   2.5s     = 3.1s/hop
  1h (~30 bkt):  0.3s    +  0.3s    +   2.5s     = 3.1s/hop
```

No meaningful difference — discovery overhead dominates.

## Epidemic Propagation (70 Concurrent Peers)

With 60-80 online peers, epidemic gossip takes approximately log2(70) = ~6 rounds:

### Current Guild

```
                Total propagation    Improvement
  6h buckets:      31.3s              baseline
  3h buckets:      28.0s              3.2s faster (10%)
  1h buckets:      30.8s              0.4s faster (1%)
```

### Fully Active Guild

```
                Total propagation    Improvement
  6h buckets:      35.1s              baseline
  3h buckets:      37.6s              2.5s SLOWER
  1h buckets:      64.5s              29.4s SLOWER
```

## Catch-Up Scenarios

When a peer has been offline, differing buckets span a time range:

### 12-Hour Catch-Up

```
             Records from        Chunks    Request    Sync      Total
             differing buckets
  6h:        119 records          5 chk     0.6s    + 1.5s    = 2.1s
  3h:         52 records          3 chk     1.0s    + 0.9s    = 1.9s
  1h:         48 records          2 chk     2.1s    + 0.6s    = 2.7s
```

3h wins by 0.2s. 1h loses to request overhead. Differences are negligible for single catch-up events.

## MANIFEST Coverage

MANIFEST_MAX_BUCKETS = 200 caps how many bucket hashes are broadcast on the GUILD channel. Truncation drops the oldest buckets.

| Bucket size | Buckets in 30d | Fits in 200? | Coverage |
|-------------|---------------|-------------|----------|
| 6-hour | 120 | Yes (80 headroom) | 50 days |
| 3-hour | 240 (if saturated) | No (truncated) | 25 days |
| 1-hour | 720 (if saturated) | No (heavy truncation) | 8.3 days |

**Impact of truncation:** MANIFEST is used ONLY for peer-selection scoring in `PopPendingPeer` (`diffCount × 20` priority). It does NOT affect delta sync precision — SYNC_REQUEST always sends complete bucket hashes. So truncation degrades peer prioritization quality but not correctness.

With 70 peers and 10-peer pending queue (`MAX_PENDING_PEERS = 10`), peer-selection quality matters more — but even with truncation, the scoring still has `txCountDiff × 10` and starvation prevention as fallback signals.

## Cross-Version Rollout

Bucket granularity is computed locally per `Fingerprint.lua`. If peers run different bucket sizes:

- Bucket keys won't align (`floor(slot/6)` vs `floor(slot/3)`)
- Every bucket appears "different" to the responder
- All syncs become full syncs — **delta sync is effectively disabled**
- This lasts until all guild members update

For a guild gradually rolling out to 60-80 members, the transition period could last weeks. During that window, every sync transfers the entire dataset — a real throughput regression.

## Verdict

### Do Not Change Bucket Size

| Factor | 6h (current) | 3h | 1h |
|--------|-------------|-----|-----|
| SYNC_REQUEST reliability | Safe (960B) | At risk (3,840B saturated) | Fails (11,520B) |
| Per-hop time (sparse guild) | 5.2s | 4.7s (10% faster) | 5.1s (worse) |
| Per-hop time (active guild) | 5.8s | 6.3s (SLOWER) | 10.8s (SLOWER) |
| Typical sync (P50) | 1 chunk | 1 chunk | 1 chunk |
| Cross-version penalty | None | Full sync for weeks | Full sync for weeks |
| Works for all guild sizes | Yes | Degrades at scale | Fails at scale |

### The Real Bottleneck

The protocol requires sending ALL bucket hashes in every SYNC_REQUEST. This couples bucket count to request size, creating a ceiling on how much smaller buckets can help. The right optimization target is the protocol, not the bucket size.

### Future: Sparse SYNC_REQUEST

The highest-impact optimization would decouple bucket count from request size:

1. Requester has cached MANIFEST from the peer (already broadcast every 5 minutes)
2. Requester pre-computes diff: `local buckets` vs `cached peer MANIFEST`
3. SYNC_REQUEST includes only `requestedBuckets = {key1, key2, ...}` (the differing ones)
4. Responder sends records from requested buckets only
5. Fallback: if no MANIFEST cached, send all bucket hashes (current behavior)

This would make SYNC_REQUEST size proportional to the DIFF (typically 1-5 buckets = 16-80 bytes), not the total dataset. With this change, even 1-hour buckets would be viable:

```
Sparse request + 1h buckets:
  Epidemic: 1 bucket hash = 16B = negligible overhead
  12h catch-up: 12 bucket hashes = 192B = negligible
  Sync data: 48 records = 2 chunks = 0.6s
  Total: 0.6s + 2.5s discovery = 3.1s per hop
```

This requires a protocol version bump and a new SYNC_REQUEST field, but is backwards-compatible (old peers ignore the new field and use `bucketHashes`).

## Appendix: Raw Data Distribution

### 6-Hour Bucket Distribution (All Data)

```
Records/bucket    Bucket count
1-5               11
6-10               7
11-25             16
26-50             10
51-100             8
101-200            4
200+               4
```

### 1-Hour Bucket Distribution (All Data)

```
Records/bucket    Bucket count
1-5               75
6-10              40
11-25             48
26-50             16
51-100             8
101-200            5
200+               2
```

### Activity Concentration Within 6-Hour Buckets

```
Active hours (out of 6)    Bucket count    Percentage
1 hour                     15              25%
2 hours                    13              22%
3 hours                     7              12%
4 hours                     6              10%
5 hours                     6              10%
6 hours                    13              22%
```

### Top 10 Hottest Buckets

**6-hour:**
```
Bucket   Records   Chunks   Active hours
82215    607       25       6
82204    581       24       6
82232    394       16       6
82216    312       13       6
82236    181        8       6
82228    141        6       6
82244    102        5       6
82219    101        5       5
82176     99        4       6
82203     94        4       5
```

**1-hour (showing the fattest slot within the hottest 6h bucket):**
```
TimeSlot    Records    Parent 6h bucket
493295      485        82215 (607 total)
493294       92        82215
493293        8        82215
493292        8        82215
493291       12        82215
493290        2        82215
```

485 of the 6h bucket's 607 records (80%) are concentrated in a single hour. Reducing bucket size from 6h to 1h would only save 122 records (20%) from this worst-case bucket.

### Last 24 Hours (Steady-State Activity)

173 records across 18 populated hourly slots:

```
6h bucket    Records    Chunks
82242         9          1
82243        45          2
82244       102          5
82245        12          1
82246         5          1
```

Typical hourly range: 1-51 records (median ~8).
