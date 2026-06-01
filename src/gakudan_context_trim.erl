-module(gakudan_context_trim).
-moduledoc """
Default context transform: token-budget trimming.

Keeps the most recent transcript entries that fit an approximate token
budget, dropping the oldest first. Token count is estimated from byte
size (`~chars/4`), which is a deliberate dependency-free heuristic - good
enough to keep a run off the context cliff without pulling in a tokeniser.

Opts:
- `max_tokens => pos_integer()` - approximate budget (default 8000).
- `keep_first => non_neg_integer()` - always retain this many oldest
  entries (e.g. a task brief). Default 0.

The `keep_first` entries plus the newest entries that fit the remaining
budget are returned in chronological order. A run that is already under
budget passes through unchanged. See
[ADR 0019](docs/adr/0019-context-compaction.md).
""".

-behaviour(gakudan_context).

-export([compact/3]).
-export([estimate_tokens/1]).

-define(DEFAULT_MAX_TOKENS, 8000).
-define(CHARS_PER_TOKEN, 4).

-doc "Trim `Entries` to fit the token budget. See `m:gakudan_context`.".
-spec compact([gakudan_blackboard:entry()], gakudan_context:ctx(), map()) ->
    [gakudan_blackboard:entry()].
compact(Entries, _Ctx, Opts) ->
    Max = maps:get(max_tokens, Opts, ?DEFAULT_MAX_TOKENS),
    KeepFirst = maps:get(keep_first, Opts, 0),
    {Pinned, Rest} = split_pinned(Entries, KeepFirst),
    PinnedTokens = total_tokens(Pinned),
    Budget = max(0, Max - PinnedTokens),
    Kept = keep_newest_within(lists:reverse(Rest), Budget, []),
    Pinned ++ Kept.

split_pinned(Entries, KeepFirst) ->
    case KeepFirst >= length(Entries) of
        true -> {Entries, []};
        false -> lists:split(KeepFirst, Entries)
    end.

%% Walk newest-first, accumulating until the next entry would overflow the
%% budget. Returns the kept entries restored to chronological order.
keep_newest_within([], _Budget, Acc) ->
    Acc;
keep_newest_within([Entry | Older], Budget, Acc) ->
    Cost = entry_tokens(Entry),
    case Cost =< Budget of
        true -> keep_newest_within(Older, Budget - Cost, [Entry | Acc]);
        false -> Acc
    end.

total_tokens(Entries) ->
    lists:sum([entry_tokens(E) || E <- Entries]).

entry_tokens(#{content := Content}) ->
    estimate_tokens(Content).

-doc "Approximate token count for a piece of content (~chars/4).".
-spec estimate_tokens(binary() | [map()] | term()) -> non_neg_integer().
estimate_tokens(Content) when is_binary(Content) ->
    (byte_size(Content) + ?CHARS_PER_TOKEN - 1) div ?CHARS_PER_TOKEN;
estimate_tokens(Content) when is_list(Content) ->
    lists:sum([estimate_tokens(Block) || Block <- Content]);
estimate_tokens(Block) when is_map(Block) ->
    estimate_tokens(iolist_to_binary(io_lib:format("~p", [Block])));
estimate_tokens(_Other) ->
    0.
