# JSON output

`--format json` prints one JSON document on standard output, for tools such
as a CI script or an editor integration:

```sh
gleam run -m grice -- --format json > grice.json
```

The library gives the same document with
`grice.render(linted, format: grice.Json)`, without `stats`.

The document is pretty-printed with two-space indentation and ends with a
newline. The same run gives the same document: nothing in it depends on the
time or on the working directory, unless `--stats` adds its `stats`.

## Stability

This is version 1 of the schema, in the document's `version`. Within
version 1, fields are only ever added, so a consumer should ignore fields
it doesn't know. Removing or changing a field means a new version. Kinds of
coverage gap are added the same way: a gap of a kind a consumer doesn't
know is still a gap, so `complete` is `false`, and its diagnostic says what
it is.

## The document

```json
{
  "version": 1,
  "root": "/home/me/my_app",
  "summary": { "errors": 0, "warnings": 1, "notes": 1, "hidden": 2 },
  "coverage": {
    "complete": false,
    "modules": 12,
    "parsed": 12,
    "types": { "requested": true, "full": 11, "partial": 1, "none": 0 },
    "gaps": [
      { "kind": "untyped-definition", "path": "src/my_app/view.gleam", "definition": "render" }
    ]
  },
  "diagnostics": [ ... ]
}
```

The top-level keys come in this order:

| Key | Value |
|---|---|
| `version` | `1`. |
| `root` | The project root, as an absolute path. Every other path is relative to it. `null` only when no `gleam.toml` was found. |
| `summary` | The number of diagnostics shown by severity, `errors`, `warnings` and `notes`, and `hidden`: how many diagnostics ignores and suppressions hid. |
| `coverage` | How much of the lint set the run analysed (below). `null` for a run with no result. |
| `diagnostics` | Every diagnostic shown, in the order the human output shows them: those with no location first, then by path and position. |
| `stats` | Only with `--stats`: what the run cost (below). |

## Coverage

| Key | Value |
|---|---|
| `complete` | `true` when the run has no gaps. |
| `modules` | The number of modules in the lint set. |
| `parsed` | How many of them parse. |
| `types` | `{"requested": false}` when no rule of the run needs types. Otherwise `{"requested": true, "full", "partial", "none"}`: how many parsed modules [girard](https://hexdocs.pm/girard) typed completely, with gaps, or not at all. |
| `gaps` | Everything the run couldn't analyse, each matching one diagnostic. The `types` counts are the lint set's, but with a typed rule that sees the whole project, a type gap can name a module outside it. |

Each gap has a `kind` and the fields of that kind:

| `kind` | Fields | Its diagnostic |
|---|---|---|
| `unparsed-module` | `path` | `grice/parse-error` |
| `untyped-definition` | `path`, `definition` | `grice/untyped-definition` |
| `uninferred-module` | `path` | `grice/uninferred-module` |
| `unavailable-import` | `path`, `module`, `cause` | `grice/unavailable-import` |
| `missing-package` | `package` | `grice/missing-package` |
| `incomplete-project` | `rules`, `paths` | `grice/incomplete-project` |

Every field is a string, except those of an incomplete project, which are
lists of strings: `rules`, the codes of the rules that see the whole
project, which didn't run, and `paths`, the files of the project they
needed that couldn't be read, don't parse, or are `.gleam` files grice
can't take for a module, sorted. The `cause` of an
unavailable import is `project-module-unparsable`,
`project-module-unusable`, `dependency-unparsable` or `no-such-module`.

## Diagnostics

```json
{
  "code": "my_app/no-echo",
  "severity": "warning",
  "title": "Echo left in the code",
  "location": {
    "path": "src/my_app.gleam",
    "primary": {
      "span": { "start": 18, "end": 24 },
      "range": {
        "start": { "line": 2, "column": 3 },
        "end": { "line": 2, "column": 9 }
      },
      "message": "This prints when it runs"
    },
    "secondary": [],
    "fix": null
  },
  "message": ["`echo` prints its value each time it runs."],
  "hint": "Remove it once you're done debugging."
}
```

| Key | Value |
|---|---|
| `code` | The rule's code, or one of grice's own, starting with `grice/`. |
| `severity` | `"error"`, `"warning"` or `"note"`. |
| `title` | A one-line summary. |
| `location` | Where it points, or `null`. |
| `message` | The explanation, as a list of paragraphs. |
| `hint` | How to fix it, or `null`. |

A location has the `path` of the file, relative to the root, a `primary`
label, a list of `secondary` labels, and a `fix` or `null`. A label has a
`span`, a `range` and a `message`, which may be empty.

Each span is written twice. `span` holds byte offsets into the file's
source, `start` included and `end` excluded, which convert to any encoding.
`range` holds the same positions as 1-based `line` and `column`, where
columns count Unicode codepoints.

A `fix` has a `title` and a list of `edits`, each a `span`, a `range` and
its `replacement`. Edits follow the Language Server Protocol's rules for
text edits: every span refers to the original source, and none overlap.

## Runs with no result

A run that couldn't complete, such as one with an invalid configuration, an
invalid rule set or a file it couldn't read, still prints a document, and
exits with code 2. Its `coverage` is `null`, its `diagnostics` say what went
wrong, and none of them has a location. A usage error is the exception: it
goes to standard error as text, since the format may be what's wrong.

## Stats

`--stats` adds a `stats` object:

```json
"stats": {
  "modules": { "loaded": 12, "dependencies": 140 },
  "rules": 4,
  "types": true,
  "load": { "milliseconds": 61, "reductions": 2875941 },
  "lint": { "milliseconds": 230, "reductions": 9105244 },
  "total": { "milliseconds": 293, "reductions": 12081463 }
}
```

`modules.loaded` counts the project modules read, which is the lint set and
every project module it imports, or every module of the project when a rule
sees the whole project, and `modules.dependencies` the dependency
modules. `types` says whether [girard](https://hexdocs.pm/girard) inferred
types. `load` runs from before reading the project to after it, `lint` from
there to after the rules ran, and `total` from the start of the run to after
linting. Rendering isn't measured, which is what lets the stats be part of
what's rendered.

Reductions count the work every process of the runtime did, grice's
parallel workers included. They compare runs more steadily than wall time,
but only on the same versions of Erlang/OTP and Gleam, and other processes
add a little noise. JavaScript doesn't count reductions, so when grice
runs there, `reductions` is `null` in every phase.
