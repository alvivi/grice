%% Erlang code behind grice's `@external` functions.
-module(grice_ffi).

-export([parallel_map/2, variable/1, stdout_is_terminal/0, milliseconds/0,
         reductions/0, exit/1, counts_code_units/0, foreign_words/1]).

%% Parallel map
%%
%% The calling process hands items to at most `schedulers_online' workers,
%% one at a time as each asks for more, and puts the results back in input
%% order. Every message of a call carries a reference made for that call,
%% and the caller only receives messages with that reference and `DOWN'
%% messages for its own workers, so nothing else in its mailbox is touched.
%%
%% A worker catches what its item raises and sends it back, and the caller
%% re-raises it unchanged. A worker that dies while it holds an item, or
%% while it's idle and hasn't been told to stop, fails the map with
%% `{grice_worker_exit, Reason}'. Before returning or raising, the caller
%% stops its workers (kills them on failure), waits for each one's `DOWN',
%% and then drops every message of the call still in its mailbox: a
%% process's messages arrive before its `DOWN', so none can come later.
%% Workers monitor the caller and exit if it dies.

parallel_map([], _F) ->
    [];
parallel_map(Items, F) ->
    Ref = make_ref(),
    Caller = self(),
    Length = length(Items),
    Count = min(erlang:system_info(schedulers_online), Length),
    Workers = maps:from_list(
        [spawn_monitor(fun() -> worker(Caller, Ref, F) end)
         || _ <- lists:seq(1, Count)]
    ),
    coordinate(Ref, Workers, lists:enumerate(Items), Length, []).

%% Each queued item carries its index, which comes back with its result.
%% `Left' counts the results still to come, and `Done' holds
%% `{Index, Result}' pairs. A worker that goes down fails the map whether
%% or not it holds an item, so nothing records which one it holds.
coordinate(Ref, Workers, _Queue, 0, Done) ->
    stop(Ref, Workers),
    [Result || {_, Result} <- lists:keysort(1, Done)];
coordinate(Ref, Workers, Queue, Left, Done) ->
    receive
        {Ref, ready, Worker} ->
            coordinate(Ref, Workers, dispatch(Ref, Worker, Queue), Left, Done);
        {Ref, done, Worker, Index, Result} ->
            coordinate(Ref, Workers, dispatch(Ref, Worker, Queue), Left - 1,
                       [{Index, Result} | Done]);
        {Ref, failed, _Worker, Class, Reason, Stack} ->
            kill(Ref, Workers),
            erlang:raise(Class, Reason, Stack);
        {'DOWN', Monitor, process, Worker, Reason}
          when map_get(Worker, Workers) =:= Monitor ->
            kill(Ref, maps:remove(Worker, Workers)),
            erlang:error({grice_worker_exit, Reason})
    end.

%% Give the worker the next item, or leave it idle when there's none.
dispatch(Ref, Worker, [{Index, Item} | Queue]) ->
    Worker ! {Ref, item, Index, Item},
    Queue;
dispatch(_Ref, _Worker, []) ->
    [].

stop(Ref, Workers) ->
    maps:foreach(fun(Worker, _) -> Worker ! {Ref, stop} end, Workers),
    clean_up(Ref, Workers).

kill(Ref, Workers) ->
    maps:foreach(fun(Worker, _) -> exit(Worker, kill) end, Workers),
    clean_up(Ref, Workers).

clean_up(Ref, Workers) ->
    maps:foreach(
        fun(Worker, Monitor) ->
            receive {'DOWN', Monitor, process, Worker, _} -> ok end
        end,
        Workers
    ),
    flush(Ref).

flush(Ref) ->
    receive
        Message when element(1, Message) =:= Ref -> flush(Ref)
    after 0 -> ok
    end.

worker(Caller, Ref, F) ->
    Monitor = monitor(process, Caller),
    Caller ! {Ref, ready, self()},
    work(Caller, Ref, Monitor, F).

work(Caller, Ref, Monitor, F) ->
    receive
        {Ref, item, Index, Item} ->
            Reply =
                try F(Item) of
                    Result -> {Ref, done, self(), Index, Result}
                catch
                    Class:Reason:Stack ->
                        {Ref, failed, self(), Class, Reason, Stack}
                end,
            Caller ! Reply,
            work(Caller, Ref, Monitor, F);
        {Ref, stop} ->
            ok;
        {'DOWN', Monitor, process, Caller, _} ->
            ok
    end.

%% Platform
%%
%% What a run needs from the runtime, for `grice/internal/platform'.

%% `{ok, Value}' when the variable is set, `{error, nil}' when it isn't.
variable(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% `io:getopts' has `{stdout, true}' only when standard output is a
%% terminal. Without the key, as before OTP 26, it isn't one.
stdout_is_terminal() ->
    case io:getopts(standard_io) of
        Options when is_list(Options) ->
            lists:keyfind(stdout, 1, Options) =:= {stdout, true};
        _ ->
            false
    end.

%% The monotonic clock, in milliseconds.
milliseconds() ->
    erlang:monotonic_time(millisecond).

%% `{ok, Reductions}': the total reductions of every process,
%% `parallel_map''s workers included.
reductions() ->
    {Reductions, _} = erlang:statistics(exact_reductions),
    {ok, Reductions}.

%% `halt/1' flushes standard output and standard error before the runtime
%% stops.
exit(Code) ->
    erlang:halt(Code).

%% Syntax trees
%%
%% What glance's offsets count, for `grice/internal/line_index'.

%% glexer counts bytes on Erlang.
counts_code_units() ->
    false.

%% Foreign sources
%%
%% The words of a foreign source, for `grice/internal/loader', split by the
%% runtime rather than byte by byte in Gleam: a source is often as large as
%% the project's Gleam code.

%% `{Words, Names}': each longest run of ASCII letters, digits, `_' and `@'
%% in the bytes of `Source', and each such run that `.mjs' follows, each
%% once. Any other byte ends a run, whatever the source's encoding.
foreign_words(Source) ->
    Separators = [<<Byte>> || Byte <- lists:seq(0, 255), not is_word_byte(Byte)],
    Words = binary:split(Source, binary:compile_pattern(Separators),
                         [global, trim_all]),
    Names = [Name || {Position, _} <- binary:matches(Source, <<".mjs">>),
                     Name <- [word_before(Source, Position, Position)],
                     Name =/= <<>>],
    {unique(Words), unique(Names)}.

%% Each item once, in no particular order: a map's keys, which is cheaper
%% than sorting a list that still holds every repeated word.
unique(Items) ->
    maps:keys(maps:from_keys(Items, [])).

%% The run of word bytes that ends at `End', found by walking back from it.
word_before(Source, Start, End) when Start > 0 ->
    case is_word_byte(binary:at(Source, Start - 1)) of
        true -> word_before(Source, Start - 1, End);
        false -> binary:part(Source, Start, End - Start)
    end;
word_before(Source, Start, End) ->
    binary:part(Source, Start, End - Start).

is_word_byte(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse (Byte >= $A andalso Byte =< $Z)
        orelse (Byte >= $0 andalso Byte =< $9) orelse Byte =:= $_
        orelse Byte =:= $@.
