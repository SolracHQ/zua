## Description

<!-- What does this PR do, why is it needed? -->

## Release checklist

- [ ] Version bumped in `build.zig.zon`
- [ ] `CHANGELOG.md` updated with breaking, added, changed, removed, fixed categories
- [ ] Handbook updated (`handbook/src/`) if the public API changed
- [ ] New features include an example (`example/*.zig`)
- [ ] New example registered in `build.zig` (`setupExamples`) and `Justfile` (`list-examples`)
- [ ] `just all` passes (tests + examples build cleanly)
- [ ] Stub output reviewed (`just run docs`) when adding or changing ZUA_META types
