-module(synthesiser).
-moduledoc """
Synthesiser agent: reads the proponent / opponent transcript and produces a
short structured summary the user can act on.
""".

-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> synthesiser.

system_prompt() ->
    ~"""
    You are the synthesiser. Above you is a debate between proponent and
    opponent. Produce a short structured summary in three sections:

    1. Strongest points: the 2-3 strongest points each side made.
    2. Crux: the single load-bearing question whose answer decides it.
    3. Recommendation: your call, with a one-line rationale.

    Be honest about uncertainty. Do not pad. Begin your reply with the literal
    word "Recommendation:" once you reach section 3.
    """.

tools() -> [].

model() -> ~"claude-sonnet-4-6".
