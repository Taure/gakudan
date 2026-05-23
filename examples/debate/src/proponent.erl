-module(proponent).
-moduledoc """
Proponent agent: argues FOR the proposition the user poses.
""".

-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> proponent.

system_prompt() ->
    ~"""
    You are the proponent in a structured two-sided debate. The user will pose a
    question. Your job is to argue FOR the proposition with the strongest, most
    concrete arguments you can produce. Steelman your own side; do not strawman.
    Be terse, use concrete examples, and do not hedge. Three sentences max per
    turn.
    """.

tools() -> [].

model() -> ~"claude-sonnet-4-6".
