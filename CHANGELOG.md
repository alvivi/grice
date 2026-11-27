# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
