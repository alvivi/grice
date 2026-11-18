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

CI runs these gates. Run them locally before pushing; green here means green
on CI:

```sh
gleam format --check src/ test/       # formatting
gleam build --warnings-as-errors      # no warnings allowed
gleam test                            # full suite
gleam run -m birdie stale check       # no snapshot left unused, after the tests
gleam run -m grice/bench              # performance budgets, after the tests
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
- Text grice prints is checked with [birdie](https://hexdocs.pm/birdie)
  snapshots in [`test/birdie_snapshots/`](test/birdie_snapshots/). A new
  or changed snapshot fails its test; review it with `gleam run -m birdie`,
  which shows each one and accepts or rejects it. Read every snapshot
  before accepting it, and accept only text you'd show a user. Titles must
  be unique.
- The end-to-end tests run the `gleam` on your `PATH` on a fixture project
  in `build/fixtures/cli/`. The fixture keeps its build between runs, so
  only its first run resolves its dependencies, which needs the network.

## Corpus and benchmark

[`corpus/`](corpus/) is a Gleam project with no modules whose dependencies
are the corpus: Hex packages grice is checked over. Its
[`gleam.toml`](corpus/gleam.toml) pins each package with `==`, and the
committed [`manifest.toml`](corpus/manifest.toml) pins their own
dependencies too, with Hex checksums, so every run sees the same code
without it being copied into the repository. `gleam deps download` in
`corpus/` fetches the packages into `corpus/build/packages/`, which git
ignores. The first `gleam test` does that itself, so it needs the network;
after that, gleam's cache serves the packages.

The corpus gate, [`test/grice/corpus_test.gleam`](test/grice/corpus_test.gleam),
runs the built-in rules over each of the Gleam core team's packages in the
corpus, with a typed probe that reports nothing, so girard types every
package even while no built-in rule needs types. Its snapshot,
`corpus: core packages`, is the gate's manifest: each package's version and
how many of its modules were parsed and typed, then every finding and
every coverage gap. A built-in rule is on by default only if it runs clean
on these packages, so review a change to the snapshot like any other: it
says what grice now reports on idiomatic Gleam.

`gleam run -m grice/bench` runs the benchmark,
[`test/grice/bench.gleam`](test/grice/bench.gleam), over every package of
the corpus. It measures four scenarios, each a rule set that never
reports: no rule, a syntax rule with every hook, a typed rule that asks
the type of every expression, and a project rule. Each scenario runs a
warm-up pass and three measured passes, and the benchmark prints the
medians of loading and linting. Every pass checks that it analysed the
whole corpus (no diagnostic, every module parsed, every module typed in
the typed scenario, and the pinned module and line totals), and fails the
run before any budget is compared if it didn't, since a pass over less
code would fit any budget.

The budgets are reductions, the runtime's count of work done, which
barely move between runs and machines; milliseconds are printed but
never checked. There's one budget for loading and one for each
scenario's linting, set to a measurement plus 10%, as constants in
`bench.gleam` with the OTP, Gleam and girard versions they were measured
on. Move them in the same change that bumps any of those versions or the
corpus, or that makes grice faster or slower on purpose. The benchmark
prints the constants its run would set, ready to paste. CI runs it on
the pinned pair only.

To bump a package, change its version in `corpus/gleam.toml` and run
`gleam deps download` in `corpus/`, which rewrites the manifest. In the
same change, review the gate's snapshot and re-measure the budgets and
the corpus totals, even when the totals didn't move: the same counts can
hide different code.

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
