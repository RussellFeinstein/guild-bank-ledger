<!--
Thanks for contributing to GuildBankLedger! A few quick notes:
- The Checklist is mostly for internal contributors. External contributors: see the "External contributors" note under Versioning.
- If this is a draft or work-in-progress, open it as a GitHub Draft PR.
-->

## Summary

<!-- What does this PR do, and why? One or two sentences is usually enough. -->

## Testing

<!--
How did you test this? For code changes, tests are required. List the new / updated specs and how to run them locally:
    bash run_tests.sh             # busted
    bash run_tests.sh --lint      # luacheck
For UI changes, describe the in-game smoke test and include a screenshot below.
-->

## Screenshots (UI changes only)

<!-- Before/after screenshots. Delete this section if not applicable. -->

## Related issues

<!-- e.g. "Closes #42" or "Part of #17". Delete if not applicable. -->

## Checklist

- [ ] Tests pass locally (`bash run_tests.sh`)
- [ ] Lint passes (`bash run_tests.sh --lint`)
- [ ] `CHANGELOG.md` updated under `### Added` / `### Changed` / `### Fixed` etc. (Keep a Changelog format)
- [ ] In-addon changelog (`UI/ChangelogView.lua` `CHANGELOG_DATA`) updated if user-visible
- [ ] `VERSION`, `GuildBankLedger.toc`, `Core.lua`, `CLAUDE.md` version strings bumped per semver policy in `CONTRIBUTING.md`. **External contributors: leave version strings alone, the maintainer will handle the bump on merge.**
