-module(gakudan_context).
-moduledoc """
Pre-LLM transcript-transform behaviour: context compaction.

Today the full blackboard transcript is replayed to the model on every
turn. For a long-running run that is a cost and context-window cliff. A
context transform runs over the transcript just before messages are built,
returning a (usually shorter) transcript to send. Summarisation, sliding
windows, and token trimming all fit this seam without warping core.

A transform is a `{module(), Opts}` ref. The default,
`gakudan_context_trim`, drops oldest entries to fit an approximate token
budget while preserving the most recent context. Bring your own module to
summarise, embed-and-retrieve, or apply a domain policy.

The transform is configured per run via `context => {Module, Opts}` in the
run config (or the `default_context` application env). It receives the
transcript entries and a context map describing the run, and must return a
list of entries in chronological order. It must not mutate the blackboard;
the returned list only shapes what this turn sends.

See [ADR 0019](docs/adr/0019-context-compaction.md).
""".

-export([apply/3]).

-export_type([ref/0, ctx/0]).

-type ref() :: {module(), Opts :: map()}.
-type ctx() :: #{
    run_id := gakudan:run_id(),
    agent_id := gakudan_agent:id(),
    turn := non_neg_integer(),
    model := binary()
}.

-doc """
Transform a transcript before it becomes LLM messages. Returns the
entries to send, in chronological order.
""".
-callback compact([gakudan_blackboard:entry()], ctx(), Opts :: map()) ->
    [gakudan_blackboard:entry()].

-doc """
Run a context-transform ref over `Entries`. `undefined` passes the
transcript through unchanged.
""".
-spec apply(undefined | ref(), [gakudan_blackboard:entry()], ctx()) ->
    [gakudan_blackboard:entry()].
apply(undefined, Entries, _Ctx) ->
    Entries;
apply({Mod, Opts}, Entries, Ctx) ->
    Mod:compact(Entries, Ctx, Opts).
