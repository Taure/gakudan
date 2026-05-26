-module(gakudan_audit_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    lifecycle_recorded/1,
    actor_attribution/1,
    interrupt_resume_recorded/1,
    guardrail_transform_recorded/1,
    guardrail_block_recorded/1,
    fail_closed_fails_turn/1,
    log_policy_continues/1
]).

all() ->
    [
        lifecycle_recorded,
        actor_attribution,
        interrupt_resume_recorded,
        guardrail_transform_recorded,
        guardrail_block_recorded,
        fail_closed_fails_turn,
        log_policy_continues
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    [{sink, gakudan_audit_ets:new()} | Config].

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

init_per_testcase(_Name, Config) ->
    ok = gakudan_audit_ets:reset(sink(Config)),
    Config.

end_per_testcase(_Name, _Config) ->
    ok.

lifecycle_recorded(Config) ->
    Sink = sink(Config),
    {Script, RunId} = start_basic(Sink, #{}),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    #{detail := #{mode := fresh}} = find_event(Sink, RunId, run_started),
    ok = gakudan:stop(RunId),
    ok = wait_for_type(Sink, RunId, run_stopped, 50),
    gen_server:stop(Script).

actor_attribution(Config) ->
    Sink = sink(Config),
    Actor = #{id => ~"u_1", tenant => ~"team_payments"},
    {Script, RunId} = start_basic(Sink, Actor),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    #{actor := #{id := ~"u_1", tenant := ~"team_payments"}} =
        find_event(Sink, RunId, run_started),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

interrupt_resume_recorded(Config) ->
    Sink = sink(Config),
    {Script, RunId} = start_basic(Sink, #{id => ~"u_2"}),
    ok = gakudan:interrupt(RunId, ~"need approval"),
    ok = wait_for_type(Sink, RunId, run_interrupted, 50),
    ok = gakudan:resume(RunId, ~"approved"),
    ok = wait_for_type(Sink, RunId, run_resumed, 50),
    #{detail := #{reason := ~"need approval"}} = find_event(Sink, RunId, run_interrupted),
    #{detail := #{mode := human}} = find_event(Sink, RunId, run_resumed),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

guardrail_transform_recorded(Config) ->
    Sink = sink(Config),
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    RunId = start_guarded(Sink, Script, [{test_guardrail_mod, #{replace => ~"[redacted]"}}]),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    Types = types_of(gakudan_audit_ets:events(Sink, RunId)),
    true = lists:member(guardrail_allow, Types),
    true = lists:member(guardrail_transform, Types),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

guardrail_block_recorded(Config) ->
    Sink = sink(Config),
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"leak SECRET data"}]),
    RunId = start_guarded(Sink, Script, [{test_guardrail_mod, #{block => ~"SECRET"}}]),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    #{detail := #{guardrail := test_guardrail_mod, stage := output, reason := blocked_content}} =
        find_event(Sink, RunId, guardrail_block),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

fail_closed_fails_turn(Config) ->
    Sink = (sink(Config))#{
        on_error => fail_closed,
        fail_types => [guardrail_allow, guardrail_transform, guardrail_block]
    },
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    RunId = start_guarded(Sink, Script, [{test_guardrail_mod, #{replace => ~"x"}}]),
    ok = gakudan:send(RunId, ~"go"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    %% The guardrail audit write fails closed, so the turn worker raises:
    %% no agent text is produced and the failure is recorded in the transcript.
    [] = agent_texts(Entries),
    true = has_system_match(Entries, ~"turn"),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

log_policy_continues(Config) ->
    Sink = (sink(Config))#{fail => true},
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1,
        audit => {gakudan_audit_ets, Sink}
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, Entries} = gakudan:await(RunId, 5000),
    %% on_error defaults to log: every write fails but the run completes.
    true = lists:member(~"hello", agent_texts(Entries)),
    [] = gakudan_audit_ets:events(Sink, RunId),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

start_basic(Sink, Actor) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"hello"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1,
        actor => Actor,
        audit => {gakudan_audit_ets, Sink}
    }),
    {Script, RunId}.

start_guarded(Sink, Script, Guardrails) ->
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1,
        guardrails => Guardrails,
        audit => {gakudan_audit_ets, Sink}
    }),
    RunId.

sink(Config) ->
    proplists:get_value(sink, Config).

types_of(Events) ->
    [maps:get(type, E) || E <- Events].

find_event(Sink, RunId, Type) ->
    case [E || E <- gakudan_audit_ets:events(Sink, RunId), maps:get(type, E) =:= Type] of
        [E | _] -> E;
        [] -> ct:fail({no_event, Type})
    end.

wait_for_type(Sink, RunId, Type, N) when N > 0 ->
    case [E || E <- gakudan_audit_ets:events(Sink, RunId), maps:get(type, E) =:= Type] of
        [_ | _] ->
            ok;
        [] ->
            timer:sleep(20),
            wait_for_type(Sink, RunId, Type, N - 1)
    end;
wait_for_type(_Sink, _RunId, Type, 0) ->
    ct:fail({timeout_waiting_for, Type}).

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
