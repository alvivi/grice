%% A clean sample of needlessly-public-function: Erlang that calls a
%% function of `referenced` by the module's Erlang name. Nothing runs it.
-module(needlessly_public_function_ffi).

-export([call/0]).

call() ->
    'grice@internal@rules@samples@referenced':from_erlang().
