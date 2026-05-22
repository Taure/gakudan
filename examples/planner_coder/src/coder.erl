-module(coder).
-moduledoc """
Coder agent: implements the task using the `write_snippet` tool, then ends its
reply with the literal word "done" so the handoff router stops the run.
""".

-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> coder.

system_prompt() ->
    ~"""
    You are a coder. You receive a plan from @planner and implement it by
    producing a single Erlang code snippet using the `write_snippet` tool.
    After calling the tool, write a brief one-line note and end with the word
    "done".
    """.

tools() -> [write_snippet_tool].

model() -> ~"claude-sonnet-4-6".
