-module(gakudan_persistence_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1, init_per_testcase/2, end_per_testcase/2]).
-export([
    snapshot_round_trip/1,
    list_active_returns_running_runs/1,
    step_record_round_trip/1,
    interrupt_then_resume/1,
    initial_messages_populate_blackboard/1,
    snapshot_persists_through_lifecycle/1,
    tool_result_round_trip/1,
    tool_not_re_executed_on_replay/1,
    supervised_restart_restores_run/1,
    auto_continues_running_fanout_on_resume/1
]).

all() ->
    [
        snapshot_round_trip,
        list_active_returns_running_runs,
        step_record_round_trip,
        interrupt_then_resume,
        initial_messages_populate_blackboard,
        snapshot_persists_through_lifecycle,
        tool_result_round_trip,
        tool_not_re_executed_on_replay,
        supervised_restart_restores_run,
        auto_continues_running_fanout_on_resume
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

tool_result_round_trip(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    Rec = #{
        run_id => ~"run-tr-1",
        tool_step_id => ~"ts-aaa",
        agent_id => agent_a,
        turn => 1,
        tool_name => ~"echo_tool",
        output => ~"hello",
        inserted_at => erlang:system_time(millisecond)
    },
    ok = gakudan_checkpointer:save_tool_result(Handle, Rec),
    {ok, Loaded} = gakudan_checkpointer:load_tool_result(Handle, ~"run-tr-1", ~"ts-aaa"),
    ~"ts-aaa" = maps:get(tool_step_id, Loaded),
    ~"hello" = maps:get(output, Loaded),
    {error, not_found} = gakudan_checkpointer:load_tool_result(Handle, ~"run-tr-1", ~"missing").

tool_not_re_executed_on_replay(Config) ->
    Backend = proplists:get_value(backend, Config),
    {ok, Handle} = gakudan_checkpointer:init(gakudan_checkpointer_ets, Backend),
    ok = counter_tool_mod:reset(),
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, ~"counter_tool", #{}},
        {text, ~"done"}
    ]),
    LOpts = #{script_owner => Script},
    RunId = ~"run-tool-idem",

    {ok, BB1} = gakudan_blackboard:start_link(RunId),
    ok = gakudan_turn:run(
        RunId,
        counter_agent,
        agent_with_counter_mod,
        1,
        Handle,
        gakudan_llm_stub,
        LOpts,
        BB1,
        undefined
    ),
    1 = counter_tool_mod:count(),

    %% Replay the same turn. The LLM step and the tool result are both
    %% cached, so the tool must not run a second time.
    {ok, BB2} = gakudan_blackboard:start_link(RunId),
    ok = gakudan_turn:run(
        RunId,
        counter_agent,
        agent_with_counter_mod,
        1,
        Handle,
        gakudan_llm_stub,
        LOpts,
        BB2,
        undefined
    ),
    1 = counter_tool_mod:count(),

    gen_server:stop(Script).

supervised_restart_restores_run(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {text, ~"alpha"}, {text, ~"beta"}, {text, ~"gamma"}, {text, ~"delta"}
    ]),
    {ok, _Sup, RunId} = start_run(Script, 8),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    {ok, BB0} = gakudan_run:blackboard(RunId),
    Before = length(gakudan_blackboard:entries(BB0)),
    true = Before > 0,

    %% Kill the run statem; one_for_all restarts the children and the new
    %% statem must rehydrate from the snapshot and restore the transcript.
    {ok, #{run_statem := StatemPid}} = gakudan_registry:lookup(RunId),
    MRef = erlang:monitor(process, StatemPid),
    exit(StatemPid, kill),
    receive
        {'DOWN', MRef, process, StatemPid, _} -> ok
    after 2000 -> ct:fail(statem_not_killed)
    end,

    ok = wait_until_idle(RunId, 5000),
    {ok, BB1} = gakudan_run:blackboard(RunId),
    After = length(gakudan_blackboard:entries(BB1)),
    true = After >= Before,

    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

auto_continues_running_fanout_on_resume(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"resumed-output"}]),
    RunId = ~"run-autocont",
    Config = #{
        run_id => RunId,
        agents => [agent_a_mod, agent_b_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 4
    },
    %% A snapshot captured mid-fanout: agent_a was dispatched as turn 1 but
    %% never finished, and the router state is already past that decision.
    {ok, R0} = gakudan_router_round_robin:init(#{}, [agent_a, agent_b]),
    {next, agent_a, R1} = gakudan_router_round_robin:next(R0, []),
    Snapshot = #{
        run_id => RunId,
        status => running,
        config => Config,
        last_step => 0,
        blackboard => [#{seq => 1, role => user, content => ~"go", ts => 0}],
        kv => #{},
        router_state => R1,
        statem_state => running,
        turn => 0,
        fanout => #{base => 0, agents => [agent_a]},
        updated_at => erlang:system_time(millisecond)
    },
    {ok, _Sup, RunId} = gakudan_runs_sup:resume_run(Config, Snapshot),
    {ok, Entries} = gakudan:await(RunId, 5000),
    %% The in-flight fanout re-ran: agent_a produced its output after resume.
    AgentAOutputs = [
        maps:get(content, E)
     || E <- Entries, maps:get(role, E) =:= {agent, agent_a}
    ],
    true = lists:member(~"resumed-output", AgentAOutputs),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

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

wait_until_idle(RunId, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_until_idle_loop(RunId, Deadline).

wait_until_idle_loop(RunId, Deadline) ->
    Status =
        try
            gakudan:status(RunId)
        catch
            _:_ -> retry
        end,
    case Status of
        {ok, idle} ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    ct:fail(not_idle_after_restart);
                false ->
                    timer:sleep(50),
                    wait_until_idle_loop(RunId, Deadline)
            end
    end.
