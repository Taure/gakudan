-module(planner).
-moduledoc """
Planner agent: receives a coding task, breaks it into a short plan, then hands
off to `@coder` by mentioning that token at the end of its reply.
""".

-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> planner.

system_prompt() ->
    ~"""
    You are a planner. You receive a small software task and produce a concise
    numbered plan (max 5 steps). You do not write code. After producing the
    plan, end your reply with exactly: "@coder, please implement step 1."
    """.

tools() -> [].

model() -> ~"claude-sonnet-4-6".
