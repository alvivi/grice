# Contributing to grice

Thanks for helping out. This file is the dev loop and house conventions; for
*what the code is* (design principles, the planned architecture and key
decisions) read [AGENTS.md](AGENTS.md).

The audience here is both human contributors and coding agents, so it is
command-first: run the commands, match the conventions, and a change is
mergeable.

## Setup

Versions are pinned in [`.tool-versions`](.tool-versions). The suite also
runs on Node, which CI pins to 24; install it as you like. With `asdf` or
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
gleam build --warnings-as-errors --target javascript
gleam test --target javascript        # the suite again, on Node
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
- The suite runs on both targets, and every test runs on both unless it
  tests something only Erlang has, such as processes: then it, and
  everything only it uses, is marked `@target(erlang)`. What the tests
  need from the runtime goes through
  [`test/grice/support.gleam`](test/grice/support.gleam), with an Erlang
  and a JavaScript implementation. Compare values in assertions rather than
  `string.inspect` output, which prints labels on JavaScript only.
- Spans differ between the targets: glance counts bytes on Erlang and
  UTF-16 code units on JavaScript, and diagnostics are bytes on both.
  `support.glance_span` gives a span in glance's units, for what a rule
  gets and reports, and `support.span_of` one in bytes, for diagnostics.
- Add or update a focused test with every behaviour change.
- Text grice prints is checked with [birdie](https://hexdocs.pm/birdie)
  snapshots in [`test/birdie_snapshots/`](test/birdie_snapshots/). A new
  or changed snapshot fails its test; review it with `gleam run -m birdie`,
  which shows each one and accepts or rejects it. Read every snapshot
  before accepting it, and accept only text you'd show a user. Titles must
  be unique.
- The end-to-end tests run the `gleam` on your `PATH` on two fixture
  projects, `build/fixtures/cli/` on Erlang and
  `build/fixtures/cli-javascript/` on Node, so they need Node on either
  target, and check that both give the same output. Each fixture keeps its
  build between runs, so only its first run resolves its dependencies,
  which needs the network.

## Adding a built-in rule

A built-in rule ships in the default set only if it passes the gate in
[`docs/RULES.md`](docs/RULES.md): the compiler is silent on what it flags,
it's exact, it's cited, it's clean on the core packages, and it finds real
problems. A rule that passes all but the citation, since no Gleam source
calls the code it flags wrong, goes in an opt-in pack such as `simplify()`,
and a rule about what a package published to Hex offers its users goes in
`library()`, whose rules report only on `src/`. A rule `<name>`, with the code
`grice_rules/<name>`, comes with:

- **Its module,** `src/grice/internal/rules/<name>.gleam`, with
  `pub fn rule() -> Rule`, its code as a private constant, and its
  diagnostic text: a title, a primary label on the code, a message that
  says why it matters and names its source, and a hint that says how to
  fix it. Every built-in rule reports a warning.
- **Its function in [`src/grice/rules.gleam`](src/grice/rules.gleam),**
  with a doc comment: what it flags, a flagged and a fixed example, and a
  link to its section of `docs/RULES.md`. Add it to its set: `default()`,
  or a pack, `simplify()` or `library()`.
- **Its samples,** `test/grice/rules/samples/<name>_flagged.gleam` and
  `<name>_clean.gleam`: ordinary modules of public functions, importing
  only the standard library, with no warning. A rule about what other
  modules hold, such as an internal module's types, has those modules
  under `test/grice/internal/rules/samples/`, which
  `support.internal_sample` reads. Every build compiles them
  with `--warnings-as-errors`, on every compiler and target CI runs, which
  shows the compiler is silent on them. `_flagged` holds each form the
  rule reports, one finding per function where it can; `_clean` holds the
  near misses it must leave alone. No sample function's name may end in
  `_test`, or gleeunit runs it. A form the compiler warns on, or that
  `gleam format` rewrites, can't be a sample: it's an in-memory source in
  the tests, with a comment saying why. A warning about another part of
  the code doesn't make a form clean: the compiler's redundant capture in
  `r |> result.map(f) |> result.flatten(_)` is still a map-then-flatten
  finding.
- **Its tests,** `test/grice/rules/<name>_test.gleam`. `support.sample`
  reads a sample, and `support.on_both_targets` lints it as a project whose
  target is Erlang and as one whose target is JavaScript, checks that both
  show the same diagnostics, and returns the Erlang run. A rule whose
  findings depend on the target, such as fold-plus, lints a sample once
  per target with `support.on_target`, or a project of several modules
  with `support.project_on_target`, and checks each run. The flagged
  sample's render is a snapshot, beside a check of its codes with
  `testing.expect_codes`; the clean sample and the forms the compiler
  already reports, as the same problem, give `testing.expect_none`.
- **The corpus gate,** which runs every built-in rule and must pass: a
  finding on a core package is either a false positive to fix, or a real
  defect to add to the gate's `allowed` list with its reason (see below).
  A pack rule's finding there may also be correct, which the reason says,
  with the pack being opt-in.
- **The benchmark's `built-in` budget,** measured again, since the rule
  adds to what the built-in rules cost (see below).
- **Its section in [`docs/RULES.md`](docs/RULES.md):** its code, what it
  flags, why, with its source linked, a flagged and a fixed example, what
  it leaves alone, and how to suppress it; and a line in the table there
  and in the README.
- **A changelog entry,** under its set's.

## Corpus and benchmark

The corpus is the Hex packages grice is checked over, pinned in
[`test/corpus/`](test/corpus/): its [`gleam.toml`](test/corpus/gleam.toml)
pins each package with `==`, and the committed
[`manifest.toml`](test/corpus/manifest.toml) pins their own dependencies
too, with Hex checksums, so every run sees the same code without it being
copied into the repository. The tests copy both files into
`build/fixtures/corpus/`, a Gleam project with no modules, and run
`gleam deps download` there, so the packages land under `build/`, which
git ignores. The first `gleam test` needs the network for that; after
that, gleam's cache serves the packages. Never run `gleam` in
`test/corpus/` itself: the packages it downloaded there would be compiled
as grice's tests.

The corpus gate, [`test/grice/corpus_test.gleam`](test/grice/corpus_test.gleam),
runs every built-in rule, the default set, the simplify pack and the
library pack, over each of the Gleam core team's packages in the corpus. Their typed rules make girard
type every package, and the gate fails a package not fully typed, so a rule
set that lost its typed rules fails it too. It asserts that every package
is clean: no finding but those it allows, no coverage gap, every module
typed. A built-in rule is on by default only if it runs clean on these
packages, or each finding it keeps there is a real defect, and a pack's
rule only if each such finding is a real defect or correct. Those are the
`allowed` list in the gate, each with its package, path, line, column, code
and the reason it's allowed. Each entry allows exactly one diagnostic: a
second one at the same place is a new finding. An entry that no diagnostic
matches is stale, and fails the gate too, so the bump that picks up a fix
removes it. An entry can't allow one of grice's own diagnostics. A failure
lists each finding not allowed, each stale entry and each package not
fully typed.

`gleam run -m grice/bench` runs the benchmark,
[`test/grice/bench.gleam`](test/grice/bench.gleam), over every package of
the corpus. It measures five scenarios: four rule sets that never report,
which are no rule, a syntax rule with every hook, a typed rule that asks
the type of every expression, and a project rule; and the built-in rules,
the default set `gleam run -m grice` runs and the packs. Each scenario runs
a warm-up pass and three measured passes, and the benchmark prints the
medians of loading and linting. Every pass checks that it analysed the
whole corpus (no diagnostic but the built-in rules' findings, so none of
grice's own, every module parsed, every module typed in the typed
scenarios, and the pinned module and line totals), and fails the run before
any budget is compared if it didn't, since a pass over less code would fit
any budget.

The budgets are reductions, the runtime's count of work done, which
barely move between runs and machines; milliseconds are printed but
never checked. There's a budget for loading the lint set, one for
loading the whole project, which the scenarios whose rules see it use,
and one for each scenario's linting, each set to a measurement plus 10%,
as constants in
`bench.gleam` with the OTP, Gleam and girard versions they were measured
on. Move them in the same change that bumps any of those versions or the
corpus, or that makes grice faster or slower on purpose. The benchmark
prints the constants its run would set, ready to paste. CI runs it on
the pinned pair only.

`gleam run --target javascript -m grice/bench` runs the same scenarios
and checks on Node. JavaScript counts no reductions, so it prints
milliseconds only, checks no budget, and fails only when a pass didn't
analyse the whole corpus. CI doesn't run it.

To bump a package, change its version in `test/corpus/gleam.toml` and run
`gleam test`. The download resolves the corpus again and fails, saying
the pinned manifest no longer matches; copy
`build/fixtures/corpus/manifest.toml` over `test/corpus/manifest.toml` as
it says. In the same change, check that the gate still passes, and
re-measure the budgets and the corpus totals, even when the totals didn't
move: the same counts can hide different code.

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
- Version bumps and `Release vX.Y.Z` commits are cut by the maintainer, and
  each release is tagged `vX.Y.Z` on GitHub. grice isn't published on Hex
  until 1.0.
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
