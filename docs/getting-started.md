# Getting started

This guide takes you from "no project" to "your own three-agent pipeline running
against the real Anthropic API". The 60-second tour in the [README](../README.md)
is the prerequisite — read it first so you have the included demos in your head.

## Add gakudan to your project

```erlang
%% rebar.config
{deps, [
    {gakudan, {git, "https://github.com/Taure/gakudan.git", {tag, "v0.1.4"}}}
]}.
```

Then in your `.app.src`:

```erlang
{applications, [kernel, stdlib, gakudan]}.
```

That's it. Gakudan boots its supervision tree the moment you call
`application:ensure_all_started(gakudan)`.

## Your first agent

An agent is just an Erlang module implementing the `gakudan_agent` behaviour —
four callbacks, no state.

```erlang
-module(my_planner).
-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> planner.

system_prompt() ->
    ~"""
    You are a planner. Read the user's request and produce a short list of
    concrete steps. One step per line. Don't write code.
    """.

tools() -> [].

model() -> ~"claude-sonnet-4-6".
```

`id/0` is the atom the router uses to refer to this agent. It does **not** have
to match the module name — `my_app_agent_risk` can declare `id() -> risk` and
the router will see it as `risk`.

## Run it

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [my_planner],
    router => {gakudan_router_round_robin, #{}},
    llm    => {gakudan_llm_stub, #{script => [~"Step 1: ...\nStep 2: ..."]}}
}),
ok = gakudan:send(RunId, ~"Write me a TCP echo server in Erlang."),
{ok, Entries} = gakudan:await(RunId, 5_000).
```

`gakudan_llm_stub` returns the next response from `script` on each call — no
network, no key, fully deterministic. Use it everywhere you would otherwise
need a real model: in unit tests, in CI, in evals.

## Add a second agent

A second agent is another module. Wire both into the same run and pick a
router that knows what to do with them.

```erlang
-module(my_coder).
-behaviour(gakudan_agent).

-export([id/0, system_prompt/0, tools/0, model/0]).

id() -> coder.

system_prompt() ->
    ~"""
    You are a coder. Read the plan above and write Erlang code to implement
    step 1. Output one self-contained module.
    """.

tools() -> [].

model() -> ~"claude-sonnet-4-6".
```

`gakudan_router_handoff` runs one agent at a time and switches when the agent
emits a `@<id>` token. Make the planner end with `@coder`:

```erlang
{ok, _Pid, RunId} = gakudan:start_run(#{
    agents => [my_planner, my_coder],
    router => {gakudan_router_handoff, #{start => planner}},
    llm    => {gakudan_llm_anthropic, #{}}     %% real API now
}),
ok = gakudan:send(RunId, ~"Write me a TCP echo server."),
{ok, Entries} = gakudan:await(RunId, 60_000).
```

`Entries` is the full transcript: a list of `#{role, agent, content, ...}`
maps you can render or inspect.

## Add a tool

Tools are JSON-schema-described callbacks the LLM can invoke mid-turn. Same
shape as Anthropic / OpenAI tool-use.

```erlang
-module(my_write_snippet_tool).
-behaviour(gakudan_tool).

-export([spec/0, run/1]).

spec() ->
    #{
        name => ~"write_snippet",
        description => ~"Save a code snippet to the working directory.",
        input_schema => #{
            type => ~"object",
            properties => #{
                filename => #{type => ~"string"},
                contents => #{type => ~"string"}
            },
            required => [~"filename", ~"contents"]
        }
    }.

run(#{~"filename" := Name, ~"contents" := Body}) ->
    ok = file:write_file(Name, Body),
    {ok, iolist_to_binary([~"Wrote ", Name])}.
```

Make the coder advertise it:

```erlang
%% my_coder.erl
tools() -> [my_write_snippet_tool].
```

That's the whole loop. The LLM sees the tool's JSON schema, decides when to
call it, and gakudan runs `my_write_snippet_tool:run/1` with the parsed
arguments before handing the result back to the model on the same turn.

## Switch to the real Anthropic API

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

```erlang
llm => {gakudan_llm_anthropic, #{}}
```

The Anthropic backend marks the system prompt and tool definitions with
`cache_control: ephemeral` automatically, so multi-turn runs hit prompt
caching at ~10% of the uncached input-token rate.

For Gemini, swap in `gakudan_llm_gemini` and set `GEMINI_API_KEY`. Agents
declare their model via the `model/0` callback, so you can mix
`claude-sonnet-4-6` (your planner) with `claude-haiku-4-5` (cheap tool-using
coder) in the same run.

## What to read next

- [`architecture.md`](architecture.md) — the supervision tree, the
  blackboard, and how a turn actually executes.
- [`examples/debate`](../examples/debate) — three agents, a custom router,
  and an eval suite. The 60-second tour example.
- [`examples/planner_coder`](../examples/planner_coder) — the two-agent
  handoff with a tool, real-world shape.
- The `gakudan_eval` module — drives a run with a scripted LLM and asserts
  against the transcript. Drop-in for CT or eunit, zero API cost.
