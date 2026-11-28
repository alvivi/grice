# Configuration

grice reads its configuration from the project's `gleam.toml`: three of
the compiler's keys, `target`, `name` and `internal_modules`, and the
`[tools.grice]` table. Every key is optional, and a project with no
`[tools.grice]` table lints `src/` with every rule.

```toml
name = "my_app"
target = "erlang"

[tools.grice]
include = ["src/"]
exclude = ["src/my_app/generated/"]

[[tools.grice.ignore]]
paths = ["src/my_app/cli.gleam"]
rules = ["my_app/no-io"]
reason = "The command line prints by design."
```

Rules and their severities aren't configured here: they're Gleam code, in
the entry module that runs them (see the README). `gleam.toml` holds only
which files are linted and what's ignored where.

grice checks the configuration strictly. An unknown key, a value of the
wrong type, a malformed glob, a `name` that isn't a package name, a module
pattern grice doesn't read or a rule code no rule of the run has is a
`grice/invalid-config` error, and the run stops with exit code 2 before
any rule runs. Every problem is reported at once.

## `target`

The compiler's own key: `"erlang"`, the default, or `"javascript"`. grice
lints the code as it's compiled for this target, so a definition or an
import whose `@target` attribute names the other target is left out, as the
compiler leaves it out. That doesn't depend on the target grice itself runs
on: `gleam run` compiles grice for this target unless `--target` names
another, and either way grice lints this one.

## `name` and `internal_modules`

The compiler's keys that say which of the package's modules are internal:
not part of its public API, and left out of its documentation. grice reads
them so that rules can ask which of the project's modules and types are
internal, with `facts.is_internal_module` and `facts.is_internal_type`.

```toml
name = "my_app"
internal_modules = ["my_app/internal", "my_app/internal/*", "my_app/web/private"]
```

- `name` is the package's name, which grice checks as the compiler does: a
  lowercase letter followed by lowercase letters, digits and `_`, all
  ASCII. Unlike the compiler, grice runs without one.
- `internal_modules` lists module patterns. Without it, the internal
  modules are `<name>/internal` and the modules under it, the compiler's
  default, which needs `name`: with neither key, no module is internal. An
  empty list, `internal_modules = []`, makes no module internal, where
  removing the key brings the default back.

A module is internal when a pattern matches its name, whether it's under
`src/`, `test/` or `dev/`, linted or not. A dependency's modules never are,
since grice doesn't read a dependency's `gleam.toml`. A type is internal
when it's a public custom type of an internal module or one marked
`@internal`, or a type alias that isn't public API, because it's private,
marked `@internal` or in an internal module, and whose definition names an
internal type.

### Module patterns

The patterns of `internal_modules` are over module names, such as
`my_app/web/private`, not the path globs of `include` and `exclude`, such
as `src/my_app/web/private.gleam`. A module pattern matches a whole module
name:

- `*` matches any run of characters, and `?` one character, `/` included
  in both, so `my_app/internal/*` matches `my_app/internal/deep/thing`;
- every other character matches itself.

That's how the compiler reads these patterns. It reads more glob syntax
there, but grice reads only `*` and `?`: a pattern holding `[`, `]`, `{`,
`}`, `\` or `**` is a `grice/invalid-config` error, which stops every run
on the project, whatever its rules. The compiler reads that syntax by its
context, so grice rejects it rather than read it approximately and mark the
wrong modules. A pattern the compiler rejects too, such as `app/[` with its
class left open, needs fixing first. For one it accepts, each of these
rewrites means the same to the compiler as the pattern it replaces, on the
module names they can match:

| Instead of | Write |
|---|---|
| `x/**` | `x/*` |
| `**/x` | `x` and `*/x` |
| `a/**/b` | `a/b` and `a/*/b` |
| `a/{x,y}` or `a/[xy]` | `a/x` and `a/y` |

For any other pattern the compiler accepts, list by name the modules it
treats as internal today: under `src/`, the ones missing from the Modules
list of the pages a successful `gleam docs build` writes, and under `test/`
and `dev/`, which the documentation never shows, the ones the pattern
matches. That keeps
today's set, but a module added later needs adding to the list. If there
are none, write `internal_modules = []`.

### Spellings grice misreads

grice reads `gleam.toml` with a TOML parser of its own, which reads a few
rare spellings differently from the compiler:

- It doesn't decode the `\u` and `\U` escapes of a string. So
  `name = "\u0061pp"`, which the compiler reads as `app`, reaches grice as
  `\u0061pp`, which isn't a package name, and a pattern written with one
  holds a `\`, which grice doesn't read. Both are errors, rather than
  values grice would read wrongly.
- It doesn't decode the escapes of a quoted key, so a top-level key
  written with a `\`, such as `"\u0069nternal_modules"`, is an error: grice
  can't tell which key it is.
- A multiline string that starts with two line breaks loses both, where
  the compiler keeps the second. Written that way, `a/*` matches nothing
  for the compiler, since no module name holds a line break, and the
  modules under `a` for grice. This goes for every string grice reads,
  globs included, and no check of the value can see it, so write each
  pattern on one line.

## `[tools.grice]`

| Key | Default | What it does |
|---|---|---|
| `include` | `["src/"]` | Globs that choose the modules to lint. |
| `exclude` | `[]` | Globs for modules not to lint, even when `include` selects them. |
| `suppression_comments` | `true` | Whether `grice-ignore` comments in the source hide diagnostics. |
| `ignore` | `[]` | Ignores, written as `[[tools.grice.ignore]]` entries (below). |

`include` and `exclude` choose the **lint set**: the modules rules run on
and diagnostics are reported for. They don't choose what's loaded. When a
linted module imports an excluded one, grice still reads and parses it, so
types that come from it are known. The modules of `test/` and `dev/` are
linted only when `include` selects them.

### Globs

A glob is a path relative to the project root, with `/` separators:

- `*` matches any run of characters within one path segment, and `?` one
  character;
- `**`, as a whole segment, matches zero or more segments;
- every other character matches itself.

A glob matches a path or any directory above it, so `src/gen`, `src/gen/`
and `src/gen/**` all select everything under `src/gen`. Syntax from richer
glob dialects (`[`, `]`, `{`, `}`, `\`), a leading `/`, and `.` or `..`
segments are errors rather than literal text, so a pattern copied from
elsewhere fails loudly instead of matching nothing.

## Ignores

Each `[[tools.grice.ignore]]` entry hides the diagnostics of some rules in
some files, and says why:

```toml
[[tools.grice.ignore]]
paths = ["src/my_app/view/**"]
definitions = ["render_*"]
rules = ["my_app/no-io-in-view"]
reason = "The render functions log on purpose."
```

| Key | Required | What it holds |
|---|---|---|
| `paths` | yes | Globs, as above, for the files the entry covers. |
| `rules` | yes | The codes of the rules whose diagnostics it hides. |
| `reason` | yes | Why the rules don't apply there. It can't be empty. |
| `definitions` | no | Name patterns: the entry then covers only diagnostics that start inside a top-level function, constant, custom type or type alias with a matching name. |

A name pattern matches a whole name. It holds letters, digits and `_`, with
`*` for any run of characters and `?` for one character.

Each code in `rules` must name a rule of the run, so a typo or a rule that
was removed stops the run instead of silently hiding nothing. That's also
why a project with rules of its own runs grice through its entry module
rather than with `gleam run -m grice`, whose built-in rules don't include
them. The built-in rules' codes start with `grice_rules/`, such as
`grice_rules/no-echo`, and are ignored like any rule's. grice's own
diagnostics, those whose codes start with `grice/`, report on the run
itself and can't be ignored.

**`[tools.grice]` must come before every `[[tools.grice.ignore]]` entry.**
The TOML parser grice uses rejects the other order as setting
`tools.grice` twice, so grice reports `gleam.toml` as invalid. The
compiler accepts either order.

## Suppression comments

A suppression is a regular `//` comment that hides one rule's diagnostics in
the source, next to the code it's about:

```gleam
// grice-ignore-file my_app/no-panic: This module is a test fixture.

pub fn main() {
  // grice-ignore my_app/no-echo: Printing is what this tool does.
  echo 1
}
```

The grammar is `// grice-ignore <rule code>: <reason>`, or
`grice-ignore-file` in place of `grice-ignore`, with spaces or tabs between
the parts. The reason is required, and the first colon ends the rule code,
so the reason may hold more colons. Doc comments (`///` and `////`) are
never suppressions.

- `grice-ignore` stands alone on its line. It covers the diagnostics whose
  primary span starts on the next line holding code: blank lines and
  comments in between are skipped, so suppressions stack.
- `grice-ignore-file` comes before the module's first line of code and
  covers the whole module.

Ignores in `gleam.toml` apply first, and each suppression is matched
against what they left. The built-in rules, whose codes start with
`grice_rules/`, are suppressed like any rule; only grice's own
diagnostics, whose codes start with `grice/`, are never hidden.

A suppression that can't do its job is a warning, so it never goes stale
unnoticed:

- `grice/unused-suppression`: it hides nothing, because no diagnostic of
  its rule is left where it reaches, or because no rule of the run has its
  code. A suppression of a rule that didn't run, such as one that sees the
  whole project in a run where some of the project couldn't be read, isn't
  reported, since nothing showed whether it's used;
- `grice/invalid-suppression`: it can't be used. It names no rule, gives no
  reason, names something that isn't a rule code or is one of grice's own,
  comes after code, or starts with `grice-ignore` but is neither form, such
  as `grice-ignore-next-line`.

Both are warnings, so they fail a run under `--warnings-as-errors`.

Setting `suppression_comments = false` turns suppressions off: each one is
then a `grice/invalid-suppression` warning and hides nothing. Ignores in
`gleam.toml` still apply, so a project can keep every exception in one
reviewed file.
