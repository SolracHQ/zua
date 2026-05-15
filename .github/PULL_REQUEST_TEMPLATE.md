## Description

<!-- What does this PR do, why is it needed? -->

## Release checklist

- [ ] Version bumped in `build.zig.zon`
- [ ] `CHANGELOG.md` updated with the right categories
- [ ] Handbook updated (`handbook/`) if the public API changed. `mdbook build` runs clean.
- [ ] Examples updated or added under `example/` for new features. Examples teach users and serve as compilation tests.
- [ ] New example registered in `build.zig` (`setupExamples`) and `Justfile` (`list-examples`) if added.
- [ ] Stub output reviewed (`just run docs`) when adding or changing ZUA_SHAPE types.
