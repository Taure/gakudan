-module(agent_with_tool_mod).
-moduledoc false.
-behaviour(gakudan_agent).
-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> agent_t.
system_prompt() -> ~"You are an agent with one tool.".
tools() -> [echo_tool_mod].
model() -> ~"stub".
