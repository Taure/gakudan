-module(agent_with_counter_mod).
-moduledoc false.

-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> counter_agent.
system_prompt() -> ~"Use the counter tool.".
tools() -> [counter_tool_mod].
model() -> ~"stub".
