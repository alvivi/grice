# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The diagnostic model.** The new `grice/diagnostic` module defines what
  every grice diagnostic is made of: a rule code, a `Severity`, a title,
  message paragraphs, a hint, and an optional `Location` that owns the file
  path, the primary and secondary `Label`s and a reserved `Fix`. Spans are
  byte offsets into the file's source.
- **A syntax tree walk.** The new `grice/visit` module walks a glance
  module, or a single expression, and calls a hook for each import, custom
  type, type alias, constant, function, statement, expression, pattern and
  type it meets, threading an accumulator through them. The walk follows
  source order, definitions of every kind included, and functions and
  expressions also have exit hooks, called after their children. Attribute
  arguments and the sizes in bit array patterns aren't walked.
- **Rules.** The new `grice/rule` module builds rules. A module rule looks
  at one module at a time: `rule.module` names it, `rule.with_context` gives
  it the context it threads through the module, the `on_*` functions add
  hooks, called during a `grice/visit` walk, and `rule.build` makes the
  `Rule`. A project rule summarises each linted module with
  `rule.per_module` and reports on all of them together with `rule.final`.
  Hooks return `Report`s, built from glance spans, with a primary label,
  secondary labels, a message and a hint. Rules report warnings unless
  `rule.with_severity` sets another severity. A rule code is a
  package-style prefix, a slash and a kebab-case name, such as
  `my_app/no-echo`, and the `grice/` prefix is reserved for grice's own
  diagnostics.
- **Module facts.** The new `grice/facts` module holds what a rule hook
  knows about the module it's looking at: its name, path, source, imports
  and syntax tree, as the module is compiled for the project's target. A
  definition whose `@target` attribute names the other target is left
  out, and each list of definitions is in source order.
- **Typed rules.** `rule.typed`, applied right after `rule.module` or
  `rule.project`, gives a rule `Typed` facts. Module and project rules now
  start from one `rule.Schema` type, which replaces `ModuleSchema` and
  `ProjectSchema`: its `ModuleForm` or `ProjectForm` says which kind of
  rule it builds, so `rule.with_context` takes only a module rule's schema
  and `rule.per_module` only a project rule's. The types are inferred once
  per run, and only when a rule of the set is typed.
- **Type facts.** `Typed` facts answer what girard, the type inference
  grice uses, found in the module: `facts.type_of` gives the type of an
  expression, `facts.resolution_of` what a field access or a name in call
  position resolved to, and `facts.signature` the type of a top-level
  function or constant. Spans match exactly, as glance gives them. A
  query with no answer returns an `Unknown` that says why: girard keeps
  nothing there, the definition it's in couldn't be typed or isn't
  compiled for the target, girard returned nothing for the module, or the
  module reaches modules girard couldn't use, which leaves every query on
  it without an answer.
- **Comments.** `facts.comments` gives a rule the module's comments, which
  glance's syntax tree leaves out, in source order. Each `Comment` has its
  `CommentKind` (`Regular`, `Doc` or `ModuleDoc`, for `//`, `///` and
  `////`), its span in bytes, slashes included, and its text after the
  slashes. A comment inside a definition left out for the other target
  isn't there, as the definition isn't.
- **girard.** grice depends on girard 4. Typed queries return its `Type`,
  `Resolution` and `Scheme`, so a rule that inspects them depends on
  girard too.
- **The library API.** The new `grice` module lints a project from code,
  for tools such as an editor integration. `grice.load_project` reads a
  project from disk, or returns a `LoadError` that says what it couldn't
  read; a relative root is made absolute against the working directory,
  keeping any `..` so a path through a symbolic link names what the file
  system names. `grice.lint` runs a rule set over it, or returns every
  problem with the rule set and with the rule codes `gleam.toml` ignores,
  and runs nothing. `grice.diagnostics` and `grice.coverage` give what the
  run found, and `grice.render` writes it as text, with or without colour
  and with paths relative to a directory, followed by a summary of the
  counts, the diagnostics ignores and suppressions hid, and the gaps in
  coverage, or as a JSON document.
- **Coverage.** The new `grice/coverage` module holds a run's `Coverage`:
  how many lint-set modules there are, how many parse and how many girard
  typed, and each `Gap`: a module that doesn't parse, a definition girard
  couldn't type, a module it returned nothing for, a module it couldn't
  use, with the `Cause`, and a dependency whose sources are missing. Each
  gap matches one diagnostic, so a tool can pattern-match on the gaps
  instead of reading text.
- **The command line.** `gleam run -m grice` runs grice's built-in rules,
  an empty set for now, over the project of the nearest `gleam.toml`, and
  an entry module of a project's own, such as `dev/lint.gleam`, runs its
  rules with `grice.run(rules)`, as `gleam run -m lint`. The options, after
  gleam's `--`, are `--format human` or `--format json`,
  `--warnings-as-errors`, `--strict`, which fails the run over any gap in
  coverage, `--no-color`, `--stats` and `--help`; anything else, an option
  given twice included, is a usage error. The exit code is 0 when no error
  is shown, 1 when one is or an option counts a warning or a gap as one,
  and 2 when the run has no result, with the reason as diagnostics:
  `grice/cannot-read`, `grice/invalid-manifest` or `grice/internal-error`
  when it isn't one already. Human output is coloured only on a terminal,
  and never when `NO_COLOR` is set to a non-empty value. grice runs on the
  Erlang target: a JavaScript project runs it with
  `gleam run --target erlang`, and its JavaScript builds still compile the
  entry module.
- **JSON output.** `--format json` prints one JSON document, schema
  version 1: the absolute root, the counts, the coverage with each gap, and
  every diagnostic with its spans in bytes and as lines and columns. Within
  version 1, fields are only added. A run with no result gives the same
  document with `coverage: null`.
- **Stats.** `--stats` adds how long loading, linting and the whole run
  took, in milliseconds and in reductions, with the number of modules and
  rules, after the summary or as the document's `stats`.
- **A testing kit for rules.** The new `grice/testing` module runs rules
  over a project built in memory, loaded and linted as grice lints one on
  disk. `testing.module` is a project with one module and
  `testing.project` takes the files of a project tree, `gleam.toml`
  included; a path grice would skip, such as one outside `src/`, `test/`
  and `dev/`, panics. `testing.with_dependency` adds a dependency module,
  and a typed run also reads the dependencies installed for the project,
  through `manifest.toml` in the working directory. `testing.render` gives
  the fixture and what grice prints for the run, for a snapshot, and
  `testing.expect_none` and `testing.expect_codes` check the diagnostics'
  codes, grice's own included, panicking with the rendered run when they
  don't match. `testing.diagnostics` gives the diagnostics. A run panics
  with the problem as grice shows it when it couldn't prove anything: an
  invalid `gleam.toml`, a module to lint that doesn't parse, an invalid
  rule set, or installed dependencies that can't be read. The kit depends
  on no test runner or snapshot library.
- **Documentation.** The README shows how to add grice, run its built-in
  rules or a project's own, run it in a JavaScript project and which of
  those can't yet, and lists the options and exit codes. New pages
  document the configuration, every `[tools.grice]` key with its default,
  the ignores and the suppression comments, and the JSON document with
  what its stats measure.
