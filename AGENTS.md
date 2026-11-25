# AGENTS.md

This file provides guidance to coding agents when working with code in this
repository.

## Project Overview

**grice** is a type-aware linter for Gleam, written in Gleam. It is the
infrastructure for linting a Gleam project: a runner, a rule API, a type layer,
suppression comments and a diagnostics renderer. Rules are ordinary Gleam
values. grice ships a default rule set, offered by `grice/rules`, and clients
write their own rules with the same API the built-ins use.

What sets it apart from a syntactic linter is that rules can ask
[girard](https://github.com/alvivi/girard) for the inferred type of any
expression and for which definition any name or field access resolved to, and
that its diagnostics follow the Gleam compiler's layout.

**Status:** 0.1.0, the first release. grice won't be on Hex until 1.0, so
each 0.x release is a tag on GitHub only. Everything the table below marks
**Exists** has landed, with the corpus gate over the core packages, the
benchmark and the JavaScript target. The default rule set has four
built-in rules, under the `grice_rules/` prefix. The type predicates
(`grice/types`) and the diagnostic builders are still to come.

## Build and Test

```sh
gleam format --check src/ test/   # check formatting
gleam build --warnings-as-errors  # compile; no warnings allowed
gleam test                        # run the test suite
gleam build --warnings-as-errors --target javascript
gleam test --target javascript    # the suite again, on Node
gleam run -m birdie stale check   # no unused snapshots, after the tests
gleam run -m grice/bench          # performance budgets over the corpus
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local dev loop and the code,
changelog and commit conventions.

Tests use **gleeunit** and live in `test/`, with **birdie** snapshots of
the text grice prints in `test/birdie_snapshots/`. The suite runs on both
targets; the few tests of what only Erlang has carry `@target(erlang)`.
Each built-in rule is tested on its samples, ordinary modules in
`test/grice/rules/samples/` that every build compiles with
`--warnings-as-errors`, which shows the compiler is silent on the code the
rule flags. The corpus gate runs the built-in rules over the packages
pinned in `test/corpus/`, and the benchmark checks grice's speed over them
against budgets; CONTRIBUTING.md says how to bump either, and how to add a
built-in rule.

## Architecture

Rows marked **Exists** have landed. The others are the planned shape, so new
code has a place to go.

The supported API will be the `grice` module plus a few documented modules (the
rule API, the built-in rules, diagnostics builders and the testing kit). Everything under
`src/grice/internal/` is an implementation detail and can change without
notice.

| File | Responsibility |
|---|---|
| `src/grice.gleam` | **Exists:** entry points: `main()`, which runs `rules.default()`, `run(rules)` for a client's own set, and the library API: `load_project`, `lint`, `diagnostics`, `coverage` and `render` |
| `src/grice/coverage.gleam` | **Exists:** the coverage of a run and its gaps, public so tools can pattern-match on them |
| `src/grice/rule.gleam` | **Exists:** module and project rule builders, reports and severities |
| `src/grice/rules.gleam` | **Exists:** the built-in rules: `default()`, the set `main()` runs, and one function per rule |
| `src/grice/facts.gleam` | **Exists:** per-module facts: name, path, source, imports, comments and the syntax tree as compiled for the target, and for typed rules the type queries and the `Unknown` type |
| `src/grice/types.gleam` | Type predicates over girard's `Type` |
| `src/grice/visit.gleam` | **Exists:** the glance syntax tree walk, in source order, with a hook per kind of node |
| `src/grice/diagnostic.gleam` | **Exists:** the diagnostic model (`Diagnostic`, `Severity`, `Location`, `Label`, `Span`, `Fix`, `Edit`). Planned: report, label and fix builders |
| `src/grice/testing.gleam` | **Exists:** the testing kit for rule authors: fixtures built in memory, with installed dependencies for typed runs, a run's render for snapshots, and assertions on its codes |
| `src/grice/internal/glob.gleam` | **Exists:** the glob syntax of `include`, `exclude` and the `paths` of ignores, and path matching; the name patterns of their `definitions` |
| `src/grice/internal/config.gleam` | **Exists:** `[tools.grice]` and `target` parsing and validation, with the `[[tools.grice.ignore]]` entries and the `suppression_comments` switch |
| `src/grice/internal/loader.gleam` | **Exists:** discovery, the load set, reading, parsing and dependency sources |
| `src/grice/internal/glance_spans.gleam` | **Exists:** the workaround for glance's string ends on JavaScript (lpil/glance#47): each parsed module's tree, corrected before anything reads it |
| `src/grice/internal/line_index.gleam` | **Exists:** byte offset to line and column, line ranges, span checks, glance's offsets to bytes, and UTF-8 decoding that keeps every byte |
| `src/grice/internal/typing.gleam` | **Exists:** girard integration: the order modules are typed in, the in-memory resolver and each module's type index |
| `src/grice/internal/runner.gleam` | **Exists:** checking the rule set, planning which facts the rules need, running rules over the lint set, resolving reports, dropping what ignores and suppressions hide, and the coverage record with its notes |
| `src/grice/internal/rules/` | **Exists:** one module per built-in rule, with its matching and its diagnostic text, and `int_literal.gleam`, which reads glance's Int literals in every spelling for the rules that compare with one |
| `src/grice/internal/suppress.gleam` | **Exists:** applying ignores and suppression comments, and the unused- and invalid-suppression warnings |
| `src/grice/internal/render/human.gleam` | **Exists:** human output in a layout modelled on the compiler's, and a run's summary and stats |
| `src/grice/internal/render/json.gleam` | **Exists:** the JSON document, schema version 1, pretty-printed |
| `src/grice/internal/cli.gleam` | **Exists:** the command line as a pure function: arguments, help, root discovery, exit codes and failed runs |
| `src/grice/internal/stats.gleam` | **Exists:** what `--stats` measures: samples, phases and counts |
| `src/grice/internal/path.gleam` | **Exists:** paths as text: segments, relative and absolute paths, parents |
| `src/grice/internal/parallel.gleam` | **Exists:** an order-keeping parallel map, as an Erlang FFI in `src/grice_ffi.erl`; a sequential map on JavaScript |
| `src/grice/internal/platform.gleam` | **Exists:** arguments, environment, terminal detection, the clock, reductions on Erlang, and exit, as an Erlang FFI in `src/grice_ffi.erl` and a JavaScript one in `src/grice_ffi.mjs` |

### Pipeline

1. **Config.** Read `[tools.grice]` from `gleam.toml`, plus the package name and
   target, and validate it strictly.
2. **Discover.** Expand the `include`/`exclude` globs into the **lint set**: the
   modules rules run on and diagnostics are reported for.
3. **Load.** Parse the lint set, then follow its in-package imports (filtered
   for the configured target) to add every module it needs. That is the
   **load set**: excluded code is still loaded when linted code imports it.
   Each file is read, parsed with glance, lexed with glexer for comments, and
   given a line index.
4. **Plan.** Collect the facts the enabled rules need. If none needs types,
   girard never runs.
5. **Types.** Call girard once over the whole load set, passing the same parsed
   modules the rules see (so spans agree) in dependency-first order (so no
   module is inferred twice).
6. **Run.** Module rules run in parallel per module. Project rules run a
   per-module step in parallel, then fold the summaries and evaluate once.
7. **Resolve and filter.** Attach rule code, severity and path to each report,
   drop what ignores and suppressions hide, and report suppressions that hid
   nothing.
8. **Report.** Sort, render as human text or JSON, and exit with a code.

## Design Principles

These apply to grice's own design and to every rule it ships.

1. **Never repeat the compiler.** If `gleam build` already reports something,
   grice doesn't. A built-in rule's tests show that the compiler is silent on
   the code the rule flags.
2. **Never guess what types can tell.** A claim that depends on a type asks
   girard, and "which definition is this?" goes through girard's resolutions,
   not name matching. When girard has no answer, the rule stays silent. The type
   API returns `Result(_, Unknown)` with a reason, never a default.
3. **Rules are code; configuration can't lie.** Rules and severities are Gleam
   values the compiler checks. `gleam.toml` holds only paths, exclusions and
   per-path ignores, and an unknown key, an unknown rule name or a malformed
   glob stops the run.
4. **Fast by construction.** Parse each file once, build each line index once,
   run inference at most once and only when needed, lint modules in parallel,
   and keep project rules linear (map, fold, final). A benchmark over a fixed
   corpus guards the budget.
5. **Diagnostics are the product.** Follow the Gleam compiler's layout. Write
   in plain words: what is wrong, why it matters, how to fix it. Every
   diagnostic has a stable rule code, there is a versioned JSON form, and colour
   is used only on a terminal and never when `NO_COLOR` is set.
6. **Fail loudly.** Never report success over code grice didn't analyse. Every
   gap is a diagnostic, appears in the summary and in the JSON coverage.
7. **The core packages are the false-positive gate.** A rule is on by default
   only if it runs clean on the Gleam core team's packages, or each remaining
   finding is recorded with a justification.
8. **Idiom comes from the source.** A rule that calls something unidiomatic
   cites the language tour, the conventions page on gleam.run, or the
   stdlib's own practice. Personal taste belongs in custom rules.
9. **Suppressions are explicit.** A suppression names the rule and should give
   a reason, and an unused suppression is itself reported. A rule that is often
   wrong gets fixed or removed, not defended.
10. **Small public surface.** Public types are structured so consumers can
    pattern-match on them. Rendered text is a convenience, not the contract.

## Key Design Decisions

- **The rule set is Gleam code.** `gleam run -m grice` runs `grice.main()` with
  the built-in rules. A client with custom rules calls `grice.run(rules)` from
  its own entry module's `main()` and runs that module. Severity is chosen in
  code, where the compiler checks it.
- **`gleam.toml` holds paths and ignores.** `[tools.grice]` has `include` and
  `exclude` globs, which choose what is linted (not what is loaded), and
  per-path rule ignores. Unknown keys and rule names are errors.
- **`lint` is pure and project-rooted.** `load_project(root)` does the IO: it
  reads the config, the project's sources and the dependency sources (located
  through `manifest.toml`). `lint` then works only on that value, with an
  in-memory resolver for girard, so the working directory never changes the
  result. Only reading files, printing and exiting do IO, which is what lets
  an editor integration and the testing kit reuse the core.
- **Coverage gaps are always reported; only input gaps fail by default.** A
  file that doesn't parse is an error and always fails the run. A definition
  girard couldn't type, or a module it returned nothing for, is a note: it fails
  the run only under `--strict`, and `--warnings-as-errors` doesn't affect it.
- **Spans are byte offsets.** Diagnostics carry byte spans plus the source, so
  an editor integration can convert them to its own positions at the edge.
  Rules see glance's units, consistently: bytes on Erlang and UTF-16 code
  units on JavaScript, in the syntax tree, the comments and girard's
  answers. grice converts a span to bytes only where it becomes part of a
  diagnostic.
- **Both targets, Node first.** grice runs on Erlang and on JavaScript with
  Node, with the same diagnostics, JSON and exit codes. On JavaScript the
  map over modules is sequential, `--stats` has no reductions, and exit sets
  the exit code and returns, so piped output is never cut short.

## Limitations

- grice assumes code the compiler accepts. It doesn't diagnose type errors.
- Parsing is bounded by glance's syntax support, and type facts by girard's
  coverage.
- JavaScript runtimes other than Node, such as Deno, Bun and browsers, aren't
  supported. Autofixes and graded effects come later.
