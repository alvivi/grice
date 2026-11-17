# Configuration

grice reads its configuration from the project's `gleam.toml`: the
`target`, and the `[tools.grice]` table. Every key is optional, and a
project with no `[tools.grice]` table lints `src/` with every rule.

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
wrong type, a malformed glob or a rule code no rule of the run has is a
`grice/invalid-config` error, and the run stops with exit code 2 before
any rule runs. Every problem is reported at once.

## `target`

The compiler's own key: `"erlang"`, the default, or `"javascript"`. grice
lints the code as it's compiled for this target, so a definition or an
import whose `@target` attribute names the other target is left out, as the
compiler leaves it out.

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
them. grice's own diagnostics, those whose codes start with `grice/`,
report on the run itself and can't be ignored.

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
against what they left. grice's own diagnostics are never hidden.

A suppression that can't do its job is a warning, so it never goes stale
unnoticed:

- `grice/unused-suppression`: it hides nothing, because no diagnostic of
  its rule is left where it reaches, or because no rule of the run has its
  code;
- `grice/invalid-suppression`: it can't be used. It names no rule, gives no
  reason, names something that isn't a rule code or is one of grice's own,
  comes after code, or starts with `grice-ignore` but is neither form, such
  as `grice-ignore-next-line`.

Both are warnings, so they fail a run under `--warnings-as-errors`.

Setting `suppression_comments = false` turns suppressions off: each one is
then a `grice/invalid-suppression` warning and hides nothing. Ignores in
`gleam.toml` still apply, so a project can keep every exception in one
reviewed file.
