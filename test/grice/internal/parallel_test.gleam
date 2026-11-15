//// Tests for the parallel map: order, the number of workers, failures, and
//// what it leaves behind. Catching a re-raised exception, process identity
//// and the mailbox go through `grice_test_ffi`. The tests that need two
//// items running at once are skipped on a VM with a single scheduler.

import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/set
import grice/internal/parallel

// Order

pub fn map_of_an_empty_list_is_empty_test() {
  assert parallel.map([], double) == []
}

pub fn map_of_one_item_test() {
  assert parallel.map([21], double) == [42]
}

pub fn map_keeps_input_order_with_more_items_than_schedulers_test() {
  let items = numbers(schedulers_online() * 3 + 1)
  // Later items take less time, so results arrive out of order.
  let uneven = fn(item) {
    sleep(2 - item % 3)
    double(item)
  }
  assert parallel.map(items, uneven) == list.map(items, double)
}

// Workers

pub fn map_uses_several_workers_up_to_the_schedulers_online_test() {
  let workers =
    numbers(200)
    |> parallel.map(fn(_) {
      sleep(1)
      self_pid()
    })
    |> set.from_list
    |> set.size
  assert workers <= schedulers_online()
  assert schedulers_online() == 1 || workers >= 2
}

// Failures

pub fn map_re_raises_a_panic_with_its_original_reason_test() {
  assert raised(fn() { parallel.map([1, 2, 3], panic_on_two) })
    == raised(fn() { panic_on_two(2) })
}

pub fn map_re_raises_every_class_with_its_reason_and_stack_test() {
  use name <- list.each(["error", "throw", "exit"])
  let raise_on_two = fn(item) {
    case item {
      2 -> raise_sentinel(name)
      _ -> item
    }
  }
  assert rescue(fn() { parallel.map([1, 2, 3], raise_on_two) })
    == Error(sentinel(name))
}

pub fn map_fails_when_a_worker_is_killed_holding_an_item_test() {
  assert raised(fn() { parallel.map([1, 2], fn(_) { kill_self() }) })
    == #(class("error"), worker_exit_killed())
}

pub fn map_fails_without_waiting_for_an_earlier_item_test() {
  use <- bool.guard(when: schedulers_online() < 2, return: Nil)
  // The first item never returns, so the map can only fail if it doesn't
  // wait for it.
  let block_on_one = fn(item) {
    case item {
      1 -> block()
      _ -> panic_on_two(item)
    }
  }
  assert raised(fn() { parallel.map([1, 2], block_on_one) })
    == raised(fn() { panic_on_two(2) })
}

// Lifetime

pub fn map_leaves_the_mailbox_as_it_found_it_test() {
  take_mailbox()
  send_self(dynamic.string("unrelated"))
  // A monitor of the caller's own, whose `DOWN` arrives during the calls.
  let down = monitor_exit_after(5)
  let slow_double = fn(item) {
    sleep(1)
    double(item)
  }
  list.each(numbers(20), fn(_) {
    assert parallel.map([1, 2, 3, 4], slow_double) == [2, 4, 6, 8]
    let assert Error(_) = rescue(fn() { parallel.map([1, 2, 3], panic_on_two) })
    let assert Error(_) =
      rescue(fn() { parallel.map([1, 2], fn(_) { kill_self() }) })
  })
  assert parallel.map([5], double) == [10]
  assert take_mailbox() == [dynamic.string("unrelated"), down]
}

pub fn map_workers_stop_when_the_caller_dies_test() {
  use <- bool.guard(when: schedulers_online() < 2, return: Nil)
  let #(idle_stopped, busy_running, busy_stopped) = caller_death(parallel.map)
  assert idle_stopped
  assert busy_running
  assert busy_stopped
}

// Helpers

type Pid

type Exception {
  Exception(class: Dynamic, reason: Dynamic, stack: Dynamic)
}

fn double(item: Int) -> Int {
  item * 2
}

fn panic_on_two(item: Int) -> Int {
  case item {
    2 -> panic as "item 2 failed"
    _ -> item
  }
}

// The class and reason of the exception `run` raises. The stack isn't
// compared, since a re-raised panic has the worker's frames.
fn raised(run: fn() -> a) -> #(Dynamic, Dynamic) {
  let assert Error(Exception(class:, reason:, ..)) = rescue(run)
    as "expected an exception"
  #(class, reason)
}

// The numbers from 0 up to `count`, exclusive.
fn numbers(count: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, count), fn(_, index) { index })
}

@external(erlang, "grice_test_ffi", "rescue")
fn rescue(run: fn() -> a) -> Result(a, Exception)

@external(erlang, "grice_test_ffi", "class")
fn class(name: String) -> Dynamic

@external(erlang, "grice_test_ffi", "raise_sentinel")
fn raise_sentinel(class: String) -> a

@external(erlang, "grice_test_ffi", "sentinel")
fn sentinel(class: String) -> Exception

@external(erlang, "grice_test_ffi", "self_pid")
fn self_pid() -> Pid

@external(erlang, "grice_test_ffi", "schedulers_online")
fn schedulers_online() -> Int

@external(erlang, "grice_test_ffi", "sleep")
fn sleep(milliseconds: Int) -> Nil

@external(erlang, "grice_test_ffi", "kill_self")
fn kill_self() -> a

@external(erlang, "grice_test_ffi", "block")
fn block() -> a

@external(erlang, "grice_test_ffi", "worker_exit_killed")
fn worker_exit_killed() -> Dynamic

@external(erlang, "grice_test_ffi", "take_mailbox")
fn take_mailbox() -> List(Dynamic)

@external(erlang, "grice_test_ffi", "send_self")
fn send_self(message: Dynamic) -> Nil

@external(erlang, "grice_test_ffi", "monitor_exit_after")
fn monitor_exit_after(milliseconds: Int) -> Dynamic

@external(erlang, "grice_test_ffi", "caller_death")
fn caller_death(
  map: fn(List(a), fn(a) -> Nil) -> List(Nil),
) -> #(Bool, Bool, Bool)
