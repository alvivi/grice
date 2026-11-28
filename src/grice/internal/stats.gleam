//// What `--stats` measures: how long loading and linting took, in wall
//// time and, on Erlang, in reductions, and how much there was to load and
//// lint.
////
//// A run takes a `Sample` at its start, before and after loading, and
//// after linting. Rendering is never measured, so the stats can be part of
//// what's rendered.

import gleam/option.{type Option}

/// The clock and the reduction count at one moment of a run.
pub type Sample {
  Sample(
    /// A monotonic clock, in milliseconds from an arbitrary start.
    milliseconds: Int,
    /// The reductions every process of the runtime has made so far, or
    /// `None` on a runtime that doesn't count them, such as JavaScript.
    reductions: Option(Int),
  )
}

/// What one span of a run cost. `reductions` is `None` when the runtime
/// doesn't count them.
pub type Phase {
  Phase(milliseconds: Int, reductions: Option(Int))
}

/// What a completed run cost, and how much it worked on.
pub type Stats {
  Stats(
    /// The number of project modules loaded: the load set, or every module
    /// of the project when a rule sees the whole project.
    loaded: Int,
    /// The number of dependency modules whose sources were read.
    dependencies: Int,
    /// The number of rules in the run.
    rules: Int,
    /// Whether girard inferred the project's types.
    types: Bool,
    /// From before loading to after it.
    load: Phase,
    /// From after loading to after linting.
    lint: Phase,
    /// From the start of the run to after linting.
    total: Phase,
  )
}

/// The span from the sample `from` to the sample `to`.
pub fn phase(from: Sample, to: Sample) -> Phase {
  Phase(
    milliseconds: to.milliseconds - from.milliseconds,
    reductions: option.then(to.reductions, fn(to) {
      option.map(from.reductions, fn(from) { to - from })
    }),
  )
}
