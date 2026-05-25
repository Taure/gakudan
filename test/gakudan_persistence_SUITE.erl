-module(gakudan_persistence_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    snapshot_round_trip/1,
    list_active_returns_running_runs/1,
    step_record_round_trip/1,
    interrupt_then_resume/1,
    initial_messages_populate_blackboard/1,
    snapshot_persists_through_lifecycle/1
]).

all() ->
    [
        snapshot_round_trip,
        list_active_returns_running_runs,
        step_record_round_trip,
        interrupt_then_resume,
        initial_messages_populate_blackboard,
        snapshot_persists_through_lifecycle
    ].

init_per_suite(Config) ->
    Backend = gakudan_checkpointer_ets:new(),
    application:set_env(gakudan, default_checkpointer, {gakudan_checkpointer_ets, Backend}),
    {ok, _} = application:ensure_all_started(gakudan),
    [{backend, Backend} | Config].

end_per_suite(_Config) ->
    application:stop(gakudan),
    ok.

init_per_testcase(_Name, Config) ->
    Backend = proplists:get_value(backend, Config),
    ok = gakudan_checkpointer_ets:reset(Backend),
    Config.

end_per_testcase(_Name, _Config) ->
    ok.

snapshot_round_trip(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    RunId = ~"run-rt-1",
    Snapshot = base_snapshot(RunId, idle),
    ok = gakudan_checkpointer:save_snapshot(Handle, Snapshot),
    {ok, Loaded} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    RunId = maps:get(run_id, Loaded),
    idle = maps:get(status, Loaded),
    ok = gakudan_checkpointer:delete_run(Handle, RunId),
    {error, not_found} = gakudan_checkpointer:load_snapshot(Handle, RunId).

list_active_returns_running_runs(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    ok = gakudan_checkpointer:save_snapshot(Handle, base_snapshot(~"a-1", running)),
    ok = gakudan_checkpointer:save_snapshot(Handle, base_snapshot(~"a-2", awaiting_human)),
    ok = gakudan_checkpointer:save_snapshot(Handle, base_snapshot(~"a-3", completed)),
    {ok, Active} = gakudan_checkpointer:list_active(Handle),
    true = lists:member(~"a-1", Active),
    true = lists:member(~"a-2", Active),
    false = lists:member(~"a-3", Active).

step_record_round_trip(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    Step = #{
        run_id => ~"run-step-1",
        step_id => ~"step-aaa",
        agent_id => agent_a,
        turn => 1,
        request => #{model => ~"m"},
        response => #{stop_reason => end_turn, usage => #{input_tokens => 5, output_tokens => 7}},
        usage => #{input_tokens => 5, output_tokens => 7},
        inserted_at => erlang:system_time(millisecond)
    },
    ok = gakudan_checkpointer:save_step(Handle, Step),
    {ok, Loaded} = gakudan_checkpointer:load_step(Handle, ~"run-step-1", ~"step-aaa"),
    ~"step-aaa" = maps:get(step_id, Loaded),
    agent_a = maps:get(agent_id, Loaded),
    1 = maps:get(turn, Loaded).

interrupt_then_resume(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"first"}, {text, ~"second"}, {text, ~"third"}, {text, ~"fourth"}
    ]),
    {ok, _Sup, RunId} = start_run(Script, 8),
    ok = gakudan:send(RunId, ~"begin"),
    {ok, _} = gakudan:await(RunId, 5000),
    ok = gakudan:interrupt(RunId, ~"hold"),
    {ok, awaiting_human} = gakudan:status(RunId),
    {ok, BB} = gakudan_run:blackboard(RunId),
    Entries = gakudan_blackboard:entries(BB),
    true = lists:any(
        fun
            (#{role := system, content := C}) ->
                binary:match(C, ~"interrupted: hold") =/= nomatch;
            (_) ->
                false
        end,
        Entries
    ),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

initial_messages_populate_blackboard(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2,
        initial_messages => [
            #{role => system, content => ~"context blob A"},
            #{role => system, content => ~"context blob B"}
        ]
    }),
    {ok, BB} = gakudan_run:blackboard(RunId),
    Entries = gakudan_blackboard:entries(BB),
    SystemTexts = [maps:get(content, E) || E <- Entries, maps:get(role, E) =:= system],
    true = lists:member(~"context blob A", SystemTexts),
    true = lists:member(~"context blob B", SystemTexts),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

snapshot_persists_through_lifecycle(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"first"}, {text, ~"second"}, {text, ~"third"}, {text, ~"fourth"}
    ]),
    {ok, _Sup, RunId} = start_run(Script, 8),
    ok = gakudan:send(RunId, ~"begin"),
    {ok, _} = gakudan:await(RunId, 5000),
    ok = gakudan:interrupt(RunId, ~"hold"),
    {ok, awaiting_human} = gakudan:status(RunId),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    {ok, Snap} = gakudan_checkpointer:load_snapshot(Handle, RunId),
    awaiting_human = maps:get(status, Snap),
    Entries = maps:get(blackboard, Snap),
    true = length(Entries) >= 2.

start_run(Script, MaxTurns) ->
    gakudan:start_run(#{
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => MaxTurns
    }).

base_snapshot(RunId, Status) ->
    #{
        run_id => RunId,
        status => Status,
        config => #{
            run_id => RunId,
            agents => [agent_a_mod],
            router => {gakudan_router_round_robin, #{}},
            llm => {gakudan_llm_stub, #{}}
        },
        last_step => 0,
        blackboard => [],
        kv => #{},
        router_state => undefined,
        statem_state => Status,
        turn => 0,
        updated_at => erlang:system_time(millisecond)
    }.
