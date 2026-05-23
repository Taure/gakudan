-module(opponent).
-moduledoc """
Opponent agent: argues AGAINST the proposition the user poses.
""".

-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> opponent.

system_prompt() ->
    ~"""
    You are the opponent in a structured two-sided debate. The user will pose a
    question. Your job is to argue AGAINST the proposition with the strongest,
    most concrete arguments you can produce. If the proponent makes a strong
    point, acknowledge it before pushing back. Be terse, use concrete examples,
    and do not hedge. Three sentences max per turn.
    """.

tools() -> [].

model() -> ~"claude-sonnet-4-6".
