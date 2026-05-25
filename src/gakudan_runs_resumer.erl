-module(gakudan_runs_resumer).
-moduledoc """
Boots after `gakudan_runs_sup`, asks the configured default checkpointer
for the set of in-flight runs (`running`, `idle`, `awaiting_human`), and
respawns each one. See ADR 0004.

One bad snapshot must not block the rest: a failed resume is logged,
marked `{error, resume_failed}` in the checkpointer, and skipped.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_continue/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, #{}, {continue, resume}}.

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_continue(resume, State) ->
    do_resume(),
    {noreply, State}.

do_resume() ->
    case application:get_env(gakudan, default_checkpointer, undefined) of
        undefined ->
            ok;
        {Mod, Opts} ->
            case gakudan_checkpointer:init(Mod, Opts) of
                {ok, Handle} ->
                    resume_all(Handle);
                {error, Reason} ->
                    ?LOG_ERROR(#{
                        event => gakudan_resumer_init_failed,
                        backend => Mod,
                        reason => Reason
                    })
            end
    end.

resume_all(Handle) ->
    case gakudan_checkpointer:list_active(Handle) of
        {ok, RunIds} ->
            lists:foreach(fun(RunId) -> resume_one(Handle, RunId) end, RunIds);
        {error, Reason} ->
            ?LOG_ERROR(#{event => gakudan_list_active_failed, reason => Reason})
    end.

resume_one(Handle, RunId) ->
    StartMeta = #{run_id => RunId},
    telemetry:execute(
        [gakudan, resume, attempted],
        #{system_time => erlang:system_time()},
        StartMeta
    ),
    case gakudan_checkpointer:load_snapshot(Handle, RunId) of
        {ok, Snapshot} ->
            try_resume(Handle, Snapshot);
        {error, Reason} ->
            ?LOG_ERROR(#{
                event => gakudan_resume_load_failed,
                run_id => RunId,
                reason => Reason
            }),
            telemetry:execute(
                [gakudan, resume, failed],
                #{system_time => erlang:system_time()},
                StartMeta#{reason => Reason}
            )
    end.

try_resume(Handle, #{run_id := RunId, config := Config} = Snapshot) ->
    StartMeta = #{run_id => RunId},
    try gakudan_runs_sup:resume_run(Config, Snapshot) of
        {ok, _Sup, _RunId} ->
            telemetry:execute(
                [gakudan, resume, succeeded],
                #{system_time => erlang:system_time()},
                StartMeta
            );
        {error, Reason} ->
            mark_failed(Handle, Snapshot, Reason),
            telemetry:execute(
                [gakudan, resume, failed],
                #{system_time => erlang:system_time()},
                StartMeta#{reason => Reason}
            )
    catch
        Class:Reason:_ST ->
            mark_failed(Handle, Snapshot, {Class, Reason}),
            telemetry:execute(
                [gakudan, resume, failed],
                #{system_time => erlang:system_time()},
                StartMeta#{reason => {Class, Reason}}
            )
    end.

mark_failed(Handle, Snapshot, Reason) ->
    ?LOG_ERROR(#{
        event => gakudan_resume_failed,
        run_id => maps:get(run_id, Snapshot),
        reason => Reason
    }),
    Failed = Snapshot#{
        status => {error, resume_failed},
        updated_at => erlang:system_time(millisecond)
    },
    _ = gakudan_checkpointer:save_snapshot(Handle, Failed),
    ok.
