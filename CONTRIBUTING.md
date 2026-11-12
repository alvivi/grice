# Contributing to grice

Thanks for helping out. This file is the dev loop and house conventions; for
*what the code is* (design principles, the planned architecture and key
decisions) read [AGENTS.md](AGENTS.md).

The audience here is both human contributors and coding agents, so it is
command-first: run the commands, match the conventions, and a change is
mergeable.

## Setup

Versions are pinned in [`.tool-versions`](.tool-versions). With `asdf` or
`mise`:

```sh
asdf install                         # Erlang + Gleam at the pinned versions
gleam deps download
gleam build
gleam test
git config core.hooksPath .githooks  # local commit-msg + branch-name hooks
pip install gitlint                  # optional: local commit-message linting
```

The hooks in [`.githooks/`](.githooks/) mirror the `Commit checks` CI: a
`commit-msg` hook runs gitlint (a no-op if gitlint is not installed) and a
`pre-push` hook rejects git-flow / conventional branch prefixes.
`core.hooksPath` is per-clone, so the `git config` line above is needed once
after cloning.

## Pre-flight checklist

CI runs three gates. Run them locally before pushing; green here means green
on CI:

```sh
gleam format --check src/ test/   # formatting
gleam build --warnings-as-errors  # no warnings allowed
gleam test                        # full suite
```

`gleam format src/ test/` (no `--check`) fixes formatting in place. When a
`dev/` directory is added, add it to both commands here, in AGENTS.md and in
CI.

CI also builds and tests on the oldest compiler grice supports, the `gleam`
floor in [`gleam.toml`](gleam.toml). If a change needs a newer compiler, or a
new dependency raises its own floor, move the floor in `gleam.toml` and the
`floor` job in [`.github/workflows/ci.yml`](.github/workflows/ci.yml) together,
in the same change.

## Tests

- Tests use gleeunit and live in [`test/`](test/). Public test functions are
  suffixed `_test`.
- Add or update a focused test with every behaviour change.

## Conventions

- **Gleam idioms.** Follow Gleam's
  [conventions, patterns, and anti-patterns](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/).
  The ones that come up most:
  - Return `Result` for fallible functions; never `panic` to signal an error a
    caller could handle.
  - Replace `Bool` with custom types when it makes invalid states impossible.
  - Match all meaningful variants explicitly; avoid catch-all `_` patterns when
    they would hide a newly added variant.
  - Annotate every module function's arguments and return type.

  Keep new code reading like its neighbours.
- **Comments explain the code.** Do not reference internal planning documents
  or this guide from source comments, changelog entries, or public docs.
- **Doc-comment slashes.** `////` documents a module and `///` documents its
  public members. Use `//` for implementation notes and private entities.
- **No ASCII-art rules.** Do not decorate code or docs with divider or banner
  lines built from repeated characters: no `// ====`, `// ----`, `# ----`, or
  similar rows. A plain comment naming a section is fine; the row of dashes or
  equals signs is not.
- **Semantic sections.** Group a file into sections by topic, each introduced
  by a header: a `//` line naming the section, a blank `//` line, then a short
  description of what it covers and why:

  ```gleam
  // Section name
  //
  // One or two sentences on what this section covers and why.
  ```

  A file that is a single section needs no header; its `////` module doc is
  enough. Order the entities within a section for readability: lead with the
  public API (including `pub opaque` types), then the private implementation,
  and within each put constants before types before functions. Keep a type
  next to the functions that build and operate on it, put an entry point ahead
  of the helpers it calls, and fall back to alphabetical order only to break
  ties among unrelated peers. Test modules follow the same sectioning and
  module-doc rules, but keep their sections in narrative order (by feature or
  scenario) rather than reordering by visibility or kind.
- **Public surface.** Treat `src/grice.gleam` and the modules documented as
  public in [AGENTS.md](AGENTS.md) as the stable API. Everything under
  `src/grice/internal/` is implementation detail even where Gleam visibility
  is needed between modules.
- **No circular dependencies** between modules under `src/grice/internal/`.

## Changelog & commits

- Record every notable change in [CHANGELOG.md](CHANGELOG.md). The format is
  [Keep a Changelog](https://keepachangelog.com/) and the project follows
  [SemVer](https://semver.org/). Entries lead with a concise summary of the
  observable change, then explain it.
- Version bumps and `Release vX.Y.Z` commits are cut by the maintainer.
- Branch off `main` with a short, descriptive kebab-case name
  (`suppression-directives`). This project does not use git-flow: no
  `feature/`, `fix/`, `release/`, or similar prefixes.

### Commit messages

Follow [the seven rules of a great commit message](https://chris.beams.io/posts/git-commit/#seven-rules):

1. Separate subject from body with a blank line.
2. Limit the subject line to 50 characters.
3. Capitalize the subject line.
4. Do not end the subject line with a period.
5. Use the imperative mood in the subject line ("Add …", not "Added …").
6. Wrap the body at 72 characters.
7. Use the body to explain what and why, not how.

Do **not** use [Conventional Commits](https://www.conventionalcommits.org/): no
`feat:` / `fix:` / `chore:` prefixes. Write commit messages and PR descriptions
as your own work, and do not add AI-attribution trailers (`Co-Authored-By:
Claude …`, "Generated with …", and the like).

A `Commit checks` workflow enforces the mechanical rules on every PR via
[gitlint](https://jorisroovers.github.io/gitlint/) (subject ≤ 72, capitalized,
body wrapped at 72; config in [`.gitlint`](.gitlint)) and rejects git-flow /
conventional branch prefixes. Imperative mood and the what-and-why body are on
you.
