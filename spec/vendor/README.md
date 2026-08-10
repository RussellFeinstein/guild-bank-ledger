# Test-only vendored libraries

`Libs/` is gitignored: the packager fetches those from upstream at build time via
`.pkgmeta` `externals`, so they exist on a developer machine that has run the
packager and nowhere else. CI checks out a tree with no `Libs/` at all.

`spec/wire_contract_spec.lua` needs a real serializer, so the two files it
depends on are committed here instead. Nothing else in the suite uses them, and
`.pkgmeta` strips `spec` from the packaged addon, so these are never shipped.

| File | Upstream | License |
|---|---|---|
| `LibStub.lua` | https://repos.wowace.com/wow/libstub/trunk | Public domain |
| `AceSerializer-3.0.lua` | https://repos.wowace.com/wow/ace3/trunk/AceSerializer-3.0 | Ace3 (permissive) |

Both are verbatim copies. Do not edit them. If a test needs different behavior,
the test is wrong.

**LibDeflate is deliberately absent.** The harness serializes but does not
compress. Compression is a pure, byte-exact codec that this addon neither
configures nor extends, so a test of it would be a test of LibDeflate rather
than of GuildBankLedger, and vendoring its 3,600 lines to get there is not worth
it. `estimateRecordBytes` is documented against AceSerializer output rather than
compressed output, and the compressed size that actually matters at runtime is
measured live as `syncState.lastChunkBytes`.

## Keeping these honest

`spec/fixtures/generate_wire_fixtures.lua` checks these copies against `Libs/`
when `Libs/` is present, and reports any difference. So the test run is
deterministic everywhere, and a developer with the real libraries still finds out
if upstream has moved. Refresh by copying the files over and running the full
suite: a real behavior change shows up as frozen fixtures that no longer decode.
