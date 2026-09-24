# Test-only vendored libraries

`Libs/` is gitignored: the packager fetches those from upstream at build time via
`.pkgmeta` `externals`, so they exist on a developer machine that has run the
packager and nowhere else. CI checks out a tree with no `Libs/` at all.

`spec/wire_contract_spec.lua` needs a real serializer and `spec/savedvariables_spec.lua`
needs a real AceDB, so the files they depend on are committed here instead. Nothing
else in the suite uses them, and `.pkgmeta` strips `spec` from the packaged addon, so
these are never shipped.

| File | Upstream | Revision | Library version | License |
|---|---|---|---|---|
| `LibStub.lua` | https://repos.wowace.com/wow/libstub/trunk | r103, 2014-10-16 | LibStub minor 2 | Public domain |
| `AceSerializer-3.0.lua` | https://repos.wowace.com/wow/ace3/trunk/AceSerializer-3.0 | r1284, 2022-09-25 | AceSerializer-3.0 minor 5 | Ace3 (permissive) |
| `AceDB-3.0.lua` | https://repos.wowace.com/wow/ace3/trunk/AceDB-3.0 | r1414, 2026-09-18 | AceDB-3.0 minor 33 | Ace3 (permissive) |

All three are verbatim copies. Do not edit them. If a test needs different behavior,
the test is wrong.

Two of the three have not moved in a long time, which is what makes pinning a copy
cheap: AceSerializer's wire format has been at minor 5 since 2022 and LibStub since
2014. AceDB is the exception and the reason the drift check below is worth having:
its vendored revision is dated 2026-09-18, so it is a library under active
maintenance and this copy can fall behind within a release or two.

**Why AceDB is here and LibDeflate is not**, since the paragraph below turns the other
way on a library of similar size. The test that matters is not how large the library is,
it is whether this addon configures it. GuildBankLedger hands AceDB a defaults block and
every claim in `docs/DATA-MODEL.md` section 2 is about what AceDB does with that block,
so a test of AceDB here is a test of our defaults. LibDeflate is handed nothing and
configured in no way.

Neither AceSerializer nor AceDB has its revision readable from the file itself. Their headers
carry an unexpanded `-- @release $Id$`, because the checkout these copies came
from did not have SVN keyword substitution on. Both figures come from the
packaged zips, where the release workflow's own fetch **did** expand them: v0.36.1 for
`$Id: AceSerializer-3.0.lua 1284 2022-09-25 09:15:30Z nevcairiel $` and v0.41.6 for
`$Id: AceDB-3.0.lua 1414 2026-09-18 01:23:16Z funkehdude $`. Those are the same files,
so if a refresh needs to know what it is replacing, download a release
zip and read the header there.

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

That check normalizes `$Id$` expansion and line endings before comparing. Both
vary with how a checkout was made rather than with what the library does, so
comparing them raw would cry drift on any machine whose `Libs/` came from the
packager, which is exactly the alarm this check needs to be trusted not to
raise falsely.
