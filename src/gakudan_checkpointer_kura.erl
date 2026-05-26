-module(gakudan_checkpointer_kura).
-moduledoc """
Default `gakudan_checkpointer` impl backed by `kura`.

Works against any kura backend (`kura_postgres`, `kura_sqlite`, future
`kura_mysql`). The schema is held in two tables, `gakudan_runs` and
`gakudan_steps`. Snapshot blobs are stored as `term_to_binary`.

Configuration:

```erlang
{checkpointer, {gakudan_checkpointer_kura, #{repo => my_repo}}}
```

`my_repo` must be a module implementing `kura_repo`, configured under
the `kura` application env in the host application's `sys.config`.
""".

-behaviour(gakudan_checkpointer).

-include_lib("kura/include/kura.hrl").

-export([
    init/1,
    save_snapshot/2,
    load_snapshot/2,
    list_active/1,
    delete_run/2,
    save_step/2,
    load_step/3,
    save_tool_result/2,
    load_tool_result/3
]).

-export_type([state/0]).

-type state() :: #{repo := module()}.

-spec init(map()) -> {ok, state()} | {error, term()}.
init(#{repo := Repo}) when is_atom(Repo) ->
    {ok, #{repo => Repo}};
init(_) ->
    {error, {bad_config, missing_repo}}.

-spec save_snapshot(state(), gakudan_checkpointer:run_snapshot()) -> ok | {error, term()}.
save_snapshot(#{repo := Repo}, Snapshot) ->
    #{
        run_id := RunId,
        status := Status,
        last_step := LastStep,
        updated_at := UpdatedAt
    } = Snapshot,
    Now = system_time_datetime(UpdatedAt),
    StatusBin = status_to_binary(Status),
    Data = term_to_binary(Snapshot),
    Changes = #{
        run_id => RunId,
        status => StatusBin,
        last_step => LastStep,
        data => Data,
        updated_at => Now
    },
    case kura_repo_worker:get(Repo, gakudan_run_schema, RunId) of
        {ok, Existing} ->
            CS = kura_changeset:cast(
                gakudan_run_schema,
                Existing,
                Changes,
                [status, last_step, data, updated_at]
            ),
            normalise(kura_repo_worker:update(Repo, CS));
        {error, not_found} ->
            FullChanges = Changes#{inserted_at => Now},
            CS = kura_changeset:cast(
                gakudan_run_schema,
                #{},
                FullChanges,
                [run_id, status, last_step, data, updated_at, inserted_at]
            ),
            normalise(kura_repo_worker:insert(Repo, CS));
        {error, _} = Err ->
            Err
    end.

-spec load_snapshot(state(), gakudan:run_id()) ->
    {ok, gakudan_checkpointer:run_snapshot()} | {error, not_found | term()}.
load_snapshot(#{repo := Repo}, RunId) ->
    case kura_repo_worker:get(Repo, gakudan_run_schema, RunId) of
        {ok, #{data := Blob}} ->
            {ok, binary_to_term(Blob)};
        {error, _} = Err ->
            Err
    end.

-spec list_active(state()) -> {ok, [gakudan:run_id()]} | {error, term()}.
list_active(#{repo := Repo}) ->
    Active = [~"running", ~"idle", ~"awaiting_human"],
    Q0 = kura_query:from(gakudan_run_schema),
    Q1 = kura_query:where(Q0, {status, in, Active}),
    Q2 = kura_query:select(Q1, [run_id]),
    case kura_repo_worker:all(Repo, Q2) of
        {ok, Rows} -> {ok, [RunId || #{run_id := RunId} <- Rows]};
        {error, _} = Err -> Err
    end.

-spec delete_run(state(), gakudan:run_id()) -> ok | {error, term()}.
delete_run(#{repo := Repo}, RunId) ->
    StepQ = kura_query:where(kura_query:from(gakudan_step_schema), {run_id, '=', RunId}),
    _ = kura_repo_worker:delete_all(Repo, StepQ),
    ToolQ = kura_query:where(kura_query:from(gakudan_tool_result_schema), {run_id, '=', RunId}),
    _ = kura_repo_worker:delete_all(Repo, ToolQ),
    RunQ = kura_query:where(kura_query:from(gakudan_run_schema), {run_id, '=', RunId}),
    case kura_repo_worker:delete_all(Repo, RunQ) of
        {ok, _N} -> ok;
        {error, _} = Err -> Err
    end.

-spec save_step(state(), gakudan_checkpointer:step_record()) -> ok | {error, term()}.
save_step(#{repo := Repo}, Step) ->
    #{
        run_id := RunId,
        step_id := StepId,
        agent_id := AgentId,
        turn := Turn,
        usage := Usage,
        inserted_at := InsertedAt
    } = Step,
    Now = system_time_datetime(InsertedAt),
    Changes = #{
        step_id => StepId,
        run_id => RunId,
        agent_id => atom_to_binary(AgentId),
        turn => Turn,
        tokens_in => maps:get(input_tokens, Usage, 0),
        tokens_out => maps:get(output_tokens, Usage, 0),
        data => term_to_binary(Step),
        inserted_at => Now
    },
    CS = kura_changeset:cast(
        gakudan_step_schema,
        #{},
        Changes,
        [step_id, run_id, agent_id, turn, tokens_in, tokens_out, data, inserted_at]
    ),
    normalise(kura_repo_worker:insert(Repo, CS)).

-spec load_step(state(), gakudan:run_id(), binary()) ->
    {ok, gakudan_checkpointer:step_record()} | {error, not_found}.
load_step(#{repo := Repo}, _RunId, StepId) ->
    case kura_repo_worker:get(Repo, gakudan_step_schema, StepId) of
        {ok, #{data := Blob}} -> {ok, binary_to_term(Blob)};
        {error, not_found} = NF -> NF;
        {error, _} -> {error, not_found}
    end.

-spec save_tool_result(state(), gakudan_checkpointer:tool_result_record()) -> ok | {error, term()}.
save_tool_result(#{repo := Repo}, Record) ->
    #{
        run_id := RunId,
        tool_step_id := ToolStepId,
        agent_id := AgentId,
        turn := Turn,
        tool_name := ToolName,
        inserted_at := InsertedAt
    } = Record,
    Now = system_time_datetime(InsertedAt),
    Changes = #{
        tool_step_id => ToolStepId,
        run_id => RunId,
        agent_id => atom_to_binary(AgentId),
        turn => Turn,
        tool_name => ToolName,
        data => term_to_binary(Record),
        inserted_at => Now
    },
    CS = kura_changeset:cast(
        gakudan_tool_result_schema,
        #{},
        Changes,
        [tool_step_id, run_id, agent_id, turn, tool_name, data, inserted_at]
    ),
    normalise(kura_repo_worker:insert(Repo, CS)).

-spec load_tool_result(state(), gakudan:run_id(), binary()) ->
    {ok, gakudan_checkpointer:tool_result_record()} | {error, not_found}.
load_tool_result(#{repo := Repo}, _RunId, ToolStepId) ->
    case kura_repo_worker:get(Repo, gakudan_tool_result_schema, ToolStepId) of
        {ok, #{data := Blob}} -> {ok, binary_to_term(Blob)};
        {error, not_found} = NF -> NF;
        {error, _} -> {error, not_found}
    end.

normalise({ok, _}) -> ok;
normalise({error, _} = Err) -> Err.

status_to_binary(pending) -> ~"pending";
status_to_binary(running) -> ~"running";
status_to_binary(idle) -> ~"idle";
status_to_binary(awaiting_human) -> ~"awaiting_human";
status_to_binary(completed) -> ~"completed";
status_to_binary({error, _}) -> ~"error".

system_time_datetime(Ms) when is_integer(Ms) ->
    calendar:system_time_to_universal_time(Ms, millisecond).
