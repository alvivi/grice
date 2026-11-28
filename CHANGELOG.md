# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **The library pack.** `rules.library()` in `grice/rules` is an opt-in
  set of built-in rules for a package published to Hex, about what it
  offers its users. `gleam run -m grice` still runs the default set alone;
  add the pack in an entry module of your own with
  `grice.run(list.append(rules.default(), rules.library()))`. Its rules
  read only the modules under `src/`, and report a warning.
  [Built-in rules](https://github.com/alvivi/grice/blob/main/docs/RULES.md)
  describes it:
  - `grice_rules/internal-type-in-public-api`: a public function, constant
    or constructor whose signature, as written, names an internal type of
    the package: a public custom type of an internal module or marked
    `@internal`, or a type alias that isn't public API (private, marked
    `@internal` or in an internal module) whose definition names an
    internal type. A type named through a public alias is fine, and an
    unannotated declaration isn't read. The compiler
    planned this warning in gleam-lang/gleam#2234, and the rule retires
    once it ships.
- **Internal modules and types in facts.** `facts.is_internal_module`
  tells every rule whether a module of the project is internal: under
  `src/`, `test/` or `dev/`, with a name that a pattern of
  `internal_modules` in `gleam.toml` matches, or, when that key is absent
  and `name` is set, `<name>/internal` or a module under it.
  `facts.is_internal_type` tells whether grice knows a type of the project
  to be internal: a public custom type of an internal module or marked
  `@internal`, or a type alias that isn't public API (private, marked
  `@internal` or in an internal module) whose definition names an internal
  type. Its answer is positive: `False` also covers what grice can't see,
  such as a dependency's types.
- **Project rules that see the whole project.** A project rule built with
  `rule.whole_project` is given every module of the project under `src/`,
  `test/` and `dev/`, linted or not, so it can ask, for example, whether a
  test uses a function. `facts.is_linted` tells which modules are linted,
  and the rule's reports on the others are dropped. grice reads the rest of
  the project, and its foreign sources (the compiler's native files there,
  `.erl`, `.hrl`, `.ex`, `.js`, `.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`,
  `.cts` and `.tsx`), only when such a rule runs, so every other run reads what it read before. When a module of the
  project can't be read or doesn't parse, or a foreign source can't be
  read, those rules don't run, their suppressions aren't reported as
  unused, and a `grice/incomplete-project` note lists the files; the
  coverage gets an `IncompleteProject` gap, `incomplete-project` in the
  JSON document, which fails the run only with `--strict`. It's a new kind
  of gap within version 1 of the JSON schema, so a decoder should take a
  kind it doesn't know for a gap. With `rule.typed`, such a rule gets types
  for every module, and girard's gaps in each are coverage gaps. The
  library API loads a project for one with `grice.load_whole_project`, and
  `grice.lint` refuses to run one on a project loaded with
  `grice.load_project`, with a `grice/invalid-rule` error;
  `rule.is_whole_project` tells a tool which to call. The command line and
  `grice/testing` load as much as the rules need, and a fixture may hold
  foreign sources.

### Changed

- **grice reads `name` and `internal_modules`.** Besides `target`, grice
  now reads two more of the compiler's keys in `gleam.toml`, to know which
  modules are internal, and checks them as strictly: a `name` that isn't a
  package name, or a top-level key written with a `\`, which grice's TOML
  reader can't decode, stops the run with a `grice/invalid-config` error. A
  project with no `name` still runs, with no default internal modules.
- **Patterns in `internal_modules` use `*` and `?` only.** grice reads a
  module pattern as the compiler does when it holds only literal
  characters, `*` and `?`, and stops the run on one that holds `[`, `]`,
  `{`, `}`, `\` or `**`, even with the default rule set alone. Write `x/*`
  for `x/**`, `x` and `*/x` for `**/x`, `a/b` and `a/*/b` for `a/**/b`, and
  `a/x` and `a/y` for `a/{x,y}`, which the compiler reads the same way on
  the module names each can match; otherwise list the internal modules by
  name. [Configuration](https://github.com/alvivi/grice/blob/main/docs/CONFIGURATION.md)
  says how.

## [0.3.0] - 2026-11-27

### Added

- **The simplify pack.** `rules.simplify()` in `grice/rules` is an opt-in
  set of built-in rules for code that is correct but takes the long way
  round, where one standard library function does the same: on the target
  grice lints for, the rewrite each finding suggests gives the same
  result, and calls any function passed to it the same way (fold-plus's
  can give a NaN sum other bits in code also built for JavaScript; see
  below). `gleam run -m grice` still runs the default
  set alone; add the pack in an entry module of your own with
  `grice.run(list.append(rules.default(), rules.simplify()))`. Each rule
  finds its functions by what girard resolved, reads the calls nested or
  piped, and reports a warning.
  [Built-in rules](https://github.com/alvivi/grice/blob/v0.3.0/docs/RULES.md)
  describes each one:
  - `grice_rules/map-then-flatten`: `result.map` then `result.flatten`, or
    `option.map` then `option.flatten`, which `result.try` and
    `option.then` do in one call.
  - `grice_rules/list-map-then-flatten`: `list.map` then `list.flatten`,
    which `list.flat_map` does in one call.
  - `grice_rules/filter-then-length`: `list.filter` then `list.length`,
    which `list.count` does without building the filtered list. It's
    silent on a count checked for emptiness, where `list.count` would
    still count every element; the compiler and no-length-for-emptiness
    report such a check in the forms each reads.
  - `grice_rules/reverse-then-first`: `list.reverse` then `list.first`,
    which `list.last` does without the reversed copy.
  - `grice_rules/fold-plus`: a `list.fold` that sums a list of ints from
    0, with `int.add` or a function that adds its two parameters, which
    `int.sum` does. On a project whose target is JavaScript, it reads
    only `fn(total, x) { x + total }`, which adds as `int.sum` does there,
    since the other order can give a NaN sum other bits.
- **The project's target in facts.** `facts.target` gives every rule the
  target the project is linted for, as the new `facts.Target`: its
  `gleam.toml`'s `target`, or Erlang when it sets none. The facts already
  describe each module as compiled for that target, and now a rule whose
  verdict depends on the target can ask for it.

## [0.2.0] - 2026-11-26

### Added

- **The default rule set.** `gleam run -m grice` runs grice's first
  built-in rules, and the new `grice/rules` module offers them: `default()`,
  the set `gleam run -m grice` runs, and a function per rule, so an entry
  module of your own can run them beside its rules, change a rule's
  severity or leave one out. Each reports a warning, and its code starts
  with `grice_rules/`, so ignores and suppression comments hide it like
  any rule's. [Built-in rules](https://github.com/alvivi/grice/blob/v0.2.0/docs/RULES.md)
  describes each one:
  - `grice_rules/no-echo`: an `echo` left in a module outside `test/` and
    `dev/`, which `gleam publish` refuses and an application prints.
  - `grice_rules/ineffective-double-comparison`: in a chain of `&&` or
    `||`, a comparison of a variable with an Int literal that the
    comparisons before it already decide, such as the second half of
    `48 >= char && char <= 57`, a range written the wrong way round.
  - `grice_rules/no-length-for-emptiness`: `string.length` or
    `list.length` compared with 0 or 1, or matched on 0 in a `case`, to
    check whether a string or a list is empty, found by what girard
    resolved, and leaving alone the `list.length` forms the compiler
    already warns on. With it, `gleam run -m grice` runs girard.
  - `grice_rules/check-then-assert`: a `Result` or an `Option` checked
    with `result.is_ok`, `result.is_error`, `option.is_some` or
    `option.is_none`, then `let assert`-ed on a path where the check
    already proved the variant, through a `case`, `bool.guard` or
    `bool.lazy_guard`, which the conventions page says should never be
    done.

### Changed

- **girard 4.0.2.** grice requires girard 4.0.2, which types more of the
  code the compiler accepts, so fewer definitions get a
  `grice/untyped-definition` note. A pipe into `echo`, as in `x |> echo`,
  now types as the piped value. A note's reason for a type mismatch may
  name the two types in the other order, as girard now checks some
  constructs in the compiler's order.

## [0.1.0] - 2026-11-20

### Added

- Module and project rules with type facts from
  [girard](https://hexdocs.pm/girard), compiler-style diagnostics, ignores
  and suppression comments, JSON output, a testing kit for rules, and both
  targets, Erlang and JavaScript on Node.

[0.3.0]: https://github.com/alvivi/grice/releases/tag/v0.3.0
[0.2.0]: https://github.com/alvivi/grice/releases/tag/v0.2.0
[0.1.0]: https://github.com/alvivi/grice/releases/tag/v0.1.0
