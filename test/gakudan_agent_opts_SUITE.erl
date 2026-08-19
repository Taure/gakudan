-module(gakudan_agent_opts_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    tools_are_scoped_per_run/1,
    tools_zero_still_works/1
]).

all() ->
    [tools_are_scoped_per_run, tools_zero_still_works].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(gakudan),
    Config.

end_per_suite(_Config) ->
    ok = application:stop(gakudan),
    ok.

%% The same agent MODULE, two runs, two namespaces. Before agent opts were
%% threaded through, tools/0 fixed them at compile time and this was
%% unreachable without letting the model choose its own namespace - which is a
%% tenant-crossing hazard, not a feature.
tools_are_scoped_per_run(_Config) ->
    ?assertEqual(~"tenant-a", namespace_seen_by_tool(~"tenant-a")),
    ?assertEqual(~"tenant-b", namespace_seen_by_tool(~"tenant-b")).

tools_zero_still_works(_Config) ->
    {ok, Script} = gakudan_llm_stub_script:start_link([{text, ~"ack"}]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [agent_with_tool_mod],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 1
    }),
    ok = gakudan:send(RunId, ~"go"),
    {ok, _} = gakudan:await(RunId, 5000),
    ok = gakudan:stop(RunId),
    gen_server:stop(Script).

namespace_seen_by_tool(NS) ->
    Name = ~"whoami",
    {ok, Script} = gakudan_llm_stub_script:start_link([
        {tool_use, Name, #{}},
        {text, ~"done"}
    ]),
    {ok, _Sup, RunId} = gakudan:start_run(#{
        agents => [{agent_scoped_tools_mod, #{namespace => NS, report_to => self()}}],
        router => {gakudan_router_round_robin, #{}},
        llm => {gakudan_llm_stub, #{script_owner => Script}},
        max_turns => 2
    }),
    ok = gakudan:send(RunId, ~"who are you"),
    {ok, _} = gakudan:await(RunId, 5000),
    Seen =
        receive
            {tool_scoped_to, Got} -> Got
        after 5000 -> tool_never_ran
        end,
    ok = gakudan:stop(RunId),
    gen_server:stop(Script),
    Seen.
