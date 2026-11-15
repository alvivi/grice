//// A map that runs in parallel on the Erlang target.

import gleam/list

/// Apply `f` to every item and return the results in input order.
///
/// On Erlang, the items are handed out one at a time to at most one worker
/// process per online scheduler, so long and short items balance out. If
/// any item raises, the map raises the same exception in the caller, without
/// waiting for the other items, and a worker killed from outside fails it
/// with `{grice_worker_exit, Reason}`. Either way, and on success, no worker
/// and none of the map's messages outlive the call. Items run in no fixed
/// order, so `f` shouldn't depend on one.
///
/// Other targets map the items one after another.
@external(erlang, "grice_ffi", "parallel_map")
pub fn map(items: List(a), with f: fn(a) -> b) -> List(b) {
  list.map(items, f)
}
