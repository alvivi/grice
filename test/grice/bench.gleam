//// The benchmark: grice over every package of the corpus, in four
//// scenarios that each isolate one cost, checked against budgets in
//// reductions. Run it from grice's root with `gleam run -m grice/bench`,
//// or with `gleam run --target javascript -m grice/bench` to measure it on
//// Node. It downloads the corpus first if needed, and has no `_test`
//// function, so `gleam test` never runs it.
////
//// A scenario is a rule set whose rules never report. `none` costs
//// loading, the facts and the suppression pass; `syntax` adds a walk with
//// every hook; `typed` adds girard and a type query at every expression;
//// `project` adds a project rule's parallel per-module pass and its
//// evaluation. Each scenario runs one warm-up pass and then
//// `measured_passes` passes, and reports the median of each phase: `load`
//// reads the corpus's installed modules once and loads every package, and
//// `lint` runs the rules over every package.
////
//// Every pass, the warm-up included, checks that it analysed the whole
//// corpus: no diagnostic in any package's run, every module parsed, every
//// module fully typed in `typed` and girard not run in the others, and
//// the module and line totals pinned below. A pass over less code would
//// fit any budget, so a pass that fails the check exits 1 before any
//// budget is compared.
////
//// Budgets are reductions, which vary by well under 3% between runs and
//// scheduler counts. Milliseconds vary with the machine, so they're
//// reported but never checked. The benchmark prints the constants this
//// run would set, its medians plus 10% rounded up to the thousand, to
//// paste when a budget moves on purpose.
////
//// Only Erlang counts reductions, so the budgets apply on Erlang only, and
//// on JavaScript the benchmark reports milliseconds and exits 1 only when a
//// pass fails its check. Whether budgets apply is decided by the runtime,
//// not by whether a sample has reductions: on Erlang, a phase without them
//// fails the run, so a lost count can't turn the budgets off.

import gleam/bool
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import grice/corpus
import grice/coverage.{NotRequested, Requested}
import grice/facts
import grice/internal/line_index
import grice/internal/loader
import grice/internal/platform
import grice/internal/runner
import grice/internal/stats.{type Phase, Phase}
import grice/rule.{type Rule}
import grice/support

// Budgets
//
// Measured on OTP 28.4.2, Gleam 1.19.2 and girard 4.0.1, over the corpus
// totals beside them. Re-measure them all when any of those versions or
// the corpus changes, and when a change makes grice faster or slower on
// purpose.

const corpus_modules = 101

// The newlines in every package's lint-set sources.
const corpus_lines = 46_378

// What every scenario's `load` may take.
const load_budget = 12_660_000

const none_lint_budget = 6_459_000

const syntax_lint_budget = 8_193_000

const typed_lint_budget = 67_061_000

const project_lint_budget = 6_652_000

const measured_passes = 3

// Running
//
// Every scenario is measured before anything is printed.

pub fn main() -> Nil {
  corpus.download()
  let packages =
    list.append(corpus.core, corpus.community) |> list.sort(string.compare)
  case list.try_map(scenarios(), measure(_, packages)) {
    Ok(results) -> report(packages, results)
    Error(problem) -> {
      io.println_error(problem)
      platform.exit(1)
    }
  }
}

// A rule set whose cost is measured over the corpus, whether girard must
// type every module for it, and what its `lint` may take.
type Scenario {
  Scenario(name: String, rules: List(Rule), typed: Bool, lint_budget: Int)
}

// What one pass over the corpus cost, and how much it covered.
type Pass {
  Pass(load: Phase, lint: Phase, modules: Int, lines: Int)
}

// The medians of a scenario's measured passes: each phase's, and the
// total milliseconds of a pass, load and lint together.
type Measured {
  Measured(scenario: Scenario, load: Phase, lint: Phase, total: Int)
}

// The warm-up loads the runtime's code and warms the file system, so the
// measured passes compare like with like. It doesn't warm girard: each
// typed run infers the dependency modules it imports afresh, as a real
// run does.
fn measure(
  scenario: Scenario,
  packages: List(String),
) -> Result(Measured, String) {
  use _warm_up <- result.try(run_pass(scenario, packages))
  use passes <- result.map(
    list.repeat(Nil, measured_passes)
    |> list.try_map(fn(_pass) { run_pass(scenario, packages) }),
  )
  Measured(
    scenario:,
    load: median(list.map(passes, fn(pass) { pass.load })),
    lint: median(list.map(passes, fn(pass) { pass.lint })),
    total: middle(
      list.map(passes, fn(pass) {
        pass.load.milliseconds + pass.lint.milliseconds
      }),
    ),
  )
}

// Read the corpus's installed modules once, then load and lint each
// package in name order.
fn run_pass(
  scenario: Scenario,
  packages: List(String),
) -> Result(Pass, String) {
  let start = platform.sample()
  let installed = corpus.installed()
  let read = stats.phase(start, platform.sample())
  let empty = Pass(load: read, lint: Phase(0, Some(0)), modules: 0, lines: 0)
  use pass <- result.try(
    list.try_fold(packages, empty, fn(pass, package) {
      run_package(scenario, installed, pass, package)
    }),
  )
  use <- bool.guard(
    when: pass.modules == corpus_modules && pass.lines == corpus_lines,
    return: Ok(pass),
  )
  Error(
    "grice bench: a "
    <> scenario.name
    <> " pass analysed "
    <> int.to_string(pass.modules)
    <> " modules and "
    <> int.to_string(pass.lines)
    <> " lines, but the corpus has "
    <> int.to_string(corpus_modules)
    <> " and "
    <> int.to_string(corpus_lines)
    <> ", so no budget was compared. If the corpus changed on purpose, re-measure the budgets and the totals.",
  )
}

// Load and lint one package, adding what each cost to `pass`. The check
// and the line count come after the last sample, so no phase counts them.
fn run_package(
  scenario: Scenario,
  installed: corpus.Installed,
  pass: Pass,
  package: String,
) -> Result(Pass, String) {
  let before = platform.sample()
  let project = corpus.load(package, installed)
  let loaded = platform.sample()
  let linted = corpus.lint(project, scenario.rules)
  let done = platform.sample()
  use Nil <- result.map(check(scenario, package, project, linted))
  Pass(
    load: add(pass.load, stats.phase(before, loaded)),
    lint: add(pass.lint, stats.phase(loaded, done)),
    modules: pass.modules + linted.coverage.modules,
    lines: pass.lines + lines(project),
  )
}

// The rules never report, so any diagnostic is grice's own: a parse error
// or a coverage note. Whether girard ran is checked against the scenario,
// not its rules, so a typed scenario that lost its typed rule fails.
fn check(
  scenario: Scenario,
  package: String,
  project: loader.Project,
  linted: runner.Linted,
) -> Result(Nil, String) {
  let coverage = linted.coverage
  let types = case scenario.typed {
    True -> Requested(full: coverage.modules, partial: 0, none: 0)
    False -> NotRequested
  }
  use <- bool.guard(
    when: linted.diagnostics == []
      && coverage.parsed == coverage.modules
      && coverage.types == types,
    return: Ok(Nil),
  )
  let describe = corpus.describe_diagnostic(package, project, _)
  let summary =
    "grice bench: a "
    <> scenario.name
    <> " pass didn't analyse the whole of "
    <> package
    <> " ("
    <> corpus.describe_coverage(coverage)
    <> "), so no budget was compared."
  [summary, ..list.map(linted.diagnostics, describe)]
  |> string.join("\n")
  |> Error
}

fn lines(project: loader.Project) -> Int {
  use total, name <- list.fold(project.lint_set, 0)
  case dict.get(project.modules, name) {
    Ok(module) -> total + line_index.line_count(module.source) - 1
    Error(Nil) -> total
  }
}

// Reductions add up only while both phases count them.
fn add(left: Phase, right: Phase) -> Phase {
  Phase(
    milliseconds: left.milliseconds + right.milliseconds,
    reductions: option.all([left.reductions, right.reductions])
      |> option.map(int.sum),
  )
}

// The median of each counter, over an odd number of phases. Reductions
// have a median only when every phase counts them.
fn median(phases: List(Phase)) -> Phase {
  Phase(
    milliseconds: middle(list.map(phases, fn(phase) { phase.milliseconds })),
    reductions: list.map(phases, fn(phase) { phase.reductions })
      |> option.all
      |> option.map(middle),
  )
}

fn middle(values: List(Int)) -> Int {
  let sorted = list.sort(values, int.compare)
  case list.drop(sorted, list.length(sorted) / 2) {
    [middle, ..] -> middle
    [] -> 0
  }
}

// Scenarios
//
// The rules never report, so resolving and rendering reports, whose cost
// grows with the findings, isn't measured.

fn scenarios() -> List(Scenario) {
  [
    Scenario("none", [], typed: False, lint_budget: none_lint_budget),
    Scenario(
      "syntax",
      [every_hook()],
      typed: False,
      lint_budget: syntax_lint_budget,
    ),
    Scenario(
      "typed",
      [type_of_every_expression()],
      typed: True,
      lint_budget: typed_lint_budget,
    ),
    Scenario(
      "project",
      [functions_per_module()],
      typed: False,
      lint_budget: project_lint_budget,
    ),
  ]
}

fn every_hook() -> Rule {
  rule.module("bench/every-hook", title: "Counts every node")
  |> rule.with_context(initial: 0)
  |> rule.on_import(count)
  |> rule.on_custom_type(count)
  |> rule.on_type_alias(count)
  |> rule.on_constant(count)
  |> rule.on_function(count)
  |> rule.on_function_exit(count)
  |> rule.on_statement(count)
  |> rule.on_expression(count)
  |> rule.on_expression_exit(count)
  |> rule.on_pattern(count)
  |> rule.on_type(count)
  |> rule.on_module_end(fn(_count, _module_facts) { [] })
  |> rule.build
}

fn count(
  nodes: Int,
  _node: node,
  _module_facts: facts.ModuleFacts(kind),
) -> #(Int, List(rule.Report)) {
  #(nodes + 1, [])
}

// Counts the expressions girard has a type for.
fn type_of_every_expression() -> Rule {
  rule.module("bench/type-of-every-expression", title: "Types every expression")
  |> rule.typed
  |> rule.with_context(initial: 0)
  |> rule.on_expression(fn(answers, expression, module_facts) {
    case facts.type_of(module_facts, expression.location) {
      Ok(_type) -> #(answers + 1, [])
      Error(_unknown) -> #(answers, [])
    }
  })
  |> rule.build
}

fn functions_per_module() -> Rule {
  rule.project("bench/functions-per-module", title: "Counts functions")
  |> rule.per_module(fn(module_facts) {
    list.length(facts.module(module_facts).functions)
  })
  |> rule.final(fn(_summaries) { [] })
}

// Output
//
// What was measured and on what, a row per scenario, and on Erlang the
// constants this run would set and what's over budget, which makes the
// exit code 1.

fn report(packages: List(String), results: List(Measured)) -> Nil {
  let #(sections, exit_code) = case support.is_erlang() {
    True -> check_budgets(results)
    False -> #(
      [
        table(results, reductions: False),
        "Budgets are reductions, which only Erlang counts, so none was checked.",
      ],
      0,
    )
  }
  [header(packages), ..sections]
  |> string.join("\n\n")
  |> io.println
  platform.exit(exit_code)
}

// The table with the reductions, the constants and the verdict, and the
// exit code.
fn check_budgets(results: List(Measured)) -> #(List(String), Int) {
  let #(verdict, exit_code) = case list.flat_map(results, over_budget) {
    [] -> #("Every phase is within its budget.", 0)
    over -> #(string.join(over, "\n"), 1)
  }
  #([table(results, reductions: True), constants(results), verdict], exit_code)
}

fn header(packages: List(String)) -> String {
  "grice bench: "
  <> int.to_string(list.length(packages))
  <> " packages, "
  <> int.to_string(corpus_modules)
  <> " modules, "
  <> int.to_string(corpus_lines)
  <> " lines; "
  <> support.runtime()
  <> ", "
  <> gleam_version()
  <> ", girard "
  // grice's own girard, which gleam installs as its manifest pins it.
  <> corpus.version("build/packages/girard")
  <> "\nEvery pass analysed the whole corpus: all modules parsed, typed fully in `typed`."
}

// The scenario's name padded to one width and each number right-aligned,
// with, when `reductions` is set, a budget's status after its reductions.
fn table(results: List(Measured), reductions reductions: Bool) -> String {
  let kred_headers = case reductions {
    True -> ["load kred", "lint kred"]
    False -> []
  }
  let header =
    row("scenario", [
      "load ms",
      "lint ms",
      "total ms",
      "modules/s",
      "lines/s",
      ..kred_headers
    ])
  let rows =
    list.map(results, fn(result) {
      let kred_cells = case reductions {
        True -> [
          kred(result.load.reductions, load_budget),
          kred(result.lint.reductions, result.scenario.lint_budget),
        ]
        False -> []
      }
      row(result.scenario.name, [
        int.to_string(result.load.milliseconds),
        int.to_string(result.lint.milliseconds),
        int.to_string(result.total),
        int.to_string(corpus_modules * 1000 / result.total),
        int.to_string(corpus_lines * 1000 / result.total),
        ..kred_cells
      ])
    })
  string.join([header, ..rows], "\n")
}

fn row(name: String, cells: List(String)) -> String {
  string.pad_end(name, 8, " ")
  <> string.concat(list.map(cells, string.pad_start(_, 12, " ")))
}

// Thousands of reductions, and whether they're within `budget`.
fn kred(reductions: Option(Int), budget: Int) -> String {
  case reductions {
    Some(reductions) if reductions > budget ->
      int.to_string(reductions / 1000) <> " over"
    Some(reductions) -> int.to_string(reductions / 1000) <> "   ok"
    None -> "none"
  }
}

// A phase is over budget when it made more reductions than its budget, or
// counted none.
fn over_budget(result: Measured) -> List(String) {
  [
    #("load", result.load.reductions, load_budget),
    #("lint", result.lint.reductions, result.scenario.lint_budget),
  ]
  |> list.filter_map(fn(phase) {
    let #(name, reductions, budget) = phase
    let subject = result.scenario.name <> "'s " <> name
    case reductions {
      Some(reductions) if reductions <= budget -> Error(Nil)
      Some(reductions) ->
        Ok(
          "Over budget: "
          <> subject
          <> " made "
          <> underscored(reductions)
          <> " reductions; its budget is "
          <> underscored(budget)
          <> ".",
        )
      None ->
        Ok(
          "No reductions: "
          <> subject
          <> " counted none, so its budget couldn't be compared.",
        )
    }
  })
}

// The constants as Gleam source, from this run's medians and the totals.
// A phase that counted no reductions, which fails the run, counts as 0.
fn constants(results: List(Measured)) -> String {
  let counted = fn(phase: Phase) { option.unwrap(phase.reductions, 0) }
  let load =
    list.fold(results, 0, fn(largest, result) {
      int.max(largest, counted(result.load))
    })
  let lint =
    list.map(results, fn(result) {
      #(result.scenario.name <> "_lint_budget", budget(counted(result.lint)))
    })
  [
    #("corpus_modules", corpus_modules),
    #("corpus_lines", corpus_lines),
    #("load_budget", budget(load)),
    ..lint
  ]
  |> list.map(fn(constant) {
    "const " <> constant.0 <> " = " <> underscored(constant.1)
  })
  |> string.join("\n\n")
  |> string.append("The budgets this run would set:\n\n", _)
}

// `reductions` plus 10%, rounded up to the thousand.
fn budget(reductions: Int) -> Int {
  let raised = { reductions * 11 + 9 } / 10
  { raised + 999 } / 1000 * 1000
}

// An integer as Gleam source, with `_` between groups of three digits.
fn underscored(value: Int) -> String {
  value
  |> int.to_string
  |> string.to_graphemes
  |> list.reverse
  |> list.sized_chunk(3)
  |> list.map(fn(group) { group |> list.reverse |> string.concat })
  |> list.reverse
  |> string.join("_")
}

// What `gleam --version` prints, such as `gleam 1.19.2`.
fn gleam_version() -> String {
  let assert Ok(#(0, stdout, _stderr)) =
    support.run_gleam(".", ["--version"], support.stderr_file("bench-stderr"))
    as "can't run gleam --version"
  string.trim(stdout)
}
