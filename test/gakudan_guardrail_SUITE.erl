-module(gakudan_guardrail_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([output_block/1, output_transform/1, input_block/1]).

all() ->
    [output_block, output_transform, input_block].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

output_block(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"leak SECRET data"}]),
    {ok, _Sup, RunId} = start_run(Script, [{test_guardrail_mod, #{block => ~"SECRET"}}]),
    ok = gakudan:send(RunId, ~"go"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    %% The output was blocked, so no agent entry leaks the secret...
    false = lists:any(
        fun(T) -> binary:match(T, ~"SECRET") =/= nomatch end,
        agent_texts(Entries)
    ),
    %% ...and a system entry records the block.
    true = has_system_match(Entries, ~"output blocked"),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

output_transform(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    {ok, _Sup, RunId} = start_run(Script, [{test_guardrail_mod, #{replace => ~"[redacted]"}}]),
    ok = gakudan:send(RunId, ~"go"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    true = lists:member(~"[redacted]", agent_texts(Entries)),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

input_block(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"should not appear"}]),
    {ok, _Sup, RunId} = start_run(Script, [{test_guardrail_mod, #{block_input => ~"forbidden"}}]),
    ok = gakudan:send(RunId, ~"this is forbidden"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    %% Input was blocked before the LLM call: no agent output at all.
    [] = agent_texts(Entries),
    true = has_system_match(Entries, ~"input blocked"),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

start_run(Script, Guardrails) ->
    gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2,
        guardrails => Guardrails
    }).

agent_texts(Entries) ->
    [maps:get(content, E) || E <- Entries, is_agent(maps:get(role, E))].

is_agent({agent, _}) -> true;
is_agent(_) -> false.

has_system_match(Entries, Substr) ->
    lists:any(
        fun(E) ->
            maps:get(role, E) =:= system andalso
                binary:match(maps:get(content, E), Substr) =/= nomatch
        end,
        Entries
    ).
