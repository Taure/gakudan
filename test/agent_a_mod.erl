-module(agent_a_mod).
-moduledoc false.
-behaviour(gakudan_agent).
-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> agent_a.
system_prompt() -> ~"You are agent A.".
tools() -> [].
model() -> ~"stub".
