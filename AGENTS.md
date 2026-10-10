# AGENTS.md — working rules for this repo (agents + humans)

## Mandatory pull requests

- Every feature or major change MUST go through a pull request to `main`.
  Direct pushes to `main` are forbidden in those cases.
- Only trivial changes (typo, micro-docs, minor CI config) may be pushed
  directly.
- Why: release notes (release-drafter + nightly) are generated from merged
  PRs and their labels. Without a PR, a change is invisible in changelogs.

## PR workflow

1. Create a branch: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`,
   `ci/<topic>`, `chore/<topic>`.
2. Open the PR with `gh pr create` (title + body in the format below) and
   set its labels right away.
3. Green CI required before merge.
4. Squash-merge (`gh pr merge --squash`): 1 PR = 1 commit on `main`,
   which keeps history and nightly notes readable.

## PR format

Title: imperative, concise, in English. E.g. `Add weekly nightly builds`.

Body (required):

```md
## Description
What the change does and why.

## Changes
- point 1
- point 2

## Tests
Commands run + outcome (e.g. `zig build test`, `zig fmt --check`).
```

## Labels (required)

- Every PR must carry **at least one changelog label**, otherwise it lands
  in uncategorized `Other changes`.
- `skip-changelog` excludes the PR from the notes (trivial changes only).
- Label → notes-section mapping (see `.github/release-drafter.yml`):

| Labels | Notes section |
|---|---|
| `feature`, `enhancement` | Features |
| `fix`, `bugfix`, `bug` | Bug Fixes |
| `chore`, `dependencies`, `ci` | Maintenance |
| (none) | Other changes |
| `skip-changelog` | excluded |

- `gh` commands:

```sh
gh pr create --title "..." --body "..." --label feature
gh pr edit <number> --add-label fix
gh pr edit <number> --remove-label skip-changelog
gh label list
gh label create <name> --color <hex-without-#> --description "..."
```

## Releases (do not touch by hand)

- `release-drafter` automatically maintains the draft for the next stable
  release on every push to `main`. Never publish it manually: a stable
  release ships by pushing a `v*` tag.
- Nightlies are automatic (Monday 02:00 UTC + manual trigger), on the
  floating `nightly` tag rewritten every run. Never move, delete, or
  publish that tag/release by hand.
