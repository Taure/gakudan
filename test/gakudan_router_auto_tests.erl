-module(gakudan_router_auto_tests).
-include_lib("eunit/include/eunit.hrl").

entry(Agent, Text) ->
    #{seq => 1, role => {agent, Agent}, content => Text, ts => 0}.

starts_with_configured_agent_test() ->
    {ok, S0} = gakudan_router_auto:init(#{start => a}, [a, b, c]),
    {next, a, _S1} = gakudan_router_auto:next(S0, []).

last_speaker_selects_next_test() ->
    {ok, S0} = gakudan_router_auto:init(#{start => a}, [a, b, c]),
    {next, a, S1} = gakudan_router_auto:next(S0, []),
    {next, c, S2} = gakudan_router_auto:next(S1, [entry(a, ~"handing over. next: c")]),
    {next, b, _} = gakudan_router_auto:next(S2, [
        entry(a, ~"next: c"),
        entry(c, ~"my turn done. next: b")
    ]).

done_directive_ends_run_test() ->
    {ok, S0} = gakudan_router_auto:init(#{start => a}, [a, b]),
    {next, a, S1} = gakudan_router_auto:next(S0, []),
    {done, _} = gakudan_router_auto:next(S1, [entry(a, ~"all done here")]).

no_directive_goes_idle_test() ->
    {ok, S0} = gakudan_router_auto:init(#{start => a}, [a, b]),
    {next, a, S1} = gakudan_router_auto:next(S0, []),
    {done, _} = gakudan_router_auto:next(S1, [entry(a, ~"just some text")]).

restricts_to_selectable_set_test() ->
    {ok, S0} = gakudan_router_auto:init(#{start => a, agents => [b]}, [a, b, c]),
    {next, a, S1} = gakudan_router_auto:next(S0, []),
    %% c is not selectable, so the directive is ignored -> done.
    {done, _} = gakudan_router_auto:next(S1, [entry(a, ~"next: c")]).

unknown_start_rejected_test() ->
    ?assertError(
        {auto_router_unknown_start, _, _},
        gakudan_router_auto:init(#{start => z}, [a, b])
    ).
