-module(agent_b_mod).
-moduledoc false.
-behaviour(gakudan_agent).
-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> agent_b.
system_prompt() -> ~"You are agent B.".
tools() -> [].
model() -> ~"stub".
