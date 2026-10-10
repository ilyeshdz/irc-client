# AGENTS.md — règles de travail sur ce repo (agents + humains)

## Pull requests obligatoires

- Toute fonctionnalité ou modification majeure DOIT passer par une pull
  request vers `main`. Le push direct sur `main` est interdit dans ces cas.
- Seuls les changements triviaux (typo, micro-doc, config CI mineure)
  peuvent être poussés directement.
- Pourquoi : les notes de release (release-drafter + nightly) sont
  générées à partir des PR mergées et de leurs labels. Sans PR, le
  changement est invisible dans les changelogs.

## Workflow d'une PR

1. Créer une branche : `feat/<sujet>`, `fix/<sujet>`, `docs/<sujet>`,
   `ci/<sujet>`, `chore/<sujet>`.
2. Ouvrir la PR avec `gh pr create` (titre + body selon le format
   ci-dessous) et lui mettre ses labels dès la création.
3. CI verte exigée avant merge.
4. Merge en squash (`gh pr merge --squash`) : 1 PR = 1 commit sur `main`,
   ce qui garde l'historique et les notes nightly lisibles.

## Format de la PR

Titre : impératif, concis, en anglais. Ex. `Add weekly nightly builds`.

Body (obligatoire) :

```md
## Description
Que fait le changement et pourquoi.

## Changements
- point 1
- point 2

## Tests
Commandes exécutées + résultat (ex. `zig build test`, `zig fmt --check`).
```

## Labels (obligatoires)

- Chaque PR doit porter **au moins un label de changelog**, sinon elle
  tombe dans `Other changes` sans catégorie.
- `skip-changelog` exclut la PR des notes (réservé au trivial).
- Correspondance labels → sections (cf. `.github/release-drafter.yml`) :

| Labels | Section des notes |
|---|---|
| `feature`, `enhancement` | Features |
| `fix`, `bugfix`, `bug` | Bug Fixes |
| `chore`, `dependencies`, `ci` | Maintenance |
| (aucun) | Other changes |
| `skip-changelog` | exclue |

- Commandes `gh` :

```sh
gh pr create --title "..." --body "..." --label feature
gh pr edit <numero> --add-label fix
gh pr edit <numero> --remove-label skip-changelog
gh label list
gh label create <nom> --color <hex-sans-#> --description "..."
```

## Releases (ne pas y toucher à la main)

- `release-drafter` met à jour tout seul le brouillon de la prochaine
  release stable à chaque push sur `main`. Ne jamais le publier
  manuellement : une stable sort en poussant un tag `v*`.
- Les nightly sont automatiques (lundi 02:00 UTC + déclenchement manuel),
  tag flottant `nightly` réécrit à chaque run. Ne jamais déplacer,
  supprimer ou publier ce tag/release à la main.
