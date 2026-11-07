# Releasing

Versions and the changelog come from the git history: nothing is written by hand except commit messages.
`scripts/release.py` does the rest. The version lives in `Resources/Info.plist`.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org): `type(scope): description`.

| Type | In changelog | Version bump |
| --- | --- | --- |
| `feat` | Added | minor |
| `fix` | Fixed | patch |
| `perf`, `refactor` | Changed | patch |
| `docs`, `test`, `ci`, `build`, `chore`, `style` | not listed | none |
| any type with `!`, or a `BREAKING CHANGE:` line | marked **BREAKING** | major (minor while the version is 0.x) |

Write the description for a user of the app, in the imperative ("add curved arrows", not "added curved arrows"):
it ends up in the changelog as is. CI checks the subjects of pull requests (`release.py lint`).

## Releasing

```sh
python3 scripts/release.py prepare --dry-run    # which version, which entries
python3 scripts/release.py prepare              # bumps Resources/Info.plist, rewrites CHANGELOG.md
git add -A && git commit -m "chore(release): 1.1.0"      # or run prepare with --commit
git tag v1.1.0 && git push origin main v1.1.0
```

- `prepare` picks the next version from the commits since the last `v*` tag; `--version X` forces one (use it
  for the very first release, `--version 1.0.0`). It refuses when no commit belongs in a release. The build
  number goes up by one.
- The tag triggers `.github/workflows/release.yml`: version and changelog checks, universal build, self-test,
  GitHub release with the zip and its SHA-256.
- The release notes are `docs/releases/<version>.md` when that file exists (use it for hand-written text), the
  changelog section of the version otherwise.

## What CI guards

`python3 scripts/release.py check` (run by `scripts/ci.sh`, so by CI and by the release workflow) fails when:

- the version in `Resources/Info.plist` is behind the last tag, or has no section in `CHANGELOG.md`;
- the section of a released version no longer matches what the history produces;
- the section of the upcoming version is stale: commits were added after `prepare` (run `prepare` again).

## Notes

- `CHANGELOG.md` is regenerated whole from the tags: never edit it by hand. Dates are ignored when comparing.
- The first release is listed as "Initial release" instead of its commits.
- Only `v<major>.<minor>.<patch>` tags count. A tag pushed without a version bump makes the release workflow fail
  at its first check; delete it (`git push origin --delete vX.Y.Z`) and tag again once the version is bumped.
