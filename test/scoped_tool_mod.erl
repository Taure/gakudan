-module(scoped_tool_mod).
-moduledoc false.
-behaviour(gakudan_tool).

-export([spec/1, run/2]).

spec(_Opts) ->
    #{
        name => ~"whoami",
        description => ~"Reports the namespace this tool instance was scoped to.",
        input_schema => #{type => ~"object", properties => #{}}
    }.

%% Reports its scope directly to the test rather than through the transcript:
%% tool output returns to the model as a tool_result block, not as searchable
%% transcript text.
run(_Input, #{namespace := NS} = Opts) ->
    case maps:get(report_to, Opts, undefined) of
        undefined -> ok;
        Pid -> Pid ! {tool_scoped_to, NS}
    end,
    {ok, NS}.
