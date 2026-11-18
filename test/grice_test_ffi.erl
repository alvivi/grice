%% What the tests need from Erlang that Gleam can't express: reading a
%% panic's message, a counter, running a program, work done once per
%% runtime and the runtime's name, and for the Erlang-only tests, catching
%% an exception, process identity, timing and the mailbox.
-module(grice_test_ffi).

-export([panic_message/1, new_counter/0, increment/1, count/1, run_gleam/3,
         once/2, runtime/0, rescue/1, class/1, raise_sentinel/1, sentinel/1,
         self_pid/0, schedulers_online/0, sleep/1, kill_self/0, block/0,
         worker_exit_killed/0, take_mailbox/0, send_self/1,
         monitor_exit_after/1, caller_death/1]).

%% `{ok, Message}' when `Run' raises a Gleam `panic' with the message
%% `Message', and `{error, nil}' when it raises anything else or returns.
panic_message(Run) ->
    try Run() of
        _ -> {error, nil}
    catch
        error:#{gleam_error := panic, message := Message} -> {ok, Message};
        _:_ -> {error, nil}
    end.

%% A counter every process can add to, for counting calls made anywhere.
new_counter() ->
    counters:new(1, []).

increment(Counter) ->
    counters:add(Counter, 1, 1),
    counters:get(Counter, 1).

count(Counter) ->
    counters:get(Counter, 1).

%% Run the `gleam' on `PATH' with `Arguments' in `Directory', and return
%% `{ok, {ExitStatus, Stdout, Stderr}}', or `{error, Reason}' when there's
%% no `gleam'. A port reads only standard output, so `/bin/sh' sends
%% standard error to `StderrFile', read once the program exits.
run_gleam(Directory, Arguments, StderrFile) ->
    case os:find_executable("gleam") of
        false ->
            {error, <<"There's no gleam executable on PATH.">>};
        Gleam ->
            Script = "exec \"$0\" \"$@\" 2>\"$GRICE_TEST_STDERR\"",
            Port = open_port(
                {spawn_executable, "/bin/sh"},
                [{args, ["-c", Script, Gleam
                         | [binary_to_list(A) || A <- Arguments]]},
                 {cd, binary_to_list(Directory)},
                 {env, [{"GRICE_TEST_STDERR", binary_to_list(StderrFile)}]},
                 exit_status, binary, use_stdio, hide]
            ),
            {Status, Stdout} = collect(Port, []),
            {ok, Stderr} = file:read_file(StderrFile),
            {ok, {Status, Stdout, Stderr}}
    end.

collect(Port, Chunks) ->
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Chunks]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Chunks))}
    end.

%% Call `F' the first time `once' is called with `Key' in this runtime, and
%% do nothing after that.
once(Key, F) ->
    Flag = {grice_test_once, Key},
    case persistent_term:get(Flag, false) of
        true -> nil;
        false ->
            F(),
            persistent_term:put(Flag, true),
            nil
    end.

%% The runtime, such as `<<"OTP 28">>'.
runtime() ->
    Release = list_to_binary(erlang:system_info(otp_release)),
    <<"OTP ", Release/binary>>.

%% Erlang only
%%
%% What only the Erlang-only tests use.

%% `{ok, Result}' when `F' returns, and `{error, {exception, Class, Reason,
%% Stack}}' when it raises an exception of any class.
rescue(F) ->
    try {ok, F()}
    catch Class:Reason:Stack -> {error, {exception, Class, Reason, Stack}}
    end.

%% The class named `Name': `error', `throw' or `exit'.
class(Name) ->
    binary_to_existing_atom(Name).

%% Raise an exception of class `Name' with a reason and a stack that no
%% other code makes.
raise_sentinel(Name) ->
    erlang:raise(class(Name), sentinel_reason(Name), sentinel_stack()).

%% The exception `raise_sentinel(Name)' raises, as `rescue' returns it.
sentinel(Name) ->
    {exception, class(Name), sentinel_reason(Name), sentinel_stack()}.

sentinel_reason(Name) ->
    {grice_test_sentinel, Name}.

sentinel_stack() ->
    [{grice_test_ffi, sentinel, 0, [{file, "sentinel.erl"}, {line, 1}]}].

self_pid() ->
    self().

schedulers_online() ->
    erlang:system_info(schedulers_online).

sleep(Milliseconds) ->
    timer:sleep(Milliseconds),
    nil.

kill_self() ->
    exit(self(), kill).

block() ->
    receive after infinity -> nil end.

worker_exit_killed() ->
    {grice_worker_exit, killed}.

%% Every message in the mailbox, oldest first, removed from it.
take_mailbox() ->
    receive Message -> [Message | take_mailbox()]
    after 0 -> []
    end.

send_self(Message) ->
    self() ! Message,
    nil.

%% Monitor a process that exits after `Milliseconds', and return the `DOWN'
%% message that will arrive.
monitor_exit_after(Milliseconds) ->
    {Pid, Monitor} = spawn_monitor(fun() ->
        timer:sleep(Milliseconds),
        exit(unrelated)
    end),
    {'DOWN', Monitor, process, Pid, unrelated}.

%% Run `Map' over two items in a process that is killed while one worker is
%% idle and the other is busy. The first item waits until the second has
%% started, so each runs on its own worker. Returns whether the idle worker
%% stopped, whether the busy one was still running, and whether it stopped
%% once its item returned.
caller_death(Map) ->
    Test = self(),
    Caller = spawn(fun() ->
        Map([first, second], fun
            (first) -> Test ! {first, self()}, receive go -> nil end;
            (second) -> Test ! {second, self()}, receive release -> nil end
        end)
    end),
    Busy = receive {second, SecondWorker} -> SecondWorker end,
    Idle = receive {first, FirstWorker} -> FirstWorker end,
    IdleMonitor = monitor(process, Idle),
    BusyMonitor = monitor(process, Busy),
    Idle ! go,
    await_idle(Idle),
    exit(Caller, kill),
    IdleStopped = await_down(IdleMonitor),
    BusyRunning = is_process_alive(Busy),
    Busy ! release,
    {IdleStopped, BusyRunning, await_down(BusyMonitor)}.

%% Wait until a worker has returned its item and waits for another.
await_idle(Worker) ->
    case process_info(Worker, [current_function, status]) of
        [{current_function, {grice_ffi, work, 4}}, {status, waiting}] -> ok;
        _ -> timer:sleep(1), await_idle(Worker)
    end.

await_down(Monitor) ->
    receive {'DOWN', Monitor, process, _, _} -> true
    after 1000 -> false
    end.
