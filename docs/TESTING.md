# Testing rules

`grice/testing` runs rules over a small project built in memory. The
project is loaded and linted the way grice lints one on disk, so its
`gleam.toml`, its target, the modules its linted modules import, ignores
and `grice-ignore` comments all apply. A test builds a fixture, runs rules
over it and checks the run:

```gleam
import grice/testing
import my_rules/no_echo

pub fn no_echo_reports_each_echo_test() {
  testing.module("pub fn main() {\n  echo 1\n  echo 2\n}\n")
  |> testing.run([no_echo.rule()])
  |> testing.expect_codes(["my_rules/no-echo", "my_rules/no-echo"])
}
```

The kit depends on no test runner and no snapshot library. A check that
fails panics, which every test runner reports as a failure. It works on
both targets, so `gleam test --target javascript` runs the same tests on
Node, typed runs included. The examples here test `my_rules/no-echo`, a
rule that reports each `echo`.

## Fixtures

`testing.module(source)` is a project with one module, `src/app.gleam`, and
the default configuration, which lints `src/` on Erlang.

`testing.project(files)` takes the files of a project, each a
`#(path, source)` with a path relative to the project root. `gleam.toml` is
the configuration: grice reads its `target`, its `name` and
`internal_modules`, and its `[tools.grice]` table. Without a `name`, no
module is internal unless `internal_modules` says so. Every other file is a
module under `src/`, `test/` or `dev/`, or a foreign source there: one of
the compiler's native files, ending in `.erl`, `.hrl`, `.ex`, `.js`,
`.mjs`, `.cjs`, `.jsx`, `.ts`, `.mts`, `.cts` or `.tsx`, which grice reads
only in a run with a rule built with
`rule.whole_project`, and no public fact shows. This test
checks that an excluded module isn't linted, even though the linted module
imports it:

```gleam
pub fn no_echo_skips_generated_code_test() {
  testing.project([
    #("gleam.toml", "[tools.grice]\nexclude = [\"src/app/generated/\"]\n"),
    #("src/app.gleam", "import app/generated/sql\n"),
    #("src/app/generated/sql.gleam", "pub fn query() {\n  echo 1\n}\n"),
  ])
  |> testing.run([no_echo.rule()])
  |> testing.expect_none
}
```

A path grice would skip panics, so a typo can't leave code that no rule
sees. That's a path outside `src/`, `test/` and `dev/`, one that is neither
a valid module name nor a foreign source, a path given twice, or two paths
that give one module name, such as `src/app.gleam` and `test/app.gleam`.

`testing.run(fixture, rules)` runs the rules over the fixture. A rule that
panics panics through `run`. When a rule of the run is built with
`rule.whole_project`, the whole fixture is loaded, as `gleam run` loads a
project for one: that rule also gets the modules outside the lint set, such
as those under `test/` and `dev/`. A module that doesn't parse there stops
that rule with a `grice/incomplete-project` note rather than failing the
run.

## Checking a run

There are three ways to check what a run found, and a test suite can mix
them.

### Checking the codes

`testing.expect_none` checks that the run shows no diagnostic, and
`testing.expect_codes` that it shows exactly the codes given, as many times
as given and in order. Diagnostics without a location come first, then the
rest by path and position. Both count grice's own diagnostics, such as a
note on code [girard](https://hexdocs.pm/girard) couldn't type.

When the codes don't match, the check panics with the codes it found, the
fixture and what grice printed for it:

```text
Expected the codes ["my_rules/no-echo"], got []:

-- src/app.gleam
pub fn main() {
  1
}
-- output
No diagnostics in 1 module.
```

This is the quickest way to test a rule, and it's enough when what matters
is whether the rule reports and how often.

### Reading the diagnostics

`testing.diagnostics` gives the run's diagnostics, in the same order, as
`grice/diagnostic` values. A test can check any part of them: the severity,
the title, the message, the hint, and the location with its path and byte
spans:

```gleam
import gleam/option.{Some}
import grice/diagnostic
import grice/testing
import my_rules/no_echo

pub fn no_echo_points_at_the_echo_test() {
  let assert [found] =
    testing.module("pub fn main() {\n  echo 1\n}\n")
    |> testing.run([no_echo.rule()])
    |> testing.diagnostics
  assert found.severity == diagnostic.Warning
  let assert Some(location) = found.location
  // Bytes 18 to 24 are `echo 1`.
  assert location.primary.span == diagnostic.Span(start: 18, end: 24)
  assert location.primary.message == "This prints when it runs"
}
```

The spans of a diagnostic are bytes on every target. The spans a rule sees
in the syntax tree, the comments and the type queries count what
[glance](https://hexdocs.pm/glance) counts on the target the tests run on:
bytes on Erlang, and UTF-16 code units on JavaScript, where `é` is one and
`🙂` two. In a fixture that's all ASCII they're the same, so a test that
compares a rule's input spans with numbers works on both targets when its
fixture is ASCII.

When one of these assertions fails, the test runner shows that assertion,
but not the fixture or the rest of the run.

### Snapshots

`testing.render` gives the run as text: the fixture's files, then what
grice prints for the run, without colour. A snapshot library keeps that
text in a file and fails the test when it changes, so the test shows the
input and the whole output, as a user would read it. With
[birdie](https://hexdocs.pm/birdie):

```sh
gleam add --dev birdie
```

```gleam
import birdie
import grice/testing
import my_rules/no_echo

pub fn no_echo_reports_each_echo_test() {
  testing.module("pub fn main() {\n  echo 1\n}\n")
  |> testing.run([no_echo.rule()])
  |> testing.render
  |> birdie.snap(title: "no_echo reports each echo")
}
```

A new snapshot fails its test until you review it with
`gleam run -m birdie`. This one holds:

```text
-- src/app.gleam
pub fn main() {
  echo 1
}
-- output
warning[my_rules/no-echo]: Echo left in the code
  ┌─ src/app.gleam:2:3
  │
2 │   echo 1
  │   ^^^^^^ This prints when it runs

`echo` prints its value each time it runs.

Hint: Remove it once you're done debugging.

1 warning in 1 module.
```

Each file comes under a `-- <path>` line, in the order given. Each module
added with `testing.with_dependency` comes next, under a
`-- dependency <module>` line, then the output under `-- output`. Paths are
relative to the project root, and installed dependencies aren't shown.

Snapshots are the way to test what a diagnostic says and where it points,
because they show the text a user reads.

## Typed rules

A typed rule asks [girard](https://hexdocs.pm/girard) for the types of the
code, and [girard](https://hexdocs.pm/girard) answers from the same sources
as in a real run. A run with a typed rule reads the dependencies installed
for the project, through `manifest.toml` in the working directory, so a
fixture can import `gleam/list`, or any module the project's own code can.
`gleam test` runs in the directory it's started from, so start it from the
project root. Without a manifest there, the run panics and says so. A run
with no typed rule reads nothing from disk.

`testing.with_dependency` adds a dependency module with a source of its
own. It takes the place of an installed module of the same name, so a test
can stand in for a dependency the project doesn't have. No rule runs on a
dependency module.

```gleam
testing.module("import shapes/square\n\npub fn main() {\n  square.new(2)\n}\n")
|> testing.with_dependency(
  module: "shapes/square",
  source: "pub type Square {\n  Square(Int)\n}\n\npub fn new(size: Int) -> Square {\n  Square(size)\n}\n",
)
|> testing.run([my_typed_rule.rule()])
|> testing.expect_none
```

Where [girard](https://hexdocs.pm/girard) has no answer, a typed rule should
stay silent, and grice adds a `grice/untyped-definition` note on the code
[girard](https://hexdocs.pm/girard) couldn't type. A test of that silence
expects exactly that note, which shows both that the rule stayed silent and
why:

```gleam
pub fn discarded_result_is_silent_over_a_gap_test() {
  testing.module("pub fn main() {\n  let _ = 1 + \"one\"\n}\n")
  |> testing.run([discarded_result.rule()])
  |> testing.expect_codes(["grice/untyped-definition"])
}
```

## Runs that panic

A run that couldn't check the fixture panics with the problem as grice
shows it:

- an invalid `gleam.toml`;
- nothing to lint, when `include` and `exclude` select no module;
- a module to lint that doesn't parse;
- an invalid rule set, such as two rules with one code;
- installed dependencies that can't be read, for a typed rule.

A module that isn't linted may still fail to parse, which is how a test
gives [girard](https://hexdocs.pm/girard) an import it can't use.
