-module(gakudan_budget_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    max_llm_calls_stops_run/1,
    max_tokens_stops_run/1,
    cache_tokens_counted/1,
    default_budget_env_stops_run/1,
    custom_budget_module_stops_run/1,
    no_budget_completes/1
]).

all() ->
    [
        max_llm_calls_stops_run,
        max_tokens_stops_run,
        cache_tokens_counted,
        default_budget_env_stops_run,
        custom_budget_module_stops_run,
        no_budget_completes
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

max_llm_calls_stops_run(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"one"}, {text, ~"two"}]),
    Reason = run_until_budget(Script, #{}, {gakudan_budget_limit, #{max_llm_calls => 1}}),
    {max_llm_calls, 1} = Reason,
    gen_server:stop(Script).

max_tokens_stops_run(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"a"}, {text, ~"b"}]),
    %% 100 tokens per call; the cap is hit at the dispatch check after turn 1.
    Usage = #{input_tokens => 60, output_tokens => 40},
    Reason = run_until_budget(
        Script, #{usage => Usage}, {gakudan_budget_limit, #{max_tokens => 100}}
    ),
    {max_tokens, 100} = Reason,
    gen_server:stop(Script).

cache_tokens_counted(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"a"}, {text, ~"b"}]),
    %% 10 plain input + 90 cache-read input = 100 tokens_in; the cap counts both.
    Usage = #{input_tokens => 10, cache_read_input_tokens => 90, output_tokens => 0},
    Reason = run_until_budget(
        Script, #{usage => Usage}, {gakudan_budget_limit, #{max_tokens => 100}}
    ),
    {max_tokens, 100} = Reason,
    gen_server:stop(Script).

default_budget_env_stops_run(_Config) ->
    ok = application:set_env(
        gakudan, default_budget, {gakudan_budget_limit, #{max_llm_calls => 1}}
    ),
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"a"}, {text, ~"b"}]),
    try
        {max_llm_calls, 1} = run_until_budget(Script, #{}, none)
    after
        application:unset_env(gakudan, default_budget),
        gen_server:stop(Script)
    end.

custom_budget_module_stops_run(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"x"}, {text, ~"y"}]),
    Reason = run_until_budget(Script, #{}, {test_budget_mod, #{deny_after => 1}}),
    {turns_over, 1} = Reason,
    gen_server:stop(Script).

no_budget_completes(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    true = lists:member(~"hello", agent_texts(Entries)),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

%% Start a run with the given budget, drive it, and return the inner deny
%% reason carried by the [gakudan, budget, exceeded] telemetry event.
run_until_budget(Script, ExtraLlmOpts, Budget) ->
    Handler = make_ref(),
    Self = self(),
    ok = telemetry:attach(
        Handler,
        [gakudan, budget, exceeded],
        fun(_Event, _Measurements, Meta, _) -> Self ! {budget_exceeded, Meta} end,
        undefined
    ),
    LlmOpts = maps:merge(#{script_owner => Script}, ExtraLlmOpts),
    BudgetCfg =
        case Budget of
            none -> #{};
            _ -> #{budget => Budget}
        end,
    {ok, _Sup, RunId} = gakudan:start_run(
        maps:merge(
            #{
                agents => [agent_a_mod],
                router => {gakudan_router_round_robin, #{}},
                llm => {gakudan_llm_stub, LlmOpts},
                max_turns => 10
            },
            BudgetCfg
        )
    ),
    ok = gakudan:send(RunId, ~"go"),
    Reason =
        receive
            {budget_exceeded, Meta} -> maps:get(reason, Meta)
        after 5000 ->
            telemetry:detach(Handler),
            ct:fail(no_budget_event)
        end,
    telemetry:detach(Handler),
    Reason.

agent_texts(Entries) ->
    [maps:get(content, E) || E <- Entries, is_agent(maps:get(role, E))].

is_agent({agent, _}) -> true;
is_agent(_) -> false.
