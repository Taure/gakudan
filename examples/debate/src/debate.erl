-module(debate).
-moduledoc """
Driver for the debate example: proponent argues FOR, opponent argues AGAINST,
synthesiser summarises and recommends.

Usage in a `rebar3 as example shell`:

```
1> application:ensure_all_started(gakudan).
2> debate:run(~"Should gakudan eval cases support JSON in v0.2?").
3> debate:run_stub().     %% offline, deterministic, two rounds of canned text
4> {ok, Report} = debate:eval_stub(), maps:get(failed, Report).
```
""".

-export([run/1, run_stub/0, eval_stub/0]).

-define(ROUTER_OPTS, #{
    rounds => 2,
    debaters => [proponent, opponent],
    synthesiser => synthesiser
}).

run(Question) ->
    {ok, _Pid, RunId} = gakudan:start_run(#{
        agents => [proponent, opponent, synthesiser],
        router => {debate_router, ?ROUTER_OPTS},
        llm => {gakudan_llm_anthropic, #{}},
        max_turns => 8
    }),
    ok = gakudan:send(RunId, Question),
    {ok, Entries} = gakudan:await(RunId, 120_000),
    print_transcript(Entries),
    gakudan:stop(RunId).

run_stub() ->
    {ok, ScriptPid} = gakudan_llm_stub_script:start_link(stub_script()),
    {ok, _Pid, RunId} = gakudan:start_run(#{
        agents => [proponent, opponent, synthesiser],
        router => {debate_router, ?ROUTER_OPTS},
        llm => {gakudan_llm_stub, #{script_owner => ScriptPid}},
        max_turns => 8
    }),
    ok = gakudan:send(RunId, ~"Should gakudan eval cases support JSON in v0.2?"),
    {ok, Entries} = gakudan:await(RunId, 5_000),
    print_transcript(Entries),
    gakudan:stop(RunId),
    gen_server:stop(ScriptPid).

eval_stub() ->
    gakudan_eval:run(#{
        name => debate_v0_2_json,
        config => #{
            agents => [proponent, opponent, synthesiser],
            router => {debate_router, ?ROUTER_OPTS},
            max_turns => 8
        },
        script => stub_script(),
        input => ~"Should gakudan eval cases support JSON in v0.2?",
        expect => [
            {outcome, idle},
            {min_turns, 5},
            {agent_turn_count, proponent, 2},
            {agent_turn_count, opponent, 2},
            {agent_turn_count, synthesiser, 1},
            {agent_turn_contains, proponent, ~"FOR"},
            {agent_turn_contains, opponent, ~"AGAINST"},
            {agent_turn_contains, synthesiser, ~"Recommendation"},
            no_failed_turns
        ]
    }).

stub_script() ->
    [
        {text, ~"FOR: JSON cases let non-Erlang teams author evals. A Python team can dump replay logs as JSON without ever touching rebar3."},
        {text, ~"AGAINST: JSON loses Erlang's pattern-match expressiveness in expectations. You end up re-inventing a poor cousin of Erlang term syntax."},
        {text, ~"FOR (continued): A JSON schema is testable independently of any BEAM toolchain. Doc-as-test becomes a thing for free."},
        {text, ~"AGAINST (continued): Tooling cost is real. JSON parsing, schema validation, version migration. Maintenance debt the project has not earned yet."},
        {text,
            ~"""
            Strongest points
            - FOR: non-BEAM contributors; schema is independently testable.
            - AGAINST: Erlang terms keep matcher expressiveness; tooling debt is concrete.

            Crux: who actually authors eval cases? If only BEAM devs, stay Erlang-term. If non-BEAM contributors are expected, JSON.

            Recommendation: hold off on JSON until a real non-BEAM contributor wants to author a case. Not yet earned.
            """}
    ].

print_transcript(Entries) ->
    io:format("~n=== debate ===~n"),
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
