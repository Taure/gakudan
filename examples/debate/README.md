# Debate example

A three-agent collaboration that pressure-tests a yes/no decision:

- `proponent` argues FOR the proposition.
- `opponent` argues AGAINST.
- `synthesiser` summarises both sides, names the crux, and recommends.

Demonstrates three things `planner_coder` does not:

1. **A custom router** (`debate_router`) that cycles the debaters for N rounds
   and then forces one synthesiser turn at the end. ~25 lines of behaviour
   code.
2. **Tool-free agents.** Sometimes the value is the structured disagreement,
   not the side-effects.
3. **An eval case** (`debate:eval_stub/0`) that asserts the canonical
   debate shape: both sides took their turns, the synthesiser ran last, the
   substantive substrings appeared.

## Try it

Offline, no API key:

```bash
rebar3 as example shell
1> application:ensure_all_started(gakudan).
2> debate:run_stub().
3> {ok, _} = debate:eval_stub().
```

Against the real Anthropic API (needs `ANTHROPIC_API_KEY`):

```bash
rebar3 as example shell
1> application:ensure_all_started(gakudan).
2> debate:run(~"Should gakudan eval cases support JSON in v0.2?").
```

Swap the question for whatever decision you are actually sitting on.
