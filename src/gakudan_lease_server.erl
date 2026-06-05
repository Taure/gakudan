-module(gakudan_lease_server).
-moduledoc """
Periodic run-lease manager for horizontal scale-out (ADR 0023).

Started under `gakudan_sup` only when `gakudan_lease:enabled()`. On a timer it
(a) claims active runs that are unowned or whose lease has expired and resumes
each locally, and (b) renews the leases on runs live on this node, signalling
any it has lost so the run fences itself.

Coordination is entirely through the shared checkpointer store; nodes never
talk to each other. See ADR 0023.
""".

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    OwnerId = gakudan_lease:owner_id(),
    self() ! claim,
    self() ! renew,
    {ok, #{owner => OwnerId}}.

handle_call(_Msg, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(claim, State) ->
    do_claim(State),
    _ = erlang:send_after(gakudan_lease:claim_interval_ms(), self(), claim),
    {noreply, State};
handle_info(renew, State) ->
    do_renew(State),
    _ = erlang:send_after(gakudan_lease:renew_interval_ms(), self(), renew),
    {noreply, State};
handle_info(_Msg, State) ->
    {noreply, State}.

do_claim(#{owner := OwnerId}) ->
    with_handle(fun(Handle) ->
        Opts = #{lease_ttl_ms => gakudan_lease:ttl_ms(), limit => gakudan_lease:claim_batch()},
        case gakudan_checkpointer:claim_runs(Handle, OwnerId, Opts) of
            {ok, []} ->
                ok;
            {ok, Snapshots} ->
                Resumed = [ok || S <- Snapshots, resume_claimed(S) =:= ok],
                case Resumed of
                    [] ->
                        ok;
                    _ ->
                        telemetry:execute(
                            [gakudan, lease, claimed],
                            #{count => length(Resumed)},
                            #{owner_id => OwnerId}
                        )
                end;
            {error, not_supported} ->
                ok;
            {error, Reason} ->
                ?LOG_WARNING(#{event => gakudan_lease_claim_failed, reason => Reason})
        end
    end).

resume_claimed(#{run_id := RunId, config := Config} = Snapshot) ->
    case gakudan_registry:lookup(RunId) of
        {ok, _} ->
            already_running;
        {error, not_found} ->
            case gakudan_runs_sup:resume_run(Config, Snapshot) of
                {ok, _Sup, _RunId} ->
                    ok;
                {error, Reason} ->
                    ?LOG_WARNING(#{
                        event => gakudan_lease_resume_failed, run_id => RunId, reason => Reason
                    }),
                    error
            end
    end.

do_renew(#{owner := OwnerId}) ->
    case [RunId || {RunId, _} <- gakudan_registry:all()] of
        [] ->
            ok;
        LocalIds ->
            with_handle(fun(Handle) ->
                case
                    gakudan_checkpointer:renew_leases(
                        Handle, OwnerId, LocalIds, gakudan_lease:ttl_ms()
                    )
                of
                    {ok, Held} ->
                        telemetry:execute(
                            [gakudan, lease, renewed],
                            #{count => length(Held)},
                            #{owner_id => OwnerId}
                        ),
                        lists:foreach(fun fence/1, LocalIds -- Held);
                    {error, not_supported} ->
                        ok;
                    {error, Reason} ->
                        telemetry:execute(
                            [gakudan, lease, renew, failed],
                            #{count => 1},
                            #{owner_id => OwnerId, reason => Reason}
                        ),
                        ?LOG_WARNING(#{event => gakudan_lease_renew_failed, reason => Reason})
                end
            end)
    end.

%% Tell the run to fence itself; the statem stops the whole run and emits the
%% lost telemetry. Signalling beats stopping it from here, so all teardown
%% goes through one path in the statem.
fence(RunId) ->
    case gakudan_registry:lookup(RunId) of
        {ok, #{run_statem := Pid}} -> Pid ! gakudan_lease_lost;
        {error, not_found} -> ok
    end.

with_handle(Fun) ->
    case application:get_env(gakudan, default_checkpointer, undefined) of
        undefined ->
            ok;
        {Mod, Opts} ->
            case gakudan_checkpointer:init(Mod, Opts) of
                {ok, Handle} ->
                    Fun(Handle);
                {error, Reason} ->
                    ?LOG_ERROR(#{event => gakudan_lease_init_failed, reason => Reason})
            end
    end.
