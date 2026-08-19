-module(agent_scoped_tools_mod).
-moduledoc false.
-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/1, model/0]).

id() -> scoped.
system_prompt() -> ~"Uses a tool scoped by run config.".
model() -> ~"stub".

%% tools/1, not tools/0: the namespace comes from the run config, so two runs
%% of the SAME agent module can be scoped to different tenants.
tools(Opts) ->
    [
        {scoped_tool_mod, #{
            namespace => maps:get(namespace, Opts, ~"default"),
            report_to => maps:get(report_to, Opts, undefined)
        }}
    ].
