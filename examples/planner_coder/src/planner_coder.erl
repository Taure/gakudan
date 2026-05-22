-module(planner_coder).
-moduledoc """
Driver for the 2-agent example.

Usage in a `rebar3 as example shell`:

```
1> application:ensure_all_started(gakudan).
2> planner_coder:run().                    %% real Anthropic, needs ANTHROPIC_API_KEY
3> planner_coder:run_stub().               %% offline, deterministic
```
""".

-export([run/0, run/1, run_stub/0]).

run() ->
    run(~"Write an Erlang function that returns the sum of a list of integers.").

run(Task) ->
    {ok, _Pid, RunId} = gakudan:start_run(#{
        agents => [planner, coder],
        router => {gakudan_router_handoff, #{start => planner}},
        llm => {gakudan_llm_anthropic, #{}},
        max_turns => 6
    }),
    ok = gakudan:send(RunId, Task),
    {ok, Entries} = gakudan:await(RunId, 90_000),
    print_transcript(Entries),
    gakudan:stop(RunId).

run_stub() ->
    {ok, ScriptPid} = gakudan_llm_stub_script:start_link([
        {text,
            ~"""
            1. Write a function `sum_list/1` that takes a list of integers.
            2. Use pattern matching on the empty list base case.
            3. Recursive case adds head to sum_list of tail.
            @coder, please implement step 1.
            """},
        {tool_use, ~"write_snippet", #{
            ~"filename" => ~"sum_list.erl",
            ~"content" =>
                ~"""
                -module(sum_list).
                -export([sum_list/1]).
                sum_list([]) -> 0;
                sum_list([H | T]) -> H + sum_list(T).
                """
        }},
        {text, ~"Implemented sum_list/1 with a base case and recursive sum. done"}
    ]),
    {ok, _Pid, RunId} = gakudan:start_run(#{
        agents => [planner, coder],
        router => {gakudan_router_handoff, #{start => planner}},
        llm => {gakudan_llm_stub, #{script_owner => ScriptPid}},
        max_turns => 6
    }),
    ok = gakudan:send(RunId, ~"Sum a list of integers."),
    {ok, Entries} = gakudan:await(RunId, 5_000),
    print_transcript(Entries),
    gakudan:stop(RunId),
    gen_server:stop(ScriptPid).

print_transcript(Entries) ->
    io:format("~n=== transcript ===~n"),
    lists:foreach(
        fun(#{role := Role, content := C}) ->
            Who =
                case Role of
                    user -> ~"user";
                    system -> ~"system";
                    {agent, A} -> atom_to_binary(A)
                end,
            io:format("[~s]~n~s~n~n", [Who, C])
        end,
        Entries
    ).
