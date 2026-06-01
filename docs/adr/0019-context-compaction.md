# 19. Context compaction hook

Date: 2026-06-01

## Status

Accepted.

## Context

`gakudan_turn` builds the LLM messages from the full blackboard transcript
on every turn. For a short collaboration that is fine; for a long-running
run it is a cost and context-window cliff - each turn re-sends and re-pays
for the entire history, and eventually overruns the model's window. Prompt
caching (ADR-era Anthropic work) softens the cost but not the window limit,
and does nothing for backends without caching.

The fix is to shrink what each turn sends. There are several valid
policies - sliding window, token-budget trim, LLM summarisation, embed-and-
retrieve - and which one fits is a host decision. Hard-coding any of them
in the turn would warp core for one policy and make the rest unreachable.

## Decision

- **Add a `gakudan_context` behaviour**: a single `compact(Entries, Ctx,
  Opts) -> Entries` callback that transforms the transcript just before it
  becomes LLM messages. It is a pure shaping step - it must not mutate the
  blackboard; the returned list only affects what this turn sends.
- **Invoke it in `gakudan_turn`** between reading the transcript and
  `transcript_to_messages/2`. `undefined` (the default) passes the
  transcript through unchanged, so existing runs are byte-for-byte
  identical.
- **Configure per run** via `context => {Module, Opts}` in the run config,
  or the `default_context` application env. Threaded through the run statem
  into the turn worker alongside audit / actor context.
- **Ship `gakudan_context_trim`** as the default: keep the newest entries
  that fit an approximate token budget (estimated as bytes/4, no tokeniser
  dependency), with an optional `keep_first` to pin the oldest N entries
  (e.g. a task brief). Newer behaviours - summarisation, retrieval - are
  drop-in alternatives implementing the same callback.

## Consequences

**Positive.**

- Long runs can stay off the cost / context cliff with a one-line config
  and zero host code (the default trim), or any custom policy via a module.
- Core is policy-free and unchanged for runs that do not opt in.
- The transform sees a run-describing `Ctx` (run_id, agent_id, turn,
  model), so a policy can vary by agent or model window.

**Negative.**

- The default trim is a heuristic: a bytes/4 token estimate is approximate
  and a `~p`-formatted estimate for structured blocks is rough. A host with
  a hard window needs a tokeniser-backed module.
- Trimming drops information the model would otherwise see; a naive budget
  can cut mid-conversation context. `keep_first` and custom summarising
  transforms mitigate this, but the trade-off is inherent to compaction.
- The transform runs every turn on the worker; an expensive transform (an
  LLM summarise call) adds latency to each turn. Such a transform should
  cache its own summaries keyed off transcript length.
